//! Minimal HS256 JWT signer for OIDC access/ID tokens.
//!
//! The existing `SecurityModule` hardcodes `iss="zigmodu"` and `aud=tenant`,
//! which is fine for the admin API but not OIDC (OIDC needs `iss` = the
//! configured issuer URL and `aud` = the client_id). This self-contained
//! signer gives full claim control while sharing the platform JWT secret.

const std = @import("std");

pub const Error = error{
    OutOfMemory,
    InvalidToken,
    TokenExpired,
    InvalidSignature,
};

const Enc = std.base64.url_safe_no_pad.Encoder;

fn b64encode(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const n = Enc.calcSize(bytes.len);
    const out = try allocator.alloc(u8, n);
    _ = Enc.encode(out, bytes);
    return out;
}

fn b64decode(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    const dec = std.base64.url_safe_no_pad.Decoder;
    const n = try dec.calcSizeForSlice(s);
    const out = try allocator.alloc(u8, n);
    errdefer allocator.free(out);
    try dec.decode(out, s);
    return out;
}

fn hmacSign(secret: []const u8, data: []const u8, out: *[32]u8) void {
    var h = std.crypto.auth.hmac.sha2.HmacSha256.init(secret);
    h.update(data);
    h.final(out);
}

/// Sign arbitrary JSON payload bytes (already serialized) into a compact JWT.
pub fn sign(
    allocator: std.mem.Allocator,
    secret: []const u8,
    payload_json: []const u8,
) ![]const u8 {
    const header_json = "{\"alg\":\"HS256\",\"typ\":\"JWT\"}";
    const header_b64 = try b64encode(allocator, header_json);
    defer allocator.free(header_b64);
    const payload_b64 = try b64encode(allocator, payload_json);
    defer allocator.free(payload_b64);

    const signing_input = try std.mem.concat(allocator, u8, &.{ header_b64, ".", payload_b64 });
    defer allocator.free(signing_input);

    var sig: [32]u8 = undefined;
    hmacSign(secret, signing_input, &sig);
    const sig_b64 = try b64encode(allocator, &sig);
    defer allocator.free(sig_b64);

    return std.mem.concat(allocator, u8, &.{ header_b64, ".", payload_b64, ".", sig_b64 });
}

/// Verify a compact JWT signature and return the parsed payload JSON bytes.
/// The returned payload is owned; free it with the same allocator.
pub fn verify(
    allocator: std.mem.Allocator,
    secret: []const u8,
    token: []const u8,
) Error![]const u8 {
    var it = std.mem.splitScalar(u8, token, '.');
    const header_b64 = it.next() orelse return error.InvalidToken;
    const payload_b64 = it.next() orelse return error.InvalidToken;
    const sig_b64 = it.next() orelse return error.InvalidToken;
    if (it.next() != null) return error.InvalidToken;

    const signing_input = try std.mem.concat(allocator, u8, &.{ header_b64, ".", payload_b64 });
    defer allocator.free(signing_input);

    var expected: [32]u8 = undefined;
    hmacSign(secret, signing_input, &expected);
    const expected_b64 = try b64encode(allocator, &expected);
    defer allocator.free(expected_b64);

    if (!std.mem.eql(u8, sig_b64, expected_b64)) return error.InvalidSignature;

    return b64decode(allocator, payload_b64) catch return error.InvalidToken;
}

// ── Asymmetric (JWS) signing ──────────────────────────────────────────────
//
// Zig's stdlib has no RSA, so third-party verifiable OIDC tokens use
// EdDSA (Ed25519) or ES256 (P-256). Both produce a fixed-width JOSE
// signature: 64 bytes (r||s for ES256, r||s for EdDSA). The JOSE header
// always carries "alg", "typ" and "kid" so clients can select the key.

/// JOSE signing algorithms this module can produce/consume.
pub const SigningAlg = enum {
    HS256,
    EdDSA,
    ES256,

    pub fn name(self: SigningAlg) []const u8 {
        return switch (self) {
            .HS256 => "HS256",
            .EdDSA => "EdDSA",
            .ES256 => "ES256",
        };
    }
};

const Ed25519 = std.crypto.sign.Ed25519;
const EcdsaP256Sha256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;

const SigningInput = struct {
    header_b64: []const u8,
    payload_b64: []const u8,
    signing_input: []const u8,

    fn deinit(self: SigningInput, a: std.mem.Allocator) void {
        a.free(self.header_b64);
        a.free(self.payload_b64);
        a.free(self.signing_input);
    }
};

const TokenParts = struct {
    header_b64: []const u8,
    payload_b64: []const u8,
    sig_b64: []const u8,
};

fn splitToken(token: []const u8) Error!TokenParts {
    var it = std.mem.splitScalar(u8, token, '.');
    const header_b64 = it.next() orelse return error.InvalidToken;
    const payload_b64 = it.next() orelse return error.InvalidToken;
    const sig_b64 = it.next() orelse return error.InvalidToken;
    if (it.next() != null) return error.InvalidToken;
    return .{ .header_b64 = header_b64, .payload_b64 = payload_b64, .sig_b64 = sig_b64 };
}

