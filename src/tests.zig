//! Unit tests for zenaipa. These cover the pure helper logic; DB-backed
//! tests are split into integration-style blocks that use an in-memory
//! zent store.

const std = @import("std");
const zigmodu = @import("zigmodu");
const zent = @import("zent");
const db_mod = @import("db.zig");
const user = @import("modules/user/root.zig");

test "health: zigmodu + zent importable together" {
    _ = zigmodu;
    _ = zent;
    try std.testing.expect(true);
}

test "AppSecurity signs and verifies a token" {
    const allocator = std.testing.allocator;
    var sec = zigmodu.security.AppSecurity.init(allocator, std.testing.io, .{ .jwt_secret = "test-secret" });
    const token = try sec.generateToken("7", &.{"admin"});
    defer allocator.free(token);
    const payload = try sec.module.verifyToken(token);
    defer sec.module.freePayload(payload);
    try std.testing.expectEqualStrings("7", payload.sub);
    try std.testing.expect(zigmodu.security.SecurityModule.hasRole(payload, "admin"));
}

test "sqlite store query prepares and runs standalone" {
    const allocator = std.testing.allocator;
    var env = try db_mod.StoreEnv(user.persistence.infos).open(allocator, .sqlite, ":memory:");
    defer env.deinit();
    var store = user.persistence.UserStore.init(allocator, env.client);
    const existing = try store.getUserByEmail("nobody@example.com");
    try std.testing.expect(existing == null);
}

test "sqlite store keyword search finds user" {
    const allocator = std.testing.allocator;
    var env = try db_mod.StoreEnv(user.persistence.infos).open(allocator, .sqlite, ":memory:");
    defer env.deinit();
    var store = user.persistence.UserStore.init(allocator, env.client);
    _ = try store.createUser("Alice", "alice@example.com", "hash", false, false, 100);
    _ = try store.createUser("Bob", "bob@example.com", "hash", false, false, 200);

    // Substring search: "alice" matches only alice's row via name or email.
    var result = try store.listUsers(1, 20, "alice");
    defer store.freeList(&result);
    try std.testing.expectEqual(@as(i64, 1), result.total);
    try std.testing.expectEqualStrings("alice@example.com", result.items[0].email);
}

test "service updateProfile keeps fields and normalizes email" {
    const allocator = std.testing.allocator;
    var env = try db_mod.StoreEnv(user.persistence.infos).open(allocator, .sqlite, ":memory:");
    defer env.deinit();
    var store = user.persistence.UserStore.init(allocator, env.client);
    var sec = zigmodu.security.AppSecurity.init(allocator, std.testing.io, .{ .jwt_secret = "test-secret" });
    var svc = user.service.UserService.init(&store, &sec, std.testing.io, 3600);

    const id = try store.createUser("Alice", "alice@example.com", "hash", false, false, 100);

    // Only the name changes; email is preserved.
    try svc.updateProfile(id, "Alice Renamed", "alice@example.com");
    {
        const row = (try store.getUserById(id)).?;
        defer row.free(allocator);
        try std.testing.expectEqualStrings("Alice Renamed", row.name);
        try std.testing.expectEqualStrings("alice@example.com", row.email);
    }

    // Mixed-case email is lowercased before persisting.
    try svc.updateProfile(id, "Alice", "ALICE@EXAMPLE.COM");
    {
        const row = (try store.getUserById(id)).?;
        defer row.free(allocator);
        try std.testing.expectEqualStrings("alice@example.com", row.email);
    }

    try std.testing.expectError(error.InvalidEmail, svc.updateProfile(id, "Alice", "not-an-email"));
    try std.testing.expectError(error.InvalidName, svc.updateProfile(id, "   ", "alice@example.com"));
}

test "emailTakenByOther detects a conflicting email" {
    const allocator = std.testing.allocator;
    var env = try db_mod.StoreEnv(user.persistence.infos).open(allocator, .sqlite, ":memory:");
    defer env.deinit();
    var store = user.persistence.UserStore.init(allocator, env.client);
    var sec = zigmodu.security.AppSecurity.init(allocator, std.testing.io, .{ .jwt_secret = "test-secret" });
    var svc = user.service.UserService.init(&store, &sec, std.testing.io, 3600);

    const alice_id = try store.createUser("Alice", "alice@example.com", "hash", false, false, 100);
    const bob_id = try store.createUser("Bob", "bob@example.com", "hash", false, false, 200);

    try std.testing.expect(try svc.emailTakenByOther(allocator, bob_id, "alice@example.com"));
    try std.testing.expect(!try svc.emailTakenByOther(allocator, alice_id, "alice@example.com"));
    try std.testing.expect(!try svc.emailTakenByOther(allocator, bob_id, "bob@example.com"));
}

test "password token lifecycle: issue, validate, expired cleanup" {
    const allocator = std.testing.allocator;
    var env = try db_mod.StoreEnv(user.persistence.infos).open(allocator, .sqlite, ":memory:");
    defer env.deinit();
    var store = user.persistence.UserStore.init(allocator, env.client);
    var sec = zigmodu.security.AppSecurity.init(allocator, std.testing.io, .{ .jwt_secret = "test-secret" });
    var svc = user.service.UserService.init(&store, &sec, std.testing.io, 3600);

    _ = try store.createUser("Alice", "alice@example.com", "hash", false, false, 100);

    // Valid token round-trips.
    const info = (try svc.createPasswordResetToken(allocator, "alice@example.com")).?;
    defer allocator.free(info.raw);
    try svc.validatePasswordResetToken(allocator, info.user_id, info.raw);

    // A stale token (far in the past) is purged, the fresh one survives.
    _ = try store.createPasswordToken(info.user_id, "stale-hash", 1000);
    const now = zigmodu.time.wallClockSeconds(std.testing.io);
    try store.deleteExpiredPasswordTokens(info.user_id, now, 3600);
    const latest = (try store.getLatestPasswordToken(info.user_id)).?;
    defer latest.free(allocator);
    try std.testing.expectEqual(info.user_id, latest.user_id);
    // The stored value is the PBKDF2 hash of the raw token — assert it is not
    // the stale marker so we know cleanup removed only the old row.
    try std.testing.expect(!std.mem.eql(u8, latest.token, "stale-hash"));
}
