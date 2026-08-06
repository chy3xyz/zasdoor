//! Persistence over the zent Client — admin audit log.

const std = @import("std");
const zent = @import("zent");
const model = @import("model.zig");
const schema = @import("../../schema.zig");

const graph = zent.codegen.graph.buildGraph(&.{model.AuditLog});
pub const infos = graph.types;
pub const Client = schema.Client;
pub const AuditLogInfo = infos[0];

pub const AuditRow = struct {
    id: i64,
    actor_user_id: i64,
    actor_name: []const u8,
    action: []const u8,
    target_type: []const u8,
    target_id: i64,
    detail: []const u8,
    ip: []const u8,
    success: bool,
    tenant_id: i64,
    created_at: i64,
    updated_at: i64,

    pub fn free(self: AuditRow, allocator: std.mem.Allocator) void {
        allocator.free(self.actor_name);
        allocator.free(self.action);
        allocator.free(self.target_type);
        allocator.free(self.detail);
        allocator.free(self.ip);
    }
};

pub const AuditListResult = struct {
    items: []AuditRow,
    total: i64,

    pub fn free(self: *AuditListResult, allocator: std.mem.Allocator) void {
        for (self.items) |r| r.free(allocator);
        allocator.free(self.items);
    }
};

pub const AuditFilters = struct {
    actor_user_id: ?i64 = null,
    action: ?[]const u8 = null,
    keyword: ?[]const u8 = null,
};

pub const AuditStore = struct {
    allocator: std.mem.Allocator,
    client: Client,

    pub fn init(allocator: std.mem.Allocator, client: Client) AuditStore {
        return .{ .allocator = allocator, .client = client };
    }

    fn dup(self: *AuditStore, e: anytype) !AuditRow {
        const actor_name = try self.allocator.dupe(u8, e.actor_name);
        errdefer self.allocator.free(actor_name);
        const action = try self.allocator.dupe(u8, e.action);
        errdefer self.allocator.free(action);
        const target_type = try self.allocator.dupe(u8, e.target_type);
        errdefer self.allocator.free(target_type);
        const detail = try self.allocator.dupe(u8, e.detail);
        errdefer self.allocator.free(detail);
        const ip = try self.allocator.dupe(u8, e.ip);
        errdefer self.allocator.free(ip);
        return .{
            .id = e.id,
            .actor_user_id = e.actor_user_id,
            .actor_name = actor_name,
            .action = action,
            .target_type = target_type,
            .target_id = e.target_id,
            .detail = detail,
            .ip = ip,
            .success = e.success,
            .tenant_id = e.tenant_id,
            .created_at = e.created_at orelse 0,
            .updated_at = e.updated_at orelse 0,
        };
    }

    pub fn create(
        self: *AuditStore,
        actor_user_id: i64,
        actor_name: []const u8,
        action: []const u8,
        target_type: []const u8,
        target_id: i64,
        detail: []const u8,
        ip: []const u8,
        success: bool,
        tenant_id: i64,
        now: i64,
    ) !i64 {
        var b = try self.client.audit_log.Create();
        defer b.deinit();
        _ = try b.setFieldValue("actor_user_id", actor_user_id);
        _ = try b.setFieldValue("actor_name", actor_name);
        _ = try b.setFieldValue("action", action);
        _ = try b.setFieldValue("target_type", target_type);
        _ = try b.setFieldValue("target_id", target_id);
        _ = try b.setFieldValue("detail", detail);
        _ = try b.setFieldValue("ip", ip);
        _ = try b.setFieldValue("success", success);
        _ = try b.setFieldValue("tenant_id", tenant_id);
        _ = try b.setFieldValue("created_at", now);
        _ = try b.setFieldValue("updated_at", now);
        var row = try b.Save();
        defer zent.codegen.deinitEntity(infos, AuditLogInfo, &row, self.allocator);
        return row.id;
    }

    /// 删除 created_at 早于 now - max_age_seconds 的记录(保留策略)。
    pub fn purgeOlderThan(self: *AuditStore, now: i64, max_age_seconds: i64) !usize {
        const preds = self.client.audit_log.predicates;
        const cutoff = now - max_age_seconds;
        var d = self.client.audit_log.Delete();
        defer d.deinit();
        _ = try d.Where(.{preds.created_atLT(.{ .int = cutoff })});
        return try d.Exec();
    }

    pub fn list(self: *AuditStore, page: usize, page_size: usize, filters: AuditFilters) !AuditListResult {
        const preds = self.client.audit_log.predicates;

        var q = self.client.audit_log.Query();
        defer q.deinit();
        if (filters.actor_user_id) |uid| _ = try q.Where(.{preds.actor_user_idEQ(.{ .int = uid })});
        if (filters.action) |a| {
            if (a.len > 0) _ = try q.Where(.{preds.actionContainsEscaped(a)});
        }
        if (filters.keyword) |kw| {
            if (kw.len > 0) _ = try q.Where(.{preds.detailContainsEscaped(kw)});
        }
        _ = try q.OrderBy(&[_]zent.sql.Order{.{ .column = .{ .name = "created_at", .desc = true } }});

        var paged = try q.paged(page, page_size);
        defer paged.deinit();

        var out = try self.allocator.alloc(AuditRow, paged.items.items.len);
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
};
