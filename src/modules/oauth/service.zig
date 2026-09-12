//! OAuth2 / OIDC protocol service: authorization code + PKCE, client
//! credentials, refresh token, and token introspection. Delegates persistence
//! to IamService and user data to UserService.

const std = @import("std");
const zigmodu = @import("zigmodu");
const jwt = @import("jwt.zig");
const keys = @import("keys.zig");
const iam = @import("../iam/service.zig");
const user_svc = @import("../user/service.zig");

pub const OAuthError = error{
    InvalidRequest,
    UnauthorizedClient,
    InvalidGrant,
    UnsupportedGrantType,
    InvalidClient,
    InvalidScope,
    ServerError,
};

pub const OAuthService = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    iam_svc: *iam.IamService,
    users: *user_svc.UserService,
    sec: *zigmodu.security.AppSecurity,
    issuer: []const u8,
    signer: keys.Signer,
    code_ttl_seconds: i64,
    refresh_ttl_days: i64,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        iam_svc: *iam.IamService,
        users: *user_svc.UserService,
        sec: *zigmodu.security.AppSecurity,
        issuer: []const u8,
    ) OAuthService {
        return .{
            .allocator = allocator,
            .io = io,
            .iam_svc = iam_svc,
            .users = users,
            .sec = sec,
            .issuer = issuer,
            .signer = keys.derive(sec.module.jwt_secret),
            .code_ttl_seconds = 600,
            .refresh_ttl_days = 30,
        };
    }

    pub fn now(self: *OAuthService) i64 {
        return zigmodu.time.wallClockSeconds(self.io);
    }

    /// Produce an OIDC ID token (JWT) for a user + client.
    pub fn issueIdToken(
        self: *OAuthService,
        user: user_svc.UserRow,
        client_id: []const u8,
        scope: []const u8,
        nonce: ?[]const u8,
    ) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);
        const sub = std.fmt.allocPrint(self.allocator, "{d}", .{user.id}) catch return error.OutOfMemory;
        defer self.allocator.free(sub);

        try buf.appendSlice(self.allocator, "{\"iss\":\"");
        try buf.appendSlice(self.allocator, self.issuer);
        try buf.appendSlice(self.allocator, "\",\"sub\":\"");
        try buf.appendSlice(self.allocator, sub);
        try buf.appendSlice(self.allocator, "\",\"aud\":\"");
        try buf.appendSlice(self.allocator, client_id);
        try buf.appendSlice(self.allocator, "\",\"exp\":");
        try appendNum(&buf, self.allocator, self.now() + 3600);
        try buf.appendSlice(self.allocator, ",\"iat\":");
        try appendNum(&buf, self.allocator, self.now());
        if (nonce) |n| try jsonAppendStr(&buf, self.allocator, "nonce", n);
        if (std.mem.indexOf(u8, scope, "profile") != null) try jsonAppendStr(&buf, self.allocator, "name", user.name);
        if (std.mem.indexOf(u8, scope, "email") != null) {
            try jsonAppendStr(&buf, self.allocator, "email", user.email);
            try buf.appendSlice(self.allocator, ",\"email_verified\":");
            try buf.appendSlice(self.allocator, if (user.verified) "true" else "false");
        }
        try buf.appendSlice(self.allocator, "}");
        return self.signer.sign(self.allocator, buf.items);
    }

    /// Produce an OAuth access token (JWT) carrying sub/aud/scope.
    pub fn issueAccessToken(
        self: *OAuthService,
        sub: []const u8,
        client_id: []const u8,
        scope: []const u8,
        ttl: i64,
    ) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);
        try buf.appendSlice(self.allocator, "{\"iss\":\"");
        try buf.appendSlice(self.allocator, self.issuer);
        try buf.appendSlice(self.allocator, "\",\"sub\":\"");
        try buf.appendSlice(self.allocator, sub);
        try buf.appendSlice(self.allocator, "\",\"aud\":\"");
        try buf.appendSlice(self.allocator, client_id);
        try buf.appendSlice(self.allocator, "\",\"azp\":\"");
        try buf.appendSlice(self.allocator, client_id);
        try buf.appendSlice(self.allocator, "\",\"scope\":\"");
        try buf.appendSlice(self.allocator, scope);
        try buf.appendSlice(self.allocator, "\",\"exp\":");
        try appendNum(&buf, self.allocator, self.now() + ttl);
        try buf.appendSlice(self.allocator, ",\"iat\":");
        try appendNum(&buf, self.allocator, self.now());
        try buf.appendSlice(self.allocator, "}");
        return self.signer.sign(self.allocator, buf.items);
    }

    pub const AuthorizeResult = struct {
        code: []const u8,
        redirect_uri: []const u8,
        state: ?[]const u8,
    };

    /// Scopes that still require an explicit user grant before a code is issued.
    pub const ConsentRequired = struct {
        scopes: []const u8,
    };

    /// Result of a consent-aware authorize request.
    pub const AuthorizeOutcome = union(enum) {
        issued: AuthorizeResult,
        consent_required: ConsentRequired,
    };

    /// Validate an authorize request and mint an authorization code.
    ///
    /// Legacy entry point: callers are assumed to have obtained user approval
    /// out-of-band, so the stored-consent gate is not applied. New
    /// integrations should call `authorizeWithConsent`.
    pub fn authorize(
        self: *OAuthService,
        client_id: []const u8,
        redirect_uri: []const u8,
        response_type: []const u8,
        scope: []const u8,
        state: ?[]const u8,
        nonce: ?[]const u8,
        code_challenge: ?[]const u8,
        code_challenge_method: ?[]const u8,
        user_id: i64,
    ) OAuthError!AuthorizeResult {
        var app = try self.loadAuthorizeApp(client_id, redirect_uri, response_type, code_challenge);
        defer app.free(self.iam_svc.allocator);
        return self.issueCodeForApp(app, user_id, redirect_uri, scope, state, nonce, code_challenge, code_challenge_method);
    }

    /// Consent-aware authorize entry point.
    ///
    /// * If the stored consent for (application, user) already covers every
    ///   requested scope, a code is issued as usual.
    /// * Otherwise, unless `consent_granted` is true, the caller receives
    ///   `.consent_required` carrying the requested scope string and no code
    ///   is minted (no silent issuance).
    /// * When `consent_granted` is true the consent is upserted first, then
    ///   the code is issued.
    pub fn authorizeWithConsent(
        self: *OAuthService,
        client_id: []const u8,
        redirect_uri: []const u8,
        response_type: []const u8,
        scope: []const u8,
        state: ?[]const u8,
        nonce: ?[]const u8,
        code_challenge: ?[]const u8,
        code_challenge_method: ?[]const u8,
        user_id: i64,
        consent_granted: bool,
    ) OAuthError!AuthorizeOutcome {
        var app = try self.loadAuthorizeApp(client_id, redirect_uri, response_type, code_challenge);
        defer app.free(self.iam_svc.allocator);

        if (self.isConsentCovered(app.id, user_id, scope)) {
            const res = try self.issueCodeForApp(app, user_id, redirect_uri, scope, state, nonce, code_challenge, code_challenge_method);
            return .{ .issued = res };
        }
        if (!consent_granted) {
            const scopes = self.allocator.dupe(u8, scope) catch return error.ServerError;
            return .{ .consent_required = .{ .scopes = scopes } };
        }
        _ = self.iam_svc.store.upsertConsent(app.tenant_id, app.id, user_id, scope, self.now()) catch return error.ServerError;
        const res = try self.issueCodeForApp(app, user_id, redirect_uri, scope, state, nonce, code_challenge, code_challenge_method);
        return .{ .issued = res };
    }

    /// Record a consent grant for (tenant, application, user) covering scope.
    pub fn grantConsent(
        self: *OAuthService,
        tenant_id: i64,
        application_id: i64,
        user_id: i64,
        scope: []const u8,
    ) OAuthError!void {
        _ = self.iam_svc.store.upsertConsent(tenant_id, application_id, user_id, scope, self.now()) catch return error.ServerError;
    }

    /// Record a consent grant addressed by OAuth client_id.
    pub fn grantConsentForClient(
        self: *OAuthService,
        client_id: []const u8,
        user_id: i64,
        scope: []const u8,
    ) OAuthError!void {
        const app_opt = self.iam_svc.getApplicationByClientId(client_id) catch return error.InvalidClient;
        const app = app_opt orelse return error.InvalidClient;
        defer app.free(self.iam_svc.allocator);
        return self.grantConsent(app.tenant_id, app.id, user_id, scope);
    }

    /// Common client / redirect / PKCE validation. The returned application row
    /// is owned by the caller and must be freed with the IAM allocator.
    fn loadAuthorizeApp(
        self: *OAuthService,
        client_id: []const u8,
        redirect_uri: []const u8,
        response_type: []const u8,
        code_challenge: ?[]const u8,
    ) OAuthError!iam.ApplicationRow {
        if (!std.mem.eql(u8, response_type, "code")) return error.InvalidRequest;

        const app_opt = self.iam_svc.getApplicationByClientId(client_id) catch return error.InvalidClient;
        const app = app_opt orelse return error.InvalidClient;
        errdefer app.free(self.iam_svc.allocator);
        if (!app.active) return error.UnauthorizedClient;

        if (!redirectUriAllowed(app.redirect_uris, redirect_uri)) return error.InvalidRequest;

        if (app.pkce_required and (code_challenge == null or code_challenge.?.len == 0)) {
            return error.InvalidRequest;
        }
        return app;
    }

    fn issueCodeForApp(
        self: *OAuthService,
        app: iam.ApplicationRow,
        user_id: i64,
        redirect_uri: []const u8,
        scope: []const u8,
        state: ?[]const u8,
        nonce: ?[]const u8,
        code_challenge: ?[]const u8,
        code_challenge_method: ?[]const u8,
    ) OAuthError!AuthorizeResult {
        const raw_code = jwt.randomToken(self.allocator, self.io, 32) catch return error.ServerError;
        defer self.allocator.free(raw_code);
        const code_hash = hashToken(self.allocator, raw_code) catch return error.ServerError;
        defer self.allocator.free(code_hash);

        _ = self.iam_svc.store.createAuthCode(
            app.tenant_id,
            app.id,
            user_id,
            code_hash,
            redirect_uri,
            scope,
            nonce orelse "",
            code_challenge orelse "",
            code_challenge_method orelse "",
            self.now() + self.code_ttl_seconds,
            self.now(),
        ) catch return error.ServerError;

        const code = self.allocator.dupe(u8, raw_code) catch return error.ServerError;
        errdefer self.allocator.free(code);
        const uri = self.allocator.dupe(u8, redirect_uri) catch return error.ServerError;
        errdefer self.allocator.free(uri);
        const state_dup = if (state) |s| (self.allocator.dupe(u8, s) catch return error.ServerError) else null;
        return .{ .code = code, .redirect_uri = uri, .state = state_dup };
    }

    /// True when a stored consent row covers every requested scope.
    fn isConsentCovered(self: *OAuthService, application_id: i64, user_id: i64, requested_scope: []const u8) bool {
        const row_opt = self.iam_svc.store.getConsent(application_id, user_id) catch return false;
        const row = row_opt orelse return false;
        defer row.free(self.iam_svc.allocator);
        return scopesCovered(row.scope, requested_scope);
    }

    /// Verify an OAuth-issued JWT. Asymmetric tokens are verified against the
    /// derived public key; legacy HS256 tokens fall back to the shared secret.
    pub fn verifyToken(self: *OAuthService, allocator: std.mem.Allocator, token_str: []const u8) ![]const u8 {
        if (jwt.peekHeaderAlg(allocator, token_str)) |alg| {
            switch (alg) {
                .EdDSA => return self.signer.verify(allocator, token_str),
                .ES256 => return error.InvalidToken,
                .HS256 => {},
            }
        }
        return jwt.verify(allocator, self.sec.module.jwt_secret, token_str);
    }

    pub const TokenIssue = struct {
        access_token: []const u8,
        id_token: ?[]const u8,
        refresh_token: ?[]const u8,
        expires_in: i64,
        scope: []const u8,
    };

    fn tokenExchangeCode(
        self: *OAuthService,
        code: []const u8,
        redirect_uri: []const u8,
        verifier: ?[]const u8,
    ) OAuthError!TokenIssue {
        const code_hash = hashToken(self.allocator, code) catch return error.InvalidGrant;
        defer self.allocator.free(code_hash);

        const code_row_opt = self.iam_svc.store.getAuthCodeByHash(code_hash) catch return error.InvalidGrant;
        const code_row = code_row_opt orelse return error.InvalidGrant;
        defer code_row.free(self.iam_svc.allocator);

        if (code_row.used_at != 0) return error.InvalidGrant;
        if (code_row.expires_at < self.now()) return error.InvalidGrant;
        if (redirect_uri.len > 0 and !std.mem.eql(u8, code_row.redirect_uri, redirect_uri)) return error.InvalidGrant;

        if (code_row.code_challenge.len > 0) {
            if (!verifyPkce(code_row.code_challenge, code_row.code_challenge_method, verifier)) {
                return error.InvalidGrant;
            }
        }

        self.iam_svc.store.consumeAuthCode(code_row.id, self.now()) catch {};

        const app_opt = self.iam_svc.getApplication(code_row.application_id) catch return error.InvalidClient;
        const app = app_opt orelse return error.InvalidClient;
        defer app.free(self.iam_svc.allocator);

        const user_opt = self.users.getUserById(code_row.user_id) catch return error.InvalidGrant;
        const user = user_opt orelse return error.InvalidGrant;
        defer user.free(self.users.store.allocator);

        return self.issueTokensForUser(app, user, code_row.scope, code_row.nonce);
    }

    fn tokenClientCredentials(
        self: *OAuthService,
        app: iam.ApplicationRow,
        scope: []const u8,
    ) OAuthError!TokenIssue {
        const sub = std.fmt.allocPrint(self.allocator, "app_{d}", .{app.id}) catch return error.ServerError;
        defer self.allocator.free(sub);
        const access = self.issueAccessToken(sub, app.client_id, scope, app.access_token_ttl) catch return error.ServerError;
        errdefer self.allocator.free(access);
        const scope_dup = self.allocator.dupe(u8, scope) catch return error.ServerError;
        return .{
            .access_token = access,
            .id_token = null,
            .refresh_token = null,
            .expires_in = app.access_token_ttl,
            .scope = scope_dup,
        };
    }

    fn tokenRefresh(self: *OAuthService, refresh_token: []const u8) OAuthError!TokenIssue {
        const hash = hashToken(self.allocator, refresh_token) catch return error.InvalidGrant;
        defer self.allocator.free(hash);
        const row_opt = self.iam_svc.store.findRefreshTokenByHash(hash) catch return error.InvalidGrant;
        const row = row_opt orelse return error.InvalidGrant;
        defer row.free(self.iam_svc.allocator);
        if (row.revoked_at != 0 or row.expires_at < self.now()) return error.InvalidGrant;

        const app_opt = self.iam_svc.getApplication(row.application_id) catch return error.InvalidClient;
        const app = app_opt orelse return error.InvalidClient;
        defer app.free(self.iam_svc.allocator);
        const user_opt = self.users.getUserById(row.user_id) catch return error.InvalidGrant;
        const user = user_opt orelse return error.InvalidGrant;
        defer user.free(self.users.store.allocator);

        return self.issueTokensForUser(app, user, row.scope, "");
    }

    fn issueTokensForUser(
        self: *OAuthService,
        app: iam.ApplicationRow,
        user: user_svc.UserRow,
        scope: []const u8,
        nonce: []const u8,
    ) OAuthError!TokenIssue {
        const sub = std.fmt.allocPrint(self.allocator, "{d}", .{user.id}) catch return error.ServerError;
        defer self.allocator.free(sub);

        const access = self.issueAccessToken(sub, app.client_id, scope, app.access_token_ttl) catch return error.ServerError;
        errdefer self.allocator.free(access);

        var id_token: ?[]const u8 = null;
        if (std.mem.indexOf(u8, scope, "openid") != null) {
            id_token = self.issueIdToken(user, app.client_id, scope, if (nonce.len > 0) nonce else null) catch return error.ServerError;
        }
        errdefer if (id_token) |it| self.allocator.free(it);

        var refresh_token: ?[]const u8 = null;
        if (std.mem.indexOf(u8, scope, "offline_access") != null or app.refresh_token_ttl > 0) {
            const raw = jwt.randomToken(self.allocator, self.io, 32) catch return error.ServerError;
            defer self.allocator.free(raw);
            const hash = hashToken(self.allocator, raw) catch return error.ServerError;
            defer self.allocator.free(hash);
            _ = self.iam_svc.store.createRefreshToken(
                app.tenant_id,
                app.id,
                user.id,
                0,
                hash,
                scope,
                self.now() + self.refresh_ttl_days * 24 * 3600,
                self.now(),
            ) catch return error.ServerError;
            refresh_token = self.allocator.dupe(u8, raw) catch return error.ServerError;
        }
        errdefer if (refresh_token) |rt| self.allocator.free(rt);

        const scope_dup = self.allocator.dupe(u8, scope) catch return error.ServerError;
        return .{
            .access_token = access,
            .id_token = id_token,
            .refresh_token = refresh_token,
            .expires_in = app.access_token_ttl,
            .scope = scope_dup,
        };
    }

    /// Handle a POST /oauth/token request.
    pub fn token(
        self: *OAuthService,
        grant_type: []const u8,
        client_id: []const u8,
        client_secret: []const u8,
        code: ?[]const u8,
        redirect_uri: ?[]const u8,
        code_verifier: ?[]const u8,
        scope: ?[]const u8,
        refresh_token: ?[]const u8,
    ) OAuthError!TokenIssue {
        if (std.mem.eql(u8, grant_type, "client_credentials")) {
            const app_opt = self.iam_svc.authenticateClient(client_id, client_secret) catch return error.InvalidClient;
            const app = app_opt orelse return error.InvalidClient;
            defer app.free(self.iam_svc.allocator);
            return self.tokenClientCredentials(app, scope orelse "");
        }
        if (std.mem.eql(u8, grant_type, "authorization_code")) {
            return self.tokenExchangeCode(code orelse return error.InvalidRequest, redirect_uri orelse "", code_verifier);
        }
        if (std.mem.eql(u8, grant_type, "refresh_token")) {
            return self.tokenRefresh(refresh_token orelse return error.InvalidRequest);
        }
        return error.UnsupportedGrantType;
    }

    pub const IntrospectionResult = struct {
        active: bool,
        sub: ?[]const u8,
        scope: ?[]const u8,
        client_id: ?[]const u8,
        exp: ?i64,
    };

    pub fn introspect(self: *OAuthService, token_str: []const u8) IntrospectionResult {
        const payload = self.verifyToken(self.allocator, token_str) catch {
            return .{ .active = false, .sub = null, .scope = null, .client_id = null, .exp = null };
        };
        defer self.allocator.free(payload);

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, payload, .{}) catch {
            return .{ .active = false, .sub = null, .scope = null, .client_id = null, .exp = null };
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return .{ .active = false, .sub = null, .scope = null, .client_id = null, .exp = null };
        const sub_s = objStr(root.object, "sub");
        const scope_s = objStr(root.object, "scope");
        const aud_s = objStr(root.object, "aud");
        const sub = if (sub_s) |x| (self.allocator.dupe(u8, x) catch null) else null;
        const scope = if (scope_s) |x| (self.allocator.dupe(u8, x) catch null) else null;
        const client_id = if (aud_s) |x| (self.allocator.dupe(u8, x) catch null) else null;
        return .{
            .active = true,
            .sub = sub,
            .scope = scope,
            .client_id = client_id,
            .exp = objInt(root.object, "exp"),
        };
    }

    pub fn freeIntrospection(self: *OAuthService, r: IntrospectionResult) void {
        if (r.sub) |x| self.allocator.free(x);
        if (r.scope) |x| self.allocator.free(x);
        if (r.client_id) |x| self.allocator.free(x);
    }
};

