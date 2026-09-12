//! Identity-provider (social login) service.
//!
//! Manages IdP configs, starts a federated login (single-use anti-CSRF state
//! plus an authorize URL) and completes the callback: consumes the state,
//! exchanges the authorization code, fetches userinfo (or decodes id_token),
//! then finds-or-creates the local user and persists the identity link.
//!
//! The pure pieces (config parsing, state validation, userinfo JSON
//! extraction, provisioning decision) are separate from network I/O so they
//! can be unit-tested without a live provider.

const std = @import("std");
const zigmodu = @import("zigmodu");
const persist = @import("persistence.zig");

pub const IdpError = error{
    InvalidConfig,
    NotFound,
    UnknownState,
    ExpiredState,
    ReusedState,
    TokenExchangeFailed,
    UserInfoFailed,
    MissingSubject,
    Unexpected,
    OutOfMemory,
};

/// Parsed IdP config relevant for a federated login round-trip.
pub const IdpConfig = struct {
    name: []const u8,
    provider_type: []const u8,
    authorize_url: []const u8,
    token_url: []const u8,
    userinfo_url: []const u8,
    client_id: []const u8,
    client_secret: []const u8,
    redirect_uri: []const u8,
    scope: []const u8,
};

/// External identity extracted from the provider's userinfo (or id_token).
pub const UserInfo = struct {
    subject: []const u8,
    email: []const u8,
    name: []const u8,

    pub fn free(self: UserInfo, a: std.mem.Allocator) void {
        a.free(self.subject);
        a.free(self.email);
        a.free(self.name);
    }
};

pub const StartLoginResult = struct {
    authorize_url: []const u8,
    state: []const u8,

    pub fn deinit(self: StartLoginResult, a: std.mem.Allocator) void {
        a.free(self.authorize_url);
        a.free(self.state);
    }
};

pub const TokenSet = struct {
    access_token: []const u8,
    id_token: []const u8,

    pub fn free(self: TokenSet, a: std.mem.Allocator) void {
        a.free(self.access_token);
        a.free(self.id_token);
    }
};

/// Pure find-or-create decision: an existing link wins, then an existing
/// local account with the same email, otherwise a new local account.
pub const ProvisionAction = enum { reuse_link, link_existing, create_user };

pub fn decideProvision(link_user_id: ?i64, existing_user_id: ?i64) ProvisionAction {
    if (link_user_id != null) return .reuse_link;
    if (existing_user_id != null) return .link_existing;
    return .create_user;
}

/// Pure state validation. Unknown (no row), replayed (used) and expired
/// states are rejected; only a fresh, unused, in-window state passes.
pub fn validateStateRow(row: ?persist.FederatedStateRow, now: i64) IdpError!void {
    const r = row orelse return error.UnknownState;
    if (r.used) return error.ReusedState;
    if (now >= r.expires_at) return error.ExpiredState;
}

