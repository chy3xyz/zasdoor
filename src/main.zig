//! zenaipa — a production-grade admin framework built on zigmodu + zent.
//!
//! Single binary serves the JSON admin API; the Solid SPA in `web/`
//! talks to it over `/api/v1`. Run:
//!   zig build run                          # sqlite (zenaipa.db)
//!   ZENAIPA_DB_DRIVER=postgres ZENAIPA_PG_CONNINFO='host=... dbname=zenaipa user=postgres password=...' zig build run
//!   zig build admin -- --email you@example.com   # create the first admin
//!
//! Feature surface:
//!   auth (register/login/logout/reset/verify/me/profile/password), user CRUD,
//!   durable background tasks + dispatcher, email (SMTP + console), cache,
//!   file uploads, notifications, cron housekeeping, access logs, security
//!   headers, health/ready probes, runtime diagnostics.

const std = @import("std");
const zigmodu = @import("zigmodu");
const config_mod = @import("config.zig");
const db_mod = @import("db.zig");
const schema = @import("schema.zig");
const access_log_mod = @import("middleware/access_log.zig");
const sec_headers = @import("middleware/security_headers.zig");
const metrics_mod = @import("middleware/metrics.zig");
const mail = @import("services/mail.zig");
const cache_svc = @import("services/cache.zig");
const jobs = @import("jobs.zig");
const scheduled = @import("scheduled.zig");
const user = @import("modules/user/root.zig");
const auth = @import("modules/auth/root.zig");
const task = @import("modules/task/root.zig");
const file = @import("modules/file/root.zig");
const notify = @import("modules/notify/root.zig");
const system = @import("modules/system/root.zig");
const tenant = @import("modules/tenant/root.zig");
const audit = @import("modules/audit/root.zig");
const mail_template = @import("modules/mail_template/root.zig");
const ai = @import("modules/ai/root.zig");

/// Shared state for scheduled housekeeping jobs (single background thread —
/// zent's SQLite driver is a single connection).
const CleanupCtx = struct {
    io: std.Io,
    user_store: *user.persistence.UserStore,
    notify_store: *notify.persistence.NotificationStore,
    password_token_max_age: i64,
    verification_token_max_age: i64,
    notification_max_age: i64,
};

fn jobTokensCleanup(ctx: ?*anyopaque) void {
    const c: *CleanupCtx = @ptrCast(@alignCast(ctx orelse return));
    const now = zigmodu.time.wallClockSeconds(c.io);
    _ = c.user_store.purgeExpiredPasswordTokens(now, c.password_token_max_age) catch {};
    _ = c.user_store.purgeExpiredEmailVerifications(now, c.verification_token_max_age) catch {};
}

