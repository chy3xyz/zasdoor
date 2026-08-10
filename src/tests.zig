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
const audit = @import("modules/audit/root.zig");
const mail_template = @import("modules/mail_template/root.zig");
const ai = @import("modules/ai/root.zig");
const cache_svc = @import("services/cache.zig");
const mail = @import("services/mail.zig");

/// In-memory SQLite store with every schema group migrated.
fn openMemory(allocator: std.mem.Allocator) !db_mod.StoreEnv(schema.infos, .{
    tenant.persistence.infos,
    user.persistence.infos,
    task.persistence.infos,
    file.persistence.infos,
    notify.persistence.infos,
    audit.persistence.infos,
    mail_template.persistence.infos,
    ai.persistence.provider_infos,
    ai.persistence.session_infos,
    ai.persistence.message_infos,
    ai.persistence.approval_infos,
    ai.persistence.run_infos,
}) {
    return db_mod.StoreEnv(schema.infos, .{
        tenant.persistence.infos,
        user.persistence.infos,
        task.persistence.infos,
        file.persistence.infos,
        notify.persistence.infos,
        audit.persistence.infos,
        mail_template.persistence.infos,
        ai.persistence.provider_infos,
        ai.persistence.session_infos,
        ai.persistence.message_infos,
        ai.persistence.approval_infos,
        ai.persistence.run_infos,
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
        audit.persistence.infos,
        mail_template.persistence.infos,
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
    try svc.validatePasswordResetToken(info.user_id, info.raw);

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
    try svc.verifyEmail(id, info.raw);

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

    try std.testing.expectError(error.InvalidCredentials, svc.changePassword(id, "wrong", "newpassword123"));
    try std.testing.expectError(error.InvalidPassword, svc.changePassword(id, "hash", "short"));
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
    var registry = zigmodu.RateLimiterRegistry.init(allocator, 100, 1);
    defer registry.deinit();
    var mailer = mail.Mailer.init(allocator, std.testing.io, "", 587, "", "", "test@localhost", true, false);
    var task_store = task.persistence.TaskStore.init(allocator, env.client);
    var task_svc = task.service.TaskService.init(&task_store, std.testing.io, 3);
    var notify_store = notify.persistence.NotificationStore.init(allocator, env.client);
    var notify_svc = notify.service.NotificationService.init(allocator, std.testing.io, &notify_store);
    var audit_store = audit.persistence.AuditStore.init(allocator, env.client);
    var audit_svc = audit.service.AuditService.init(allocator, std.testing.io, &audit_store);
    var template_store = mail_template.persistence.TemplateStore.init(allocator, env.client);
    var template_svc = mail_template.service.MailTemplateService.init(allocator, std.testing.io, &template_store);
    var auth_api = auth.api.AuthApi(@TypeOf(svc)).init(&svc, "http://localhost:3001", &registry, &mailer, &task_svc, &notify_svc, &audit_svc, &template_svc, 1);

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

test "audit log: create, filter by actor/action/keyword, paginate" {
    const allocator = std.testing.allocator;
    var env = try openMemory(allocator);
    defer env.deinit();
    var audit_store = audit.persistence.AuditStore.init(allocator, env.client);
    var audit_svc = audit.service.AuditService.init(allocator, std.testing.io, &audit_store);

    audit_svc.log(7, "Boss", "user.create", "user", 10, "创建用户 Alice", "127.0.0.1", true, 1);
    audit_svc.log(7, "Boss", "task.retry", "task", 3, "重试任务 #3", "127.0.0.1", true, 1);
    audit_svc.log(0, "", "auth.login.fail", "user", 0, "登录失败: x@y.z", "10.0.0.1", false, 1);

    var all = try audit_svc.list(1, 20, .{});
    defer all.free(allocator);
    try std.testing.expectEqual(@as(i64, 3), all.total);

    var by_actor = try audit_svc.list(1, 20, .{ .actor_user_id = 7 });
    defer by_actor.free(allocator);
    try std.testing.expectEqual(@as(i64, 2), by_actor.total);

    var by_action = try audit_svc.list(1, 20, .{ .action = "task." });
    defer by_action.free(allocator);
    try std.testing.expectEqual(@as(i64, 1), by_action.total);

    var by_kw = try audit_svc.list(1, 20, .{ .keyword = "登录失败" });
    defer by_kw.free(allocator);
    try std.testing.expectEqual(@as(i64, 1), by_kw.total);
    try std.testing.expectEqualStrings("auth.login.fail", by_kw.items[0].action);
    try std.testing.expect(!by_kw.items[0].success);
}

test "mail template: default fallback, upsert override, variable render" {
    const allocator = std.testing.allocator;
    var env = try openMemory(allocator);
    defer env.deinit();
    var tstore = mail_template.persistence.TemplateStore.init(allocator, env.client);
    var tsvc = mail_template.service.MailTemplateService.init(allocator, std.testing.io, &tstore);

    // 未配置时回退内置默认,变量被替换。
    var r1 = (try tsvc.render("verify_email", .{ .link = "https://a/verify", .email = "x@y.z" })).?;
    defer r1.free(allocator);
    try std.testing.expect(std.mem.indexOf(u8, r1.subject, "zenaipa") != null);
    try std.testing.expect(std.mem.indexOf(u8, r1.body, "https://a/verify") != null);
    try std.testing.expect(std.mem.indexOf(u8, r1.body, "x@y.z") != null);

    // upsert 覆盖后渲染用自定义内容。
    try tsvc.upsert("verify_email", "自定义主题 {app_name}", "链接: {link}");
    var r2 = (try tsvc.render("verify_email", .{ .link = "https://b/verify", .email = "a@b.c" })).?;
    defer r2.free(allocator);
    try std.testing.expectEqualStrings("自定义主题 zenaipa", r2.subject);
    try std.testing.expectEqualStrings("链接: https://b/verify", r2.body);

    // 未知 code → null。
    try std.testing.expect((try tsvc.render("nope", .{ .link = "x", .email = "y" })) == null);
}

test "dashboard counts: countAll + registration trend buckets" {
    const allocator = std.testing.allocator;
    var env = try openMemory(allocator);
    defer env.deinit();
    var store = user.persistence.UserStore.init(allocator, env.client);
    var file_store = file.persistence.FileStore.init(allocator, env.client);
    var notify_store = notify.persistence.NotificationStore.init(allocator, env.client);
    var tenant_store = tenant.persistence.TenantStore.init(allocator, env.client);

    _ = try store.createUser("A", "a@x.com", "h", false, false, 1, 100);
    _ = try store.createUser("B", "b@x.com", "h", false, false, 1, 150);
    try std.testing.expectEqual(@as(i64, 2), try store.countAll());
    try std.testing.expectEqual(@as(i64, 2), try store.countRegisteredBetween(0, 200));
    try std.testing.expectEqual(@as(i64, 1), try store.countRegisteredBetween(120, 160)); // 桶边界 [start, end)
    try std.testing.expectEqual(@as(i64, 0), try store.countRegisteredBetween(200, 300));

    _ = try file_store.create("a.txt", "k", "text/plain", 3, 1, 1, 100);
    _ = try notify_store.create(1, "t", "b", "info", 100);
    try std.testing.expectEqual(@as(i64, 1), try file_store.countAll());
    try std.testing.expectEqual(@as(i64, 1), try notify_store.countAll());
    try std.testing.expectEqual(@as(i64, 0), try tenant_store.countAll());
    _ = try tenant_store.create("Acme", "active", 100);
    try std.testing.expectEqual(@as(i64, 1), try tenant_store.countAll());
}

test "admin-only endpoints reject missing/non-admin tokens" {
    const allocator = std.testing.allocator;
    var env = try openMemory(allocator);
    defer env.deinit();
    var store = user.persistence.UserStore.init(allocator, env.client);
    var sec = zigmodu.security.AppSecurity.init(allocator, std.testing.io, .{ .jwt_secret = "testkit-secret" });
    var svc = user.service.UserService.init(&store, &sec, std.testing.io, 3600, 86400);

    var audit_store = audit.persistence.AuditStore.init(allocator, env.client);
    var audit_svc = audit.service.AuditService.init(allocator, std.testing.io, &audit_store);
    var tstore = mail_template.persistence.TemplateStore.init(allocator, env.client);
    var tsvc = mail_template.service.MailTemplateService.init(allocator, std.testing.io, &tstore);

    const plain_uid = try store.createUser("Alice", "alice@example.com", "hash", false, false, 1, 100);
    const admin_uid = try store.createUser("Boss", "boss@example.com", "hash", false, true, 1, 100);

    var uid_buf: [32]u8 = undefined;
    const plain_token = try sec.module.generateTokenWithTenant(try std.fmt.bufPrint(&uid_buf, "{d}", .{plain_uid}), &.{}, "1");
    defer allocator.free(plain_token);
    const admin_token = try sec.module.generateTokenWithTenant(try std.fmt.bufPrint(&uid_buf, "{d}", .{admin_uid}), &.{"admin"}, "1");
    defer allocator.free(admin_token);

    var server = zigmodu.http.Server.init(std.testing.io, allocator, 0);
    defer server.deinit();
    var g = server.group("/api/v1");
    var audit_api = audit.api.AuditApi(@TypeOf(audit_svc), @TypeOf(svc)).init(&audit_svc, &svc);
    try audit_api.registerRoutes(&g);
    var mt_api = mail_template.api.MailTemplateApi(@TypeOf(tsvc), @TypeOf(svc)).init(&tsvc, &svc);
    try mt_api.registerRoutes(&g);

    // 无 token → 401。
    var anon = try zigmodu.http.Testkit.dispatch(&server, .GET, "/api/v1/audit-logs", null);
    defer anon.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 401), anon.status_code);

    // 普通用户 token → 403(后端再次校验 admin,而非仅依赖前端隐藏)。
    var hdr: [512]u8 = undefined;
    var denied = try zigmodu.http.Testkit.dispatchOpts(&server, .GET, "/api/v1/audit-logs", .{
        .headers = &.{.{ "authorization", try std.fmt.bufPrint(&hdr, "Bearer {s}", .{plain_token}) }},
    });
    defer denied.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 403), denied.status_code);

    // admin token → 200。
    var allowed = try zigmodu.http.Testkit.dispatchOpts(&server, .GET, "/api/v1/audit-logs", .{
        .headers = &.{.{ "authorization", try std.fmt.bufPrint(&hdr, "Bearer {s}", .{admin_token}) }},
    });
    defer allowed.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), allowed.status_code);

    // 模板 PUT 无 token → 401。
    var anon_put = try zigmodu.http.Testkit.dispatch(&server, .PUT, "/api/v1/email-templates/verify_email", null);
    defer anon_put.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 401), anon_put.status_code);
}

