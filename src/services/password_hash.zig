//! Argon2id password hashing with PHC string format.
//!
//! New hashes: $argon2id$v=19$m=<KiB>,t=<iters>,p=<lanes>$<b64salt>$<b64hash>
//! Legacy PBKDF2 hashes are verified by the caller (SecurityModule).

const std = @import("std");
const argon2 = std.crypto.pwhash.argon2;

pub const Error = error{
    MalformedStoredHash,
    UnsupportedAlgorithm,
    EntropyUnavailable,
    OutOfMemory,
    Unexpected,
};

pub const Params = struct {
    memory_kib: u32 = 64 * 1024,
    time_cost: u32 = 3,
    parallelism: u24 = 1,
    hash_len: usize = 32,
    salt_len: usize = 16,
};

fn b64Encode(a: std.mem.Allocator, bytes: []const u8) Error![]u8 {
    const enc = std.base64.standard_no_pad.Encoder;
    const out = a.alloc(u8, enc.calcSize(bytes.len)) catch return error.OutOfMemory;
    errdefer a.free(out);
    _ = enc.encode(out, bytes);
    return out;
}

fn b64Decode(a: std.mem.Allocator, text: []const u8) Error![]u8 {
    const dec = std.base64.standard_no_pad.Decoder;
    const n = dec.calcSizeForSlice(text) catch return error.MalformedStoredHash;
    const out = a.alloc(u8, n) catch return error.OutOfMemory;
    errdefer a.free(out);
    dec.decode(out, text) catch return error.MalformedStoredHash;
    return out;
}

pub fn hash(a: std.mem.Allocator, io: std.Io, password: []const u8, params: Params) Error![]u8 {
    const salt = a.alloc(u8, params.salt_len) catch return error.OutOfMemory;
    defer a.free(salt);
    std.Io.randomSecure(io, salt) catch return error.EntropyUnavailable;

    const dk = a.alloc(u8, params.hash_len) catch return error.OutOfMemory;
    defer a.free(dk);
    argon2.kdf(a, dk, password, salt, .{
        .t = params.time_cost,
        .m = params.memory_kib,
        .p = params.parallelism,
    }, .argon2id, io) catch return error.Unexpected;

    const salt_b64 = try b64Encode(a, salt);
    defer a.free(salt_b64);
    const hash_b64 = try b64Encode(a, dk);
    defer a.free(hash_b64);
    return std.fmt.allocPrint(a, "$argon2id$v=19$m={d},t={d},p={d}${s}${s}", .{
        params.memory_kib, params.time_cost, @as(u32, params.parallelism), salt_b64, hash_b64,
    }) catch return error.OutOfMemory;
}

pub fn verify(a: std.mem.Allocator, io: std.Io, password: []const u8, stored: []const u8) Error!bool {
    var it = std.mem.splitScalar(u8, stored, '$');
    const empty = it.next() orelse return error.MalformedStoredHash;
    if (empty.len != 0) return error.MalformedStoredHash;
    const algo = it.next() orelse return error.MalformedStoredHash;
    if (!std.mem.eql(u8, algo, "argon2id")) return error.UnsupportedAlgorithm;
    const version = it.next() orelse return error.MalformedStoredHash;
    if (!std.mem.eql(u8, version, "v=19")) return error.UnsupportedAlgorithm;
    const param_str = it.next() orelse return error.MalformedStoredHash;
    const salt_b64 = it.next() orelse return error.MalformedStoredHash;
    const hash_b64 = it.next() orelse return error.MalformedStoredHash;
    if (it.next() != null) return error.MalformedStoredHash;

    var pit = std.mem.splitScalar(u8, param_str, ',');
    const mk = pit.next() orelse return error.MalformedStoredHash;
    const tk = pit.next() orelse return error.MalformedStoredHash;
    const pk = pit.next() orelse return error.MalformedStoredHash;
    if (pit.next() != null) return error.MalformedStoredHash;
    if (!std.mem.startsWith(u8, mk, "m=") or !std.mem.startsWith(u8, tk, "t=") or !std.mem.startsWith(u8, pk, "p=")) return error.MalformedStoredHash;
    const m = std.fmt.parseInt(u32, mk[2..], 10) catch return error.MalformedStoredHash;
    const t = std.fmt.parseInt(u32, tk[2..], 10) catch return error.MalformedStoredHash;
    const p = std.fmt.parseInt(u32, pk[2..], 10) catch return error.MalformedStoredHash;
    if (m == 0 or t == 0 or p == 0 or p > std.math.maxInt(u24)) return error.MalformedStoredHash;

    const salt = try b64Decode(a, salt_b64);
    defer a.free(salt);
    const expected = try b64Decode(a, hash_b64);
    defer a.free(expected);
    if (expected.len < 4) return error.MalformedStoredHash;

    const dk = a.alloc(u8, expected.len) catch return error.OutOfMemory;
    defer a.free(dk);
    argon2.kdf(a, dk, password, salt, .{
        .t = t,
        .m = m,
        .p = @intCast(p),
    }, .argon2id, io) catch return error.Unexpected;
    return std.mem.eql(u8, dk, expected);
}

test "argon2id: PHC hash/verify round-trip and wrong password" {
    const a = std.testing.allocator;
    const pwd = "Str0ng-Passw0rd!23";
    const params = Params{ .memory_kib = 8192, .time_cost = 1, .parallelism = 1, .hash_len = 16 };
    const stored = try hash(a, std.testing.io, pwd, params);
    defer a.free(stored);
    try std.testing.expect(std.mem.startsWith(u8, stored, "$argon2id$v=19$m=8192,t=1,p=1$"));
    try std.testing.expect(try verify(a, std.testing.io, pwd, stored));
    try std.testing.expect(!try verify(a, std.testing.io, "wrong", stored));
}

test "argon2id: malformed and legacy PHC strings are reported" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.MalformedStoredHash, verify(a, std.testing.io, "x", "$argon2id$v=19$oops"));
    try std.testing.expectError(error.UnsupportedAlgorithm, verify(a, std.testing.io, "x", "$pbkdf2$1$aa$bb"));
}
