//! Cross-module HTTP integration tests (zigmodu Testkit dispatch, no socket).
//!
//! These drive the real HTTP stack for the IAM / OAuth / MFA / web3 / agent /
//! health routes: an in-memory SQLite store with every schema group migrated,
//! an admin + a non-admin user, and JWTs minted through AppSecurity. Every
//! assertion checks both the HTTP status code and the {code,msg,data} envelope.

const std = @import("std");
const zigmodu = @import("zigmodu");
const db_mod = @import("db.zig");
const schema = @import("schema.zig");
const tenant = @import("modules/tenant/root.zig");
const user = @import("modules/user/root.zig");
const task = @import("modules/task/root.zig");
const file = @import("modules/file/root.zig");
const notify = @import("modules/notify/root.zig");
const audit = @import("modules/audit/root.zig");
const mail_template = @import("modules/mail_template/root.zig");
const ai = @import("modules/ai/root.zig");
const eventstore = @import("modules/eventstore/root.zig");
const iam = @import("modules/iam/root.zig");
const oauth = @import("modules/oauth/root.zig");
const mfa = @import("modules/mfa/root.zig");
const web3 = @import("modules/web3/root.zig");
const agent = @import("modules/agent/root.zig");

const Testkit = zigmodu.http.Testkit;
const Pair = Testkit.AttrPair;

/// In-memory SQLite store with every schema group migrated. Duplicated from
/// src/tests.zig because a test root cannot import another test root.
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

/// Static store handle for the /api/v1/health/ready probe handler.
const ReadyProbe = struct {
    var user_store: *user.persistence.UserStore = undefined;
};

