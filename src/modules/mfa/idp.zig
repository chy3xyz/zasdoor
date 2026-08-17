//! Identity-provider (social login) service: manages IdP configs and builds
//! OAuth2/OIDC authorization URLs for federated login (dev.md V3).

const std = @import("std");
const persist = @import("persistence.zig");

pub const IdpError = error{
    InvalidConfig,
    NotFound,
    Unexpected,
};

/// Parsed IdP config relevant for building an authorization request.
pub const IdpConfig = struct {
    name: []const u8,
    provider_type: []const u8,
    authorize_url: []const u8,
    client_id: []const u8,
    redirect_uri: []const u8,
    scope: []const u8,
};

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

    /// Build the provider's OAuth2 authorization URL from a stored config +
    /// per-request state. Supports response_type=code and optional PKCE
    /// code_challenge.
    pub fn buildAuthorizeUrl(
        self: *IdpService,
        config_json: []const u8,
        state: []const u8,
        code_challenge: ?[]const u8,
    ) anyerror![]const u8 {
        const cfg = try self.parseConfig(config_json);
        defer self.freeConfig(cfg);
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

    fn parseConfig(self: *IdpService, config_json: []const u8) anyerror!IdpConfig {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, config_json, .{}) catch return error.InvalidConfig;
        defer parsed.deinit();
        const root = parsed.value;
        if (root != .object) return error.InvalidConfig;
        const m = root.object;
        const authorize_url = getStr(m, "authorize_url") orelse return error.InvalidConfig;
        const client_id = getStr(m, "client_id") orelse return error.InvalidConfig;
        const redirect_uri = getStr(m, "redirect_uri") orelse return error.InvalidConfig;
        return .{
            .name = try self.allocator.dupe(u8, getStr(m, "name") orelse ""),
            .provider_type = try self.allocator.dupe(u8, getStr(m, "type") orelse "oidc"),
            .authorize_url = try self.allocator.dupe(u8, authorize_url),
            .client_id = try self.allocator.dupe(u8, client_id),
            .redirect_uri = try self.allocator.dupe(u8, redirect_uri),
            .scope = try self.allocator.dupe(u8, getStr(m, "scope") orelse "openid profile email"),
        };
    }

    fn freeConfig(self: *IdpService, cfg: IdpConfig) void {
        self.allocator.free(cfg.name);
        self.allocator.free(cfg.provider_type);
        self.allocator.free(cfg.authorize_url);
        self.allocator.free(cfg.client_id);
        self.allocator.free(cfg.redirect_uri);
        self.allocator.free(cfg.scope);
    }
};

fn getStr(m: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = m.get(key) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}