test "ai: provider key encryption round-trip + tamper detection" {
    const allocator = std.testing.allocator;
    var env = try openMemory(allocator);
    defer env.deinit();
    var ai_store = ai.persistence.AiStore.init(allocator, env.client);
    var user_store = user.persistence.UserStore.init(allocator, env.client);
    var task_store = task.persistence.TaskStore.init(allocator, env.client);
    var audit_store = audit.persistence.AuditStore.init(allocator, env.client);
    var tenant_store = tenant.persistence.TenantStore.init(allocator, env.client);
    var notify_store = notify.persistence.NotificationStore.init(allocator, env.client);
    var notify_svc = notify.service.NotificationService.init(allocator, std.testing.io, &notify_store);

    const RefA = struct {
        var user_store_ref: *user.persistence.UserStore = undefined;
        var task_store_ref: *task.persistence.TaskStore = undefined;
        var audit_store_ref: *audit.persistence.AuditStore = undefined;
        var tenant_store_ref: *tenant.persistence.TenantStore = undefined;
        var ai_store_ref: *ai.persistence.AiStore = undefined;
        var notify_ref: *notify.service.NotificationService = undefined;
    };
    RefA.user_store_ref = &user_store;
    RefA.task_store_ref = &task_store;
    RefA.audit_store_ref = &audit_store;
    RefA.tenant_store_ref = &tenant_store;
    RefA.ai_store_ref = &ai_store;
    RefA.notify_ref = &notify_svc;
    const refs = ai.service.SkillsRefs{
        .user_store = RefA.user_store_ref,
        .task_store = RefA.task_store_ref,
        .audit_store = RefA.audit_store_ref,
        .tenant_store = RefA.tenant_store_ref,
        .ai_store = RefA.ai_store_ref,
        .notify_svc = RefA.notify_ref,
    };

    var svc = try ai.service.AiService.init(allocator, std.testing.io, &ai_store, .{ .key_secret = "master-secret" }, refs);
    defer svc.deinit();

    // 加密 → 解密 round-trip。
    const enc = try svc.encryptKeys(allocator, "[\"sk-abc\"]");
    defer allocator.free(enc);
    const dec = try svc.decryptKeys(allocator, enc);
    defer allocator.free(dec);
    try std.testing.expectEqualStrings("[\"sk-abc\"]", dec);

    // 错误主密钥 → 认证失败(防篡改/防错配)。
    var svc2 = try ai.service.AiService.init(allocator, std.testing.io, &ai_store, .{ .key_secret = "wrong-secret" }, refs);
    defer svc2.deinit();
    try std.testing.expectError(error.AuthenticationFailed, svc2.decryptKeys(allocator, enc));

    // 未配置主密钥 → MissingKeySecret。
    var svc3 = try ai.service.AiService.init(allocator, std.testing.io, &ai_store, .{ .key_secret = "" }, refs);
    defer svc3.deinit();
    try std.testing.expectError(error.MissingKeySecret, svc3.encryptKeys(allocator, "x"));
}

