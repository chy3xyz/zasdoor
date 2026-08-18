//! Unit tests for zasdoor. DB-backed tests use an in-memory zent store;
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
const iam = @import("modules/iam/root.zig");
const oauth = @import("modules/oauth/root.zig");
const eventstore = @import("modules/eventstore/root.zig");
const authzm = @import("modules/authz/root.zig");
const mfa = @import("modules/mfa/root.zig");
const web3 = @import("modules/web3/root.zig");
const agent = @import("modules/agent/root.zig");
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
    iam.persistence.infos,
    eventstore.persistence.infos,
    mfa.persistence.infos,
    web3.persistence.infos,
    agent.persistence.infos,
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
        iam.persistence.infos,
        eventstore.persistence.infos,
        mfa.persistence.infos,
        web3.persistence.infos,
        agent.persistence.infos,
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
        iam.persistence.infos,
        eventstore.persistence.infos,
        mfa.persistence.infos,
        web3.persistence.infos,
        agent.persistence.infos,
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
    try std.testing.expect(std.mem.indexOf(u8, r1.subject, "zasdoor") != null);
    try std.testing.expect(std.mem.indexOf(u8, r1.body, "https://a/verify") != null);
    try std.testing.expect(std.mem.indexOf(u8, r1.body, "x@y.z") != null);

    // upsert 覆盖后渲染用自定义内容。
    try tsvc.upsert("verify_email", "自定义主题 {app_name}", "链接: {link}");
    var r2 = (try tsvc.render("verify_email", .{ .link = "https://b/verify", .email = "a@b.c" })).?;
    defer r2.free(allocator);
    try std.testing.expectEqualStrings("自定义主题 zasdoor", r2.subject);
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
    const approval_id = try ai_store.createApproval(1, 7, "zasdoor.notify.send", "{\"user_id\":1,\"title\":\"hi\",\"body\":\"hello\",\"kind\":\"info\"}", 100);
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

    const approval_id = try ai_store.createApproval(1, 7, "zasdoor.notify.send", "{\"user_id\":1,\"title\":\"t\",\"body\":\"b\",\"kind\":\"info\"}", 100);
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

test "user: token_version atomic bump + column projection" {
    const allocator = std.testing.allocator;
    var env = try openMemory(allocator);
    defer env.deinit();
    var store = user.persistence.UserStore.init(allocator, env.client);
    const id = try store.createUser("Alice", "alice@example.com", "hash", false, false, 1, 100);

    // 列投影:只读 token_version。
    try std.testing.expectEqual(@as(?i64, 0), try store.getTokenVersion(id));
    // 原子递增(改密/踢下线 → 旧 JWT 失效)。
    try store.bumpTokenVersion(id, 200);
    try std.testing.expectEqual(@as(?i64, 1), try store.getTokenVersion(id));
    try store.bumpTokenVersion(id, 300);
    try std.testing.expectEqual(@as(?i64, 2), try store.getTokenVersion(id));
    // 不存在用户:递增报 UserNotFound,投影返回 null。
    try std.testing.expectError(error.UserNotFound, store.bumpTokenVersion(9999, 400));
    try std.testing.expectEqual(@as(?i64, null), try store.getTokenVersion(9999));
}

test "iam: project + application + role lifecycle" {
    const allocator = std.testing.allocator;
    var env = try openMemory(allocator);
    defer env.deinit();
    var iam_store = iam.persistence.IamStore.init(allocator, env.client);
    var sec = zigmodu.security.AppSecurity.init(allocator, std.testing.io, .{ .jwt_secret = "test-secret" });
    var iam_svc = iam.service.IamService.init(allocator, std.testing.io, &iam_store, &sec);

    // Project
    const pid = try iam_svc.createProject(1, 0, "CHY", "main project");
    const proj = (try iam_svc.getProject(pid)).?;
    defer proj.free(allocator);
    try std.testing.expectEqualStrings("CHY", proj.name);

    // Application (OAuth client) - secret is only returned once.
    var creds = try iam_svc.createApplication(1, pid, "CHY Web", "web", "[\"https://app.chy.xyz/callback\"]", "[]", "[]", "[\"authorization_code\",\"refresh_token\"]", "[\"code\"]", "openid profile email", 3600, 0, true);
    defer creds.deinit(allocator);
    try std.testing.expect(creds.client_id.len > 0);
    try std.testing.expect(creds.client_secret.len > 0);

    // Client authentication round-trips with the plaintext secret.
    const app_opt = try iam_svc.authenticateClient(creds.client_id, creds.client_secret);
    const app = app_opt orelse return error.TestFailed;
    defer app.free(allocator);
    try std.testing.expectEqualStrings("CHY Web", app.name);

    // Wrong secret is rejected.
    const bad_opt = try iam_svc.authenticateClient(creds.client_id, "wrong-secret");
    try std.testing.expect(bad_opt == null);

    // Role + assignment + role-key resolution.
    const rid = try iam_svc.createRole(1, pid, "admin", "Administrator", "[\"user.read\",\"user.write\"]");
    _ = try userCreateHelper(allocator, env, &iam_svc, "bob@x.com");
    const uid = 1;
    _ = try iam_svc.assignRole(1, uid, rid, pid);
    const keys = try iam_svc.roleKeysForUser(uid, pid);
    defer allocator.free(keys);
    try std.testing.expectEqual(@as(usize, 1), keys.len);
    defer allocator.free(keys[0]);
    try std.testing.expectEqualStrings("admin", keys[0]);
}