fn appendNum(buf: *std.ArrayList(u8), a: std.mem.Allocator, n: i64) !void {
    var num: [24]u8 = undefined;
    const s = try std.fmt.bufPrint(&num, "{d}", .{n});
    try buf.appendSlice(a, s);
}

/// Deterministic hash for opaque tokens (codes / refresh tokens). SHA-256
/// is stable across calls (unlike salted PBKDF2 used for passwords).
pub fn hashToken(a: std.mem.Allocator, token: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(token, &digest, .{});
    const enc = std.base64.url_safe_no_pad.Encoder;
    const n = enc.calcSize(32);
    const out = try a.alloc(u8, n);
    errdefer a.free(out);
    _ = enc.encode(out, &digest);
    return out;
}

/// Append a quoted string pair. Values must not contain quote characters.
fn jsonAppendStr(buf: *std.ArrayList(u8), a: std.mem.Allocator, key: []const u8, value: []const u8) !void {
    try buf.appendSlice(a, ",\"");
    try buf.appendSlice(a, key);
    try buf.appendSlice(a, "\":\"");
    try buf.appendSlice(a, value);
    try buf.appendSlice(a, "\"");
}

fn redirectUriAllowed(registered: []const u8, candidate: []const u8) bool {
    if (registered.len == 0) return false;
    return std.mem.indexOf(u8, registered, candidate) != null;
}

