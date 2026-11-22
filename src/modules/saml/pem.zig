//! PEM certificate helpers for SAML signature pinning.
const std = @import("std");

pub const PemError = error{
    MalformedPem,
    UnsupportedBlock,
    TooLarge,
    InvalidCertificate,
    OutOfMemory,
};

pub const Pin = struct {
    der: []const u8,
    fingerprint: [32]u8,

    pub fn free(self: Pin, a: std.mem.Allocator) void {
        a.free(self.der);
    }
};

/// Decode a single CERTIFICATE PEM block (cap 8 KiB DER).
pub fn decodeCertificate(a: std.mem.Allocator, pem: []const u8) PemError!Pin {
    if (std.mem.indexOf(u8, pem, "PRIVATE KEY") != null) return error.UnsupportedBlock;
    const begin = "-----BEGIN CERTIFICATE-----";
    const end = "-----END CERTIFICATE-----";
    const start = std.mem.indexOf(u8, pem, begin) orelse return error.MalformedPem;
    const after = start + begin.len;
    const stop_rel = std.mem.indexOf(u8, pem[after..], end) orelse return error.MalformedPem;
    // Reject a second certificate block after the first.
    if (std.mem.indexOf(u8, pem[after + stop_rel + end.len ..], begin) != null) return error.UnsupportedBlock;
    const body = pem[after .. after + stop_rel];
    var compact = std.ArrayList(u8).empty;
    defer compact.deinit(a);
    for (body) |c| switch (c) {
        ' ', '\t', '\r', '\n' => {},
        else => compact.append(a, c) catch return error.OutOfMemory,
    };
    const size = std.base64.standard.Decoder.calcSizeForSlice(compact.items) catch return error.MalformedPem;
    if (size == 0 or size > 8 * 1024) return error.TooLarge;
    const der = a.alloc(u8, size) catch return error.OutOfMemory;
    errdefer a.free(der);
    std.base64.standard.Decoder.decode(der, compact.items) catch return error.MalformedPem;
    var fp: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(der, &fp, .{});
    return .{ .der = der, .fingerprint = fp };
}

/// Parse RSA public key from a pinned DER certificate and enforce 2048-4096 bits.
pub fn rsaPublicKey(der: []const u8) PemError!std.crypto.Certificate.rsa.PublicKey {
    const parsed = std.crypto.Certificate.parse(.{ .buffer = der, .index = 0 }) catch return error.InvalidCertificate;
    const spki = parsed.publicKey() catch return error.InvalidCertificate;
    const parts = std.crypto.Certificate.rsa.PublicKey.parseDer(spki) catch return error.InvalidCertificate;
    if (parts.modulus.len < 256 or parts.modulus.len > 512) return error.InvalidCertificate;
    return std.crypto.Certificate.rsa.PublicKey.fromBytes(parts.exponent, parts.modulus) catch return error.InvalidCertificate;
}

test "pem: rejects private keys and multiple blocks" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.UnsupportedBlock, decodeCertificate(a, "-----BEGIN PRIVATE KEY-----x-----END PRIVATE KEY-----"));
    const block = "-----BEGIN CERTIFICATE-----QUJD-----END CERTIFICATE-----";
    const joined = try std.fmt.allocPrint(a, "{s}{s}", .{ block, block });
    defer a.free(joined);
    try std.testing.expectError(error.UnsupportedBlock, decodeCertificate(a, joined));
}

test "pem: decodes one certificate block" {
    const a = std.testing.allocator;
    const block = "-----BEGIN CERTIFICATE-----\nQUJD\n-----END CERTIFICATE-----";
    const pin = try decodeCertificate(a, block);
    defer pin.free(a);
    try std.testing.expectEqualStrings("ABC", pin.der);
}