pub const IdpService = struct {
    allocator: std.mem.Allocator,
    store: *persist.MfaStore,

    pub fn init(allocator: std.mem.Allocator, store: *persist.MfaStore) IdpService {
        return .{ .allocator = allocator, .store = store };
    }

    pub fn create(self: *IdpService, tenant_id: i64, name: []const u8, provider_type: []const u8, config_json: []const u8, now: i64) !i64 {
        return self.store.createIdp(tenant_id, name, provider_type, config_json, now);
    }

    pub fn list(self: *IdpService, tenant_id: i64) ![]persist.IdentityProviderRow {
        return self.store.listIdps(tenant_id);
    }

    // ---- Pure config parsing ----

    /// Parse the JSON config blob. authorize_url / client_id / redirect_uri
    /// are required; token_url / userinfo_url / client_secret are optional so
    /// old link-only configs keep working.
    pub fn parseConfig(self: *IdpService, config_json: []const u8) IdpError!IdpConfig {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, config_json, .{}) catch return error.InvalidConfig;
        defer parsed.deinit();
        const root = parsed.value;
        if (root != .object) return error.InvalidConfig;
        const m = root.object;
        const authorize_url = getStr(m, "authorize_url") orelse return error.InvalidConfig;
        const client_id = getStr(m, "client_id") orelse return error.InvalidConfig;
        const redirect_uri = getStr(m, "redirect_uri") orelse return error.InvalidConfig;

        const name = try self.allocator.dupe(u8, getStr(m, "name") orelse "");
        errdefer self.allocator.free(name);
        const provider_type = try self.allocator.dupe(u8, getStr(m, "type") orelse getStr(m, "provider_type") orelse "oidc");
        errdefer self.allocator.free(provider_type);
        const authorize_dup = try self.allocator.dupe(u8, authorize_url);
        errdefer self.allocator.free(authorize_dup);
        const token_url = try self.allocator.dupe(u8, getStr(m, "token_url") orelse "");
        errdefer self.allocator.free(token_url);
        const userinfo_url = try self.allocator.dupe(u8, getStr(m, "userinfo_url") orelse "");
        errdefer self.allocator.free(userinfo_url);
        const client_id_dup = try self.allocator.dupe(u8, client_id);
        errdefer self.allocator.free(client_id_dup);
        const client_secret = try self.allocator.dupe(u8, getStr(m, "client_secret") orelse "");
        errdefer self.allocator.free(client_secret);
        const redirect_dup = try self.allocator.dupe(u8, redirect_uri);
        errdefer self.allocator.free(redirect_dup);
        const scope = try self.allocator.dupe(u8, getStr(m, "scope") orelse "openid profile email");
        errdefer self.allocator.free(scope);
        return .{
            .name = name,
            .provider_type = provider_type,
            .authorize_url = authorize_dup,
            .token_url = token_url,
            .userinfo_url = userinfo_url,
            .client_id = client_id_dup,
            .client_secret = client_secret,
            .redirect_uri = redirect_dup,
            .scope = scope,
        };
    }

    pub fn freeConfig(self: *IdpService, cfg: IdpConfig) void {
        self.allocator.free(cfg.name);
        self.allocator.free(cfg.provider_type);
        self.allocator.free(cfg.authorize_url);
        self.allocator.free(cfg.token_url);
        self.allocator.free(cfg.userinfo_url);
        self.allocator.free(cfg.client_id);
        self.allocator.free(cfg.client_secret);
        self.allocator.free(cfg.redirect_uri);
        self.allocator.free(cfg.scope);
    }

    // ---- Authorize URL ----

    /// Build the provider's OAuth2 authorization URL from a stored config +
    /// per-request state. Supports response_type=code and optional PKCE.
    pub fn buildAuthorizeUrl(
        self: *IdpService,
        config_json: []const u8,
        state: []const u8,
        code_challenge: ?[]const u8,
    ) anyerror![]const u8 {
        const cfg = try self.parseConfig(config_json);
        defer self.freeConfig(cfg);
        return self.buildAuthorizeUrlFromConfig(cfg, state, code_challenge);
    }

    pub fn buildAuthorizeUrlFromConfig(
        self: *IdpService,
        cfg: IdpConfig,
        state: []const u8,
        code_challenge: ?[]const u8,
    ) ![]const u8 {
        var url = std.ArrayList(u8).empty;
        errdefer url.deinit(self.allocator);
        try url.appendSlice(self.allocator, cfg.authorize_url);
        try url.appendSlice(self.allocator, "?response_type=code&client_id=");
        try url.appendSlice(self.allocator, cfg.client_id);
        try url.appendSlice(self.allocator, "&redirect_uri=");
        try url.appendSlice(self.allocator, cfg.redirect_uri);
        try url.appendSlice(self.allocator, "&scope=");
        try url.appendSlice(self.allocator, cfg.scope);
        try url.appendSlice(self.allocator, "&state=");
        try url.appendSlice(self.allocator, state);
        if (code_challenge) |cc| {
            try url.appendSlice(self.allocator, "&code_challenge=");
            try url.appendSlice(self.allocator, cc);
            try url.appendSlice(self.allocator, "&code_challenge_method=S256");
        }
        return url.toOwnedSlice(self.allocator);
    }

    // ---- Start login ----

    /// Create a persisted single-use state and return the authorize URL.
    pub fn startLogin(
        self: *IdpService,
        io: std.Io,
        tenant_id: i64,
        provider_id: i64,
        redirect_to: []const u8,
        now: i64,
        ttl_seconds: i64,
    ) !StartLoginResult {
        const config_json = (try self.store.getIdpConfig(provider_id)) orelse return error.NotFound;
        defer self.allocator.free(config_json);
        const cfg = try self.parseConfig(config_json);
        defer self.freeConfig(cfg);
        const state = try randomHex(self.allocator, io, 24);
        errdefer self.allocator.free(state);
        const ttl: i64 = if (ttl_seconds > 0) ttl_seconds else 600;
        _ = try self.store.createFederatedState(tenant_id, provider_id, state, redirect_to, now + ttl, now);
        const url = try self.buildAuthorizeUrlFromConfig(cfg, state, null);
        return .{ .authorize_url = url, .state = state };
    }

    /// Validate then consume a state exactly once. Returns the state row
    /// (caller frees) so the callback can recover the tenant.
    pub fn consumeState(self: *IdpService, provider_id: i64, state: []const u8, now: i64) anyerror!persist.FederatedStateRow {
        const row = (try self.store.findFederatedState(state)) orelse return error.UnknownState;
        errdefer row.free(self.allocator);
        try validateStateRow(row, now);
        if (row.provider_id != provider_id) return error.UnknownState;
        try self.store.markFederatedStateUsed(row.id, now);
        return row;
    }

    // ---- Network I/O (never used in unit tests) ----

    /// Exchange the authorization code for tokens at token_url
    /// (application/x-www-form-urlencoded POST).
    pub fn exchangeCode(self: *IdpService, io: std.Io, cfg: IdpConfig, code: []const u8) IdpError!TokenSet {
        if (cfg.token_url.len == 0) return error.InvalidConfig;
        if (cfg.client_id.len == 0) return error.InvalidConfig;
        var body = std.ArrayList(u8).empty;
        defer body.deinit(self.allocator);
        body.appendSlice(self.allocator, "grant_type=authorization_code&code=") catch return error.TokenExchangeFailed;
        appendFormValue(self.allocator, &body, code) catch return error.TokenExchangeFailed;
        body.appendSlice(self.allocator, "&redirect_uri=") catch return error.TokenExchangeFailed;
        appendFormValue(self.allocator, &body, cfg.redirect_uri) catch return error.TokenExchangeFailed;
        body.appendSlice(self.allocator, "&client_id=") catch return error.TokenExchangeFailed;
        appendFormValue(self.allocator, &body, cfg.client_id) catch return error.TokenExchangeFailed;
        body.appendSlice(self.allocator, "&client_secret=") catch return error.TokenExchangeFailed;
        appendFormValue(self.allocator, &body, cfg.client_secret) catch return error.TokenExchangeFailed;

        var http = zigmodu.http.HttpClient.init(self.allocator, io, 4, 15_000);
        defer http.deinit();
        var req = zigmodu.http.HttpClient.HttpRequest.init(self.allocator, "POST", cfg.token_url);
        defer req.deinit();
        req.setHeader("content-type", "application/x-www-form-urlencoded") catch return error.TokenExchangeFailed;
        req.setHeader("accept", "application/json") catch return error.TokenExchangeFailed;
        req.setBody(body.items) catch return error.TokenExchangeFailed;

        var resp = http.request(req) catch return error.TokenExchangeFailed;
        defer resp.deinit();
        if (!resp.isSuccess()) return error.TokenExchangeFailed;

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, resp.body, .{}) catch return error.TokenExchangeFailed;
        defer parsed.deinit();
        const root = parsed.value;
        if (root != .object) return error.TokenExchangeFailed;
        const m = root.object;
        const access = getStr(m, "access_token") orelse "";
        const idt = getStr(m, "id_token") orelse "";
        if (access.len == 0 and idt.len == 0) return error.TokenExchangeFailed;
        const access_dup = try self.allocator.dupe(u8, access);
        errdefer self.allocator.free(access_dup);
        const idt_dup = try self.allocator.dupe(u8, idt);
        return .{ .access_token = access_dup, .id_token = idt_dup };
    }

    /// Fetch the userinfo document with the bearer access token.
    pub fn fetchUserInfo(self: *IdpService, io: std.Io, cfg: IdpConfig, access_token: []const u8) IdpError!UserInfo {
        if (cfg.userinfo_url.len == 0) return error.UserInfoFailed;
        var http = zigmodu.http.HttpClient.init(self.allocator, io, 4, 15_000);
        defer http.deinit();
        var req = zigmodu.http.HttpClient.HttpRequest.init(self.allocator, "GET", cfg.userinfo_url);
        defer req.deinit();
        const bearer = std.fmt.allocPrint(self.allocator, "Bearer {s}", .{access_token}) catch return error.UserInfoFailed;
        defer self.allocator.free(bearer);
        req.setHeader("authorization", bearer) catch return error.UserInfoFailed;
        req.setHeader("accept", "application/json") catch return error.UserInfoFailed;
        var resp = http.request(req) catch return error.UserInfoFailed;
        defer resp.deinit();
        if (!resp.isSuccess()) return error.UserInfoFailed;
        return parseUserInfoJson(self.allocator, resp.body);
    }

    // ---- Provisioning (DB only) ----

    /// Find-or-create the local user for info and persist the identity link.
    pub fn resolveLocalUser(self: *IdpService, tenant_id: i64, provider_id: i64, info: UserInfo, now: i64) !i64 {
        if (try self.store.findIdentityLink(provider_id, info.subject)) |link| {
            defer link.free(self.allocator);
            return link.user_id;
        }
        const existing_id: ?i64 = if (info.email.len > 0) try self.store.findUserIdByEmail(info.email) else null;
        switch (decideProvision(null, existing_id)) {
            .link_existing => {
                const uid = existing_id.?;
                _ = try self.store.createIdentityLink(tenant_id, provider_id, uid, info.subject, info.email, now);
                return uid;
            },
            .create_user => {
                var generated: ?[]const u8 = null;
                defer if (generated) |g| self.allocator.free(g);
                const email: []const u8 = if (info.email.len > 0) info.email else blk: {
                    const g = try std.fmt.allocPrint(self.allocator, "federated+{d}-{s}@local", .{ provider_id, info.subject });
                    generated = g;
                    break :blk g;
                };
                const name: []const u8 = if (info.name.len > 0) info.name else email;
                const uid = try self.store.createFederatedUser(name, email, tenant_id, now);
                _ = try self.store.createIdentityLink(tenant_id, provider_id, uid, info.subject, info.email, now);
                return uid;
            },
            .reuse_link => unreachable,
        }
    }

    // ---- Orchestration ----

    /// Full callback: consume state, exchange code, resolve userinfo and
    /// return the local user id. Network failures surface as IdpError.
    pub fn completeCallback(
        self: *IdpService,
        io: std.Io,
        provider_id: i64,
        code: []const u8,
        state: []const u8,
        now: i64,
    ) !i64 {
        const config_json = (try self.store.getIdpConfig(provider_id)) orelse return error.NotFound;
        defer self.allocator.free(config_json);
        const cfg = try self.parseConfig(config_json);
        defer self.freeConfig(cfg);

        const state_row = try self.consumeState(provider_id, state, now);
        const tenant_id = state_row.tenant_id;
        state_row.free(self.allocator);

        const tokens = try self.exchangeCode(io, cfg, code);
        defer tokens.free(self.allocator);

        var info: UserInfo = undefined;
        if (cfg.userinfo_url.len > 0 and tokens.access_token.len > 0) {
            info = try self.fetchUserInfo(io, cfg, tokens.access_token);
        } else if (tokens.id_token.len > 0) {
            info = try parseIdTokenClaims(self.allocator, tokens.id_token);
        } else {
            return error.UserInfoFailed;
        }
        defer info.free(self.allocator);
        return self.resolveLocalUser(tenant_id, provider_id, info, now);
    }
};

