//! Unit tests for zenaipa. DB-backed tests use an in-memory zent store;
//! HTTP-layer tests dispatch through zigmodu's Testkit without a socket.
//! Tenant tests cover default bootstrap, JWT aud binding and row isolation.

const std = @import("std");
const zigmodu = @import("zigmodu");
const zent = @import("zent");
const db_mod = @import("db.zig");
const schema = @import("schema.zig");
const user = @import("modules/user/root.zig");
const auth = @import("modules/auth/root.zig");
const task = @import("modules/task/root.zig");
const file = @import("modules/file/root.zig");
const notify = @import("modules/notify/root.zig");
const tenant = @import("modules/tenant/root.zig");
const cache_svc = @import("services/cache.zig");
const mail = @import("services/mail.zig");

/// In-memory SQLite store with every schema group migrated.
fn openMemory(allocator: std.mem.Allocator) !db_mod.StoreEnv(schema.infos, .{
    tenant.persistence.infos,
    user.persistence.infos,
    task.persistence.infos,
    file.persistence.infos,
    notify.persistence.infos,
}) {
    return db_mod.StoreEnv(schema.infos, .{
        tenant.persistence.infos,
        user.persistence.infos,
        task.persistence.infos,
        file.persistence.infos,
        notify.persistence.infos,
    }).open(allocator, .sqlite, ":memory:");
}

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
    var env = try db_mod.StoreEnv(schema.infos, .{
        user.persistence.infos,
        task.persistence.infos,
        file.persistence.infos,
        notify.persistence.infos,
    }).open(allocator, .sqlite, ":memory:");
    defer env.deinit();
    var store = user.persistence.UserStore.init(allocator, env.client);
    const existing = try store.getUserByEmail("nobody@example.com");
    try std.testing.expect(existing == null);
}

test "sqlite store keyword search finds user" {
    const allocator = std.testing.allocator;
    var env = try openMemory(allocator);
    defer env.deinit();
    var store = user.persistence.UserStore.init(allocator, env.client);
    _ = try store.createUser("Alice", "alice@example.com", "hash", false, false, 1, 100);
    _ = try store.createUser("Bob", "bob@example.com", "hash", false, false, 1, 200);

    // Substring search: "alice" matches only alice's row via name or email.
    var result = try store.listUsers(1, 20, "alice", null, null, false);
    defer store.freeList(&result);
    try std.testing.expectEqual(@as(i64, 1), result.total);
    try std.testing.expectEqualStrings("alice@example.com", result.items[0].email);
}

test "service updateProfile keeps fields and normalizes email" {
    const allocator = std.testing.allocator;
    var env = try openMemory(allocator);
    defer env.deinit();
    var store = user.persistence.UserStore.init(allocator, env.client);
    var sec = zigmodu.security.AppSecurity.init(allocator, std.testing.io, .{ .jwt_secret = "test-secret" });
    var svc = user.service.UserService.init(&store, &sec, std.testing.io, 3600, 86400);

    const id = try store.createUser("Alice", "alice@example.com", "hash", false, false, 1, 100);

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
    var env = try openMemory(allocator);
    defer env.deinit();
    var store = user.persistence.UserStore.init(allocator, env.client);
    var sec = zigmodu.security.AppSecurity.init(allocator, std.testing.io, .{ .jwt_secret = "test-secret" });
    var svc = user.service.UserService.init(&store, &sec, std.testing.io, 3600, 86400);

    const alice_id = try store.createUser("Alice", "alice@example.com", "hash", false, false, 1, 100);
    const bob_id = try store.createUser("Bob", "bob@example.com", "hash", false, false, 1, 200);

    try std.testing.expect(try svc.emailTakenByOther(allocator, bob_id, "alice@example.com"));
    try std.testing.expect(!try svc.emailTakenByOther(allocator, alice_id, "alice@example.com"));
    try std.testing.expect(!try svc.emailTakenByOther(allocator, bob_id, "bob@example.com"));
}

