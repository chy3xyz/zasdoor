//! Persistence over the zent Client — tenants.

const std = @import("std");
const zent = @import("zent");
const model = @import("model.zig");
const schema = @import("../../schema.zig");

const graph = zent.codegen.graph.buildGraph(&.{model.Tenant});
pub const infos = graph.types;
pub const Client = schema.Client;
pub const TenantInfo = infos[0];

pub const TenantRow = struct {
    id: i64,
    name: []const u8,
    status: []const u8,
    created_at: i64,
    updated_at: i64,

    pub fn free(self: TenantRow, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.status);
    }
};

pub const TenantListResult = struct {
    items: []TenantRow,
    total: i64,

    pub fn free(self: *TenantListResult, allocator: std.mem.Allocator) void {
        for (self.items) |r| r.free(allocator);
        allocator.free(self.items);
    }
};

pub const TenantStore = struct {
    allocator: std.mem.Allocator,
    client: Client,

    pub fn init(allocator: std.mem.Allocator, client: Client) TenantStore {
        return .{ .allocator = allocator, .client = client };
    }

    fn dup(self: *TenantStore, e: anytype) !TenantRow {
        const name = try self.allocator.dupe(u8, e.name);
        errdefer self.allocator.free(name);
        const status = try self.allocator.dupe(u8, e.status);
        errdefer self.allocator.free(status);
        return .{
            .id = e.id,
            .name = name,
            .status = status,
            .created_at = e.created_at orelse 0,
            .updated_at = e.updated_at orelse 0,
        };
    }

    pub fn create(self: *TenantStore, name: []const u8, status: []const u8, now: i64) !i64 {
        var b = try self.client.tenant.Create();
        defer b.deinit();
        _ = try b.setFieldValue("name", name);
        _ = try b.setFieldValue("status", status);
        _ = try b.setFieldValue("created_at", now);
        _ = try b.setFieldValue("updated_at", now);
        var row = try b.Save();
        defer zent.codegen.deinitEntity(infos, TenantInfo, &row, self.allocator);
        return row.id;
    }

    pub fn getById(self: *TenantStore, id: i64) !?TenantRow {
        var q = self.client.tenant.Query();
        defer q.deinit();
        const preds = self.client.tenant.predicates;
        _ = try q.Where(.{preds.idEQ(.{ .int = id })});
        const entity_opt = try q.First();
        var entity = entity_opt orelse return null;
        defer zent.codegen.deinitEntity(infos, TenantInfo, &entity, self.allocator);
        return try self.dup(entity);
    }

    pub fn list(self: *TenantStore, page: usize, page_size: usize) !TenantListResult {
        var q = self.client.tenant.Query();
        defer q.deinit();
        _ = try q.OrderBy(&[_]zent.sql.Order{zent.sql.OrderAsc("id")});

        var paged = try q.paged(page, page_size);
        defer paged.deinit();

        var out = try self.allocator.alloc(TenantRow, paged.items.items.len);
        var n: usize = 0;
        errdefer {
            for (out[0..n]) |r| r.free(self.allocator);
            self.allocator.free(out);
        }
        for (paged.items.items) |e| {
            out[n] = try self.dup(e);
            n += 1;
        }
        return .{ .items = out, .total = paged.total };
    }

    pub fn update(self: *TenantStore, id: i64, name: []const u8, status: []const u8, now: i64) !bool {
        const preds = self.client.tenant.predicates;
        var upd = self.client.tenant.Update();
        defer upd.deinit();
        _ = try upd.set("name", .{ .string = name });
        _ = try upd.set("status", .{ .string = status });
        _ = try upd.setFieldValue("updated_at", now);
        _ = try upd.Where(.{preds.idEQ(.{ .int = id })});
        _ = try upd.Save();
        return true;
    }
    /// Total tenant count (dashboard stats).
    pub fn countAll(self: *TenantStore) !i64 {
        var q = self.client.tenant.Query();
        defer q.deinit();
        return @intCast(try q.Count());
    }
};
