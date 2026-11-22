//! Minimal XML-DSig primitives for SAML (RSA-SHA256/PKCS1v1_5).
//!
//! This module verifies a signature over already-canonicalized SignedInfo
//! bytes and validates the algorithm URIs used by a SAML signature. Locating
//! Signature nodes and computing Reference digests is done by the caller.
const std = @import("std");
const pem = @import("pem.zig");

pub const DsigError = error{
    UnsupportedAlgorithm,
    InvalidSignature,
    InvalidSignatureLength,
};

pub const Algorithm = enum { rsa_sha256, rsa_sha1 };

/// Parse a SignatureMethod Algorithm URI. SHA-1 is opt-in and disabled by default.
pub fn signatureAlgorithm(uri: []const u8, allow_sha1: bool) DsigError!Algorithm {
    if (std.mem.eql(u8, uri, "http://www.w3.org/2001/04/xmldsig-more#rsa-sha256")) return .rsa_sha256;
    if (allow_sha1 and std.mem.eql(u8, uri, "http://www.w3.org/2000/09/xmldsig#rsa-sha1")) return .rsa_sha1;
    return error.UnsupportedAlgorithm;
}

/// Only exclusive c14n 1.0 is accepted for SignedInfo / Reference transforms.
pub fn canonicalizationAllowed(uri: []const u8) bool {
    return std.mem.eql(u8, uri, "http://www.w3.org/2001/10/xml-exc-c14n#") or
        std.mem.eql(u8, uri, "http://www.w3.org/2001/10/xml-exc-c14n#WithComments");
}

/// Digest algorithms accepted for Reference/DigestMethod.
pub fn digestAllowed(uri: []const u8) bool {
    return std.mem.eql(u8, uri, "http://www.w3.org/2001/04/xmlenc#sha256");
}

/// Verify an enveloped RSA signature over canonicalized SignedInfo bytes.
pub fn verifyRsa(
    sig: []const u8,
    signed_info_c14n: []const u8,
    pubkey: std.crypto.Certificate.rsa.PublicKey,
    alg: Algorithm,
) DsigError!void {
    const Hash = switch (alg) {
        .rsa_sha256 => std.crypto.hash.sha2.Sha256,
        .rsa_sha1 => std.crypto.hash.sha1.Sha1,
    };
    const mod_len: usize = switch (pubkey.n.bits()) {
        0...2047 => return error.InvalidSignatureLength,
        2048...3071 => 256,
        3072...4095 => 384,
        4096...8192 => 512,
        else => return error.InvalidSignatureLength,
    };
    if (sig.len != mod_len) return error.InvalidSignatureLength;
    const sig_array: *const [mod_len]u8 = @ptrCast(sig.ptr);
    std.crypto.Certificate.rsa.PKCS1v1_5Signature.verify(mod_len, sig_array, signed_info_c14n, pubkey, Hash) catch return error.InvalidSignature;
}

test "dsig: algorithm URI allow-list" {
    try std.testing.expectEqual(.rsa_sha256, try signatureAlgorithm("http://www.w3.org/2001/04/xmldsig-more#rsa-sha256", false));
    try std.testing.expectError(error.UnsupportedAlgorithm, signatureAlgorithm("http://www.w3.org/2000/09/xmldsig#rsa-sha1", false));
    try std.testing.expectEqual(.rsa_sha1, try signatureAlgorithm("http://www.w3.org/2000/09/xmldsig#rsa-sha1", true));
    try std.testing.expect(canonicalizationAllowed("http://www.w3.org/2001/10/xml-exc-c14n#"));
    try std.testing.expect(!canonicalizationAllowed("http://www.w3.org/TR/2001/REC-xml-c14n-20010315"));
    try std.testing.expect(digestAllowed("http://www.w3.org/2001/04/xmlenc#sha256"));
    try std.testing.expect(!digestAllowed("http://www.w3.org/2000/09/xmldsig#sha1"));
}

pub const VerifyError = DsigError || error{
    SignatureNotFound,
    MultipleSignatures,
    UnsupportedTransform,
    MalformedSignature,
    OutOfMemory,
    Unexpected,
};

const xml = @import("xml.zig");
const c14n = @import("c14n.zig");