/// Build the JWS signing input "<header>.<payload>" with a JOSE header that
/// advertises `alg`, `typ` and `kid`.
fn makeSigningInput(
    allocator: std.mem.Allocator,
    alg: SigningAlg,
    kid: []const u8,
    payload_json: []const u8,
) !SigningInput {
    var header = std.ArrayList(u8).empty;
    defer header.deinit(allocator);
    try header.appendSlice(allocator, "{\"alg\":\"");
    try header.appendSlice(allocator, alg.name());
    try header.appendSlice(allocator, "\",\"typ\":\"JWT\",\"kid\":\"");
    try header.appendSlice(allocator, kid);
    try header.appendSlice(allocator, "\"}");

    const header_b64 = try b64encode(allocator, header.items);
    errdefer allocator.free(header_b64);
    const payload_b64 = try b64encode(allocator, payload_json);
    errdefer allocator.free(payload_b64);
    const signing_input = try std.mem.concat(allocator, u8, &.{ header_b64, ".", payload_b64 });
    return .{ .header_b64 = header_b64, .payload_b64 = payload_b64, .signing_input = signing_input };
}

/// Sign a payload as an EdDSA (Ed25519) compact JWT.
pub fn signEdDsa(
    allocator: std.mem.Allocator,
    key_pair: Ed25519.KeyPair,
    kid: []const u8,
    payload_json: []const u8,
) ![]const u8 {
    const si = try makeSigningInput(allocator, .EdDSA, kid, payload_json);
    defer si.deinit(allocator);
    const sig = key_pair.sign(si.signing_input, null) catch return error.InvalidSignature;
    const sig_bytes = sig.toBytes();
    const sig_b64 = try b64encode(allocator, &sig_bytes);
    defer allocator.free(sig_b64);
    return std.mem.concat(allocator, u8, &.{ si.header_b64, ".", si.payload_b64, ".", sig_b64 });
}

/// Verify an EdDSA compact JWT and return the owned payload bytes.
pub fn verifyEdDsa(
    allocator: std.mem.Allocator,
    public_key: Ed25519.PublicKey,
    token: []const u8,
) Error![]const u8 {
    const parts = try splitToken(token);
    const signing_input = try std.mem.concat(allocator, u8, &.{ parts.header_b64, ".", parts.payload_b64 });
    defer allocator.free(signing_input);

    const sig_raw = b64decode(allocator, parts.sig_b64) catch return error.InvalidToken;
    defer allocator.free(sig_raw);
    if (sig_raw.len != Ed25519.Signature.encoded_length) return error.InvalidToken;
    const sig_arr: [Ed25519.Signature.encoded_length]u8 = sig_raw[0..Ed25519.Signature.encoded_length].*;
    const sig = Ed25519.Signature.fromBytes(sig_arr);
    sig.verify(signing_input, public_key) catch return error.InvalidSignature;

    return b64decode(allocator, parts.payload_b64) catch return error.InvalidToken;
}

/// Sign a payload as an ES256 (P-256 / SHA-256) compact JWT.
pub fn signEs256(
    allocator: std.mem.Allocator,
    key_pair: EcdsaP256Sha256.KeyPair,
    kid: []const u8,
    payload_json: []const u8,
) ![]const u8 {
    const si = try makeSigningInput(allocator, .ES256, kid, payload_json);
    defer si.deinit(allocator);
    const sig = key_pair.sign(si.signing_input, null) catch return error.InvalidSignature;
    const sig_bytes = sig.toBytes();
    const sig_b64 = try b64encode(allocator, &sig_bytes);
    defer allocator.free(sig_b64);
    return std.mem.concat(allocator, u8, &.{ si.header_b64, ".", si.payload_b64, ".", sig_b64 });
}

/// Verify an ES256 compact JWT and return the owned payload bytes.
pub fn verifyEs256(
    allocator: std.mem.Allocator,
    public_key: EcdsaP256Sha256.PublicKey,
    token: []const u8,
) Error![]const u8 {
    const parts = try splitToken(token);
    const signing_input = try std.mem.concat(allocator, u8, &.{ parts.header_b64, ".", parts.payload_b64 });
    defer allocator.free(signing_input);

    const sig_raw = b64decode(allocator, parts.sig_b64) catch return error.InvalidToken;
    defer allocator.free(sig_raw);
    if (sig_raw.len != EcdsaP256Sha256.Signature.encoded_length) return error.InvalidToken;
    const sig_arr: [EcdsaP256Sha256.Signature.encoded_length]u8 = sig_raw[0..EcdsaP256Sha256.Signature.encoded_length].*;
    const sig = EcdsaP256Sha256.Signature.fromBytes(sig_arr);
    sig.verify(signing_input, public_key) catch return error.InvalidSignature;

    return b64decode(allocator, parts.payload_b64) catch return error.InvalidToken;
}

/// Inspect the JOSE header of a compact token and return its declared
/// algorithm, or null if the header is malformed/unknown.
pub fn peekHeaderAlg(allocator: std.mem.Allocator, token: []const u8) ?SigningAlg {
    const parts = splitToken(token) catch return null;
    const header_json = b64decode(allocator, parts.header_b64) catch return null;
    defer allocator.free(header_json);
    if (std.mem.indexOf(u8, header_json, "\"alg\":\"EdDSA\"") != null) return .EdDSA;
    if (std.mem.indexOf(u8, header_json, "\"alg\":\"ES256\"") != null) return .ES256;
    if (std.mem.indexOf(u8, header_json, "\"alg\":\"HS256\"") != null) return .HS256;
    return null;
}

/// Encode `n` random bytes as a base64url string (secure token source).
/// Entropy is read from /dev/urandom.
pub fn randomToken(allocator: std.mem.Allocator, io: std.Io, n: usize) ![]const u8 {
    const buf = try allocator.alloc(u8, n);
    defer allocator.free(buf);
    var file = try std.Io.Dir.cwd().openFile(io, "/dev/urandom", .{});
    defer file.close(io);
    const read = try file.readPositionalAll(io, buf, 0);
    if (read != n) return error.Unexpected;
    return b64encode(allocator, buf);
}