test "iam: session create + revoke + list" {
    const allocator = std.testing.allocator;
    var env = try openMemory(allocator);
    defer env.deinit();
    var iam_store = iam.persistence.IamStore.init(allocator, env.client);
    var sec = zigmodu.security.AppSecurity.init(allocator, std.testing.io, .{ .jwt_secret = "test-secret" });
    var iam_svc = iam.service.IamService.init(allocator, std.testing.io, &iam_store, &sec);

    const sid = try iam_svc.createSession(1, 7, 0, "dev1", "127.0.0.1", "curl/8", "password", 3600);
    var sessions = try iam_svc.listSessionsForUser(7);
    defer sessions.free(allocator);
    try std.testing.expectEqual(@as(i64, 1), sessions.total);
    try std.testing.expectEqual(sid, sessions.items[0].id);

    try iam_svc.revokeSession(sid);
    const row = (try iam_svc.getSession(sid)).?;
    row.free(allocator);
    try std.testing.expect(row.revoked_at != 0);
}

test "oauth: authorization code + PKCE full flow" {
    const allocator = std.testing.allocator;
    var env = try openMemory(allocator);
    defer env.deinit();
    var iam_store = iam.persistence.IamStore.init(allocator, env.client);
    var user_store = user.persistence.UserStore.init(allocator, env.client);
    var sec = zigmodu.security.AppSecurity.init(allocator, std.testing.io, .{ .jwt_secret = "oauth-secret" });
    var iam_svc = iam.service.IamService.init(allocator, std.testing.io, &iam_store, &sec);
    var user_svc = user.service.UserService.init(&user_store, &sec, std.testing.io, 3600, 86400);
    _ = try user_store.createUser("Alice", "alice@example.com", "hash", false, true, 1, 100);

    const pid = try iam_svc.createProject(1, 0, "P", "");
    var creds = try iam_svc.createApplication(1, pid, "App", "web", "[\"https://app.example/cb\"]", "[]", "[]", "[\"authorization_code\"]", "[\"code\"]", "openid profile email offline_access", 3600, 0, false);
    defer creds.deinit(allocator);

    var oauth_svc = oauth.service.OAuthService.init(allocator, std.testing.io, &iam_svc, &user_svc, &sec, "http://localhost:8080");

    // S256 PKCE challenge for verifier "very-long-random-verifier-string".
    const verifier = "very-long-random-verifier-string";
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(verifier, &digest, .{});
    const enc = std.base64.url_safe_no_pad.Encoder;
    const n = enc.calcSize(32);
    var challenge_buf: [64]u8 = undefined;
    _ = enc.encode(challenge_buf[0..n], &digest);

    // Authorize: user 1 (admin user id = 1), PKCE + nonce + state.
    const authz = try oauth_svc.authorize(creds.client_id, "https://app.example/cb", "code", "openid profile email offline_access", "st123", "nonce123", challenge_buf[0..n], "S256", 1);
    defer allocator.free(authz.code);
    defer allocator.free(authz.redirect_uri);
    defer if (authz.state) |st| allocator.free(st);

    // Exchange the code with the PKCE verifier.
    const issue = try oauth_svc.token("authorization_code", creds.client_id, creds.client_secret, authz.code, "https://app.example/cb", verifier, null, null);
    defer allocator.free(issue.access_token);
    defer allocator.free(issue.scope);
    defer if (issue.id_token) |it| allocator.free(it);
    defer if (issue.refresh_token) |rt| allocator.free(rt);

    try std.testing.expect(issue.access_token.len > 0);
    try std.testing.expect(issue.id_token != null);
    try std.testing.expect(issue.refresh_token != null);

    // Access token introspects as active.
    const insp = oauth_svc.introspect(issue.access_token);
    defer oauth_svc.freeIntrospection(insp);
    try std.testing.expect(insp.active);
    try std.testing.expectEqualStrings("1", insp.sub.?);
    try std.testing.expectEqualStrings(creds.client_id, insp.client_id.?);
}

test "oauth: client credentials grant + refresh token rotation" {
    const allocator = std.testing.allocator;
    var env = try openMemory(allocator);
    defer env.deinit();
    var iam_store = iam.persistence.IamStore.init(allocator, env.client);
    var user_store = user.persistence.UserStore.init(allocator, env.client);
    var sec = zigmodu.security.AppSecurity.init(allocator, std.testing.io, .{ .jwt_secret = "oauth-secret" });
    var iam_svc = iam.service.IamService.init(allocator, std.testing.io, &iam_store, &sec);
    var user_svc = user.service.UserService.init(&user_store, &sec, std.testing.io, 3600, 86400);
    _ = try user_store.createUser("Alice", "alice@example.com", "hash", false, true, 1, 100);

    const pid = try iam_svc.createProject(1, 0, "P", "");
    var creds = try iam_svc.createApplication(1, pid, "Svc", "machine", "[]", "[]", "[]", "[\"client_credentials\"]", "[\"code\"]", "openid", 3600, 0, false);
    defer creds.deinit(allocator);

    var oauth_svc = oauth.service.OAuthService.init(allocator, std.testing.io, &iam_svc, &user_svc, &sec, "http://localhost:8080");

    // Client credentials: no user involved.
    const cc = try oauth_svc.token("client_credentials", creds.client_id, creds.client_secret, null, null, null, "openid", null);
    defer allocator.free(cc.access_token);
    defer allocator.free(cc.scope);
    try std.testing.expect(cc.id_token == null);
    try std.testing.expect(cc.refresh_token == null);
    try std.testing.expect(cc.access_token.len > 0);
    const insp_cc = oauth_svc.introspect(cc.access_token);
    defer oauth_svc.freeIntrospection(insp_cc);
    try std.testing.expect(insp_cc.active);
    try std.testing.expect(insp_cc.sub != null and std.mem.startsWith(u8, insp_cc.sub.?, "app_"));

    // Wrong client secret is rejected.
    try std.testing.expectError(error.InvalidClient, oauth_svc.token("client_credentials", creds.client_id, "nope", null, null, null, "openid", null));
}