test "ai: notify.send approval pending → approve executes, double-resolve rejected" {
    const allocator = std.testing.allocator;
    var env = try openMemory(allocator);
    defer env.deinit();
    var ai_store = ai.persistence.AiStore.init(allocator, env.client);
    var user_store = user.persistence.UserStore.init(allocator, env.client);
    var task_store = task.persistence.TaskStore.init(allocator, env.client);
    var audit_store = audit.persistence.AuditStore.init(allocator, env.client);
    var tenant_store = tenant.persistence.TenantStore.init(allocator, env.client);
    var notify_store = notify.persistence.NotificationStore.init(allocator, env.client);
    var notify_svc = notify.service.NotificationService.init(allocator, std.testing.io, &notify_store);
    const refs = ai.service.SkillsRefs{
        .user_store = &user_store,
        .task_store = &task_store,
        .audit_store = &audit_store,
        .tenant_store = &tenant_store,
        .ai_store = &ai_store,
        .notify_svc = &notify_svc,
    };
    var svc = try ai.service.AiService.init(allocator, std.testing.io, &ai_store, .{ .key_secret = "master-secret" }, refs);
    defer svc.deinit();

    _ = try user_store.createUser("Alice", "a@x.com", "hash", false, false, 1, 100);
    const approval_id = try ai_store.createApproval(1, 7, "zenaipa.notify.send", "{\"user_id\":1,\"title\":\"hi\",\"body\":\"hello\",\"kind\":\"info\"}", 100);
    try std.testing.expectEqual(@as(i64, 0), try notify_svc.unreadCount(1));

    // 批准 → 实际发送通知。
    try std.testing.expect(try svc.approve(allocator, approval_id, 1, true));
    try std.testing.expectEqual(@as(i64, 1), try notify_svc.unreadCount(1));

    // 重复处理 → false。
    try std.testing.expect(!try svc.approve(allocator, approval_id, 1, true));
    const row = (try ai_store.getApproval(approval_id)).?;
    defer row.free(allocator);
    try std.testing.expectEqualStrings("approved", row.status);
}

