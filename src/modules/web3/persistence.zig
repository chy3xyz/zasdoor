//! Persistence over the zent Client for Web3 wallet identity.

const std = @import("std");
const zent = @import("zent");
const crud = zent.crud_helpers;
const model = @import("model.zig");
const schema = @import("../../schema.zig");

const graph = zent.codegen.graph.buildGraph(&.{model.Wallet});
pub const infos = graph.types;
pub const Client = schema.Client;
pub const WalletInfo = infos[0];

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

    pub fn create(self: *WalletStore, tenant_id: i64, chain: []const u8, address: []const u8, now: i64) !i64 {
        _ = now;
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
};