fn jobNotifyPrune(ctx: ?*anyopaque) void {
    const c: *CleanupCtx = @ptrCast(@alignCast(ctx orelse return));
    const now = zigmodu.time.wallClockSeconds(c.io);
    _ = c.notify_store.purgeOlderThan(now, c.notification_max_age) catch {};
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const cfg = config_mod.Config.fromEnv(init.environ_map);
    std.log.info("zenaipa starting (db={s}, port={d})", .{ cfg.db_driver, cfg.http_port });

    // ── Data store: zent driver + schema-as-code migration ──
    const kind: db_mod.DriverKind = if (std.mem.eql(u8, cfg.db_driver, "postgres")) .postgres else .sqlite;
    const dsn = if (kind == .postgres) cfg.pg_conninfo else cfg.sqlite_path;
    var store_env = try db_mod.StoreEnv(schema.infos, .{
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
    }).open(allocator, kind, dsn);
    defer store_env.deinit();
    std.log.info("[zent] migrated schema via {s} ({s})", .{ @tagName(kind), dsn });

    // ── Domain services ──
    var store = user.persistence.UserStore.init(allocator, store_env.client);
    var sec = zigmodu.security.AppSecurity.init(allocator, io, .{
        .jwt_secret = cfg.jwt_secret,
        .token_expiry_seconds = cfg.token_expiry_seconds,
    });
    var mailer = mail.Mailer.init(
        allocator,
        io,
        cfg.smtp_host,
        cfg.smtp_port,
        cfg.smtp_username,
        cfg.smtp_password,
        cfg.smtp_from,
        cfg.smtp_starttls,
        cfg.mail_console,
    );
    defer mailer.deinit();
    var cache = cache_svc.CacheService.init(allocator, cfg.cache_max_entries, cfg.cache_ttl_seconds);
    defer cache.deinit();

    var user_svc = user.service.UserService.init(
        &store,
        &sec,
        io,
        cfg.password_token_expiration_seconds,
        cfg.verification_token_expiration_seconds,
    );
    var task_store = task.persistence.TaskStore.init(allocator, store_env.client);
    var task_svc = task.service.TaskService.init(&task_store, io, cfg.task_max_attempts);
    var notify_store = notify.persistence.NotificationStore.init(allocator, store_env.client);
    var notify_svc = notify.service.NotificationService.init(allocator, io, &notify_store);
    var file_store = file.persistence.FileStore.init(allocator, store_env.client);
    var file_svc = file.service.FileService.init(allocator, io, &file_store, cfg.upload_dir, cfg.upload_max_bytes);
    try file_svc.ensureDir();
    var tenant_store = tenant.persistence.TenantStore.init(allocator, store_env.client);
    var tenant_svc = tenant.service.TenantService.init(allocator, io, &tenant_store);
    const default_tenant_id = try tenant_svc.ensureDefault();
    std.log.info("[tenant] default tenant ready (id={d})", .{default_tenant_id});

    var audit_store = audit.persistence.AuditStore.init(allocator, store_env.client);
    var audit_svc = audit.service.AuditService.init(allocator, io, &audit_store);

    var template_store = mail_template.persistence.TemplateStore.init(allocator, store_env.client);
    var template_svc = mail_template.service.MailTemplateService.init(allocator, io, &template_store);

    var ai_store = ai.persistence.AiStore.init(allocator, store_env.client);
    var ai_svc = try ai.service.AiService.init(allocator, io, &ai_store, .{
        .key_secret = cfg.ai_key_secret,
        .daily_run_limit = cfg.ai_daily_run_limit,
    }, .{
        .user_store = &store,
        .task_store = &task_store,
        .audit_store = &audit_store,
        .tenant_store = &tenant_store,
        .ai_store = &ai_store,
        .notify_svc = &notify_svc,
    });
    defer ai_svc.deinit();

    // ── ZigModu module lifecycle (Application API: scan + validate + start/stop) ──
    var app = try zigmodu.Application.init(io, allocator, "zenaipa", .{
        tenant.module,
        user.module,
        auth.module,
        task.module,
        file.module,
        notify.module,
        system.module,
        audit.module,
        mail_template.module,
        ai.module,
    }, .{});
    defer app.deinit();
    try app.start();
    defer app.stop();
    const module_count = app.modules.modules.count();

    // ── Background: task dispatcher + scheduled housekeeping ──
    var cleanup_ctx = CleanupCtx{
        .io = io,
        .user_store = &store,
        .notify_store = &notify_store,
        .password_token_max_age = cfg.password_token_expiration_seconds,
        .verification_token_max_age = cfg.verification_token_expiration_seconds,
        .notification_max_age = 30 * 24 * 3600,
    };
    var scheduled_jobs = [_]scheduled.ScheduledJob{
        .{
            .name = "tokens.cleanup",
            .interval_seconds = 3600,
            .run = jobTokensCleanup,
            .ctx = &cleanup_ctx,
        },
        .{
            .name = "notify.prune",
            .interval_seconds = 24 * 3600,
            .run = jobNotifyPrune,
            .ctx = &cleanup_ctx,
        },
    };
    var scheduled_runner = scheduled.ScheduledRunner{ .jobs = &scheduled_jobs };

    const handler_registry = jobs.handlers(&mailer);
    var dispatcher = task.service.Dispatcher.init(
        allocator,
        io,
        &task_store,
        &handler_registry,
        cfg.task_retry_interval_seconds,
        300, // stale claim threshold (seconds)
    );
    dispatcher.scheduled = &scheduled_runner;
    try dispatcher.start();
    defer dispatcher.deinit();
    std.log.info("[task] dispatcher started ({d} handlers, {d} workers)", .{ handler_registry.len, cfg.task_workers });

    // ── HTTP API ──
    var login_limiter = try zigmodu.RateLimiter.init(allocator, "auth-public", 20, 1);
    defer login_limiter.deinit();

    var user_api = user.api.UserApi(@TypeOf(user_svc)).init(&user_svc, default_tenant_id, &audit_svc);
    var auth_api = auth.api.AuthApi(@TypeOf(user_svc)).init(&user_svc, cfg.app_host, &login_limiter, &mailer, &task_svc, &notify_svc, &audit_svc, &template_svc, default_tenant_id);
    var task_api = task.api.TaskApi(@TypeOf(task_svc), @TypeOf(user_svc)).init(&task_svc, &user_svc, &audit_svc);
    var file_api = file.api.FileApi(@TypeOf(file_svc), @TypeOf(user_svc)).init(&file_svc, &user_svc, &audit_svc, default_tenant_id);
    var notify_api = notify.api.NotificationApi(@TypeOf(notify_svc), @TypeOf(user_svc)).init(&notify_svc, &user_svc);
    var tenant_api = tenant.api.TenantApi(@TypeOf(tenant_svc), @TypeOf(user_svc)).init(&tenant_svc, &user_svc, &audit_svc);
    var audit_api = audit.api.AuditApi(@TypeOf(audit_svc), @TypeOf(user_svc)).init(&audit_svc, &user_svc);
    var mail_template_api = mail_template.api.MailTemplateApi(@TypeOf(template_svc), @TypeOf(user_svc)).init(&template_svc, &user_svc);
    var ai_api = ai.api.AiApi(@TypeOf(ai_svc), @TypeOf(user_svc)).init(&ai_svc, &user_svc);
    var system_api = system.api.SystemApi(@TypeOf(cache), @TypeOf(task_svc)).init(
        &cache,
        &task_svc,
        &user_svc,
        &store,
        &file_store,
        &notify_store,
        &tenant_store,
        io,
        zigmodu.time.wallClockSeconds(io),
        @tagName(kind),
        cfg.smtp_host.len > 0,
        cfg.mail_console,
        module_count,
    );

    var server = zigmodu.http.Server.initWithConfig(io, allocator, .{
        .port = cfg.http_port,
        .name = "zenaipa",
        .max_body_size = cfg.upload_max_bytes + 64 * 1024,
    });
    defer server.deinit();

    const origins = try parseCorsOrigins(allocator, cfg.cors_origins);
    defer allocator.free(origins);

    var access_log = access_log_mod.AccessLog.init(allocator, 4096);
    defer access_log.deinit();
    var metrics = metrics_mod.Metrics.init(io);
    try server.addMiddleware(zigmodu.http.tracingMiddleware());
    try server.addMiddleware(metrics.middleware());
    try server.addMiddleware(sec_headers.securityHeaders());
    try server.addMiddleware(access_log.middleware());
    try server.addMiddleware(zigmodu.http.http_middleware.cors(.{ .allow_origins = origins }));

    var v1 = server.group("/api/v1");
    try auth_api.registerRoutes(&v1);
    try user_api.registerRoutes(&v1);
    try task_api.registerRoutes(&v1);
    try file_api.registerRoutes(&v1);
    try notify_api.registerRoutes(&v1);
    try tenant_api.registerRoutes(&v1);
    try audit_api.registerRoutes(&v1);
    try mail_template_api.registerRoutes(&v1);
    try ai_api.registerRoutes(&v1);
    try system_api.registerRoutes(&v1);

    // Health: liveness at the server root (probe convention) and readiness
    // under the API prefix (checks the data store).
    const Ready = struct {
        var user_store_ref: *user.persistence.UserStore = undefined;
    };
    Ready.user_store_ref = &store;
    try server.addRoute(.{
        .method = .GET,
        .path = "health/live",
        .handler = struct {
            fn handle(ctx: *zigmodu.http.Context) !void {
                try ctx.json(200, "{\"code\":0,\"msg\":\"ok\",\"data\":{\"status\":\"UP\"}}");
            }
        }.handle,
    });
    try server.addRoute(.{
        .method = .GET,
        .path = "api/v1/health/live",
        .handler = struct {
            fn handle(ctx: *zigmodu.http.Context) !void {
                try ctx.json(200, "{\"code\":0,\"msg\":\"ok\",\"data\":{\"status\":\"UP\"}}");
            }
        }.handle,
    });
    try server.addRoute(.{
        .method = .GET,
        .path = "api/v1/health/ready",
        .handler = struct {
            fn handle(ctx: *zigmodu.http.Context) !void {
                var probe = Ready.user_store_ref.listUsers(1, 1, null, null, null, false) catch {
                    try ctx.sendErrorResponse(503, 503, "数据库不可用");
                    return;
                };
                defer probe.free(ctx.allocator);
                try ctx.json(200, "{\"code\":0,\"msg\":\"ok\",\"data\":{\"status\":\"READY\"}}");
            }
        }.handle,
    });
    // Prometheus metrics (public, like the health probes).
    const MetricsRoute = struct {
        var metrics_ref: *metrics_mod.Metrics = undefined;
    };
    MetricsRoute.metrics_ref = &metrics;
    try server.addRoute(.{
        .method = .GET,
        .path = "metrics",
        .handler = struct {
            fn handle(ctx: *zigmodu.http.Context) !void {
                const body = try MetricsRoute.metrics_ref.renderPrometheus(ctx.allocator, zigmodu.time.wallClockSeconds(ctx.io orelse return error.InternalError));
                defer ctx.allocator.free(body);
                try ctx.text(200, body);
            }
        }.handle,
    });

    std.log.info("zenaipa listening on http://127.0.0.1:{d} (admin CLI: zig build admin -- --help)", .{cfg.http_port});
    try server.start();
}

/// Parse `ZENAIPA_CORS_ORIGINS` ("*" or a comma-separated allow-list) into
/// the `[]const []const u8` slice the CORS middleware expects.
fn parseCorsOrigins(allocator: std.mem.Allocator, spec: []const u8) ![]const []const u8 {
    const trimmed = std.mem.trim(u8, spec, " \t");
    if (std.mem.eql(u8, trimmed, "*") or trimmed.len == 0) {
        return allocator.dupe([]const u8, &.{"*"});
    }
    var out = std.ArrayList([]const u8).empty;
    errdefer out.deinit(allocator);
    var it = std.mem.splitScalar(u8, trimmed, ',');
    while (it.next()) |raw| {
        const origin = std.mem.trim(u8, raw, " \t");
        if (origin.len > 0) try out.append(allocator, origin);
    }
    if (out.items.len == 0) return allocator.dupe([]const u8, &.{"*"});
    return out.toOwnedSlice(allocator);
}
