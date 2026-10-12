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
    // RFC 8628 device grant transient/final states.
    AuthorizationPending,
    SlowDown,
    AccessDenied,
    ExpiredToken,
};

pub const OAuthService = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    iam_svc: *iam.IamService,
    users: *user_svc.UserService,
    sec: *zigmodu.security.AppSecurity,
    issuer: []const u8,
    ring: keys.KeyRing,
    code_ttl_seconds: i64,
    refresh_ttl_days: i64,
    device_code_ttl_seconds: i64 = 600,
    device_poll_interval_seconds: i64 = 5,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        iam_svc: *iam.IamService,
        users: *user_svc.UserService,
        sec: *zigmodu.security.AppSecurity,
        issuer: []const u8,
    ) OAuthService {
        return initWithExtraKeys(allocator, io, iam_svc, users, sec, issuer, "");
    }

    /// Same as init, plus optional older signing secrets (comma-separated) kept
    /// in the key ring for verification during a rotation overlap window.
    pub fn initWithExtraKeys(
        allocator: std.mem.Allocator,
        io: std.Io,
        iam_svc: *iam.IamService,
        users: *user_svc.UserService,
        sec: *zigmodu.security.AppSecurity,
        issuer: []const u8,
        extra_key_secrets_csv: []const u8,
    ) OAuthService {
        return .{
            .allocator = allocator,
            .io = io,
            .iam_svc = iam_svc,
            .users = users,
            .sec = sec,
            .issuer = issuer,
            .ring = keys.deriveRing(sec.module.jwt_secret, extra_key_secrets_csv),
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
        access_token: ?[]const u8,
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
        // OIDC phone / address claims (only when the scope was requested and a
        // value is stored; values are JSON-safe by construction).
        if (std.mem.indexOf(u8, scope, "phone") != null and user.phone.len > 0) {
            try jsonAppendStr(&buf, self.allocator, "phone_number", user.phone);
            try buf.appendSlice(self.allocator, ",\"phone_number_verified\":false");
        }
        if (std.mem.indexOf(u8, scope, "address") != null and user.address.len > 0) {
            try buf.appendSlice(self.allocator, ",\"address\":{\"formatted\":\"");
            try buf.appendSlice(self.allocator, user.address);
            try buf.appendSlice(self.allocator, "\"}");
        }
        // OIDC at_hash binds the ID token to the access token (required when
        // both are returned from the token endpoint). c_hash is intentionally
        // not emitted: this server only issues ID tokens at the token endpoint
        // (authorization-code flow), never at the authorization endpoint, so
        // the hybrid-flow c_hash binding does not apply.
        if (access_token) |at| {
            const h = atHash(self.allocator, at) catch return error.OutOfMemory;
            defer self.allocator.free(h);
            try jsonAppendStr(&buf, self.allocator, "at_hash", h);
        }
        try buf.appendSlice(self.allocator, "}");
        return self.ring.sign(self.allocator, buf.items);
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
        return self.ring.sign(self.allocator, buf.items);
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
                .EdDSA => return self.ring.verify(allocator, token_str),
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
        /// RFC 8693 Token Exchange responses carry the issued token type.
        issued_token_type: ?[]const u8 = null,
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

        return self.issueTokensForUser(app, user, code_row.scope, code_row.nonce, "");
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

    // ── RFC 8628 device authorization grant ──────────────────

    pub const DeviceAuthorization = struct {
        device_code: []const u8,
        user_code: []const u8,
        verification_uri: []const u8,
        verification_uri_complete: []const u8,
        expires_in: i64,
        interval: i64,
    };

    pub fn freeDeviceAuthorization(self: *OAuthService, d: DeviceAuthorization) void {
        self.allocator.free(d.device_code);
        self.allocator.free(d.user_code);
        self.allocator.free(d.verification_uri);
        self.allocator.free(d.verification_uri_complete);
    }

    /// Start a device grant: mint a device_code (polled by the client) and a
    /// short user_code the human enters on the verification page.
    pub fn deviceAuthorization(self: *OAuthService, client_id: []const u8, scope: []const u8) OAuthError!DeviceAuthorization {
        const app_opt = self.iam_svc.getApplicationByClientId(client_id) catch return error.InvalidClient;
        const app = app_opt orelse return error.InvalidClient;
        defer app.free(self.iam_svc.allocator);
        if (!app.active) return error.UnauthorizedClient;

        const raw_device = jwt.randomToken(self.allocator, self.io, 32) catch return error.ServerError;
        defer self.allocator.free(raw_device);
        const hash = hashToken(self.allocator, raw_device) catch return error.ServerError;
        defer self.allocator.free(hash);
        const user_code = generateUserCode(self.allocator, self.io) catch return error.ServerError;
        errdefer self.allocator.free(user_code);

        const eff_scope = if (scope.len > 0) scope else "openid profile email offline_access";
        _ = self.iam_svc.store.createDeviceCode(
            app.tenant_id,
            app.id,
            hash,
            user_code,
            eff_scope,
            self.now() + self.device_code_ttl_seconds,
            self.now(),
        ) catch return error.ServerError;

        const device_code = self.allocator.dupe(u8, raw_device) catch return error.ServerError;
        errdefer self.allocator.free(device_code);
        const verification_uri = std.fmt.allocPrint(self.allocator, "{s}/device", .{self.issuer}) catch return error.ServerError;
        errdefer self.allocator.free(verification_uri);
        const complete = std.fmt.allocPrint(self.allocator, "{s}?user_code={s}", .{ verification_uri, user_code }) catch return error.ServerError;
        return .{
            .device_code = device_code,
            .user_code = user_code,
            .verification_uri = verification_uri,
            .verification_uri_complete = complete,
            .expires_in = self.device_code_ttl_seconds,
            .interval = self.device_poll_interval_seconds,
        };
    }

    /// Approve or deny a pending device code on behalf of an authenticated user.
    pub fn deviceResolve(self: *OAuthService, user_code: []const u8, user_id: i64, approve: bool) OAuthError!void {
        const row_opt = self.iam_svc.store.getDeviceCodeByUserCode(user_code) catch return error.ServerError;
        const row = row_opt orelse return error.InvalidGrant;
        defer row.free(self.iam_svc.allocator);
        if (!std.mem.eql(u8, row.status, "pending")) return error.InvalidGrant;
        if (row.expires_at < self.now()) return error.ExpiredToken;
        self.iam_svc.store.resolveDeviceCode(row.id, if (approve) "approved" else "denied", if (approve) user_id else 0, self.now()) catch return error.ServerError;
    }

    fn tokenDevice(self: *OAuthService, device_code: []const u8, client_id: []const u8) OAuthError!TokenIssue {
        const hash = hashToken(self.allocator, device_code) catch return error.InvalidGrant;
        defer self.allocator.free(hash);
        const row_opt = self.iam_svc.store.getDeviceCodeByHash(hash) catch return error.InvalidGrant;
        const row = row_opt orelse return error.InvalidGrant;
        defer row.free(self.iam_svc.allocator);

        if (row.expires_at < self.now()) return error.ExpiredToken;
        if (std.mem.eql(u8, row.status, "denied")) return error.AccessDenied;
        if (std.mem.eql(u8, row.status, "used")) return error.InvalidGrant;
        if (!std.mem.eql(u8, row.status, "approved")) {
            // Still pending: enforce the advertised poll interval.
            if (row.last_polled_at != 0 and self.now() - row.last_polled_at < self.device_poll_interval_seconds) {
                self.iam_svc.store.touchDeviceCode(row.id, self.now()) catch {};
                return error.SlowDown;
            }
            self.iam_svc.store.touchDeviceCode(row.id, self.now()) catch {};
            return error.AuthorizationPending;
        }

        const app_opt = self.iam_svc.getApplication(row.application_id) catch return error.InvalidClient;
        const app = app_opt orelse return error.InvalidClient;
        defer app.free(self.iam_svc.allocator);
        if (client_id.len == 0 or !std.mem.eql(u8, app.client_id, client_id)) return error.InvalidGrant;

        const user_opt = self.users.getUserById(row.user_id) catch return error.InvalidGrant;
        const user = user_opt orelse return error.InvalidGrant;
        defer user.free(self.users.store.allocator);

        // Single use: mark it used before issuing so a concurrent poll cannot
        // mint two token sets from the same device code.
        self.iam_svc.store.consumeDeviceCode(row.id, self.now()) catch {};
        return self.issueTokensForUser(app, user, row.scope, "", "");
    }

    // ── RFC 8693 token exchange ──────────────────────────────

    pub const token_exchange_grant = "urn:ietf:params:oauth:grant-type:token-exchange";
    pub const token_type_access = "urn:ietf:params:oauth:token-type:access_token";
    pub const token_type_id = "urn:ietf:params:oauth:token-type:id_token";
    pub const token_type_jwt = "urn:ietf:params:oauth:token-type:jwt";

    /// Exchange a subject (and optional actor) token for a new access token.
    /// The requesting client must authenticate; scope may only be downscoped
    /// from the subject token; when an actor token is supplied the result
    /// carries an act claim (delegation, RFC 8693 section 4.1).
    pub fn tokenExchange(
        self: *OAuthService,
        client_id: []const u8,
        client_secret: []const u8,
        subject_token: []const u8,
        subject_token_type: []const u8,
        actor_token: ?[]const u8,
        actor_token_type: ?[]const u8,
        requested_token_type: ?[]const u8,
        audience: ?[]const u8,
        scope: ?[]const u8,
    ) OAuthError!TokenIssue {
        const app_opt = self.iam_svc.authenticateClient(client_id, client_secret) catch return error.InvalidClient;
        const app = app_opt orelse return error.InvalidClient;
        defer app.free(self.iam_svc.allocator);

        if (subject_token.len == 0) return error.InvalidRequest;
        if (!isJwtTokenType(subject_token_type)) return error.InvalidRequest;

        const sub_payload = self.verifyToken(self.allocator, subject_token) catch return error.InvalidGrant;
        defer self.allocator.free(sub_payload);
        const sub_parsed = std.json.parseFromSlice(std.json.Value, self.allocator, sub_payload, .{}) catch return error.InvalidGrant;
        defer sub_parsed.deinit();
        const sub = jsonField(sub_parsed.value, "sub") orelse return error.InvalidGrant;
        const sub_scope = jsonField(sub_parsed.value, "scope") orelse "";

        var actor_sub: ?[]const u8 = null;
        var actor_owned: ?[]const u8 = null;
        defer if (actor_owned) |a| self.allocator.free(a);
        if (actor_token) |at| {
            if (!isJwtTokenType(actor_token_type orelse "")) return error.InvalidRequest;
            const act_payload = self.verifyToken(self.allocator, at) catch return error.InvalidGrant;
            defer self.allocator.free(act_payload);
            const act_parsed = std.json.parseFromSlice(std.json.Value, self.allocator, act_payload, .{}) catch return error.InvalidGrant;
            defer act_parsed.deinit();
            // The parser arena dies at the end of this block; own a copy.
            const raw_actor = jsonField(act_parsed.value, "sub") orelse return error.InvalidGrant;
            actor_owned = self.allocator.dupe(u8, raw_actor) catch return error.ServerError;
            actor_sub = actor_owned;
        }

        // This endpoint issues access tokens; refresh/id exchange is not offered.
        if (requested_token_type) |rtt| {
            if (rtt.len > 0 and !std.mem.eql(u8, rtt, token_type_access)) return error.InvalidRequest;
        }

        // Scope may only shrink.
        const eff_scope = if (scope) |s| blk: {
            if (s.len == 0) break :blk sub_scope;
            if (!scopesCovered(sub_scope, s)) return error.InvalidScope;
            break :blk s;
        } else sub_scope;

        const aud = if (audience) |a| (if (a.len > 0) a else app.client_id) else app.client_id;
        if (!jsonSafe(aud)) return error.InvalidRequest;
        if (!jsonSafe(eff_scope)) return error.InvalidRequest;

        const access = self.issueExchangedToken(sub, aud, eff_scope, app.access_token_ttl, actor_sub) catch return error.ServerError;
        errdefer self.allocator.free(access);
        const scope_dup = self.allocator.dupe(u8, eff_scope) catch return error.ServerError;
        return .{
            .access_token = access,
            .id_token = null,
            .refresh_token = null,
            .expires_in = app.access_token_ttl,
            .scope = scope_dup,
            .issued_token_type = token_type_access,
        };
    }

    /// Sign an access token for a token-exchange result, including the RFC 8693
    /// delegation act claim when an actor is present.
    pub fn issueExchangedToken(self: *OAuthService, sub: []const u8, aud: []const u8, scope: []const u8, ttl: i64, actor_sub: ?[]const u8) ![]const u8 {
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(self.allocator);
        try buf.appendSlice(self.allocator, "{\"iss\":\"");
        try buf.appendSlice(self.allocator, self.issuer);
        try buf.appendSlice(self.allocator, "\",\"sub\":\"");
        try buf.appendSlice(self.allocator, sub);
        try buf.appendSlice(self.allocator, "\",\"aud\":\"");
        try buf.appendSlice(self.allocator, aud);
        try buf.appendSlice(self.allocator, "\",\"scope\":\"");
        try buf.appendSlice(self.allocator, scope);
        try buf.appendSlice(self.allocator, "\",\"exp\":");
        try appendNum(&buf, self.allocator, self.now() + ttl);
        try buf.appendSlice(self.allocator, ",\"iat\":");
        try appendNum(&buf, self.allocator, self.now());
        if (actor_sub) |a| {
            if (!jsonSafe(a)) return error.InvalidRequest;
            try buf.appendSlice(self.allocator, ",\"act\":{\"sub\":\"");
            try buf.appendSlice(self.allocator, a);
            try buf.appendSlice(self.allocator, "\"}");
        }
        try buf.appendSlice(self.allocator, "}");
        return self.ring.sign(self.allocator, buf.items);
    }

    fn tokenRefresh(
        self: *OAuthService,
        client_id: []const u8,
        client_secret: []const u8,
        refresh_token: []const u8,
    ) OAuthError!TokenIssue {
        const hash = hashToken(self.allocator, refresh_token) catch return error.InvalidGrant;
        defer self.allocator.free(hash);
        const row_opt = self.iam_svc.store.findRefreshTokenByHash(hash) catch return error.InvalidGrant;
        const row = row_opt orelse return error.InvalidGrant;
        defer row.free(self.iam_svc.allocator);

        // Reuse detection: a token that was already rotated away must never be
        // accepted. Someone replayed a leaked token -> revoke the whole family
        // (the legitimate holder's current token included).
        if (row.rotated_at != 0) {
            self.iam_svc.store.revokeRefreshTokenFamily(row.family_id, self.now()) catch {};
            return error.InvalidGrant;
        }
        if (row.revoked_at != 0 or row.expires_at < self.now()) return error.InvalidGrant;

        const app_opt = self.iam_svc.getApplication(row.application_id) catch return error.InvalidClient;
        const app = app_opt orelse return error.InvalidClient;
        defer app.free(self.iam_svc.allocator);

        // Bind the refresh token to the authenticating client. Public clients
        // (spa/native) send no secret; confidential clients must authenticate.
        if (client_id.len == 0 or !std.mem.eql(u8, app.client_id, client_id)) return error.InvalidGrant;
        const public_client = std.mem.eql(u8, app.type, "spa") or std.mem.eql(u8, app.type, "native");
        if (!public_client) {
            const authed = self.iam_svc.authenticateClient(client_id, client_secret) catch null;
            if (authed) |a| a.free(self.iam_svc.allocator) else return error.InvalidClient;
        }

        const user_opt = self.users.getUserById(row.user_id) catch return error.InvalidGrant;
        const user = user_opt orelse return error.InvalidGrant;
        defer user.free(self.users.store.allocator);

        // Issue the successor first, then mark the presented token single-use.
        const issue = try self.issueTokensForUser(app, user, row.scope, "", row.family_id);
        self.iam_svc.store.rotateRefreshToken(row.id, self.now()) catch {};
        return issue;
    }

    fn issueTokensForUser(
        self: *OAuthService,
        app: iam.ApplicationRow,
        user: user_svc.UserRow,
        scope: []const u8,
        nonce: []const u8,
        family_id: []const u8,
    ) OAuthError!TokenIssue {
        const sub = std.fmt.allocPrint(self.allocator, "{d}", .{user.id}) catch return error.ServerError;
        defer self.allocator.free(sub);

        const access = self.issueAccessToken(sub, app.client_id, scope, app.access_token_ttl) catch return error.ServerError;
        errdefer self.allocator.free(access);

        var id_token: ?[]const u8 = null;
        if (std.mem.indexOf(u8, scope, "openid") != null) {
            id_token = self.issueIdToken(user, app.client_id, scope, if (nonce.len > 0) nonce else null, access) catch return error.ServerError;
        }
        errdefer if (id_token) |it| self.allocator.free(it);

        var refresh_token: ?[]const u8 = null;
        if (std.mem.indexOf(u8, scope, "offline_access") != null or app.refresh_token_ttl > 0) {
            const raw = jwt.randomToken(self.allocator, self.io, 32) catch return error.ServerError;
            defer self.allocator.free(raw);
            const hash = hashToken(self.allocator, raw) catch return error.ServerError;
            defer self.allocator.free(hash);
            // A fresh grant opens a new family; a rotation keeps the family id.
            const fam = if (family_id.len > 0)
                (self.allocator.dupe(u8, family_id) catch return error.ServerError)
            else
                (jwt.randomToken(self.allocator, self.io, 16) catch return error.ServerError);
            defer self.allocator.free(fam);
            _ = self.iam_svc.store.createRefreshToken(
                app.tenant_id,
                app.id,
                user.id,
                0,
                hash,
                fam,
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
        device_code: ?[]const u8,
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
            return self.tokenRefresh(client_id, client_secret, refresh_token orelse return error.InvalidRequest);
        }
        if (std.mem.eql(u8, grant_type, "urn:ietf:params:oauth:grant-type:device_code")) {
            return self.tokenDevice(device_code orelse return error.InvalidRequest, client_id);
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

fn isJwtTokenType(t: []const u8) bool {
    return std.mem.eql(u8, t, OAuthService.token_type_access) or std.mem.eql(u8, t, OAuthService.token_type_id) or std.mem.eql(u8, t, OAuthService.token_type_jwt);
}

/// True when a value can be embedded in a JSON string without escaping.
fn jsonSafe(s: []const u8) bool {
    for (s) |c| {
        if (c == '"' or c == '\\' or c < 0x20) return false;
    }
    return true;
}

fn jsonField(v: std.json.Value, key: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const val = v.object.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

/// RFC 8628 user code: 8 chars from the unambiguous base-20 alphabet, grouped
/// as XXXX-XXXX (RFC 8628 §6.1).
fn generateUserCode(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    const alphabet = "BCDFGHJKLMNPQRSTVWXZ";
    var bytes: [8]u8 = undefined;
    var file = try std.Io.Dir.cwd().openFile(io, "/dev/urandom", .{});
    defer file.close(io);
    const read = try file.readPositionalAll(io, &bytes, 0);
    if (read != bytes.len) return error.Unexpected;
    const out = try allocator.alloc(u8, 9);
    var i: usize = 0;
    while (i < 4) : (i += 1) out[i] = alphabet[bytes[i] % alphabet.len];
    out[4] = '-';
    i = 0;
    while (i < 4) : (i += 1) out[5 + i] = alphabet[bytes[4 + i] % alphabet.len];
    return out;
}

/// OIDC at_hash: base64url(SHA-256(access_token)[0..16]).
pub fn atHash(allocator: std.mem.Allocator, access_token: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(access_token, &digest, .{});
    const enc = std.base64.url_safe_no_pad.Encoder;
    const n = enc.calcSize(16);
    const out = try allocator.alloc(u8, n);
    errdefer allocator.free(out);
    _ = enc.encode(out, digest[0..16]);
    return out;
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

/// Exact-match a candidate against a JSON string array (redirect_uris /
/// post_logout_redirect_uris). Substring matching would let
/// "https://app.example/cb" match "https://app.example/cb.evil.com".
pub fn jsonListContains(registered: []const u8, candidate: []const u8) bool {
    if (registered.len == 0) return false;
    var it = std.mem.splitScalar(u8, registered, ',');
    while (it.next()) |raw| {
        const t = std.mem.trim(u8, raw, " \t[]\"");
        if (t.len == 0) continue;
        if (std.mem.eql(u8, t, candidate)) return true;
    }
    return false;
}

fn redirectUriAllowed(registered: []const u8, candidate: []const u8) bool {
    return jsonListContains(registered, candidate);
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