test "password token lifecycle: issue, validate, expired cleanup" {
    const allocator = std.testing.allocator;
    var env = try openMemory(allocator);
    defer env.deinit();
    var store = user.persistence.UserStore.init(allocator, env.client);
    var sec = zigmodu.security.AppSecurity.init(allocator, std.testing.io, .{ .jwt_secret = "test-secret" });
    var svc = user.service.UserService.init(&store, &sec, std.testing.io, 3600, 86400);

    _ = try store.createUser("Alice", "alice@example.com", "hash", false, false, 1, 100);

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

test "email verification lifecycle: issue, verify, purge" {
    const allocator = std.testing.allocator;
    var env = try openMemory(allocator);
    defer env.deinit();
    var store = user.persistence.UserStore.init(allocator, env.client);
    var sec = zigmodu.security.AppSecurity.init(allocator, std.testing.io, .{ .jwt_secret = "test-secret" });
    var svc = user.service.UserService.init(&store, &sec, std.testing.io, 3600, 86400);

    const id = try store.createUser("Alice", "alice@example.com", "hash", false, false, 1, 100);
    const info = (try svc.createEmailVerification(allocator, id)).?;
    defer allocator.free(info.raw);
    try svc.verifyEmail(allocator, id, info.raw);

    const row = (try store.getUserById(id)).?;
    defer row.free(allocator);
    try std.testing.expect(row.verified);
}

test "changePassword verifies the current password" {
    const allocator = std.testing.allocator;
    var env = try openMemory(allocator);
    defer env.deinit();
    var store = user.persistence.UserStore.init(allocator, env.client);
    var sec = zigmodu.security.AppSecurity.init(allocator, std.testing.io, .{ .jwt_secret = "test-secret" });
    var svc = user.service.UserService.init(&store, &sec, std.testing.io, 3600, 86400);
    const id = try store.createUser("Alice", "alice@example.com", "hash", false, false, 1, 100);

    try std.testing.expectError(error.InvalidCredentials, svc.changePassword(allocator, id, "wrong", "newpassword123"));
    try std.testing.expectError(error.InvalidPassword, svc.changePassword(allocator, id, "hash", "short"));
}

test "cache service set/get/remove" {
    const allocator = std.testing.allocator;
    var cache = cache_svc.CacheService.init(allocator, 16, 60);
    defer cache.deinit();
    try cache.set("user:1", "{\"name\":\"Alice\"}");
    try std.testing.expectEqualStrings("{\"name\":\"Alice\"}", cache.get("user:1").?);
    try std.testing.expect(cache.remove("user:1"));
    try std.testing.expect(cache.get("user:1") == null);
}

test "mailer console sink never fails" {
    const allocator = std.testing.allocator;
    var mailer = mail.Mailer.init(allocator, std.testing.io, "", 587, "", "", "test@localhost", true, true);
    mailer.send(.{ .to = "a@example.com", .subject = "hi", .text = "hello" });
    mailer.send(.{ .to = "b@example.com", .subject = "hi", .text = "hello" });
}

test "task queue: enqueue -> claim -> done" {
    const allocator = std.testing.allocator;
    var env = try openMemory(allocator);
    defer env.deinit();
    var task_store = task.persistence.TaskStore.init(allocator, env.client);
    var task_svc = task.service.TaskService.init(&task_store, std.testing.io, 3);

    const id = try task_svc.enqueueNow("mail.send", "{}", 1);
    const claimed = (try task_store.claimNext(1000)).?;
    defer claimed.free(allocator);
    try std.testing.expectEqual(id, claimed.id);
    try std.testing.expectEqualStrings("claimed", claimed.status);
    try task_store.markDone(id, 1001);
    const row = (try task_store.getTaskById(id)).?;
    defer row.free(allocator);
    try std.testing.expectEqualStrings("done", row.status);
}

test "task queue: retry backoff and failure budget" {
    const allocator = std.testing.allocator;
    var env = try openMemory(allocator);
    defer env.deinit();
    var task_store = task.persistence.TaskStore.init(allocator, env.client);

    const id = try task_store.createTask("mail.send", "{}", "pending", 1, 1, 2, "", 0, 100);
    try task_store.markFailedOrRetry(id, 1, 2, "boom", 200, 60);
    const after = (try task_store.getTaskById(id)).?;
    defer after.free(allocator);
    try std.testing.expectEqualStrings("pending", after.status);
    try std.testing.expectEqual(@as(i64, 260), after.available_at);

    try task_store.markFailedOrRetry(id, 2, 2, "boom", 300, 60);
    const failed = (try task_store.getTaskById(id)).?;
    defer failed.free(allocator);
    try std.testing.expectEqualStrings("failed", failed.status);
}

test "notification store: create, unread count, mark read" {
    const allocator = std.testing.allocator;
    var env = try openMemory(allocator);
    defer env.deinit();
    var notify_store = notify.persistence.NotificationStore.init(allocator, env.client);
    var notify_svc = notify.service.NotificationService.init(allocator, std.testing.io, &notify_store);

    _ = try notify_svc.notify(7, "任务完成", "mail.send ok", "success");
    _ = try notify_svc.notify(7, "系统消息", "欢迎", "info");
    try std.testing.expectEqual(@as(i64, 2), try notify_svc.unreadCount(7));

    var result = try notify_svc.list(7, 1, 20, true);
    defer result.free(allocator);
    try std.testing.expectEqual(@as(i64, 2), result.total);
    try notify_svc.markAllRead(7);
    try std.testing.expectEqual(@as(i64, 0), try notify_svc.unreadCount(7));
}

test "file store metadata CRUD" {
    const allocator = std.testing.allocator;
    var env = try openMemory(allocator);
    defer env.deinit();
    var file_store = file.persistence.FileStore.init(allocator, env.client);

    const id = try file_store.create("a.txt", "key1", "text/plain", 4, 9, 1, 100);
    const row = (try file_store.getById(id)).?;
    defer row.free(allocator);
    try std.testing.expectEqualStrings("a.txt", row.name);
    try std.testing.expectEqualStrings("key1", row.storage_key);
    try file_store.delete(id);
    try std.testing.expect((try file_store.getById(id)) == null);
}

test "HTTP dispatch: public auth flow (register -> me) via Testkit" {
    const allocator = std.testing.allocator;
    var env = try openMemory(allocator);
    defer env.deinit();
    var store = user.persistence.UserStore.init(allocator, env.client);
    var sec = zigmodu.security.AppSecurity.init(allocator, std.testing.io, .{ .jwt_secret = "testkit-secret" });
    var svc = user.service.UserService.init(&store, &sec, std.testing.io, 3600, 86400);
    var limiter = try zigmodu.RateLimiter.init(allocator, "test", 100, 1);
    defer limiter.deinit();
    var mailer = mail.Mailer.init(allocator, std.testing.io, "", 587, "", "", "test@localhost", true, false);
    var task_store = task.persistence.TaskStore.init(allocator, env.client);
    var task_svc = task.service.TaskService.init(&task_store, std.testing.io, 3);
    var notify_store = notify.persistence.NotificationStore.init(allocator, env.client);
    var notify_svc = notify.service.NotificationService.init(allocator, std.testing.io, &notify_store);
    var auth_api = auth.api.AuthApi(@TypeOf(svc)).init(&svc, "http://localhost:3001", &limiter, &mailer, &task_svc, &notify_svc, 1);

    var server = zigmodu.http.Server.init(std.testing.io, allocator, 0);
    defer server.deinit();
    var g = server.group("/api/v1");
    try auth_api.registerRoutes(&g);

    var resp = try zigmodu.http.Testkit.dispatch(&server, .POST, "/api/v1/auth/register", "{\"name\":\"Tester\",\"email\":\"t@example.com\",\"password\":\"password123\"}");
    defer resp.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 201), resp.status_code);
    try std.testing.expect(std.mem.indexOf(u8, resp.body, "\"code\":0") != null);
}

