//! TOTP (RFC 6238) two-factor helpers - base32 secrets and time-based one-time
//! passwords built on HMAC-SHA1.

const std = @import("std");

const B32_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";

/// Encode bytes as uppercase base32 (RFC 4648, no padding).
pub fn base32Encode(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var buffer: u32 = 0;
    var bits: u5 = 0;
    for (data) |byte| {
        buffer = (buffer << 8) | byte;
        bits += 8;
        while (bits >= 5) : (bits -= 5) {
            const idx = (buffer >> (bits - 5)) & 0x1f;
            try out.append(allocator, B32_ALPHABET[idx]);
        }
    }
    if (bits > 0) {
        const idx = (buffer << (5 - bits)) & 0x1f;
        try out.append(allocator, B32_ALPHABET[idx]);
    }
    return out.toOwnedSlice(allocator);
}

/// Decode a base32 (case-insensitive, no padding) string into bytes.
pub fn base32Decode(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var buffer: u32 = 0;
    var bits: u5 = 0;
    for (s) |c| {
        if (c == '=' or c == ' ') continue; // ignore padding/space
        const v = charVal(c) orelse return error.InvalidBase32;
        buffer = (buffer << 5) | v;
        bits += 5;
        if (bits >= 8) {
            bits -= 8;
            try out.append(allocator, @intCast((buffer >> bits) & 0xff));
        }
    }
    return out.toOwnedSlice(allocator);
}

fn charVal(c: u8) ?u5 {
    const upper = std.ascii.toUpper(c);
    if (upper >= 'A' and upper <= 'Z') return @intCast(upper - 'A');
    if (upper >= '2' and upper <= '7') return @intCast(26 + (upper - '2'));
    return null;
}

/// Generate a cryptographically-random base32 secret of `n` bytes (default 20).
pub fn generateSecret(allocator: std.mem.Allocator, io: std.Io, n: usize) ![]const u8 {
    const buf = try allocator.alloc(u8, n);
    defer allocator.free(buf);
    try fillFromSystemEntropy(io, buf);
    return base32Encode(allocator, buf);
}

/// Compute the current (or `counter`) TOTP code for a secret and time step.
pub fn generateCode(allocator: std.mem.Allocator, secret_b32: []const u8, counter: u64) ![]const u8 {
    const key = try base32Decode(allocator, secret_b32);
    defer allocator.free(key);
    const otp = try hotp(allocator, key, counter);
    return std.fmt.allocPrint(allocator, "{d:0>6}", .{otp});
}

/// HOTP (RFC 4226): HMAC-SHA1 counter-based one-time password, truncated to 6 digits.
fn hotp(allocator: std.mem.Allocator, key: []const u8, counter: u64) !u32 {
    var msg: [8]u8 = undefined;
    var c = counter;
    for (0..8) |i| {
        msg[7 - i] = @intCast(c & 0xff);
        c >>= 8;
    }
    var hmac = std.crypto.auth.hmac.HmacSha1.init(key);
    hmac.update(&msg);
    var digest: [20]u8 = undefined;
    hmac.final(&digest);
    const offset: usize = digest[19] & 0x0f;
    const bin_code = (@as(u32, digest[offset]) << 24) |
        (@as(u32, digest[offset + 1]) << 16) |
        (@as(u32, digest[offset + 2]) << 8) |
        @as(u32, digest[offset + 3]);
    const truncated = bin_code & 0x7fffffff;
    _ = allocator;
    return truncated % 1000000;
}

/// Verify a submitted code against the current time step within `window`
/// steps of tolerance (default 1 before + 1 after).
pub fn verify(allocator: std.mem.Allocator, secret_b32: []const u8, code: []const u8, counter: u64, window: i64) !bool {
    var delta: i64 = -window;
    while (delta <= window) : (delta += 1) {
        const step: u64 = @intCast(@as(i64, @intCast(counter)) + delta);
        const candidate = try generateCode(allocator, secret_b32, step);
        defer allocator.free(candidate);
        if (std.mem.eql(u8, candidate, code)) return true;
    }
    return false;
}

/// The current 30-second TOTP counter for a unix timestamp.
pub fn counterAt(timestamp_seconds: i64, step: i64) u64 {
    return @intCast(@divTrunc(timestamp_seconds, step));
}

fn fillFromSystemEntropy(io: std.Io, buf: []u8) !void {
    var file = try std.Io.Dir.cwd().openFile(io, "/dev/urandom", .{});
    defer file.close(io);
    const read = try file.readPositionalAll(io, buf, 0);
    if (read != buf.len) return error.Unexpected;
}