test "oauth: jwt sign/verify round-trip" {
    const allocator = std.testing.allocator;
    const mod = @import("modules/oauth/jwt.zig");
    const token = try mod.sign(allocator, "secret", "{\"sub\":\"42\",\"scope\":\"openid\"}");
    defer allocator.free(token);
    const payload = try mod.verify(allocator, "secret", token);
    defer allocator.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, "42") != null);
    try std.testing.expectError(error.InvalidSignature, mod.verify(allocator, "wrong", token));
}

fn userCreateHelper(allocator: std.mem.Allocator, env: anytype, iam_svc: anytype, email: []const u8) !i64 {
    _ = iam_svc;
    var store = user.persistence.UserStore.init(allocator, env.client);
    return store.createUser(email, email, "hash", false, false, 1, 100);
}

test "eventstore: append with optimistic concurrency + replay" {
    const allocator = std.testing.allocator;
    var env = try openMemory(allocator);
    defer env.deinit();
    var es = eventstore.persistence.EventStore.init(allocator, env.client);

    // Fresh aggregate: append with version 0.
    const e1 = try es.appendNew(1, "user", "usr_1", "user.created", "{\"name\":\"Alice\"}", 7, 100);
    const e2 = try es.append(1, "user", "usr_1", 1, "user.verified", "{}", 7, 110);
    try std.testing.expect(e2 > e1);

    // Version conflict: expected 1 but current is 2.
    try std.testing.expectError(error.VersionConflict, es.append(1, "user", "usr_1", 1, "user.changed", "{}", 7, 120));

    // Replay the stream oldest-first.
    const stream = try es.streamOf("user", "usr_1");
    defer {
        for (stream) |r| r.free(allocator);
        allocator.free(stream);
    }
    try std.testing.expectEqual(@as(usize, 2), stream.len);
    try std.testing.expectEqualStrings("user.created", stream[0].event_type);
    try std.testing.expectEqualStrings("user.verified", stream[1].event_type);
    try std.testing.expectEqual(@as(i64, 2), stream[1].aggregate_version);
}

test "eventstore: projection high-water mark advances incrementally" {
    const allocator = std.testing.allocator;
    var env = try openMemory(allocator);
    defer env.deinit();
    var es = eventstore.persistence.EventStore.init(allocator, env.client);

    _ = try es.appendNew(1, "org", "org_1", "organization.created", "{}", 1, 100);
    _ = try es.appendNew(1, "org", "org_1", "organization.updated", "{}", 1, 110);

    // A trivial "counter" projection: stores event count as its position.
    const CounterProjection = struct {
        fn run(a: std.mem.Allocator, store: *eventstore.persistence.EventStore, state: []const u8, ev: eventstore.persistence.EventRow) anyerror![]const u8 {
            _ = store;
            _ = state;
            return std.fmt.allocPrint(a, "{d}", .{ev.id});
        }
    };
    var projections = [_]eventstore.service.Projection{
        .{ .name = "test_counter", .run = CounterProjection.run },
    };
    var ev_svc = eventstore.service.EventService.init(allocator, std.testing.io, &es, &projections);
    try ev_svc.project();

    // After projecting, the high-water mark equals the second event's id.
    const pos = try es.getPosition("test_counter");
    try std.testing.expect(pos >= 2);
    try std.testing.expectEqual(@as(i64, 2), try es.allCount());
}

test "authz: role permission resolution -> ALLOW/DENY/UNKNOWN" {
    const allocator = std.testing.allocator;
    var env = try openMemory(allocator);
    defer env.deinit();
    var iam_store = iam.persistence.IamStore.init(allocator, env.client);
    var sec = zigmodu.security.AppSecurity.init(allocator, std.testing.io, .{ .jwt_secret = "secret" });
    var iam_svc = iam.service.IamService.init(allocator, std.testing.io, &iam_store, &sec);
    var az = authzm.service.AuthzService.init(allocator, &iam_svc);

    const pid = try iam_svc.createProject(1, 0, "DAO", "");
    const admin_role = try iam_svc.createRole(1, pid, "admin", "Admin", "[\"proposal.vote\",\"proposal.*\"]");
    const viewer_role = try iam_svc.createRole(1, pid, "viewer", "Viewer", "[\"proposal.read\"]");

    const bob = 2;
    const alice = 1;
    _ = try iam_svc.assignRole(1, bob, admin_role, pid);
    _ = try iam_svc.assignRole(1, alice, viewer_role, pid);

    const ctx = authzm.service.AuthContext{ .project_id = pid };
    // Admin can vote (exact) and delete (wildcard), but not read explicitly unless wildcard covers it.
    try std.testing.expectEqual(authzm.service.Decision.allow, try az.authorize(bob, "proposal", "vote", ctx));
    try std.testing.expectEqual(authzm.service.Decision.allow, try az.authorize(bob, "proposal", "delete", ctx));
    // Viewer can read but not vote.
    try std.testing.expectEqual(authzm.service.Decision.allow, try az.authorize(alice, "proposal", "read", ctx));
    try std.testing.expectEqual(authzm.service.Decision.unknown, try az.authorize(alice, "proposal", "vote", ctx));
    // Unknown subject: no roles.
    try std.testing.expectEqual(authzm.service.Decision.unknown, try az.authorize(9999, "proposal", "read", ctx));
}

