//! SAML provider configuration, parsed from IdentityProvider.config JSON.
const std = @import("std");

pub const ConfigError = error{ InvalidJson, InvalidConfig, OutOfMemory };

pub const SamlConfig = struct {
    arena: std.heap.ArenaAllocator,
    sso_url: []const u8,
    idp_entity_id: []const u8,
    sp_entity_id: []const u8,
    pinned_certs: [][]const u8,
    name_id_format: []const u8 = "urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress",
    email_attribute: []const u8 = "email",
    name_attribute: []const u8 = "name",
    want_assertions_signed: bool = true,
    trust_email_as_verified: bool = false,
    max_assertion_bytes: usize = 256 * 1024,

    pub fn deinit(self: *SamlConfig) void {
        self.arena.deinit();
    }
};

fn dupStr(a: std.mem.Allocator, v: std.json.Value) ConfigError![]const u8 {
    return switch (v) {
        .string => |x| a.dupe(u8, x) catch return error.OutOfMemory,
        else => error.InvalidConfig,
    };
}

pub fn fromJson(backing: std.mem.Allocator, json: []const u8) ConfigError!SamlConfig {
    var arena = std.heap.ArenaAllocator.init(backing);
    errdefer arena.deinit();
    const a = arena.allocator();
    var parsed = std.json.parseFromSlice(std.json.Value, a, json, .{ .allocate = .alloc_always }) catch return error.InvalidJson;
    defer parsed.deinit();
    const obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidConfig,
    };
    const certs_arr = switch (obj.get("pinned_certs") orelse return error.InvalidConfig) {
        .array => |arr| arr,
        else => return error.InvalidConfig,
    };
    if (certs_arr.items.len == 0 or certs_arr.items.len > 4) return error.InvalidConfig;
    const certs = a.alloc([]const u8, certs_arr.items.len) catch return error.OutOfMemory;
    for (certs_arr.items, 0..) |v, i| certs[i] = try dupStr(a, v);
    var cfg = SamlConfig{
        .arena = arena,
        .sso_url = try dupStr(a, obj.get("sso_url") orelse return error.InvalidConfig),
        .idp_entity_id = try dupStr(a, obj.get("idp_entity_id") orelse return error.InvalidConfig),
        .sp_entity_id = try dupStr(a, obj.get("sp_entity_id") orelse return error.InvalidConfig),
        .pinned_certs = certs,
    };
    if (obj.get("name_id_format")) |v| cfg.name_id_format = try dupStr(a, v);
    if (cfg.name_id_format.len == 0 or std.mem.eql(u8, cfg.name_id_format, "urn:oasis:names:tc:SAML:2.0:nameid-format:transient")) return error.InvalidConfig;
    if (obj.get("email_attribute")) |v| cfg.email_attribute = try dupStr(a, v);
    if (obj.get("name_attribute")) |v| cfg.name_attribute = try dupStr(a, v);
    if (obj.get("want_assertions_signed")) |v| cfg.want_assertions_signed = switch (v) {
        .bool => |b| b,
        else => return error.InvalidConfig,
    };
    if (obj.get("trust_email_as_verified")) |v| cfg.trust_email_as_verified = switch (v) {
        .bool => |b| b,
        else => return error.InvalidConfig,
    };
    if (!std.mem.startsWith(u8, cfg.sso_url, "https://") and !std.mem.startsWith(u8, cfg.sso_url, "http://")) return error.InvalidConfig;
    if (std.mem.indexOfScalar(u8, cfg.sso_url, '#') != null) return error.InvalidConfig;
    return cfg;
}

test "saml config: minimal valid config" {
    const a = std.testing.allocator;
    const json = "{\"sso_url\":\"https://idp.example/sso\",\"idp_entity_id\":\"https://idp.example\",\"sp_entity_id\":\"urn:zasdoor:sp\",\"pinned_certs\":[\"CERT\"]}";
    var cfg = try fromJson(a, json);
    defer cfg.deinit();
    try std.testing.expectEqualStrings("https://idp.example/sso", cfg.sso_url);
    try std.testing.expect(cfg.want_assertions_signed);
}

test "saml config: rejects empty certs and transient nameid" {
    const a = std.testing.allocator;
    const no_certs = "{\"sso_url\":\"https://idp.example\",\"idp_entity_id\":\"idp\",\"sp_entity_id\":\"sp\",\"pinned_certs\":[]}";
    try std.testing.expectError(error.InvalidConfig, fromJson(a, no_certs));
    const transient = "{\"sso_url\":\"https://idp.example\",\"idp_entity_id\":\"idp\",\"sp_entity_id\":\"sp\",\"pinned_certs\":[\"C\"],\"name_id_format\":\"urn:oasis:names:tc:SAML:2.0:nameid-format:transient\"}";
    try std.testing.expectError(error.InvalidConfig, fromJson(a, transient));
}