fn findAllSignatures(node: *const xml.Node, out: *std.ArrayList(*const xml.Node), a: std.mem.Allocator) !void {
    if (std.mem.eql(u8, node.local, "Signature") and std.mem.eql(u8, node.ns, "http://www.w3.org/2000/09/xmldsig#")) {
        try out.append(a, node);
    }
    for (node.children) |child| switch (child) {
        .element => |n| try findAllSignatures(n, out, a),
        else => {},
    };
}

fn childElement(node: *const xml.Node, local: []const u8) ?*const xml.Node {
    for (node.children) |child| switch (child) {
        .element => |n| if (std.mem.eql(u8, n.local, local)) return n,
        else => {},
    };
    return null;
}

fn attr(node: *const xml.Node, local: []const u8) ?[]const u8 {
    for (node.attrs) |a| if (std.mem.eql(u8, a.local, local)) return a.value;
    return null;
}

fn textOf(a: std.mem.Allocator, node: *const xml.Node) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(a);
    for (node.children) |child| switch (child) {
        .text => |t| try out.appendSlice(a, t),
        .element => |n| {
            const inner = try textOf(a, n);
            defer a.free(inner);
            try out.appendSlice(a, inner);
        },
    };
    return out.toOwnedSlice(a);
}

/// Find a single enveloped Signature, validate its algorithm URIs,
/// canonicalize SignedInfo with its inherited namespace context and verify
/// the RSA signature against one of the pinned certificates.
///
/// NOTE: Reference/DigestValue verification is not yet performed here; a
/// caller MUST check the digest before trusting assertion data. This function
/// only establishes that SignedInfo was signed by a pinned key.
pub fn verifySignature(
    a: std.mem.Allocator,
    doc: *const xml.Node,
    certs_der: []const []const u8,
    allow_sha1: bool,
) VerifyError!void {
    var sigs = std.ArrayList(*const xml.Node).empty;
    defer sigs.deinit(a);
    try findAllSignatures(doc, &sigs, a);
    if (sigs.items.len == 0) return error.SignatureNotFound;
    if (sigs.items.len != 1) return error.MultipleSignatures;
    const sig = sigs.items[0];

    const signed_info = childElement(sig, "SignedInfo") orelse return error.MalformedSignature;
    const canon_m = childElement(signed_info, "CanonicalizationMethod") orelse return error.MalformedSignature;
    const canon_uri = attr(canon_m, "Algorithm") orelse return error.MalformedSignature;
    if (!canonicalizationAllowed(canon_uri)) return error.UnsupportedTransform;
    const sig_m = childElement(signed_info, "SignatureMethod") orelse return error.MalformedSignature;
    const sig_uri = attr(sig_m, "Algorithm") orelse return error.MalformedSignature;
    const alg = signatureAlgorithm(sig_uri, allow_sha1) catch return error.UnsupportedAlgorithm;

    const ref = childElement(signed_info, "Reference") orelse return error.MalformedSignature;
    const digest_m = childElement(ref, "DigestMethod") orelse return error.MalformedSignature;
    const digest_uri = attr(digest_m, "Algorithm") orelse return error.MalformedSignature;
    if (!digestAllowed(digest_uri)) return error.UnsupportedAlgorithm;

    const sig_value = childElement(sig, "SignatureValue") orelse return error.MalformedSignature;
    const sig_b64 = textOf(a, sig_value) catch return error.OutOfMemory;
    defer a.free(sig_b64);
    const dec = std.base64.standard.Decoder;
    const sig_len = dec.calcSizeForSlice(sig_b64) catch return error.MalformedSignature;
    const sig_bytes = a.alloc(u8, sig_len) catch return error.OutOfMemory;
    defer a.free(sig_bytes);
    dec.decode(sig_bytes, sig_b64) catch return error.MalformedSignature;

    var inherited = std.ArrayList(xml.NsDecl).empty;
    defer inherited.deinit(a);
    xml.inheritedNamespaces(a, signed_info, null, &inherited) catch return error.OutOfMemory;
    const si_c14n = c14n.canonicalize(a, signed_info, inherited.items, .{}) catch return error.Unexpected;
    defer a.free(si_c14n);

    var last: ?VerifyError = null;
    for (certs_der) |der| {
        const pubkey = pem.rsaPublicKey(der) catch continue;
        verifyRsa(sig_bytes, si_c14n, pubkey, alg) catch |err| {
            last = err;
            continue;
        };
        return;
    }
    return last orelse error.InvalidSignature;
}