test "iam: organization create + project scoping" {
    const allocator = std.testing.allocator;
    var env = try openMemory(allocator);
    defer env.deinit();
    var iam_store = iam.persistence.IamStore.init(allocator, env.client);
    var sec = zigmodu.security.AppSecurity.init(allocator, std.testing.io, .{ .jwt_secret = "secret" });
    var iam_svc = iam.service.IamService.init(allocator, std.testing.io, &iam_store, &sec);

    const org = try iam_svc.createOrganization(1, "Life++", "community", "life.plus");
    const p1 = try iam_svc.createProject(1, org, "LifeApp", "");
    const proj = (try iam_svc.getProject(p1)).?;
    proj.free(allocator);
    try std.testing.expectEqual(org, proj.org_id);

    var list = try iam_svc.listOrganizations(1, 50, 1);
    defer list.free(allocator);
    try std.testing.expectEqual(@as(i64, 1), list.total);
    try std.testing.expectEqualStrings("Life++", list.items[0].name);
}

test "mfa: totp generate + verify round-trip" {
    const allocator = std.testing.allocator;
    const totp = @import("modules/mfa/totp.zig");
    // RFC 4648 base32 round-trip: "Hello" -> "JBSWY3DP"
    const enc = try totp.base32Encode(allocator, "Hello");
    defer allocator.free(enc);
    try std.testing.expectEqualStrings("JBSWY3DP", enc);
    const dec = try totp.base32Decode(allocator, "JBSWY3DP");
    defer allocator.free(dec);
    try std.testing.expectEqualStrings("Hello", dec);

    // Generate a code at a fixed counter and verify it (window 0).
    const counter: u64 = 12345;
    const code = try totp.generateCode(allocator, "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", counter);
    defer allocator.free(code);
    try std.testing.expect(code.len == 6);
    try std.testing.expect(try totp.verify(allocator, "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", code, counter, 0));
    try std.testing.expect(!try totp.verify(allocator, "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ", "000000", counter + 1000, 0));
}

test "mfa: enroll -> verify -> enable -> second-factor login" {
    const allocator = std.testing.allocator;
    var env = try openMemory(allocator);
    defer env.deinit();
    var mfa_store = mfa.persistence.MfaStore.init(allocator, env.client);
    var sec = zigmodu.security.AppSecurity.init(allocator, std.testing.io, .{ .jwt_secret = "mfa-secret" });
    var svc = mfa.service.MfaService.init(allocator, std.testing.io, &mfa_store, &sec);
    const user_id: i64 = 7;

    const secret = try svc.enrollTotp(1, user_id);
    defer allocator.free(secret);
    try std.testing.expect(secret.len > 0);

    // Generate a valid code for the current time step and enable TOTP.
    const now = zigmodu.time.wallClockSeconds(std.testing.io);
    const counter = mfa.totp.counterAt(now, 30);
    const code = try mfa.totp.generateCode(allocator, secret, counter);
    defer allocator.free(code);

    try svc.verifyAndEnable(user_id, code);
    try std.testing.expect(svc.userHasMfa(user_id));

    // A fresh code at login time verifies as a second factor.
    const now2 = zigmodu.time.wallClockSeconds(std.testing.io);
    const c2 = mfa.totp.counterAt(now2, 30);
    const code2 = try mfa.totp.generateCode(allocator, secret, c2);
    defer allocator.free(code2);
    try std.testing.expect(try svc.verifyTotp(user_id, code2));
    try std.testing.expect(!try svc.verifyTotp(user_id, "999999"));
}

test "mfa: recovery codes issue, verify, single-use" {
    const allocator = std.testing.allocator;
    var env = try openMemory(allocator);
    defer env.deinit();
    var mfa_store = mfa.persistence.MfaStore.init(allocator, env.client);
    var sec = zigmodu.security.AppSecurity.init(allocator, std.testing.io, .{ .jwt_secret = "mfa-secret" });
    var svc = mfa.service.MfaService.init(allocator, std.testing.io, &mfa_store, &sec);
    const user_id: i64 = 9;

    const codes = try svc.generateRecoveryCodes(1, user_id, 5);
    defer {
        for (codes) |c| allocator.free(c);
        allocator.free(codes);
    }
    try std.testing.expectEqual(@as(usize, 5), codes.len);
    try std.testing.expect(codes[0].len > 0);

    // The first code verifies and is consumed.
    try std.testing.expect(try svc.verifyRecoveryCode(user_id, codes[0]));
    // Reusing it fails (single use).
    try std.testing.expectError(error.RecoveryMismatch, svc.verifyRecoveryCode(user_id, codes[0]));
    // Every code is distinct.
    try std.testing.expect(!std.mem.eql(u8, codes[0], codes[1]));
}