/// Full in-place wiring of the HTTP stack under test. The APIs are fields (not
/// locals) because routes store their address as user_data.
const Harness = struct {
    allocator: std.mem.Allocator,
    // Production allocates per-request from an arena; Testkit dispatches with
    // server.allocator, so the server gets its own arena for request scopes.
    server_arena: std.heap.ArenaAllocator = undefined,
    server_allocator: std.mem.Allocator = undefined,
    io: std.Io,
    sec: zigmodu.security.AppSecurity,
    user_store: user.persistence.UserStore,
    audit_store: audit.persistence.AuditStore,
    iam_store: iam.persistence.IamStore,
    mfa_store: mfa.persistence.MfaStore,
    wallet_store: web3.persistence.WalletStore,
    agent_store: agent.persistence.AgentStore,
    user_svc: user.service.UserService,
    audit_svc: audit.service.AuditService,
    iam_svc: iam.service.IamService,
    oauth_svc: oauth.service.OAuthService,
    mfa_svc: mfa.service.MfaService,
    web3_svc: web3.service.Web3Service,
    agent_svc: agent.service.AgentService,
    iam_api: iam.api.IamApi(iam.service.IamService, user.service.UserService),
    oauth_api: oauth.api.OAuthApi(oauth.service.OAuthService, user.service.UserService),
    mfa_api: mfa.api.MfaApi(mfa.service.MfaService, user.service.UserService),
    web3_api: web3.api.Web3Api(web3.service.Web3Service, user.service.UserService),
    agent_api: agent.api.AgentApi(agent.service.AgentService, user.service.UserService),
    server: zigmodu.http.Server,
    admin_id: i64 = 0,
    user_id: i64 = 0,
    admin_token: []const u8 = "",
    user_token: []const u8 = "",
    admin_auth: []const u8 = "",
    user_auth: []const u8 = "",

    fn init(h: *Harness, allocator: std.mem.Allocator, io: std.Io, client: anytype) !void {
        h.allocator = allocator;
        h.server_arena = std.heap.ArenaAllocator.init(allocator);
        h.server_allocator = h.server_arena.allocator();
        h.io = io;
        h.user_store = user.persistence.UserStore.init(allocator, client);
        h.audit_store = audit.persistence.AuditStore.init(allocator, client);
        h.iam_store = iam.persistence.IamStore.init(allocator, client);
        h.mfa_store = mfa.persistence.MfaStore.init(allocator, client);
        h.wallet_store = web3.persistence.WalletStore.init(allocator, client);
        h.agent_store = agent.persistence.AgentStore.init(allocator, client);

        h.sec = zigmodu.security.AppSecurity.init(allocator, io, .{ .jwt_secret = "integration-secret" });
        h.user_svc = user.service.UserService.init(&h.user_store, &h.sec, io, 3600, 86400);
        h.audit_svc = audit.service.AuditService.init(allocator, io, &h.audit_store);
        h.iam_svc = iam.service.IamService.init(allocator, io, &h.iam_store, &h.sec);
        h.oauth_svc = oauth.service.OAuthService.init(allocator, io, &h.iam_svc, &h.user_svc, &h.sec, "http://localhost:8080");
        h.mfa_svc = mfa.service.MfaService.init(allocator, io, &h.mfa_store, &h.sec);
        h.web3_svc = web3.service.Web3Service.init(allocator, io, &h.wallet_store, &h.user_svc, &h.sec);
        h.agent_svc = agent.service.AgentService.init(allocator, io, &h.agent_store, &h.user_svc, &h.sec, "http://localhost:8080");

        h.iam_api = iam.api.IamApi(iam.service.IamService, user.service.UserService).init(&h.iam_svc, &h.user_svc, &h.audit_svc, 1);
        h.oauth_api = oauth.api.OAuthApi(oauth.service.OAuthService, user.service.UserService).init(&h.oauth_svc, &h.user_svc);
        h.mfa_api = mfa.api.MfaApi(mfa.service.MfaService, user.service.UserService).init(&h.mfa_svc, &h.user_svc, 1);
        h.web3_api = web3.api.Web3Api(web3.service.Web3Service, user.service.UserService).init(&h.web3_svc, &h.user_svc, 1);
        h.agent_api = agent.api.AgentApi(agent.service.AgentService, user.service.UserService).init(&h.agent_svc, &h.user_svc, 1);

        h.server = zigmodu.http.Server.init(io, h.server_allocator, 0);
        ReadyProbe.user_store = &h.user_store;
        // OAuth / OIDC protocol endpoints live at the server root.
        try h.oauth_api.registerRoutes(&h.server);
        var g = h.server.group("/api/v1");
        try h.iam_api.registerRoutes(&g);
        try h.mfa_api.registerRoutes(&g);
        try h.web3_api.registerRoutes(&g);
        try h.agent_api.registerRoutes(&g);
        try h.server.addRoute(.{
            .method = .GET,
            .path = "api/v1/health/ready",
            .handler = struct {
                fn handle(ctx: *zigmodu.http.Context) !void {
                    var probe = ReadyProbe.user_store.listUsers(1, 1, null, null, null, false) catch {
                        try ctx.sendErrorResponse(503, 503, "database unavailable");
                        return;
                    };
                    // main.zig passes ctx.allocator here, but listUsers allocates rows
                    // with the store allocator; free with the allocator that owns them.
                    defer probe.free(ReadyProbe.user_store.allocator);
                    try ctx.json(200, "{\"code\":0,\"msg\":\"ok\",\"data\":{\"status\":\"READY\"}}");
                }
            }.handle,
        });
    }

    fn seedIdentities(h: *Harness) !void {
        h.admin_id = try h.user_store.createUser("Admin", "admin@example.com", "hash", true, true, 1, 100);
        h.user_id = try h.user_store.createUser("Operator", "operator@example.com", "hash", true, false, 1, 101);
        h.admin_token = try h.mint(h.admin_id, &.{"admin"});
        h.user_token = try h.mint(h.user_id, &.{});
        h.admin_auth = try std.fmt.allocPrint(h.allocator, "Bearer {s}", .{h.admin_token});
        h.user_auth = try std.fmt.allocPrint(h.allocator, "Bearer {s}", .{h.user_token});
    }

    fn mint(h: *Harness, id: i64, roles: []const []const u8) ![]const u8 {
        var buf: [32]u8 = undefined;
        const sub = try std.fmt.bufPrint(&buf, "{d}", .{id});
        return h.sec.module.generateTokenWithTenantAndVersion(sub, roles, "1", 0);
    }

    fn deinit(h: *Harness) void {
        h.server.deinit();
        h.server_arena.deinit();
        if (h.admin_token.len > 0) h.allocator.free(h.admin_token);
        if (h.user_token.len > 0) h.allocator.free(h.user_token);
        if (h.admin_auth.len > 0) h.allocator.free(h.admin_auth);
        if (h.user_auth.len > 0) h.allocator.free(h.user_auth);
    }
};