/// True when every space/tab separated scope in `requested` appears as a
/// whole token in `granted`. Substring matches (e.g. "open" vs "openid")
/// are deliberately rejected.
pub fn scopesCovered(granted: []const u8, requested: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, requested, " \t");
    while (it.next()) |token| {
        if (token.len == 0) continue;
        if (!scopeGranted(granted, token)) return false;
    }
    return true;
}

fn scopeGranted(granted: []const u8, scope: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, granted, " \t");
    while (it.next()) |token| {
        if (std.mem.eql(u8, token, scope)) return true;
    }
    return false;
}

fn verifyPkce(challenge: []const u8, method: []const u8, verifier: ?[]const u8) bool {
    const v = verifier orelse return false;
    if (std.mem.eql(u8, method, "plain")) {
        return std.mem.eql(u8, challenge, v);
    }
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(v, &digest, .{});
    const enc = std.base64.url_safe_no_pad.Encoder;
    const n = enc.calcSize(32);
    var out: [64]u8 = undefined;
    _ = enc.encode(out[0..n], &digest);
    return std.mem.eql(u8, challenge, out[0..n]);
}

fn objStr(m: std.json.ObjectMap, k: []const u8) ?[]const u8 {
    const v = m.get(k) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

fn objInt(m: std.json.ObjectMap, k: []const u8) ?i64 {
    const v = m.get(k) orelse return null;
    return switch (v) {
        .integer => |i| i,
        else => null,
    };
}