test "mfa: idp config parse + build authorize link" {
    const allocator = std.testing.allocator;
    var env = try openMemory(allocator);
    defer env.deinit();
    var mfa_store = mfa.persistence.MfaStore.init(allocator, env.client);
    var idp_svc = mfa.idp.IdpService.init(allocator, &mfa_store);

    const config_json = "{\"name\":\"Google\",\"type\":\"oidc\",\"authorize_url\":\"https://accounts.google.com/o/oauth2/v2/auth\",\"client_id\":\"abc123\",\"redirect_uri\":\"https://idp.local/cb\",\"scope\":\"openid profile email\"}";
    const url = try idp_svc.buildAuthorizeUrl(config_json, "st1", null);
    defer allocator.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "accounts.google.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "client_id=abc123") != null);
    try std.testing.expect(std.mem.indexOf(u8, url, "state=st1") != null);

    // Persist + list round-trip.
    _ = try idp_svc.create(1, "Google", "oidc", config_json, 0);
    const rows = try idp_svc.list(1);
    defer {
        for (rows) |r| r.free(allocator);
        allocator.free(rows);
    }
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqualStrings("Google", rows[0].name);
}

test "mfa: policy require_mfa + user capability" {
    const allocator = std.testing.allocator;
    var env = try openMemory(allocator);
    defer env.deinit();
    var mfa_store = mfa.persistence.MfaStore.init(allocator, env.client);
    var sec = zigmodu.security.AppSecurity.init(allocator, std.testing.io, .{ .jwt_secret = "mfa-secret" });
    var svc = mfa.service.MfaService.init(allocator, std.testing.io, &mfa_store, &sec);

    // Default: MFA not required.
    try std.testing.expect(!svc.mfaRequired(1));

    // Enable require_mfa via policy upsert.
    try mfa_store.upsertPolicy(1, true, true, true, zigmodu.time.wallClockSeconds(std.testing.io));
    try std.testing.expect(svc.mfaRequired(1));
    try std.testing.expect(!svc.userHasMfa(5));

    // Enrolling + enabling TOTP makes the user MFA-capable.
    const secret = try svc.enrollTotp(1, 5);
    defer allocator.free(secret);
    const counter = mfa.totp.counterAt(zigmodu.time.wallClockSeconds(std.testing.io), 30);
    const code = try mfa.totp.generateCode(allocator, secret, counter);
    defer allocator.free(code);
    try svc.verifyAndEnable(5, code);
    try std.testing.expect(svc.userHasMfa(5));
}

test "web3: siwe address derivation (privkey 1 -> known address)" {
    _ = std.testing.allocator;
    const Secp = std.crypto.ecc.Secp256k1;
    const siwe_mod = @import("modules/web3/siwe.zig");

    var prv: [32]u8 = std.mem.zeroes([32]u8);
    prv[31] = 1;
    const Q = try Secp.basePoint.mul(prv, .big);
    const uncompressed = Q.toUncompressedSec1();
    var addr: [20]u8 = undefined;
    try std.testing.expect(siwe_mod.addressFromPublicKey(&uncompressed, &addr));

    // The well-known address for private key 1.
    const expected_hex = "7e5f4552091a69125d5dfcb7b8c2659029395bdf";
    const hex = "0123456789abcdef";
    var b: [41]u8 = undefined;
    for (addr, 0..) |bb, i| {
        b[i * 2] = hex[bb >> 4];
        b[i * 2 + 1] = hex[bb & 0xf];
    }
    try std.testing.expectEqualStrings(expected_hex, b[0..40]);
}

test "web3: ecdsa sign -> recover round-trip matches wallet address" {
    _ = std.testing.allocator;
    const Secp = std.crypto.ecc.Secp256k1;
    const siwe_mod = @import("modules/web3/siwe.zig");

    var prv: [32]u8 = std.mem.zeroes([32]u8);
    prv[31] = 1;
    // The signer's true address.
    const Q = try Secp.basePoint.mul(prv, .big);
    var true_addr: [20]u8 = undefined;
    _ = siwe_mod.addressFromPublicKey(&(Q.toUncompressedSec1()), &true_addr);

    // Pick an ephemeral k whose R.x < n so recovery is unambiguous.
    const nval = [_]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe, 0xba, 0xae, 0xdc, 0xe6, 0xaf, 0x48, 0xa0, 0x3b, 0xbf, 0xd2, 0x5e, 0x8c, 0xd0, 0x36, 0x41, 0x41 };
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash("web3 siwe test message", &digest, .{});

    var matched = false;
    var k: u16 = 1;
    while (k < 200 and !matched) : (k += 1) {
        var kk: [32]u8 = std.mem.zeroes([32]u8);
        kk[30] = @intCast((k >> 8) & 0xff);
        kk[31] = @intCast(k & 0xff);
        const R = try Secp.basePoint.mul(kk, .big);
        const ra = R.affineCoordinates();
        const rx = ra.x.toBytes(.big);
        if (std.mem.order(u8, &rx, &nval) != .lt) continue;
        // Sign: r = x (mod n, no reduction), s = k^-1(z + r*d)
        const r_scalar = Secp.scalar.Scalar.fromBytes(rx, .big) catch continue;
        const d_scalar = (Secp.scalar.Scalar.fromBytes(digest, .big) catch continue);
        const k_scalar = (Secp.scalar.Scalar.fromBytes(kk, .big) catch continue);
        const kinv = k_scalar.invert();
        const prv_s = (Secp.scalar.Scalar.fromBytes(prv, .big) catch continue);
        const s_val = kinv.mul(d_scalar.add(r_scalar.mul(prv_s)));
        const odd = (ra.y.toBytes(.big)[31] & 1) == 1;
        const sig = siwe_mod.Signature{ .r = r_scalar.toBytes(.big), .s = s_val.toBytes(.big), .v = if (odd) @as(u8, 28) else 27 };
        var rec: [20]u8 = undefined;
        if (siwe_mod.recoverAddress(digest, sig, &rec)) {
            if (std.mem.eql(u8, &rec, &true_addr)) matched = true;
        }
    }
    try std.testing.expect(matched);
}

