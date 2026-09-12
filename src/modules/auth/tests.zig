//! Auth module tests: shared password policy and per-account login lockout.

const std = @import("std");
const zigmodu = @import("zigmodu");
const db_mod = @import("../../db.zig");
const schema = @import("../../schema.zig");
const user = @import("../user/root.zig");

const service = user.service;

/// In-memory SQLite store with just the user schema group migrated.
fn openUserDb(allocator: std.mem.Allocator) !db_mod.StoreEnv(schema.infos, .{user.persistence.infos}) {
    return db_mod.StoreEnv(schema.infos, .{user.persistence.infos}).open(allocator, .sqlite, ":memory:");
}

test "password policy: short, long, common, identity and good passwords" {
    const policy = service.PasswordPolicy{};

    try std.testing.expectError(error.PasswordTooShort, policy.validate("short", "alice@example.com", "Alice"));

    var long_pw: [129]u8 = undefined;
    @memset(&long_pw, 120);
    try std.testing.expectError(error.PasswordTooLong, policy.validate(&long_pw, "alice@example.com", "Alice"));

    try std.testing.expectError(error.PasswordTooCommon, policy.validate("qwertyuiop", "alice@example.com", "Alice"));

    try std.testing.expectError(error.PasswordContainsIdentity, policy.validate("my-alice-pass-99", "alice@example.com", "Bob"));
    try std.testing.expectError(error.PasswordContainsIdentity, policy.validate("MyAliceSecret99", "zed@example.com", "Alice"));

    try policy.validate("Tr0ub4dor&3-correct", "alice@example.com", "Alice");

    // One-letter email local-parts are ignored so they cannot reject every
    // otherwise-valid password.
    try policy.validate("t-valid-password-99", "t@example.com", "T");

    // Tunable fields are honored.
    const weak = service.PasswordPolicy{ .min_length = 4, .max_length = 6 };
    try weak.validate("abcd", "x@example.com", "Xavier");
    try std.testing.expectError(error.PasswordTooLong, weak.validate("abcdefg", "x@example.com", "Xavier"));
}

test "password policy enforced on register, change and reset" {
    const allocator = std.testing.allocator;
    var env = try openUserDb(allocator);
    defer env.deinit();
    var store = user.persistence.UserStore.init(allocator, env.client);
    var sec = zigmodu.security.AppSecurity.init(allocator, std.testing.io, .{ .jwt_secret = "test-secret" });
    var svc = service.UserService.init(&store, &sec, std.testing.io, 3600, 86400);

    try std.testing.expectError(error.PasswordTooShort, svc.register(allocator, "Alice", "alice@example.com", "short", false, 1));
    try std.testing.expectError(error.PasswordTooCommon, svc.register(allocator, "Alice", "alice@example.com", "qwertyuiop", false, 1));
    try std.testing.expectError(error.PasswordContainsIdentity, svc.register(allocator, "Alice", "alice@example.com", "alice-password-99", false, 1));

    var session = try svc.register(allocator, "Alice", "alice@example.com", "Tr0ub4dor&3-correct", false, 1);
    defer session.deinit(allocator);
    const uid = session.row.id;
    const good = "Tr0ub4dor&3-correct";

    // change-password keeps error.InvalidPassword for sub-8 inputs and
    // reports the specific rule for 8+ inputs.
    try std.testing.expectError(error.InvalidPassword, svc.changePassword(uid, good, "short"));
    try std.testing.expectError(error.PasswordTooShort, svc.changePassword(uid, good, "abcd1234"));
    try std.testing.expectError(error.PasswordTooCommon, svc.changePassword(uid, good, "qwertyuiop"));
    try std.testing.expectError(error.PasswordContainsIdentity, svc.changePassword(uid, good, "alice-new-password"));

    // reset-password funnels through the same shared validator.
    const info = (try svc.createPasswordResetToken(allocator, "alice@example.com")).?;
    defer allocator.free(info.raw);
    try std.testing.expectError(error.PasswordTooShort, svc.resetPassword(info.user_id, info.raw, "abcd1234"));
    try std.testing.expectError(error.PasswordTooCommon, svc.resetPassword(info.user_id, info.raw, "qwertyuiop"));
}

test "lockout store: threshold, cooldown expiry and success reset" {
    var lo = service.LoginLockout{ .allocator = std.testing.allocator };
    defer lo.reset(std.testing.io);
    const io = std.testing.io;
    const t0: i64 = 1_000_000;

    var i: u32 = 0;
    while (i < 4) : (i += 1) lo.recordFailure(io, "a@example.com", t0);
    try std.testing.expect(!lo.isLocked(io, "a@example.com", t0));
    lo.recordFailure(io, "a@example.com", t0);
    try std.testing.expect(lo.isLocked(io, "a@example.com", t0));
    try std.testing.expect(lo.isLocked(io, "a@example.com", t0 + 899));
    try std.testing.expect(!lo.isLocked(io, "a@example.com", t0 + 900));

    // A successful login clears the counter, so later failures start over.
    i = 0;
    while (i < 4) : (i += 1) lo.recordFailure(io, "b@example.com", t0);
    lo.clear(io, "b@example.com");
    i = 0;
    while (i < 4) : (i += 1) lo.recordFailure(io, "b@example.com", t0 + 1);
    try std.testing.expect(!lo.isLocked(io, "b@example.com", t0 + 1));

    // Failures older than the window do not accumulate toward a lock.
    lo.recordFailure(io, "c@example.com", t0);
    i = 0;
    while (i < 5) : (i += 1) lo.recordFailure(io, "c@example.com", t0 + 901);
    try std.testing.expect(lo.isLocked(io, "c@example.com", t0 + 901));
}

test "login lockout: failed attempts lock, correct password waits for cooldown" {
    const allocator = std.testing.allocator;
    var env = try openUserDb(allocator);
    defer env.deinit();
    var store = user.persistence.UserStore.init(allocator, env.client);
    var sec = zigmodu.security.AppSecurity.init(allocator, std.testing.io, .{ .jwt_secret = "test-secret" });
    var svc = service.UserService.init(&store, &sec, std.testing.io, 3600, 86400);

    service.resetLoginLockout(std.testing.io);
    defer service.resetLoginLockout(std.testing.io);

    var session = try svc.register(allocator, "Carol", "carol@example.com", "Tr0ub4dor&3-correct", false, 1);
    session.deinit(allocator);

    const t0: i64 = 2_000_000;
    var i: u32 = 0;
    while (i < 5) : (i += 1) {
        try std.testing.expect((try svc.loginAt(allocator, "carol@example.com", "wrong-password-99", t0)) == null);
    }
    // Correct password is still rejected while locked.
    try std.testing.expectError(error.AccountLocked, svc.loginAt(allocator, "carol@example.com", "Tr0ub4dor&3-correct", t0));

    // After the cooldown the correct password works again.
    var after = (try svc.loginAt(allocator, "carol@example.com", "Tr0ub4dor&3-correct", t0 + 900)).?;
    after.deinit(allocator);

    // Unknown emails lock identically: no user-enumeration oracle.
    var j: u32 = 0;
    while (j < 5) : (j += 1) {
        try std.testing.expect((try svc.loginAt(allocator, "ghost@example.com", "whatever-99", t0)) == null);
    }
    try std.testing.expectError(error.AccountLocked, svc.loginAt(allocator, "ghost@example.com", "whatever-99", t0));
}