test "tenant service: ensureDefault is idempotent, CRUD works" {
    const allocator = std.testing.allocator;
    var env = try openMemory(allocator);
    defer env.deinit();
    var tenant_store = tenant.persistence.TenantStore.init(allocator, env.client);
    var tenant_svc = tenant.service.TenantService.init(allocator, std.testing.io, &tenant_store);

    const default_id = try tenant_svc.ensureDefault();
    try std.testing.expectEqual(default_id, try tenant_svc.ensureDefault());

    const acme = try tenant_svc.create("Acme Inc");
    const acme_row = (try tenant_svc.get(acme)).?;
    defer acme_row.free(allocator);
    try std.testing.expectEqualStrings("Acme Inc", acme_row.name);
    try std.testing.expectEqualStrings("active", acme_row.status);

    _ = try tenant_svc.update(acme, "Acme Inc", "disabled");
    const disabled = (try tenant_svc.get(acme)).?;
    defer disabled.free(allocator);
    try std.testing.expectEqualStrings("disabled", disabled.status);

    var result = try tenant_svc.list(1, 20);
    defer result.free(allocator);
    try std.testing.expectEqual(@as(i64, 2), result.total);
}

test "register binds tenant and JWT aud carries it" {
    const allocator = std.testing.allocator;
    var env = try openMemory(allocator);
    defer env.deinit();
    var store = user.persistence.UserStore.init(allocator, env.client);
    var sec = zigmodu.security.AppSecurity.init(allocator, std.testing.io, .{ .jwt_secret = "test-secret" });
    var svc = user.service.UserService.init(&store, &sec, std.testing.io, 3600, 86400);

    var session = try svc.register(allocator, "Alice", "alice@example.com", "password123", false, 7);
    defer session.deinit(allocator);
    try std.testing.expectEqual(@as(i64, 7), session.row.tenant_id);

    const payload = try sec.module.verifyToken(session.token);
    defer sec.module.freePayload(payload);
    try std.testing.expectEqualStrings("7", payload.aud);
}

