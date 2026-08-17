//! Persistence over the zent Client for the MFA / account-security domain.

const std = @import("std");
const zent = @import("zent");
const crud = zent.crud_helpers;
const model = @import("model.zig");
const schema = @import("../../schema.zig");

const graph = zent.codegen.graph.buildGraph(&.{
    model.TotpCredential,
    model.RecoveryCode,
    model.IdentityProvider,
    model.MfaPolicy,
});
pub const infos = graph.types;
pub const Client = schema.Client;
pub const TotpInfo = infos[0];
pub const RecoveryInfo = infos[1];
pub const IdpInfo = infos[2];
pub const PolicyInfo = infos[3];

pub const MfaStore = struct {
    allocator: std.mem.Allocator,
    client: Client,

    pub fn init(allocator: std.mem.Allocator, client: Client) MfaStore {
        return .{ .allocator = allocator, .client = client };
    }

    fn ts(e: anytype) i64 {
        return @as(?i64, e) orelse 0;
    }

    // ---- TOTP credential ----

    pub fn saveTotpSecret(self: *MfaStore, tenant_id: i64, user_id: i64, secret: []const u8, now: i64) !void {
        const preds = self.client.totp_credential.predicates;
        var existing = try crud.first(self.client.totp_credential, .{preds.user_idEQ(.{ .int = user_id })});
        if (existing) |*e| {
            defer zent.codegen.deinitEntity(infos, TotpInfo, e, self.allocator);
            const id = e.id;
            var u = self.client.totp_credential.Update();
            defer u.deinit();
            _ = try u.set("secret", .{ .string = secret });
            _ = try u.setFieldValue("enabled", false);
            _ = try u.setFieldValue("created_at", now);
            _ = try u.setFieldValue("updated_at", now);
            _ = try u.Where(.{preds.idEQ(.{ .int = id })});
            _ = try u.Save();
            return;
        }
        var b = try self.client.totp_credential.Create();
        defer b.deinit();
        _ = try b.setFieldValue("tenant_id", tenant_id);
        _ = try b.setFieldValue("user_id", user_id);
        _ = try b.setFieldValue("secret", secret);
        _ = try b.setFieldValue("enabled", false);
        _ = try b.setFieldValue("created_at", now);
        _ = try b.setFieldValue("verified_at", 0);
        var row = try b.Save();
        defer zent.codegen.deinitEntity(infos, TotpInfo, &row, self.allocator);
    }

    pub fn getTotpSecret(self: *MfaStore, user_id: i64) !?[]const u8 {
        const preds = self.client.totp_credential.predicates;
        var e = (try crud.first(self.client.totp_credential, .{preds.user_idEQ(.{ .int = user_id })})) orelse return null;
        defer zent.codegen.deinitEntity(infos, TotpInfo, &e, self.allocator);
        return try self.allocator.dupe(u8, e.secret);
    }

    pub fn getTotpEnabled(self: *MfaStore, user_id: i64) !bool {
        const preds = self.client.totp_credential.predicates;
        var e = (try crud.first(self.client.totp_credential, .{preds.user_idEQ(.{ .int = user_id })})) orelse return false;
        defer zent.codegen.deinitEntity(infos, TotpInfo, &e, self.allocator);
        return e.enabled;
    }

    pub fn setTotpEnabled(self: *MfaStore, user_id: i64, enabled: bool, now: i64) !void {
        const preds = self.client.totp_credential.predicates;
        var e = (try crud.first(self.client.totp_credential, .{preds.user_idEQ(.{ .int = user_id })})) orelse return;
        defer zent.codegen.deinitEntity(infos, TotpInfo, &e, self.allocator);
        const id = e.id;
        var u = self.client.totp_credential.Update();
        defer u.deinit();
        _ = try u.setFieldValue("enabled", enabled);
        _ = try u.setFieldValue("verified_at", now);
        _ = try u.setFieldValue("updated_at", now);
        _ = try u.Where(.{preds.idEQ(.{ .int = id })});
        _ = try u.Save();
    }

    // ---- Recovery codes ----

    pub fn createRecoveryCode(self: *MfaStore, tenant_id: i64, user_id: i64, code_hash: []const u8, expires_at: i64, now: i64) !i64 {
        _ = now;
        var b = try self.client.recovery_code.Create();
        defer b.deinit();
        _ = try b.setFieldValue("tenant_id", tenant_id);
        _ = try b.setFieldValue("user_id", user_id);
        _ = try b.setFieldValue("code_hash", code_hash);
        _ = try b.setFieldValue("used", false);
        _ = try b.setFieldValue("expires_at", expires_at);
        var row = try b.Save();
        defer zent.codegen.deinitEntity(infos, RecoveryInfo, &row, self.allocator);
        return row.id;
    }

    /// Find an unused recovery code by its hash.
    pub fn findRecoveryByHash(self: *MfaStore, user_id: i64, code_hash: []const u8) !?i64 {
        const preds = self.client.recovery_code.predicates;
        const u_q = preds.user_idEQ(.{ .int = user_id });
        const h_q = preds.code_hashEQ(.{ .string = code_hash });
        const used_q = preds.usedEQ(.{ .bool = false });
        const and1 = zent.sql.And(&u_q, &h_q);
        const and2 = zent.sql.And(&and1, &used_q);
        var e = (try crud.first(self.client.recovery_code, .{and2})) orelse return null;
        defer zent.codegen.deinitEntity(infos, RecoveryInfo, &e, self.allocator);
        return e.id;
    }

    pub fn markRecoveryUsed(self: *MfaStore, id: i64, now: i64) !void {
        const preds = self.client.recovery_code.predicates;
        var u = self.client.recovery_code.Update();
        defer u.deinit();
        _ = try u.setFieldValue("used", true);
        _ = try u.setFieldValue("updated_at", now);
        _ = try u.Where(.{preds.idEQ(.{ .int = id })});
        _ = try u.Save();
    }

    // ---- Identity providers ----

    pub fn createIdp(self: *MfaStore, tenant_id: i64, name: []const u8, provider_type: []const u8, config: []const u8, now: i64) !i64 {
        _ = now;
        var b = try self.client.identity_provider.Create();
        defer b.deinit();
        _ = try b.setFieldValue("tenant_id", tenant_id);
        _ = try b.setFieldValue("name", name);
        _ = try b.setFieldValue("provider_type", provider_type);
        _ = try b.setFieldValue("config", config);
        _ = try b.setFieldValue("enabled", true);
        var row = try b.Save();
        defer zent.codegen.deinitEntity(infos, IdpInfo, &row, self.allocator);
        return row.id;
    }

    pub fn listIdps(self: *MfaStore, tenant_id: i64) ![]IdentityProviderRow {
        const preds = self.client.identity_provider.predicates;
        const rows = try crud.all(self.client.identity_provider, .{preds.tenant_idEQ(.{ .int = tenant_id })});
        defer zent.crud_helpers.deinitRows(infos, IdpInfo, rows, self.allocator);
        var out = try self.allocator.alloc(IdentityProviderRow, rows.items.len);
        var i: usize = 0;
        errdefer {
            for (out[0..i]) |r| r.free(self.allocator);
            self.allocator.free(out);
        }
        for (rows.items) |e| {
            out[i] = .{
                .id = e.id,
                .name = try self.allocator.dupe(u8, e.name),
                .provider_type = try self.allocator.dupe(u8, e.provider_type),
                .enabled = e.enabled,
            };
            i += 1;
        }
        return out;
    }

    // ---- MFA policy ----

    pub fn getPolicy(self: *MfaStore, tenant_id: i64) !MfaPolicyRow {
        const preds = self.client.mfa_policy.predicates;
        var e = (try crud.first(self.client.mfa_policy, .{preds.tenant_idEQ(.{ .int = tenant_id })})) orelse
            return .{ .tenant_id = tenant_id, .require_mfa = false, .allow_recovery_codes = true, .allow_totp = true };
        defer zent.codegen.deinitEntity(infos, PolicyInfo, &e, self.allocator);
        return .{
            .tenant_id = e.tenant_id,
            .require_mfa = e.require_mfa,
            .allow_recovery_codes = e.allow_recovery_codes,
            .allow_totp = e.allow_totp,
        };
    }

    pub fn upsertPolicy(self: *MfaStore, tenant_id: i64, require_mfa: bool, allow_recovery_codes: bool, allow_totp: bool, now: i64) !void {
        const preds = self.client.mfa_policy.predicates;
        var existing = try crud.first(self.client.mfa_policy, .{preds.tenant_idEQ(.{ .int = tenant_id })});
        if (existing) |*e| {
            defer zent.codegen.deinitEntity(infos, PolicyInfo, e, self.allocator);
            const id = e.id;
            var u = self.client.mfa_policy.Update();
            defer u.deinit();
            _ = try u.setFieldValue("require_mfa", require_mfa);
            _ = try u.setFieldValue("allow_recovery_codes", allow_recovery_codes);
            _ = try u.setFieldValue("allow_totp", allow_totp);
            _ = try u.setFieldValue("updated_at", now);
            _ = try u.Where(.{preds.idEQ(.{ .int = id })});
            _ = try u.Save();
            return;
        }
        var b = try self.client.mfa_policy.Create();
        defer b.deinit();
        _ = try b.setFieldValue("tenant_id", tenant_id);
        _ = try b.setFieldValue("require_mfa", require_mfa);
        _ = try b.setFieldValue("allow_recovery_codes", allow_recovery_codes);
        _ = try b.setFieldValue("allow_totp", allow_totp);
        var row = try b.Save();
        defer zent.codegen.deinitEntity(infos, PolicyInfo, &row, self.allocator);
    }
};

pub const IdentityProviderRow = struct {
    id: i64,
    name: []const u8,
    provider_type: []const u8,
    enabled: bool,

    pub fn free(self: IdentityProviderRow, a: std.mem.Allocator) void {
        a.free(self.name);
        a.free(self.provider_type);
    }
};

pub const MfaPolicyRow = struct {
    tenant_id: i64,
    require_mfa: bool,
    allow_recovery_codes: bool,
    allow_totp: bool,
};