test "ai: run quota counts within rolling window + health workflow" {
    const allocator = std.testing.allocator;
    var env = try openMemory(allocator);
    defer env.deinit();
    var ai_store = ai.persistence.AiStore.init(allocator, env.client);
    var user_store = user.persistence.UserStore.init(allocator, env.client);
    var task_store = task.persistence.TaskStore.init(allocator, env.client);
    var audit_store = audit.persistence.AuditStore.init(allocator, env.client);
    var tenant_store = tenant.persistence.TenantStore.init(allocator, env.client);
    var notify_store = notify.persistence.NotificationStore.init(allocator, env.client);
    var notify_svc = notify.service.NotificationService.init(allocator, std.testing.io, &notify_store);
    const refs = ai.service.SkillsRefs{
        .user_store = &user_store,
        .task_store = &task_store,
        .audit_store = &audit_store,
        .tenant_store = &tenant_store,
        .ai_store = &ai_store,
        .notify_svc = &notify_svc,
    };
    var svc = try ai.service.AiService.init(allocator, std.testing.io, &ai_store, .{ .key_secret = "master-secret" }, refs);
    defer svc.deinit();

    // 用量快照字段(tokens/steps/tool_calls/tool_errors)持久化往返。
    _ = try ai_store.createRun(0, 7, 1, "chat", "hi", "test-model", 0, 0, 0, 0, 0, "ok", "", 100);
    _ = try ai_store.createRun(0, 7, 1, "chat", "hi", "test-model", 12, 34, 3, 2, 1, "ok", "", 200);
    _ = try ai_store.createRun(0, 8, 1, "chat", "hi", "test-model", 0, 0, 0, 0, 0, "ok", "", 300);
    try std.testing.expectEqual(@as(i64, 2), try ai_store.runCountForUser(7, 50));
    // zent v0.29.4:Sum 返回 f64;quotaForUser 用 @intFromFloat 显式转换并聚合校验。
    {
        const agg = try ai_store.quotaForUser(7, 50);
        try std.testing.expectEqual(@as(i64, 12), agg.tokens_in);
        try std.testing.expectEqual(@as(i64, 34), agg.tokens_out);
    }
    {
        // listRuns 按 created_at 降序:最新一条(200)带用量快照。
        var runs = try ai_store.listRuns(7, 1, 10);
        defer runs.free(allocator);
        try std.testing.expectEqual(@as(i64, 12), runs.items[0].tokens_in);
        try std.testing.expectEqual(@as(i64, 34), runs.items[0].tokens_out);
        try std.testing.expectEqual(@as(i64, 3), runs.items[0].steps);
        try std.testing.expectEqual(@as(i64, 2), runs.items[0].tool_calls);
        try std.testing.expectEqual(@as(i64, 1), runs.items[0].tool_errors);
    }

    // 用量增量逐字段 fetchAdd 累加 → currentAgentMetrics 快照回读(并发安全,不丢增量)。
    svc.addAgentMetrics(.{ .runs = 1, .steps = 3, .tool_calls = 2, .tool_errors = 1 });
    svc.addAgentMetrics(.{ .runs = 1, .steps = 1 });
    const acc = svc.currentAgentMetrics().toStats();
    try std.testing.expectEqual(@as(usize, 2), acc.runs);
    try std.testing.expectEqual(@as(usize, 4), acc.steps);
    try std.testing.expectEqual(@as(usize, 2), acc.tool_calls);
    try std.testing.expectEqual(@as(usize, 1), acc.tool_errors);

    // 无 LLM 的健康工作流:两个只读技能按序执行。
    var result = try svc.runHealthWorkflow(allocator, 1, 1);
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 2), result.steps.items.len);
    try std.testing.expectEqualStrings("task_stats", result.steps.items[0].name);
    try std.testing.expectEqualStrings("tenant_list", result.steps.items[1].name);
}