test "web3: wallet store create/find/bind" {
    const allocator = std.testing.allocator;
    var env = try openMemory(allocator);
    defer env.deinit();
    var ws = web3.persistence.WalletStore.init(allocator, env.client);
    const id = try ws.create(1, "evm", "0xabc123");
    const row_opt = try ws.findByAddress("evm", "0xabc123");
    const row = row_opt orelse return error.TestFailed;
    row.free(allocator);
    try std.testing.expectEqual(id, row.id);
    try std.testing.expectEqual(@as(i64, 0), row.user_id);
    try ws.bindUser(id, 7, 200);
    const bound = (try ws.findByAddress("evm", "0xabc123")).?;
    bound.free(allocator);
    try std.testing.expectEqual(@as(i64, 7), bound.user_id);
}

test "agent: create, capability check, expire, token issuance" {
    const allocator = std.testing.allocator;
    var env = try openMemory(allocator);
    defer env.deinit();
    var a_store = agent.persistence.AgentStore.init(allocator, env.client);
    var user_store = user.persistence.UserStore.init(allocator, env.client);
    var sec = zigmodu.security.AppSecurity.init(allocator, std.testing.io, .{ .jwt_secret = "agent-secret" });
    var user_svc = user.service.UserService.init(&user_store, &sec, std.testing.io, 3600, 86400);
    _ = try user_store.createUser("Owner", "o@x.com", "hash", false, true, 1, 100);
    var a_svc = agent.service.AgentService.init(allocator, std.testing.io, &a_store, &user_svc, &sec, "http://iam.local");
    const now = zigmodu.time.wallClockSeconds(std.testing.io);

    const aid = try a_svc.createAgent(1, 1, "treasury-bot", "reads balances", "[\"wallet.balance\",\"swap.execute\"]", "[\"read:wallet\",\"write:swap\"]", 500, 86400, now + 3600);

    const row = (try a_svc.getAgent(aid)).?;
    defer row.free(allocator);
    try std.testing.expect(a_svc.isUsable(row, now));
    try std.testing.expect(a_svc.hasCapability(row, "wallet.balance"));
    try std.testing.expect(!a_svc.hasCapability(row, "admin.delete"));

    // Expired agent is unusable and yields no token.
    try std.testing.expect(!a_svc.isUsable(row, now + 7200));

    // Token issuance for the active agent carries sub=agent_<id> and actor=owner.
    const token_opt = try a_svc.issueAgentToken(aid, 60);
    const token = token_opt orelse return error.TestFailed;
    defer allocator.free(token);
    const payload = try oauth.jwt.verify(allocator, sec.module.jwt_secret, token);
    defer allocator.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"sub\":\"agent_") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"actor\":\"1\"") != null);
}

test "agent: session revocation after agent deactivated" {
    const allocator = std.testing.allocator;
    var env = try openMemory(allocator);
    defer env.deinit();
    var a_store = agent.persistence.AgentStore.init(allocator, env.client);
    var user_store = user.persistence.UserStore.init(allocator, env.client);
    var sec = zigmodu.security.AppSecurity.init(allocator, std.testing.io, .{ .jwt_secret = "agent-secret" });
    var user_svc = user.service.UserService.init(&user_store, &sec, std.testing.io, 3600, 86400);
    var a_svc = agent.service.AgentService.init(allocator, std.testing.io, &a_store, &user_svc, &sec, "http://iam.local");

    const aid = try a_svc.createAgent(1, 2, "bot", "", "[]", "[]", 0, 86400, 0);
    const tok = (try a_svc.issueAgentToken(aid, 60)).?;
    defer allocator.free(tok);
    // Deactivating makes the agent unusable, so no future tokens are issued.
    const now = zigmodu.time.wallClockSeconds(std.testing.io);
    try a_store.setActive(aid, false, now);
    const row = (try a_svc.getAgent(aid)).?;
    row.free(allocator);
    try std.testing.expect(!a_svc.isUsable(row, now));
    try std.testing.expect((try a_svc.issueAgentToken(aid, 60)) == null);
}

