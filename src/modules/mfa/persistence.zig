//! Persistence over the zent Client for the MFA / account-security domain.

const std = @import("std");
const zent = @import("zent");
const crud = zent.crud_helpers;
const model = @import("model.zig");
const schema = @import("../../schema.zig");
const user_persist = @import("../user/persistence.zig");

const graph = zent.codegen.graph.buildGraph(&.{
    model.TotpCredential,
    model.RecoveryCode,
    model.IdentityProvider,
    model.MfaPolicy,
    model.IdentityLink,
    model.FederatedState,
});
pub const infos = graph.types;
pub const Client = schema.Client;
pub const TotpInfo = infos[0];
pub const RecoveryInfo = infos[1];
pub const IdpInfo = infos[2];
pub const PolicyInfo = infos[3];
pub const LinkInfo = infos[4];
pub const StateInfo = infos[5];
/// The user table belongs to another module but shares the one typed
/// client; federated provisioning reads/writes it through the same store.
const UserTableInfo = user_persist.infos[0];
/// Marker stored in `User.password` for accounts with no local password.
/// It is not a valid PBKDF2 string, so `verifyPassword` always fails.
pub const FEDERATED_PASSWORD_MARKER = "!federated";

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

    /// Fetch a provider's stored JSON config (owned copy), if it exists.
    pub fn getIdpConfig(self: *MfaStore, provider_id: i64) !?[]const u8 {
        var e = (try crud.get(self.client.identity_provider, provider_id)) orelse return null;
        defer zent.codegen.deinitEntity(infos, IdpInfo, &e, self.allocator);
        return try self.allocator.dupe(u8, e.config);
    }

    // ---- Federated identity links ----

    pub fn createIdentityLink(
        self: *MfaStore,
        tenant_id: i64,
        provider_id: i64,
        user_id: i64,
        subject: []const u8,
        email: []const u8,
        now: i64,
    ) !i64 {
        var b = try self.client.identity_link.Create();
        defer b.deinit();
        _ = try b.setFieldValue("tenant_id", tenant_id);
        _ = try b.setFieldValue("provider_id", provider_id);
        _ = try b.setFieldValue("user_id", user_id);
        _ = try b.setFieldValue("subject", subject);
        _ = try b.setFieldValue("email", email);
        _ = try b.setFieldValue("created_at", now);
        _ = try b.setFieldValue("updated_at", now);
        var row = try b.Save();
        defer zent.codegen.deinitEntity(infos, LinkInfo, &row, self.allocator);
        return row.id;
    }

    /// Look up the local user bound to (provider_id, subject).
    pub fn findIdentityLink(self: *MfaStore, provider_id: i64, subject: []const u8) !?IdentityLinkRow {
        const preds = self.client.identity_link.predicates;
        var e = (try crud.first(self.client.identity_link, .{
            preds.provider_idEQ(.{ .int = provider_id }),
            preds.subjectEQ(.{ .string = subject }),
        })) orelse return null;
        defer zent.codegen.deinitEntity(infos, LinkInfo, &e, self.allocator);
        const subject_dup = try self.allocator.dupe(u8, e.subject);
        errdefer self.allocator.free(subject_dup);
        const email_dup = try self.allocator.dupe(u8, e.email);
        return .{
            .id = e.id,
            .provider_id = e.provider_id,
            .user_id = e.user_id,
            .subject = subject_dup,
            .email = email_dup,
        };
    }

    /// All federated identities bound to a local user.
    pub fn listIdentityLinksByUser(self: *MfaStore, user_id: i64) ![]IdentityLinkRow {
        const preds = self.client.identity_link.predicates;
        const rows = try crud.all(self.client.identity_link, .{preds.user_idEQ(.{ .int = user_id })});
        defer zent.crud_helpers.deinitRows(infos, LinkInfo, rows, self.allocator);
        var out = try self.allocator.alloc(IdentityLinkRow, rows.items.len);
        var i: usize = 0;
        errdefer {
            for (out[0..i]) |row| row.free(self.allocator);
            self.allocator.free(out);
        }
        for (rows.items) |e| {
            out[i] = .{
                .id = e.id,
                .provider_id = e.provider_id,
                .user_id = e.user_id,
                .subject = try self.allocator.dupe(u8, e.subject),
                .email = try self.allocator.dupe(u8, e.email),
            };
            i += 1;
        }
        return out;
    }

    // ---- Federated login state (single-use anti-CSRF) ----

    pub fn createFederatedState(
        self: *MfaStore,
        tenant_id: i64,
        provider_id: i64,
        state: []const u8,
        redirect_to: []const u8,
        expires_at: i64,
        now: i64,
    ) !i64 {
        var b = try self.client.federated_state.Create();
        defer b.deinit();
        _ = try b.setFieldValue("tenant_id", tenant_id);
        _ = try b.setFieldValue("provider_id", provider_id);
        _ = try b.setFieldValue("state", state);
        _ = try b.setFieldValue("redirect_to", redirect_to);
        _ = try b.setFieldValue("expires_at", expires_at);
        _ = try b.setFieldValue("used", false);
        _ = try b.setFieldValue("created_at", now);
        _ = try b.setFieldValue("updated_at", now);
        var row = try b.Save();
        defer zent.codegen.deinitEntity(infos, StateInfo, &row, self.allocator);
        return row.id;
    }

    pub fn findFederatedState(self: *MfaStore, state: []const u8) !?FederatedStateRow {
        const preds = self.client.federated_state.predicates;
        var e = (try crud.first(self.client.federated_state, .{preds.stateEQ(.{ .string = state })})) orelse return null;
        defer zent.codegen.deinitEntity(infos, StateInfo, &e, self.allocator);
        const state_dup = try self.allocator.dupe(u8, e.state);
        errdefer self.allocator.free(state_dup);
        const redirect_dup = try self.allocator.dupe(u8, e.redirect_to);
        return .{
            .id = e.id,
            .tenant_id = e.tenant_id,
            .provider_id = e.provider_id,
            .state = state_dup,
            .redirect_to = redirect_dup,
            .expires_at = e.expires_at,
            .used = e.used,
        };
    }

    pub fn markFederatedStateUsed(self: *MfaStore, id: i64, now: i64) !void {
        const preds = self.client.federated_state.predicates;
        var u = self.client.federated_state.Update();
        defer u.deinit();
        _ = try u.setFieldValue("used", true);
        _ = try u.setFieldValue("updated_at", now);
        _ = try u.Where(.{preds.idEQ(.{ .int = id })});
        _ = try u.Save();
    }

    /// Housekeeping: drop states that expired before `now`.
    pub fn deleteExpiredFederatedStates(self: *MfaStore, now: i64) !void {
        const preds = self.client.federated_state.predicates;
        var d = self.client.federated_state.Delete();
        defer d.deinit();
        _ = try d.Where(.{preds.expires_atLT(.{ .int = now })});
        _ = try d.Exec();
    }

    // ---- Federated user provisioning (shared user table) ----

    /// Lookup by the already-normalized email used at signup.
    pub fn findUserIdByEmail(self: *MfaStore, email: []const u8) !?i64 {
        const preds = self.client.user.predicates;
        var e = (try crud.first(self.client.user, .{preds.emailEQ(.{ .string = email })})) orelse return null;
        defer zent.codegen.deinitEntity(user_persist.infos, UserTableInfo, &e, self.allocator);
        return e.id;
    }

    /// Create a locally password-less account for a federated identity.
    pub fn createFederatedUser(self: *MfaStore, name: []const u8, email: []const u8, tenant_id: i64, now: i64) !i64 {
        var b = try self.client.user.Create();
        defer b.deinit();
        _ = try b.setFieldValue("name", name);
        _ = try b.setFieldValue("email", email);
        _ = try b.setFieldValue("password", FEDERATED_PASSWORD_MARKER);
        _ = try b.setFieldValue("verified", true);
        _ = try b.setFieldValue("admin", false);
        _ = try b.setFieldValue("tenant_id", tenant_id);
        _ = try b.setFieldValue("token_version", 0);
        _ = try b.setFieldValue("created_at", now);
        _ = try b.setFieldValue("updated_at", now);
        var row = try b.Save();
        defer zent.codegen.deinitEntity(user_persist.infos, UserTableInfo, &row, self.allocator);
        return row.id;
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

pub const IdentityLinkRow = struct {
    id: i64,
    provider_id: i64,
    user_id: i64,
    subject: []const u8,
    email: []const u8,

    pub fn free(self: IdentityLinkRow, a: std.mem.Allocator) void {
        a.free(self.subject);
        a.free(self.email);
    }
};

pub const FederatedStateRow = struct {
    id: i64,
    tenant_id: i64,
    provider_id: i64,
    state: []const u8,
    redirect_to: []const u8,
    expires_at: i64,
    used: bool,

    pub fn free(self: FederatedStateRow, a: std.mem.Allocator) void {
        a.free(self.state);
        a.free(self.redirect_to);
    }
};

pub const MfaPolicyRow = struct {
    tenant_id: i64,
    require_mfa: bool,
    allow_recovery_codes: bool,
    allow_totp: bool,
};
