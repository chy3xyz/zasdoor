//! zasdoor — a production-grade admin framework built on zigmodu + zent.
//!
//! Single binary serves the JSON admin API; the Solid SPA in `web/`
//! talks to it over `/api/v1`. Run:
//!   zig build run                          # sqlite (zasdoor.db)
//!   ZASDOOR_DB_DRIVER=postgres ZASDOOR_PG_CONNINFO='host=... dbname=zasdoor user=postgres password=...' zig build run
//!   zig build admin -- --email you@example.com   # create the first admin
//!
//! Feature surface:
//!   auth (register/login/logout/reset/verify/me/profile/password), user CRUD,
//!   durable background tasks + dispatcher, email (SMTP + console), cache,
//!   file uploads, notifications, cron housekeeping, access logs, security
//!   headers, health/ready probes, runtime diagnostics.

const std = @import("std");
const zigmodu = @import("zigmodu");
const zent = @import("zent");
const build_info = @import("build_info");
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
const iam = @import("modules/iam/root.zig");
const oauth = @import("modules/oauth/root.zig");
const eventstore = @import("modules/eventstore/root.zig");
const authz = @import("modules/authz/root.zig");
const mfa = @import("modules/mfa/root.zig");
const web3 = @import("modules/web3/root.zig");
const agent = @import("modules/agent/root.zig");

/// Set by SIGINT/SIGTERM so the main thread can stop the server gracefully.
const ShutdownFlag = struct {
    var requested = std.atomic.Value(bool).init(false);
};

fn onShutdownSignal(_: std.posix.SIG) callconv(.c) void {
    ShutdownFlag.requested.store(true, .release);
}

/// Shared state for scheduled housekeeping jobs (single background thread —
/// zent's SQLite driver is a single connection).
const CleanupCtx = struct {
    io: std.Io,
    user_store: *user.persistence.UserStore,
    notify_store: *notify.persistence.NotificationStore,
    audit_store: *audit.persistence.AuditStore,
    iam_store: *iam.persistence.IamStore,
    mfa_store: *mfa.persistence.MfaStore,
    authz_store: *authz.persistence.AuthzStore,
    password_token_max_age: i64,
    verification_token_max_age: i64,
    notification_max_age: i64,
    audit_retention_seconds: i64,
};

fn jobTokensCleanup(ctx: ?*anyopaque) void {
    const c: *CleanupCtx = @ptrCast(@alignCast(ctx orelse return));
    const now = zigmodu.time.wallClockSeconds(c.io);
    _ = c.user_store.purgeExpiredPasswordTokens(now, c.password_token_max_age) catch {};
    _ = c.user_store.purgeExpiredEmailVerifications(now, c.verification_token_max_age) catch {};
    _ = c.mfa_store.purgeExpiredWebauthnChallenges(now) catch {};
    _ = c.authz_store.purgeDecisionsBefore(now - 30 * 24 * 3600) catch {};
}

fn jobNotifyPrune(ctx: ?*anyopaque) void {
    const c: *CleanupCtx = @ptrCast(@alignCast(ctx orelse return));
    const now = zigmodu.time.wallClockSeconds(c.io);
    _ = c.notify_store.purgeOlderThan(now, c.notification_max_age) catch {};
}

/// Runs the Event Store projection worker forward (incremental).
fn jobEventProjections(ctx: ?*anyopaque) void {
    _ = ctx;
    const svc: *eventstore.service.EventService = @ptrCast(@alignCast(ProjectionCtx.svc orelse return));
    svc.project() catch |err| {
        std.log.err("[eventstore] projection run failed: {s}", .{@errorName(err)});
    };
}

/// Static holder for the projection worker context (job fns are top-level).
const ProjectionCtx = struct {
    var svc: ?*eventstore.service.EventService = null;
};