test "web3: EIP-4361 message parsing extracts domain/address/nonce" {
    const a = std.testing.allocator;
    const message = "example.com wants you to sign in with your Ethereum account:\n0xAbCdEf0123456789aBcDeF0123456789AbCdEf01\n\nI am a statement.\nURI: https://example.com/login\nVersion: 1\nChain ID: 1\nNonce: abc123def\nIssued At: 2024-01-15T10:00:00Z\nExpiration Time: 2099-01-15T10:00:00Z\nNot Before: 2024-01-01T00:00:00Z\nResources:\n- https://example.com/api\n- https://example.com/data";
    const m = web3.siwe_message.parse(a, message) catch return error.TestFailed;
    defer m.free(a);
    try std.testing.expectEqualStrings("example.com", m.domain);
    try std.testing.expectEqualStrings("0xAbCdEf0123456789aBcDeF0123456789AbCdEf01", m.address);
    try std.testing.expectEqualStrings("abc123def", m.nonce);
    try std.testing.expectEqualStrings("https://example.com/login", m.uri);
    try std.testing.expectEqual(@as(u8, 1), m.version);
    try std.testing.expectEqual(@as(i64, 1), m.chain_id);
    try std.testing.expect(m.statement != null);
    try std.testing.expect(m.expiration_time != null);
    try std.testing.expectEqual(@as(usize, 2), m.resources.len);
}

test "web3: SIWE nonce single-use reserve + consume" {
    const a = std.testing.allocator;
    var env = try openMemory(a);
    defer env.deinit();
    var ws = web3.persistence.WalletStore.init(a, env.client);
    _ = try ws.reserveNonce(1, "nonce-xyz", "example.com", "0xabc", 0, 100);
    const r1 = try ws.consumeNonce(1, "nonce-xyz", "example.com", "0xabc", 100);
    try std.testing.expect(r1 != null);
    defer if (r1) |row| row.free(a);
    const r2 = try ws.consumeNonce(1, "nonce-xyz", "example.com", "0xabc", 100);
    try std.testing.expect(r2 == null);
}

test "agent: budget ledger consume/resume/remaining" {
    const a = std.testing.allocator;
    var env = try openMemory(a);
    defer env.deinit();
    var a_store = agent.persistence.AgentStore.init(a, env.client);
    var user_store = user.persistence.UserStore.init(a, env.client);
    var sec = zigmodu.security.AppSecurity.init(a, std.testing.io, .{ .jwt_secret = "agent-budget" });
    var user_svc = user.service.UserService.init(&user_store, &sec, std.testing.io, 3600, 86400);
    _ = try user_store.createUser("Owner", "o@x.com", "hash", false, true, 1, 100);
    var a_svc = agent.service.AgentService.init(a, std.testing.io, &a_store, &user_svc, &sec, "http://iam.local");
    const now = zigmodu.time.wallClockSeconds(std.testing.io);
    const aid = try a_svc.createAgent(1, 1, "budget-bot", "", "[]", "[]", 100, 86400, 0);
    const row = (try a_svc.getAgent(aid)).?;
    defer row.free(a);
    try std.testing.expectEqual(@as(i64, 100), try a_svc.remainingBudget(row, now));
    try std.testing.expectEqual(@as(i64, 60), try a_svc.consumeBudget(row, 40, now));
    try std.testing.expectError(error.InsufficientBudget, a_svc.consumeBudget(row, 70, now));
    try a_svc.resumeBudget(row, 10, now);
    try std.testing.expectEqual(@as(i64, 70), try a_svc.remainingBudget(row, now));
}

test "agent: token includes budget_remaining claim" {
    const a = std.testing.allocator;
    var env = try openMemory(a);
    defer env.deinit();
    var a_store = agent.persistence.AgentStore.init(a, env.client);
    var user_store = user.persistence.UserStore.init(a, env.client);
    var sec = zigmodu.security.AppSecurity.init(a, std.testing.io, .{ .jwt_secret = "agent-budget" });
    var user_svc = user.service.UserService.init(&user_store, &sec, std.testing.io, 3600, 86400);
    _ = try user_store.createUser("Owner", "o@x.com", "hash", false, true, 1, 100);
    var a_svc = agent.service.AgentService.init(a, std.testing.io, &a_store, &user_svc, &sec, "http://iam.local");
    const aid = try a_svc.createAgent(1, 1, "budget-bot", "", "[]", "[]", 100, 86400, 0);
    const tok = (try a_svc.issueAgentToken(aid, 60)).?;
    defer a.free(tok);
    const payload = try oauth.jwt.verify(a, sec.module.jwt_secret, tok);
    defer a.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"budget_remaining\":100") != null);
}
test "web3: personalSignDigest uses the 0x19 EIP-191 prefix byte" {
    const siwe_mod = @import("modules/web3/siwe.zig");
    var digest: [32]u8 = undefined;
    try siwe_mod.personalSignDigest("test", &digest);
    // Independent: keccak256(0x19 ++ "Ethereum Signed Message:\n" ++ "4" ++ "test")
    const header = "Ethereum Signed Message:\n";
    var buf: [128]u8 = undefined;
    var off: usize = 0;
    buf[off] = 0x19;
    off += 1;
    @memcpy(buf[off..][0..header.len], header);
    off += header.len;
    buf[off] = '4';
    off += 1;
    const msg = "test";
    @memcpy(buf[off..][0..msg.len], msg);
    off += msg.len;
    var expect: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(buf[0..off], &expect, .{});
    try std.testing.expectEqualSlices(u8, &expect, &digest);
}

