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