fn jobOAuthCodesPrune(ctx: ?*anyopaque) void {
    const c: *CleanupCtx = @ptrCast(@alignCast(ctx orelse return));
    const now = zigmodu.time.wallClockSeconds(c.io);
    _ = c.iam_store.purgeExpiredAuthCodes(now) catch {};
    _ = c.iam_store.purgeExpiredDeviceCodes(now) catch {};
}

fn jobAuditPrune(ctx: ?*anyopaque) void {
    const c: *CleanupCtx = @ptrCast(@alignCast(ctx orelse return));
    const now = zigmodu.time.wallClockSeconds(c.io);
    _ = c.audit_store.purgeOlderThan(now, c.audit_retention_seconds) catch {};
}

/// Drops lockout rows untouched for a day so the shared table does not grow
/// without bound as attackers try random emails.
fn jobLoginAttemptsPrune(ctx: ?*anyopaque) void {
    const c: *CleanupCtx = @ptrCast(@alignCast(ctx orelse return));
    const now = zigmodu.time.wallClockSeconds(c.io);
    _ = c.user_store.purgeStaleLoginAttempts(now, 24 * 3600) catch |err| {
        std.log.err("[cleanup] login_attempts.prune failed: {s}", .{@errorName(err)});
    };
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const cfg = config_mod.Config.fromEnv(init.environ_map);
    // Production-shaped startup preflight, fail-closed: a default/short JWT
    // secret is a full authentication bypass and CORS "*" exposes every
    // endpoint. Refuse to start rather than silently degrade.
    if (cfg.isProdLike()) {
        var env_ctx = zigmodu.Preflight.EnvCheck.fromMap(init.environ_map, &.{"ZASDOOR_JWT_SECRET"});
        var secret_ctx = zigmodu.Preflight.SecretCheck{ .secret = cfg.jwt_secret, .min_len = 16 };
        var report = zigmodu.Preflight.run(allocator, &.{
            zigmodu.Preflight.envCheck(&env_ctx),
            zigmodu.Preflight.secretCheck(&secret_ctx),
        });
        defer report.deinit();
        report.log();
        if (!report.ok() or !cfg.jwt_secret_explicit) {
            std.log.err("ZASDOOR_JWT_SECRET must be set explicitly (>=16 chars, non-placeholder) in production. Refusing to start.", .{});
            return error.PreflightFailed;
        }
        if (std.mem.eql(u8, cfg.cors_origins, "*")) {
            std.log.err("ZASDOOR_CORS_ORIGINS=* is not allowed in production. Set an explicit origin allow-list.", .{});
            return error.PreflightFailed;
        }
    }
    std.log.info("zasdoor starting (db={s}, port={d}, env={s})", .{ cfg.db_driver, cfg.http_port, cfg.env });

    // Route zent's library-level diagnostics (scan/migration/pool err/warn)
    // into std.log instead of swallowing them.
    zent.runtime.log.setSink(struct {
        fn sink(level: zent.runtime.log.Level, message: []const u8) void {
            switch (level) {
                .err => std.log.err("[zent] {s}", .{message}),
                .warn => std.log.warn("[zent] {s}", .{message}),
                .info => std.log.info("[zent] {s}", .{message}),
                .debug => std.log.debug("[zent] {s}", .{message}),
            }
        }
    }.sink);

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
        iam.persistence.infos,
        eventstore.persistence.infos,
        mfa.persistence.infos,
        web3.persistence.infos,
        agent.persistence.infos,
        authz.persistence.infos,
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
    var cache = cache_svc.CacheService.init(allocator, io, cfg.cache_max_entries, cfg.cache_ttl_seconds);
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

    var iam_store = iam.persistence.IamStore.init(allocator, store_env.client);
    var iam_svc = iam.service.IamService.init(allocator, io, &iam_store, &sec);
    var oauth_svc = oauth.service.OAuthService.initWithExtraKeys(allocator, io, &iam_svc, &user_svc, &sec, cfg.app_host, cfg.oidc_key_secrets);

    var event_store = eventstore.persistence.EventStore.init(allocator, store_env.client);
    var event_svc = eventstore.service.EventService.init(allocator, io, &event_store, &.{}); // projections added below
    var authz_store = authz.persistence.AuthzStore.init(allocator, store_env.client);
    var authz_svc = authz.service.AuthzService.initWithStore(allocator, &iam_svc, &authz_store);
    ProjectionCtx.svc = &event_svc;
    var authz_api = authz.api.AuthzApi(@TypeOf(authz_svc), @TypeOf(user_svc)).init(&authz_svc, &user_svc);
    var mfa_store = mfa.persistence.MfaStore.init(allocator, store_env.client);
    var mfa_svc = mfa.service.MfaService.init(allocator, io, &mfa_store, &sec);
    var idp_svc = mfa.idp.IdpService.init(allocator, &mfa_store);
    var webauthn_svc = mfa.webauthn.WebauthnService.init(allocator, io, &mfa_store, &user_svc, .{
        .rp_id = cfg.webauthn_rp_id,
        .rp_name = cfg.webauthn_rp_name,
        .origin = cfg.webauthn_origin,
        .challenge_ttl_seconds = cfg.webauthn_challenge_ttl_seconds,
    });
    var wallet_store = web3.persistence.WalletStore.init(allocator, store_env.client);
    var web3_svc = web3.service.Web3Service.init(allocator, io, &wallet_store, &user_svc, &sec);
    var agent_store = agent.persistence.AgentStore.init(allocator, store_env.client);
    var agent_svc = agent.service.AgentService.init(allocator, io, &agent_store, &user_svc, &sec, cfg.app_host);
    var agent_api = agent.api.AgentApi(@TypeOf(agent_svc), @TypeOf(user_svc)).init(&agent_svc, &user_svc, default_tenant_id);

    // ── ZigModu module lifecycle (Application API: scan + validate + start/stop) ──
    var app = try zigmodu.Application.init(io, allocator, "zasdoor", .{
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
        iam.module,
        oauth.module,
        eventstore.module,
        authz.module,
        mfa.module,
        web3.module,
        agent.module,
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
        .audit_store = &audit_store,
        .iam_store = &iam_store,
        .mfa_store = &mfa_store,
        .authz_store = &authz_store,
        .password_token_max_age = cfg.password_token_expiration_seconds,
        .verification_token_max_age = cfg.verification_token_expiration_seconds,
        .notification_max_age = 30 * 24 * 3600,
        .audit_retention_seconds = cfg.audit_retention_days * 24 * 3600,
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
        .{
            .name = "audit.prune",
            .interval_seconds = 24 * 3600,
            .run = jobAuditPrune,
            .ctx = &cleanup_ctx,
        },
        .{
            .name = "oauth.codes.prune",
            .interval_seconds = 3600,
            .run = jobOAuthCodesPrune,
            .ctx = &cleanup_ctx,
        },
        .{
            .name = "login_attempts.prune",
            .interval_seconds = 24 * 3600,
            .run = jobLoginAttemptsPrune,
            .ctx = &cleanup_ctx,
        },
        .{
            .name = "eventstore.project",
            .interval_seconds = 30,
            .run = jobEventProjections,
            .ctx = null,
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

    // ── HTTP API ──
    // per-IP 登录限流(而非全局单桶):每个客户端独立 20 token / 1 补。
    var login_registry = zigmodu.RateLimiterRegistry.init(allocator, 20, 1);
    defer login_registry.deinit();

    var user_api = user.api.UserApi(@TypeOf(user_svc)).init(&user_svc, default_tenant_id, &audit_svc);
    var auth_api = auth.api.AuthApi(@TypeOf(user_svc)).init(&user_svc, cfg.app_host, &login_registry, &mailer, &task_svc, &notify_svc, &audit_svc, &template_svc, default_tenant_id);
    var task_api = task.api.TaskApi(@TypeOf(task_svc), @TypeOf(user_svc)).init(&task_svc, &user_svc, &audit_svc);
    var file_api = file.api.FileApi(@TypeOf(file_svc), @TypeOf(user_svc)).init(&file_svc, &user_svc, &audit_svc, default_tenant_id);
    var notify_api = notify.api.NotificationApi(@TypeOf(notify_svc), @TypeOf(user_svc)).init(&notify_svc, &user_svc);
    var tenant_api = tenant.api.TenantApi(@TypeOf(tenant_svc), @TypeOf(user_svc)).init(&tenant_svc, &user_svc, &audit_svc);
    var audit_api = audit.api.AuditApi(@TypeOf(audit_svc), @TypeOf(user_svc)).init(&audit_svc, &user_svc);
    var mail_template_api = mail_template.api.MailTemplateApi(@TypeOf(template_svc), @TypeOf(user_svc)).init(&template_svc, &user_svc);
    var ai_api = ai.api.AiApi(@TypeOf(ai_svc), @TypeOf(user_svc)).init(&ai_svc, &user_svc);
    var iam_api = iam.api.IamApi(@TypeOf(iam_svc), @TypeOf(user_svc)).init(&iam_svc, &user_svc, &audit_svc, default_tenant_id);
    var oauth_api = oauth.api.OAuthApi(@TypeOf(oauth_svc), @TypeOf(user_svc)).init(&oauth_svc, &user_svc);
    var mfa_api = mfa.api.MfaApi(@TypeOf(mfa_svc), @TypeOf(user_svc)).init(&mfa_svc, &user_svc, default_tenant_id);
    var webauthn_api = mfa.webauthn_api.WebauthnApi(@TypeOf(webauthn_svc), @TypeOf(user_svc)).init(&webauthn_svc, &user_svc, &login_registry, default_tenant_id);
    var web3_api = web3.api.Web3Api(@TypeOf(web3_svc), @TypeOf(user_svc)).init(&web3_svc, &user_svc, default_tenant_id);
    var idp_api = mfa.idp_api.IdpApi(@TypeOf(idp_svc), @TypeOf(user_svc)).init(&idp_svc, &user_svc, default_tenant_id);
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
        .name = "zasdoor",
        .max_body_size = cfg.upload_max_bytes + 64 * 1024,
        // accept back-pressure: instant 503 over the cap (fd/memory protection),
        // with a per-request timeout as the drain bound.
        .max_connections = cfg.http_max_connections,
        .over_limit_response = .unavailable,
        .request_timeout_ms = cfg.http_request_timeout_ms,
    });
    defer server.deinit();

    const origins = try parseCorsOrigins(allocator, cfg.cors_origins);
    defer allocator.free(origins);

    var access_log = access_log_mod.AccessLog.init(allocator, 4096);
    defer access_log.deinit();
    var metrics = metrics_mod.Metrics.init(io);
    try server.addMiddleware(zigmodu.http.tracingMiddleware());
    try server.addMiddleware(metrics.middleware());
    try server.addMiddleware(try sec_headers.securityHeaders());
    try server.addMiddleware(access_log.middleware());
    try server.addMiddleware(try zigmodu.http.http_middleware.cors(.{ .allow_origins = origins }));

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
    try iam_api.registerRoutes(&v1);
    try authz_api.registerRoutes(&v1);
    try mfa_api.registerRoutes(&v1);
    try webauthn_api.registerRoutes(&v1);
    try idp_api.registerRoutes(&v1);
    try web3_api.registerRoutes(&v1);
    try agent_api.registerRoutes(&v1);
    try system_api.registerRoutes(&v1);

    // OAuth2 / OIDC public protocol endpoints (server root, no /api prefix).
    try oauth_api.registerRoutes(&server);

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
                // Rows are allocated by the store's allocator, not the per-request
                // connection arena, so free with the allocator that produced them.
                defer probe.free(Ready.user_store_ref.allocator);
                try ctx.json(200, "{\"code\":0,\"msg\":\"ok\",\"data\":{\"status\":\"READY\"}}");
            }
        }.handle,
    });
    // Prometheus metrics (public, like the health probes).
    const MetricsRoute = struct {
        var metrics_ref: *metrics_mod.Metrics = undefined;
        var allow_ips: []const u8 = "";
        var dispatcher_ref: *task.service.Dispatcher = undefined;
    };
    MetricsRoute.metrics_ref = &metrics;
    MetricsRoute.allow_ips = cfg.metrics_allow_ips;
    MetricsRoute.dispatcher_ref = &dispatcher;
    try server.addRoute(.{
        .method = .GET,
        .path = "metrics",
        .handler = struct {
            fn handle(ctx: *zigmodu.http.Context) !void {
                // /metrics IP 白名单(空 = 允许全部;生产建议限制到监控网段)。
                if (MetricsRoute.allow_ips.len > 0) {
                    const ip = zigmodu.http.RequestUtil.getRealIp(ctx);
                    var allowed = false;
                    var it = std.mem.splitScalar(u8, MetricsRoute.allow_ips, ',');
                    while (it.next()) |a| {
                        if (std.mem.eql(u8, std.mem.trim(u8, a, " \t"), ip)) {
                            allowed = true;
                            break;
                        }
                    }
                    if (!allowed) {
                        try ctx.sendErrorResponse(403, 403, "forbidden");
                        return;
                    }
                }
                const body = try MetricsRoute.metrics_ref.renderPrometheus(ctx.allocator, zigmodu.time.wallClockSeconds(ctx.io orelse return error.InternalError));
                defer ctx.allocator.free(body);
                // Dispatcher counters (previously only incremented internally).
                const full = try std.fmt.allocPrint(ctx.allocator, "{s}" ++
                    "# HELP zasdoor_task_processed_total Background tasks completed by the dispatcher.\n" ++
                    "# TYPE zasdoor_task_processed_total counter\n" ++
                    "zasdoor_task_processed_total {d}\n" ++
                    "# HELP zasdoor_task_failed_total Background tasks that ended failed.\n" ++
                    "# TYPE zasdoor_task_failed_total counter\n" ++
                    "zasdoor_task_failed_total {d}\n", .{
                    body,
                    MetricsRoute.dispatcher_ref.processed.load(.monotonic),
                    MetricsRoute.dispatcher_ref.failed.load(.monotonic),
                });
                defer ctx.allocator.free(full);
                try ctx.text(200, full);
            }
        }.handle,
    });

    std.log.info("zasdoor listening on http://127.0.0.1:{d} (admin CLI: zig build admin -- --help)", .{cfg.http_port});

    // 优雅关闭:SIGINT/SIGTERM → 停止 accept → 排空在途请求 → 停 modules。
    const sig = std.posix.Sigaction{
        .handler = .{ .handler = onShutdownSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &sig, null);
    std.posix.sigaction(std.posix.SIG.TERM, &sig, null);

    const ServerThread = struct {
        fn run(s: *zigmodu.http.Server) !void {
            try s.start(); // 阻塞;stop() 后返回(内部 await 在途请求)
        }
    };
    const server_handle = try std.Thread.spawn(.{ .stack_size = 4 * 1024 * 1024 }, ServerThread.run, .{&server});

    const poll = std.posix.timespec{ .sec = 0, .nsec = 100 * std.time.ns_per_ms };
    while (!ShutdownFlag.requested.load(.acquire)) {
        _ = std.c.nanosleep(&poll, null);
    }
    std.log.info("shutdown signal received, draining in-flight requests...", .{});
    server.stop();
    server_handle.join();
    std.log.info("server stopped gracefully (zasdoor {s})", .{build_info.version});
}

/// Parse `ZASDOOR_CORS_ORIGINS` ("*" or a comma-separated allow-list) into
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