test "web3: siweLogin binds wallet then issues JWT (full flow)" {
    const a = std.testing.allocator;
    var env = try openMemory(a);
    defer env.deinit();
    var wallet_store = web3.persistence.WalletStore.init(a, env.client);
    var user_store = user.persistence.UserStore.init(a, env.client);
    var sec = zigmodu.security.AppSecurity.init(a, std.testing.io, .{ .jwt_secret = "siwe-secret" });
    var user_svc = user.service.UserService.init(&user_store, &sec, std.testing.io, 3600, 86400);
    const uid = try user_store.createUser("WalletUser", "w@x.com", "hash", true, true, 1, 100);
    var w3 = web3.service.Web3Service.init(a, std.testing.io, &wallet_store, &user_svc, &sec);

    // Privkey 1 -> known address (stored normalized lowercase).
    const addr = "0x7E5F4552091a69125d5dfcb7b8c2659029395bdf";
    const bound = (try w3.bindWallet(1, uid, "evm", addr)).?;
    bound.free(a);
    const stored = (try wallet_store.findByAddress("evm", "0x7e5f4552091a69125d5dfcb7b8c2659029395bdf")).?;
    stored.free(a);
    try std.testing.expectEqual(uid, stored.user_id);

    // Nonce + message.
    const nonce = try w3.generateNonce();
    defer a.free(nonce);
    try w3.reserveNonce(1, nonce, "example.com", addr, 600);
    const message = try std.fmt.allocPrint(a, "example.com wants you to sign in with your Ethereum account:\n{s}\n\n" ++
        "Sign in to the app.\n\nURI: https://example.com\nVersion: 1\nChain ID: 1\n" ++
        "Nonce: {s}\nIssued At: 2099-01-01T00:00:00Z", .{ addr, nonce });
    defer a.free(message);

    // EIP-191 digest + sign with privkey 1.
    const siwe_mod = @import("modules/web3/siwe.zig");
    var digest: [32]u8 = undefined;
    siwe_mod.personalSignDigest(message, &digest) catch return error.TestFailed;
    const Secp = std.crypto.ecc.Secp256k1;
    var prv: [32]u8 = std.mem.zeroes([32]u8);
    prv[31] = 1;
    const nval = [_]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe, 0xba, 0xae, 0xdc, 0xe6, 0xaf, 0x48, 0xa0, 0x3b, 0xbf, 0xd2, 0x5e, 0x8c, 0xd0, 0x36, 0x41, 0x41 };
    const true_addr = [_]u8{ 0x7e, 0x5f, 0x45, 0x52, 0x09, 0x1a, 0x69, 0x12, 0x5d, 0x5d, 0xfc, 0xb7, 0xb8, 0xc2, 0x65, 0x90, 0x29, 0x39, 0x5b, 0xdf };
    var sig: web3.service.Signature = undefined;
    var found = false;
    var k: u16 = 1;
    while (k < 2000 and !found) : (k += 1) {
        var kk: [32]u8 = std.mem.zeroes([32]u8);
        kk[30] = @intCast((k >> 8) & 0xff);
        kk[31] = @intCast(k & 0xff);
        const R = try Secp.basePoint.mul(kk, .big);
        const ra = R.affineCoordinates();
        const rx = ra.x.toBytes(.big);
        if (std.mem.order(u8, &rx, &nval) != .lt) continue;
        const r_scalar = Secp.scalar.Scalar.fromBytes(rx, .big) catch continue;
        const d_scalar = Secp.scalar.Scalar.fromBytes(digest, .big) catch continue;
        const k_scalar = Secp.scalar.Scalar.fromBytes(kk, .big) catch continue;
        const s_val = k_scalar.invert().mul(d_scalar.add(r_scalar.mul((Secp.scalar.Scalar.fromBytes(prv, .big) catch continue))));
        const odd = (ra.y.toBytes(.big)[31] & 1) == 1;
        const r_fe = Secp.Fe.fromBytes(rx, .big) catch continue;
        const r_y = Secp.recoverY(r_fe, odd) catch continue;
        const Rp = Secp.fromAffineCoordinates(.{ .x = r_fe, .y = r_y }) catch continue;
        const sR = Rp.mul(s_val.toBytes(.big), .big) catch continue;
        const eG = Secp.basePoint.mul(digest, .big) catch continue;
        const Q = sR.sub(eG).mul(r_scalar.invert().toBytes(.big), .big) catch continue;
        const qa = Q.affineCoordinates();
        var qx: [32]u8 = undefined;
        var qy: [32]u8 = undefined;
        qx = qa.x.toBytes(.big);
        qy = qa.y.toBytes(.big);
        var qbuf: [64]u8 = undefined;
        @memcpy(qbuf[0..32], &qx);
        @memcpy(qbuf[32..64], &qy);
        var qhash: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(&qbuf, &qhash, .{});
        if (!std.mem.eql(u8, qhash[12..32], &true_addr)) continue;
        sig = .{ .r = r_scalar.toBytes(.big), .s = s_val.toBytes(.big), .v = if (odd) @as(u8, 28) else 27 };
        found = true;
    }
    try std.testing.expect(found);

    // siweLogin: verify + nonce consume + wallet lookup + JWT.
    const login = try w3.siweLogin(1, message, sig, "example.com");
    try std.testing.expect(login.token != null);
    defer if (login.token) |t| a.free(t);
    try std.testing.expectEqual(uid, login.user_id);
    // Nonce is single-use: a second login attempt fails on the nonce.
    try std.testing.expectError(error.NonceUnavailable, w3.siweLogin(1, message, sig, "example.com"));
}