/// Extract (sub, email, name) from a userinfo JSON document. Accepts the
/// common aliases: sub / id / user_id; name / preferred_username / login.
pub fn parseUserInfoJson(allocator: std.mem.Allocator, json: []const u8) IdpError!UserInfo {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return error.UserInfoFailed;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.UserInfoFailed;
    const m = root.object;
    const sub = getStr(m, "sub") orelse getStr(m, "id") orelse getStr(m, "user_id") orelse return error.MissingSubject;
    const email = getStr(m, "email") orelse "";
    const name = getStr(m, "name") orelse getStr(m, "preferred_username") orelse getStr(m, "login") orelse "";
    const sub_dup = try allocator.dupe(u8, sub);
    errdefer allocator.free(sub_dup);
    const email_dup = try allocator.dupe(u8, email);
    errdefer allocator.free(email_dup);
    const name_dup = try allocator.dupe(u8, name);
    return .{ .subject = sub_dup, .email = email_dup, .name = name_dup };
}

/// Decode an id_token (JWT) payload and extract the same identity fields,
/// used when the provider has no userinfo endpoint.
pub fn parseIdTokenClaims(allocator: std.mem.Allocator, id_token: []const u8) IdpError!UserInfo {
    var it = std.mem.splitScalar(u8, id_token, '.');
    _ = it.next() orelse return error.UserInfoFailed;
    const payload_b64 = it.next() orelse return error.UserInfoFailed;
    const decoded_len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(payload_b64) catch return error.UserInfoFailed;
    const buf = try allocator.alloc(u8, decoded_len);
    defer allocator.free(buf);
    _ = std.base64.url_safe_no_pad.Decoder.decode(buf, payload_b64) catch return error.UserInfoFailed;
    return parseUserInfoJson(allocator, buf);
}

fn getStr(m: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = m.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

/// application/x-www-form-urlencoded encoding of a single value.
pub fn appendFormValue(a: std.mem.Allocator, list: *std.ArrayList(u8), value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |ch| {
        switch (ch) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => try list.append(a, ch),
            ' ' => try list.appendSlice(a, "+"),
            else => {
                try list.append(a, '%');
                try list.append(a, hex[ch >> 4]);
                try list.append(a, hex[ch & 0xf]);
            },
        }
    }
}

fn randomHex(allocator: std.mem.Allocator, io: std.Io, nbytes: usize) ![]const u8 {
    var buf: [32]u8 = undefined;
    const n: usize = if (nbytes > buf.len) buf.len else nbytes;
    var file = try std.Io.Dir.cwd().openFile(io, "/dev/urandom", .{});
    defer file.close(io);
    const read = try file.readPositionalAll(io, buf[0..n], 0);
    if (read != n) return error.Unexpected;
    return hexEncode(allocator, buf[0..n]);
}

fn hexEncode(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const hex_chars = "0123456789abcdef";
    const out = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |b, i| {
        out[i * 2] = hex_chars[b >> 4];
        out[i * 2 + 1] = hex_chars[b & 0xf];
    }
    return out;
}
