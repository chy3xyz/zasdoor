//! Persistence over the zent Client for Web3 wallet identity and SIWE nonces.

const std = @import("std");
const zent = @import("zent");
const crud = zent.crud_helpers;
const model = @import("model.zig");
const schema = @import("../../schema.zig");

const graph = zent.codegen.graph.buildGraph(&.{ model.Wallet, model.SiweNonce });
pub const infos = graph.types;
pub const Client = schema.Client;
pub const WalletInfo = infos[0];
pub const SiweNonceInfo = infos[1];

pub const WalletRow = struct {
    id: i64,
    tenant_id: i64,
    user_id: i64,
    chain: []const u8,
    address: []const u8,
    verified: bool,
    created_at: i64,
    updated_at: i64,

    pub fn free(self: WalletRow, a: std.mem.Allocator) void {
        a.free(self.chain);
        a.free(self.address);
    }
};

pub const SiweNonceRow = struct {
    id: i64,
    tenant_id: i64,
    nonce: []const u8,
    domain: []const u8,
    address: []const u8,
    expires_at: i64,
    used: bool,
    created_at: i64,

    pub fn free(self: SiweNonceRow, a: std.mem.Allocator) void {
        a.free(self.nonce);
        a.free(self.domain);
        a.free(self.address);
    }
};

pub const WalletStore = struct {
    allocator: std.mem.Allocator,
    client: Client,

    pub fn init(allocator: std.mem.Allocator, client: Client) WalletStore {
        return .{ .allocator = allocator, .client = client };
    }

    fn ts(e: anytype) i64 {
        return @as(?i64, e) orelse 0;
    }

    fn dup(self: *WalletStore, e: anytype) !WalletRow {
        return .{
            .id = e.id,
            .tenant_id = e.tenant_id,
            .user_id = e.user_id,
            .chain = try self.allocator.dupe(u8, e.chain),
            .address = try self.allocator.dupe(u8, e.address),
            .verified = e.verified,
            .created_at = ts(e.created_at),
            .updated_at = ts(e.updated_at),
        };
    }

    pub fn create(self: *WalletStore, tenant_id: i64, chain: []const u8, address: []const u8) !i64 {
        var b = try self.client.wallet.Create();
        defer b.deinit();
        _ = try b.setFieldValue("tenant_id", tenant_id);
        _ = try b.setFieldValue("user_id", 0);
        _ = try b.setFieldValue("chain", chain);
        _ = try b.setFieldValue("address", address);
        _ = try b.setFieldValue("verified", false);
        var row = try b.Save();
        defer zent.codegen.deinitEntity(infos, WalletInfo, &row, self.allocator);
        return row.id;
    }

    pub fn findByAddress(self: *WalletStore, chain: []const u8, address: []const u8) !?WalletRow {
        const preds = self.client.wallet.predicates;
        const c_q = preds.chainEQ(.{ .string = chain });
        const a_q = preds.addressEQ(.{ .string = address });
        const and_q = zent.sql.And(&c_q, &a_q);
        var e = (try crud.first(self.client.wallet, .{and_q})) orelse return null;
        defer zent.codegen.deinitEntity(infos, WalletInfo, &e, self.allocator);
        return try self.dup(e);
    }

    pub fn bindUser(self: *WalletStore, id: i64, user_id: i64, now: i64) !void {
        const preds = self.client.wallet.predicates;
        var u = self.client.wallet.Update();
        defer u.deinit();
        _ = try u.setFieldValue("user_id", user_id);
        _ = try u.setFieldValue("updated_at", now);
        _ = try u.Where(.{preds.idEQ(.{ .int = id })});
        _ = try u.Save();
    }

    pub fn setVerified(self: *WalletStore, id: i64, verified: bool, now: i64) !void {
        const preds = self.client.wallet.predicates;
        var u = self.client.wallet.Update();
        defer u.deinit();
        _ = try u.setFieldValue("verified", verified);
        _ = try u.setFieldValue("updated_at", now);
        _ = try u.Where(.{preds.idEQ(.{ .int = id })});
        _ = try u.Save();
    }

    // ---- SIWE nonce store ----

    fn dupNonce(self: *WalletStore, e: anytype) !SiweNonceRow {
        return .{
            .id = e.id,
            .tenant_id = e.tenant_id,
            .nonce = try self.allocator.dupe(u8, e.nonce),
            .domain = try self.allocator.dupe(u8, e.domain),
            .address = try self.allocator.dupe(u8, e.address),
            .expires_at = e.expires_at,
            .used = e.used,
            .created_at = ts(e.created_at),
        };
    }

    pub fn reserveNonce(
        self: *WalletStore,
        tenant_id: i64,
        nonce: []const u8,
        domain: []const u8,
        address: []const u8,
        expires_at: i64,
        now: i64,
    ) !i64 {
        _ = now;
        var b = try self.client.siwe_nonce.Create();
        defer b.deinit();
        _ = try b.setFieldValue("tenant_id", tenant_id);
        _ = try b.setFieldValue("nonce", nonce);
        _ = try b.setFieldValue("domain", domain);
        _ = try b.setFieldValue("address", address);
        _ = try b.setFieldValue("expires_at", expires_at);
        _ = try b.setFieldValue("used", false);
        var row = try b.Save();
        defer zent.codegen.deinitEntity(infos, SiweNonceInfo, &row, self.allocator);
        return row.id;
    }

    /// Find an unused, unexpired nonce by (tenant, nonce) and mark it used
    /// atomically. Returns null when the nonce was not reserved, was already
    /// consumed, or expired.
    pub fn consumeNonce(
        self: *WalletStore,
        tenant_id: i64,
        nonce: []const u8,
        domain: []const u8,
        address: []const u8,
        now: i64,
    ) !?SiweNonceRow {
        const preds = self.client.siwe_nonce.predicates;
        const t_q = preds.tenant_idEQ(.{ .int = tenant_id });
        const n_q = preds.nonceEQ(.{ .string = nonce });
        const used_q = preds.usedEQ(.{ .bool = false });
        const nu_q = zent.sql.And(&n_q, &used_q);
        const all_q = zent.sql.And(&t_q, &nu_q);
        const raw_row = crud.first(self.client.siwe_nonce, .{all_q}) catch return null;
        const raw_or_null = raw_row orelse return null;
        var row_copy = raw_or_null;
        defer zent.codegen.deinitEntity(infos, SiweNonceInfo, &row_copy, self.allocator);
        if (row_copy.expires_at > 0 and row_copy.expires_at <= now) return null;
        if (!std.mem.eql(u8, row_copy.domain, domain)) return null;
        if (!std.mem.eql(u8, row_copy.address, address)) return null;
        var u = self.client.siwe_nonce.Update();
        defer u.deinit();
        _ = try u.setFieldValue("used", true);
        _ = try u.Where(.{preds.idEQ(.{ .int = row_copy.id })});
        _ = try u.Save();
        row_copy.used = true;
        return try self.dupNonce(row_copy);
    }
};
