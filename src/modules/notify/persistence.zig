//! Persistence over the zent Client — per-user notifications.

const std = @import("std");
const zent = @import("zent");
const model = @import("model.zig");
const schema = @import("../../schema.zig");

const graph = zent.codegen.graph.buildGraph(&.{model.Notification});
pub const infos = graph.types;
pub const Client = schema.Client;
pub const NotificationInfo = infos[0];

pub const NotificationRow = struct {
    id: i64,
    user_id: i64,
    title: []const u8,
    body: []const u8,
    read: bool,
    kind: []const u8,
    created_at: i64,
    updated_at: i64,

    pub fn free(self: NotificationRow, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.body);
        allocator.free(self.kind);
    }
};

pub const NotificationListResult = struct {
    items: []NotificationRow,
    total: i64,

    pub fn free(self: *NotificationListResult, allocator: std.mem.Allocator) void {
        for (self.items) |r| r.free(allocator);
        allocator.free(self.items);
    }
};

pub const NotificationStore = struct {
    allocator: std.mem.Allocator,
    client: Client,

    pub fn init(allocator: std.mem.Allocator, client: Client) NotificationStore {
        return .{ .allocator = allocator, .client = client };
    }

    fn dup(self: *NotificationStore, e: anytype) !NotificationRow {
        const title = try self.allocator.dupe(u8, e.title);
        errdefer self.allocator.free(title);
        const body = try self.allocator.dupe(u8, e.body);
        errdefer self.allocator.free(body);
        const kind = try self.allocator.dupe(u8, e.kind);
        errdefer self.allocator.free(kind);
        return .{
            .id = e.id,
            .user_id = e.user_id,
            .title = title,
            .body = body,
            .read = e.read,
            .kind = kind,
            .created_at = e.created_at orelse 0,
            .updated_at = e.updated_at orelse 0,
        };
    }

    pub fn create(self: *NotificationStore, user_id: i64, title: []const u8, body: []const u8, kind: []const u8, now: i64) !i64 {
        var b = try self.client.notification.Create();
        defer b.deinit();
        _ = try b.setFieldValue("user_id", user_id);
        _ = try b.setFieldValue("title", title);
        _ = try b.setFieldValue("body", body);
        _ = try b.setFieldValue("read", false);
        _ = try b.setFieldValue("kind", kind);
        _ = try b.setFieldValue("created_at", now);
        _ = try b.setFieldValue("updated_at", now);
        var row = try b.Save();
        defer zent.codegen.deinitEntity(infos, NotificationInfo, &row, self.allocator);
        return row.id;
    }

    pub fn listForUser(self: *NotificationStore, user_id: i64, page: usize, page_size: usize, unread_only: bool) !NotificationListResult {
        const preds = self.client.notification.predicates;
        const user_pred = preds.user_idEQ(.{ .int = user_id });
        const unread_pred = if (unread_only) preds.readEQ(.{ .bool = false }) else null;

        var q = self.client.notification.Query();
        defer q.deinit();
        _ = try q.Where(.{user_pred});
        if (unread_pred) |up| _ = try q.Where(.{up});
        _ = try q.OrderBy(&[_]zent.sql.Order{.{ .column = .{ .name = "created_at", .desc = true } }});

        var paged = try q.paged(page, page_size);
        defer paged.deinit();

        var out = try self.allocator.alloc(NotificationRow, paged.items.items.len);
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

    pub fn unreadCount(self: *NotificationStore, user_id: i64) !i64 {
        const preds = self.client.notification.predicates;
        var q = self.client.notification.Query();
        defer q.deinit();
        _ = try q.Where(.{preds.user_idEQ(.{ .int = user_id })});
        _ = try q.Where(.{preds.readEQ(.{ .bool = false })});
        return @intCast(try q.Count());
    }

    pub fn markRead(self: *NotificationStore, id: i64, user_id: i64) !bool {
        const preds = self.client.notification.predicates;
        var upd = self.client.notification.Update();
        defer upd.deinit();
        _ = try upd.setFieldValue("read", true);
        _ = try upd.Where(.{preds.idEQ(.{ .int = id })});
        _ = try upd.Where(.{preds.user_idEQ(.{ .int = user_id })});
        _ = try upd.Save();
        return true;
    }

    pub fn markAllRead(self: *NotificationStore, user_id: i64) !void {
        const preds = self.client.notification.predicates;
        var upd = self.client.notification.Update();
        defer upd.deinit();
        _ = try upd.setFieldValue("read", true);
        _ = try upd.Where(.{preds.user_idEQ(.{ .int = user_id })});
        _ = try upd.Save();
    }

    pub fn delete(self: *NotificationStore, id: i64, user_id: i64) !bool {
        const preds = self.client.notification.predicates;
        var d = self.client.notification.Delete();
        defer d.deinit();
        _ = try d.Where(.{preds.idEQ(.{ .int = id })});
        _ = try d.Where(.{preds.user_idEQ(.{ .int = user_id })});
        _ = try d.Exec();
        return true;
    }

    /// Global sweep (cron): remove notifications older than `max_age` seconds.
    pub fn purgeOlderThan(self: *NotificationStore, now: i64, max_age: i64) !usize {
        const preds = self.client.notification.predicates;
        const cutoff = now - max_age;
        var d = self.client.notification.Delete();
        defer d.deinit();
        _ = try d.Where(.{preds.created_atLT(.{ .int = cutoff })});
        _ = try d.Exec();
        return 0;
    }
    /// Total notification count (dashboard stats).
    pub fn countAll(self: *NotificationStore) !i64 {
        var q = self.client.notification.Query();
        defer q.deinit();
        return @intCast(try q.Count());
    }
};
