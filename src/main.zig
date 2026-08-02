//! zenaipa — zigmodu + zent rewrite of pagoda (admin starter kit).
//!
//! Single binary serves the JSON admin API; the Solid SPA in `web/`
//! talks to it over `/api/v1`. Run:
//!   zig build run                          # sqlite (zenaipa.db)
//!   ZENAIPA_DB_DRIVER=postgres ZENAIPA_PG_CONNINFO='host=... dbname=zenaipa user=postgres password=...' zig build run

const std = @import("std");
const zigmodu = @import("zigmodu");
const config_mod = @import("config.zig");
const db_mod = @import("db.zig");
const cors_mw = @import("middleware/cors.zig");
const user = @import("modules/user/root.zig");
const auth = @import("modules/auth/root.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const cfg = config_mod.Config.fromEnv(init.environ_map);
    std.log.info("zenaipa starting (db={s}, port={d})", .{ cfg.db_driver, cfg.http_port });

    // ── Data store: zent driver + schema-as-code migration ──
    const kind: db_mod.DriverKind = if (std.mem.eql(u8, cfg.db_driver, "postgres")) .postgres else .sqlite;
    const dsn = if (kind == .postgres) cfg.pg_conninfo else cfg.sqlite_path;
    var store_env = try db_mod.StoreEnv(user.persistence.infos).open(allocator, kind, dsn);
    defer store_env.deinit();
    std.log.info("[zent] migrated schema via {s} ({s})", .{ @tagName(kind), dsn });

    var store = user.persistence.UserStore.init(allocator, store_env.client);

    var sec = zigmodu.security.AppSecurity.init(allocator, io, .{
        .jwt_secret = cfg.jwt_secret,
        .token_expiry_seconds = cfg.token_expiry_seconds,
    });

    var user_svc = user.service.UserService.init(&store, &sec, io, cfg.password_token_expiration_seconds);
    var user_api = user.api.UserApi(@TypeOf(user_svc)).init(&user_svc);
    var login_limiter = try zigmodu.RateLimiter.init(allocator, "auth-public", 20, 1);
    defer login_limiter.deinit();
    var auth_api = auth.api.AuthApi(@TypeOf(user_svc)).init(&user_svc, cfg.app_host, &login_limiter);

    // ── ZigModu module lifecycle ──
    var modules = try zigmodu.scanModules(allocator, .{ user.module, auth.module });
    defer modules.deinit();
    try zigmodu.validateModules(&modules);
    try zigmodu.startAll(&modules);
    defer zigmodu.stopAll(&modules);

    // ── HTTP server ──
    var server = zigmodu.http.Server.init(io, allocator, cfg.http_port);
    defer server.deinit();

    const origins = try parseCorsOrigins(allocator, cfg.cors_origins);
    defer allocator.free(origins);
    try server.addMiddleware(cors_mw.cors(origins));

    var v1 = server.group("/api/v1");
    try auth_api.registerRoutes(&v1);
    try user_api.registerRoutes(&v1);

    try server.addRoute(.{
        .method = .GET,
        .path = "health/live",
        .handler = struct {
            fn handle(ctx: *zigmodu.http.Context) !void {
                try ctx.json(200, "{\"code\":0,\"msg\":\"ok\",\"data\":{\"status\":\"UP\"}}");
            }
        }.handle,
    });

    std.log.info("zenaipa listening on http://127.0.0.1:{d}", .{cfg.http_port});
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