test "user list filters by tenant" {
    const allocator = std.testing.allocator;
    var env = try openMemory(allocator);
    defer env.deinit();
    var store = user.persistence.UserStore.init(allocator, env.client);

    _ = try store.createUser("A1", "a1@example.com", "hash", false, false, 1, 100);
    _ = try store.createUser("A2", "a2@example.com", "hash", false, false, 1, 101);
    _ = try store.createUser("B1", "b1@example.com", "hash", false, false, 2, 102);

    var tenant1 = try store.listUsers(1, 20, null, 1, null, false);
    defer tenant1.free(allocator);
    try std.testing.expectEqual(@as(i64, 2), tenant1.total);

    var tenant2 = try store.listUsers(1, 20, null, 2, null, false);
    defer tenant2.free(allocator);
    try std.testing.expectEqual(@as(i64, 1), tenant2.total);
    try std.testing.expectEqualStrings("b1@example.com", tenant2.items[0].email);
}

test "file list isolates tenants" {
    const allocator = std.testing.allocator;
    var env = try openMemory(allocator);
    defer env.deinit();
    var file_store = file.persistence.FileStore.init(allocator, env.client);

    _ = try file_store.create("t1.txt", "k1", "text/plain", 3, 1, 1, 100);
    _ = try file_store.create("t2.txt", "k2", "text/plain", 3, 1, 2, 101);

    var tenant1 = try file_store.list(1, 20, null, 1, null, false);
    defer tenant1.free(allocator);
    try std.testing.expectEqual(@as(i64, 1), tenant1.total);
    try std.testing.expectEqualStrings("t1.txt", tenant1.items[0].name);
}