/// Testkit.dispatchOpts matches ctx.path against the route trie verbatim, so a
/// "?query" suffix would fail to match. Build the Context exactly as Testkit
/// does, inject the query params, then dispatch through the server (no socket).
fn dispatchGetQuery(
    server: *zigmodu.http.Server,
    allocator: std.mem.Allocator,
    path: []const u8,
    query: []const Pair,
    auth_header: []const u8,
) !Testkit.TestResponse {
    var ctx = try zigmodu.http.Context.init(allocator, .GET, path);
    errdefer ctx.deinit();
    for (query) |pair| try ctx.query.put(pair[0], pair[1]);
    if (auth_header.len > 0) {
        const key = try allocator.dupe(u8, "authorization");
        errdefer allocator.free(key);
        const val = try allocator.dupe(u8, auth_header);
        errdefer allocator.free(val);
        try ctx.headers.put(key, val);
    }
    try server.handleForTest(&ctx);
    const status = ctx.status_code;
    const body = try allocator.dupe(u8, ctx.response_body.items);
    ctx.deinit();
    return .{ .status_code = status, .body = body, .body_owned = true };
}

// ── JSON helpers ────────────────────────────────────────────────────────

fn jsonField(v: ?std.json.Value, key: []const u8) ?std.json.Value {
    const val = v orelse return null;
    if (val != .object) return null;
    return val.object.get(key);
}

fn jsonInt(v: ?std.json.Value) ?i64 {
    const val = v orelse return null;
    return switch (val) {
        .integer => |i| i,
        .float => |f| @intFromFloat(f),
        else => null,
    };
}