test "ai: usageDelta computes per-run AgentMetrics increment" {
    const Stats = zigmodu.ai.AgentMetrics.Stats;
    const before = Stats{ .runs = 5, .steps = 10, .tool_calls = 3, .tool_errors = 1, .tool_denied = 0, .max_steps_hits = 0, .budget_exhausted = 0, .canceled = 0 };
    const after = Stats{ .runs = 6, .steps = 13, .tool_calls = 5, .tool_errors = 2, .tool_denied = 1, .max_steps_hits = 0, .budget_exhausted = 0, .canceled = 1 };
    const d = ai.service.usageDelta(before, after);
    try std.testing.expectEqual(@as(usize, 1), d.runs);
    try std.testing.expectEqual(@as(usize, 3), d.steps);
    try std.testing.expectEqual(@as(usize, 2), d.tool_calls);
    try std.testing.expectEqual(@as(usize, 1), d.tool_errors);
    try std.testing.expectEqual(@as(usize, 1), d.tool_denied);
    try std.testing.expectEqual(@as(usize, 1), d.canceled);
    // 前后快照一致(如 run 被拒绝)时差值为 0。
    const d0 = ai.service.usageDelta(after, after);
    try std.testing.expectEqual(@as(usize, 0), d0.runs);
    try std.testing.expectEqual(@as(usize, 0), d0.steps);
    try std.testing.expectEqual(@as(usize, 0), d0.tool_calls);
    try std.testing.expectEqual(@as(usize, 0), d0.tool_errors);
    try std.testing.expectEqual(@as(usize, 0), d0.tool_denied);
    try std.testing.expectEqual(@as(usize, 0), d0.canceled);
}