fn jsonStr(v: ?std.json.Value) ?[]const u8 {
    const val = v orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

fn jsonBool(v: ?std.json.Value) ?bool {
    const val = v orelse return null;
    return switch (val) {
        .bool => |b| b,
        else => null,
    };
}

/// Assert the HTTP status then parse the body and assert the envelope code.
fn expectEnvelope(
    allocator: std.mem.Allocator,
    body: []const u8,
    actual_status: u16,
    want_status: u16,
    want_code: i64,
) !std.json.Parsed(std.json.Value) {
    try std.testing.expectEqual(want_status, actual_status);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    errdefer parsed.deinit();
    const code = jsonInt(jsonField(parsed.value, "code")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(want_code, code);
    try std.testing.expect(jsonField(parsed.value, "data") != null);
    return parsed;
}

fn arrayHasName(v: ?std.json.Value, name: []const u8) bool {
    const arr = v orelse return false;
    if (arr != .array) return false;
    for (arr.array.items) |item| {
        const n = jsonStr(jsonField(item, "name")) orelse continue;
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

fn arrayHasId(v: ?std.json.Value, id: i64) bool {
    const arr = v orelse return false;
    if (arr != .array) return false;
    for (arr.array.items) |item| {
        const got = jsonInt(jsonField(item, "id")) orelse continue;
        if (got == id) return true;
    }
    return false;
}

test "integration: IAM organizations 201/200, 401 without token, 403 non-admin" {
    const allocator = std.testing.allocator;
    var env = try openMemory(allocator);
    defer env.deinit();
    var h: Harness = undefined;
    try Harness.init(&h, allocator, std.testing.io, env.client);
    defer h.deinit();
    try h.seedIdentities();

    // 401 — no Authorization header at all.
    var anon = try Testkit.dispatch(&h.server, .GET, "/api/v1/iam/organizations", null);
    defer anon.deinit(h.server_allocator);
    try std.testing.expectEqual(@as(u16, 401), anon.status_code);

    // 403 — authenticated but not an admin.
    var denied = try Testkit.dispatchOpts(&h.server, .GET, "/api/v1/iam/organizations", .{
        .headers = &.{.{ "authorization", h.user_auth }},
    });
    defer denied.deinit(h.server_allocator);
    var dp = try expectEnvelope(allocator, denied.body, denied.status_code, 403, 403);
    defer dp.deinit();

    // 201 — admin creates an organization.
    var created = try Testkit.dispatchOpts(&h.server, .POST, "/api/v1/iam/organizations", .{
        .body = "{\"name\":\"Acme\",\"description\":\"integration\",\"domain\":\"acme.test\"}",
        .headers = &.{.{ "authorization", h.admin_auth }},
    });
    defer created.deinit(h.server_allocator);
    var cp = try expectEnvelope(allocator, created.body, created.status_code, 201, 0);
    defer cp.deinit();
    const org_id = jsonInt(jsonField(jsonField(cp.value, "data"), "id")) orelse return error.TestUnexpectedResult;
    try std.testing.expect(org_id > 0);

    // 200 — the list contains the organization just created.
    var listed = try Testkit.dispatchOpts(&h.server, .GET, "/api/v1/iam/organizations", .{
        .headers = &.{.{ "authorization", h.admin_auth }},
    });
    defer listed.deinit(h.server_allocator);
    var lp = try expectEnvelope(allocator, listed.body, listed.status_code, 200, 0);
    defer lp.deinit();
    const ldata = jsonField(lp.value, "data") orelse return error.TestUnexpectedResult;
    try std.testing.expect(arrayHasName(jsonField(ldata, "list"), "Acme"));
    try std.testing.expectEqual(@as(i64, 1), jsonInt(jsonField(ldata, "total")) orelse return error.TestUnexpectedResult);
}

test "integration: OAuth discovery + JWKS and web3 SIWE nonce (public)" {
    const allocator = std.testing.allocator;
    var env = try openMemory(allocator);
    defer env.deinit();
    var h: Harness = undefined;
    try Harness.init(&h, allocator, std.testing.io, env.client);
    defer h.deinit();
    try h.seedIdentities();

    // OIDC discovery is a raw JSON document (not the envelope).
    var disc = try Testkit.dispatch(&h.server, .GET, "/.well-known/openid-configuration", null);
    defer disc.deinit(h.server_allocator);
    try std.testing.expectEqual(@as(u16, 200), disc.status_code);
    var dp = try std.json.parseFromSlice(std.json.Value, allocator, disc.body, .{});
    defer dp.deinit();
    const issuer = jsonStr(jsonField(dp.value, "issuer")) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("http://localhost:8080", issuer);

    // JWKS must be present and "keys" must be an array (may be empty).
    var jwks = try Testkit.dispatch(&h.server, .GET, "/.well-known/jwks.json", null);
    defer jwks.deinit(h.server_allocator);
    try std.testing.expectEqual(@as(u16, 200), jwks.status_code);
    var jp = try std.json.parseFromSlice(std.json.Value, allocator, jwks.body, .{});
    defer jp.deinit();
    const keys = jsonField(jp.value, "keys") orelse return error.TestUnexpectedResult;
    try std.testing.expect(keys == .array);

    // SIWE nonce is public and returns a non-empty nonce with a numeric ttl.
    var nonce = try Testkit.dispatch(&h.server, .POST, "/api/v1/web3/siwe/nonce", "{\"address\":\"0x7E5F4552091a69125d5dfcb7b8c2659029395bdf\",\"domain\":\"example.com\"}");
    defer nonce.deinit(h.server_allocator);
    var np = try expectEnvelope(allocator, nonce.body, nonce.status_code, 200, 0);
    defer np.deinit();
    const ndata = jsonField(np.value, "data") orelse return error.TestUnexpectedResult;
    const nstr = jsonStr(jsonField(ndata, "nonce")) orelse return error.TestUnexpectedResult;
    try std.testing.expect(nstr.len > 0);
    try std.testing.expectEqual(@as(i64, 600), jsonInt(jsonField(ndata, "ttl")) orelse return error.TestUnexpectedResult);
}

test "integration: MFA policy round trip, agent create/list, health ready" {
    const allocator = std.testing.allocator;
    var env = try openMemory(allocator);
    defer env.deinit();
    var h: Harness = undefined;
    try Harness.init(&h, allocator, std.testing.io, env.client);
    defer h.deinit();
    try h.seedIdentities();

    // MFA policy: default is require_mfa = false.
    var pol0 = try Testkit.dispatchOpts(&h.server, .GET, "/api/v1/mfa/policy", .{
        .headers = &.{.{ "authorization", h.admin_auth }},
    });
    defer pol0.deinit(h.server_allocator);
    var p0 = try expectEnvelope(allocator, pol0.body, pol0.status_code, 200, 0);
    defer p0.deinit();
    try std.testing.expectEqual(false, jsonBool(jsonField(jsonField(p0.value, "data"), "require_mfa")) orelse return error.TestUnexpectedResult);

    // PUT flips it on.
    var put = try Testkit.dispatchOpts(&h.server, .PUT, "/api/v1/mfa/policy", .{
        .body = "{\"require_mfa\":true}",
        .headers = &.{.{ "authorization", h.admin_auth }},
    });
    defer put.deinit(h.server_allocator);
    var pp = try expectEnvelope(allocator, put.body, put.status_code, 200, 0);
    defer pp.deinit();

    // GET round-trips the change.
    var pol1 = try Testkit.dispatchOpts(&h.server, .GET, "/api/v1/mfa/policy", .{
        .headers = &.{.{ "authorization", h.admin_auth }},
    });
    defer pol1.deinit(h.server_allocator);
    var p1 = try expectEnvelope(allocator, pol1.body, pol1.status_code, 200, 0);
    defer p1.deinit();
    try std.testing.expectEqual(true, jsonBool(jsonField(jsonField(p1.value, "data"), "require_mfa")) orelse return error.TestUnexpectedResult);

    // Agent create (the handler replies 201 Created).
    var ac = try Testkit.dispatchOpts(&h.server, .POST, "/api/v1/agents", .{
        .body = "{\"name\":\"treasury-bot\",\"description\":\"integration\",\"capabilities\":\"[\\\"wallet.balance\\\"]\"}",
        .headers = &.{.{ "authorization", h.admin_auth }},
    });
    defer ac.deinit(h.server_allocator);
    var ap = try expectEnvelope(allocator, ac.body, ac.status_code, 201, 0);
    defer ap.deinit();
    const agent_id = jsonInt(jsonField(jsonField(ap.value, "data"), "id")) orelse return error.TestUnexpectedResult;

    // Paged list finds it. Testkit cannot carry a query string, so inject
    // page/page_size on the Context (see dispatchGetQuery).
    var lr = try dispatchGetQuery(&h.server, h.server_allocator, "/api/v1/agents", &.{
        .{ "page", "1" },
        .{ "page_size", "10" },
    }, h.admin_auth);
    defer lr.deinit(h.server_allocator);
    var alp = try expectEnvelope(allocator, lr.body, lr.status_code, 200, 0);
    defer alp.deinit();
    const adata = jsonField(alp.value, "data") orelse return error.TestUnexpectedResult;
    try std.testing.expect(arrayHasId(jsonField(adata, "list"), agent_id));
    try std.testing.expectEqual(@as(i64, 1), jsonInt(jsonField(adata, "total")) orelse return error.TestUnexpectedResult);

    // Readiness probe reaches the store and reports 200.
    var ready = try Testkit.dispatch(&h.server, .GET, "/api/v1/health/ready", null);
    defer ready.deinit(h.server_allocator);
    var rp = try expectEnvelope(allocator, ready.body, ready.status_code, 200, 0);
    defer rp.deinit();
}