test "ai: message reasoning_content persists and round-trips" {
    const allocator = std.testing.allocator;
    var env = try openMemory(allocator);
    defer env.deinit();
    var ai_store = ai.persistence.AiStore.init(allocator, env.client);

    _ = try ai_store.addMessage(1, "user", "你好", "", 100);
    _ = try ai_store.addMessage(1, "assistant", "这是回答", "这是推理过程(thinking chain)", 110);

    var msgs = try ai_store.listMessages(1);
    defer msgs.free(allocator);
    try std.testing.expectEqual(@as(i64, 2), msgs.total);
    try std.testing.expectEqualStrings("这是回答", msgs.items[1].content);
    try std.testing.expectEqualStrings("这是推理过程(thinking chain)", msgs.items[1].reasoning_content);
    try std.testing.expectEqualStrings("", msgs.items[0].reasoning_content);
}

test "ai: deleting a session cascades to its messages" {
    const allocator = std.testing.allocator;
    var env = try openMemory(allocator);
    defer env.deinit();
    var ai_store = ai.persistence.AiStore.init(allocator, env.client);

    const sid = try ai_store.createSession(7, 1, "会话", 100);
    _ = try ai_store.addMessage(sid, "user", "hi", "", 100);
    _ = try ai_store.addMessage(sid, "assistant", "hello", "thinking", 110);

    try std.testing.expect(try ai_store.deleteSession(sid, 7));
    var msgs = try ai_store.listMessages(sid);
    defer msgs.free(allocator);
    try std.testing.expectEqual(@as(i64, 0), msgs.total); // 消息已级联清除
    try std.testing.expect((try ai_store.getSession(sid, 7)) == null);
}

test "ai: approval resolve writes audit log" {
    const allocator = std.testing.allocator;
    var env = try openMemory(allocator);
    defer env.deinit();
    var ai_store = ai.persistence.AiStore.init(allocator, env.client);
    var user_store = user.persistence.UserStore.init(allocator, env.client);
    var task_store = task.persistence.TaskStore.init(allocator, env.client);
    var audit_store = audit.persistence.AuditStore.init(allocator, env.client);
    var tenant_store = tenant.persistence.TenantStore.init(allocator, env.client);
    var notify_store = notify.persistence.NotificationStore.init(allocator, env.client);
    var notify_svc = notify.service.NotificationService.init(allocator, std.testing.io, &notify_store);
    const refs = ai.service.SkillsRefs{
        .user_store = &user_store,
        .task_store = &task_store,
        .audit_store = &audit_store,
        .tenant_store = &tenant_store,
        .ai_store = &ai_store,
        .notify_svc = &notify_svc,
    };
    var svc = try ai.service.AiService.init(allocator, std.testing.io, &ai_store, .{ .key_secret = "master-secret" }, refs);
    defer svc.deinit();

    const approval_id = try ai_store.createApproval(1, 7, "zenaipa.notify.send", "{\"user_id\":1,\"title\":\"t\",\"body\":\"b\",\"kind\":\"info\"}", 100);
    _ = try user_store.createUser("Boss", "boss@x.com", "hash", false, true, 1, 100);
    _ = try svc.approve(allocator, approval_id, 2, true);

    // 审计日志应有 ai.approval 记录。
    var logs = try audit_store.list(1, 10, .{ .action = "ai." });
    defer logs.free(allocator);
    try std.testing.expectEqual(@as(i64, 1), logs.total);
    try std.testing.expectEqualStrings("ai.approval", logs.items[0].action);
}

test "session revocation: token_version bump invalidates old JWTs" {
    const allocator = std.testing.allocator;
    var env = try openMemory(allocator);
    defer env.deinit();
    var store = user.persistence.UserStore.init(allocator, env.client);
    var sec = zigmodu.security.AppSecurity.init(allocator, std.testing.io, .{ .jwt_secret = "testkit-secret" });
    const uid = try store.createUser("Alice", "a@x.com", "hash", false, false, 1, 100);

    const Whoami = struct {
        fn h(ctx: *zigmodu.http.Context) !void {
            const mw_mod = @import("middleware/auth.zig");
            const uid_ = mw_mod.authUserId(ctx) orelse {
                try ctx.sendErrorResponse(401, 401, "未登录或登录已过期");
                return;
            };
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "", .data = .{ .uid = uid_ } });
        }
    };

    var server = zigmodu.http.Server.init(std.testing.io, allocator, 0);
    defer server.deinit();
    var g = server.group("/api/v1");
    var guarded = try g.use(zigmodu.http.http_middleware.jwtAuthWithSecurity(&sec.module));
    guarded = try guarded.use(@import("middleware/auth.zig").tokenVersionGuard(&sec, &store));
    try guarded.get("/whoami", Whoami.h, null);

    var uid_buf: [32]u8 = undefined;
    const token = try sec.module.generateTokenWithTenantAndVersion(try std.fmt.bufPrint(&uid_buf, "{d}", .{uid}), &.{}, "1", 0);
    defer allocator.free(token);
    var hdr: [512]u8 = undefined;
    const auth_header = try std.fmt.bufPrint(&hdr, "Bearer {s}", .{token});

    // 版本未递增 → 正常访问。
    var ok = try zigmodu.http.Testkit.dispatchOpts(&server, .GET, "/api/v1/whoami", .{ .headers = &.{.{ "authorization", auth_header }} });
    defer ok.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 200), ok.status_code);

    // 改密/踢下线(版本 +1)→ 旧 token 立即失效。
    const now = zigmodu.time.wallClockSeconds(std.testing.io);
    try store.bumpTokenVersion(uid, now);
    var denied = try zigmodu.http.Testkit.dispatchOpts(&server, .GET, "/api/v1/whoami", .{ .headers = &.{.{ "authorization", auth_header }} });
    defer denied.deinit(allocator);
    try std.testing.expectEqual(@as(u16, 401), denied.status_code);
}
