//! Persistence over the zent Client — durable background tasks.

const std = @import("std");
const zent = @import("zent");
const model = @import("model.zig");
const schema = @import("../../schema.zig");

const graph = zent.codegen.graph.buildGraph(&.{model.Task});
pub const infos = graph.types;
pub const Client = schema.Client;
pub const TaskInfo = infos[0];

pub const TaskRow = struct {
    id: i64,
    name: []const u8,
    payload: []const u8,
    status: []const u8,
    tenant_id: i64,
    attempts: i64,
    max_attempts: i64,
    last_error: []const u8,
    available_at: i64,
    started_at: i64,
    finished_at: i64,
    created_at: i64,
    updated_at: i64,

    pub fn free(self: TaskRow, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.payload);
        allocator.free(self.status);
        allocator.free(self.last_error);
    }
};

pub const TaskListResult = struct {
    items: []TaskRow,
    total: i64,

    pub fn free(self: *TaskListResult, allocator: std.mem.Allocator) void {
        for (self.items) |r| r.free(allocator);
        allocator.free(self.items);
    }
};

pub const StatusCounts = struct {
    pending: i64 = 0,
    claimed: i64 = 0,
    done: i64 = 0,
    failed: i64 = 0,
    canceled: i64 = 0,
};

pub const TaskStore = struct {
    allocator: std.mem.Allocator,
    client: Client,

    pub fn init(allocator: std.mem.Allocator, client: Client) TaskStore {
        return .{ .allocator = allocator, .client = client };
    }

    fn dupTask(self: *TaskStore, e: anytype) !TaskRow {
        const name = try self.allocator.dupe(u8, e.name);
        errdefer self.allocator.free(name);
        const payload = try self.allocator.dupe(u8, e.payload);
        errdefer self.allocator.free(payload);
        const status = try self.allocator.dupe(u8, e.status);
        errdefer self.allocator.free(status);
        const last_error = try self.allocator.dupe(u8, e.last_error);
        errdefer self.allocator.free(last_error);
        return .{
            .id = e.id,
            .name = name,
            .payload = payload,
            .status = status,
            .tenant_id = e.tenant_id,
            .attempts = e.attempts,
            .max_attempts = e.max_attempts,
            .last_error = last_error,
            .available_at = e.available_at,
            .started_at = e.started_at,
            .finished_at = e.finished_at,
            .created_at = e.created_at orelse 0,
            .updated_at = e.updated_at orelse 0,
        };
    }

    pub fn createTask(
        self: *TaskStore,
        name: []const u8,
        payload: []const u8,
        status: []const u8,
        tenant_id: i64,
        attempts: i64,
        max_attempts: i64,
        last_error: []const u8,
        available_at: i64,
        now: i64,
    ) !i64 {
        var b = try self.client.task.Create();
        defer b.deinit();
        _ = try b.setFieldValue("name", name);
        _ = try b.setFieldValue("payload", payload);
        _ = try b.setFieldValue("status", status);
        _ = try b.setFieldValue("tenant_id", tenant_id);
        _ = try b.setFieldValue("attempts", attempts);
        _ = try b.setFieldValue("max_attempts", max_attempts);
        _ = try b.setFieldValue("last_error", last_error);
        _ = try b.setFieldValue("available_at", available_at);
        _ = try b.setFieldValue("started_at", 0);
        _ = try b.setFieldValue("finished_at", 0);
        _ = try b.setFieldValue("created_at", now);
        _ = try b.setFieldValue("updated_at", now);
        var row = try b.Save();
        defer zent.codegen.deinitEntity(infos, TaskInfo, &row, self.allocator);
        return row.id;
    }

    pub fn getTaskById(self: *TaskStore, id: i64) !?TaskRow {
        var q = self.client.task.Query();
        defer q.deinit();
        const preds = self.client.task.predicates;
        _ = try q.Where(.{preds.idEQ(.{ .int = id })});
        const entity_opt = try q.First();
        var entity = entity_opt orelse return null;
        defer zent.codegen.deinitEntity(infos, TaskInfo, &entity, self.allocator);
        return try self.dupTask(entity);
    }

    pub fn listTasks(self: *TaskStore, page: usize, page_size: usize, status: ?[]const u8) !TaskListResult {
        const preds = self.client.task.predicates;
        const status_pred = if (status) |s| if (s.len > 0) preds.statusEQ(.{ .string = s }) else null else null;

        var q = self.client.task.Query();
        defer q.deinit();
        if (status_pred) |sp| _ = try q.Where(.{sp});
        _ = try q.OrderBy(&[_]zent.sql.Order{zent.sql.OrderAsc("id")});

        var paged = try q.paged(page, page_size);
        defer paged.deinit();

        var out = try self.allocator.alloc(TaskRow, paged.items.items.len);
        var n: usize = 0;
        errdefer {
            for (out[0..n]) |r| r.free(self.allocator);
            self.allocator.free(out);
        }
        for (paged.items.items) |e| {
            out[n] = try self.dupTask(e);
            n += 1;
        }
        return .{ .items = out, .total = paged.total };
    }

    /// Oldest due task (`pending` and `available_at <= now`), or null.
    pub fn claimNext(self: *TaskStore, now: i64) !?TaskRow {
        var q = self.client.task.Query();
        defer q.deinit();
        const preds = self.client.task.predicates;
        _ = try q.Where(.{preds.statusEQ(.{ .string = "pending" })});
        _ = try q.Where(.{preds.available_atLTE(.{ .int = now })});
        _ = try q.OrderBy(&[_]zent.sql.Order{zent.sql.OrderAsc("id")});
        _ = q.Limit(1);
        const entity_opt = try q.First();
        var entity = entity_opt orelse return null;
        defer zent.codegen.deinitEntity(infos, TaskInfo, &entity, self.allocator);

        // Mark claimed atomically-ish: only a row still pending may be claimed.
        var upd = self.client.task.Update();
        defer upd.deinit();
        _ = try upd.set("status", .{ .string = "claimed" });
        _ = try upd.setFieldValue("attempts", entity.attempts + 1);
        _ = try upd.setFieldValue("started_at", now);
        _ = try upd.setFieldValue("updated_at", now);
        _ = try upd.Where(.{preds.idEQ(.{ .int = entity.id })});
        _ = try upd.Where(.{preds.statusEQ(.{ .string = "pending" })});
        _ = try upd.Save();

        // Re-read so the returned row reflects the claimed state.
        return try self.getTaskById(entity.id);
    }

    pub fn markDone(self: *TaskStore, id: i64, now: i64) !void {
        const preds = self.client.task.predicates;
        var upd = self.client.task.Update();
        defer upd.deinit();
        _ = try upd.set("status", .{ .string = "done" });
        _ = try upd.setFieldValue("finished_at", now);
        _ = try upd.setFieldValue("updated_at", now);
        _ = try upd.Where(.{preds.idEQ(.{ .int = id })});
        _ = try upd.Save();
    }

    /// Mark failed permanently, or schedule a retry (attempts stay as-is;
    /// the next claim increments them again).
    pub fn markFailedOrRetry(self: *TaskStore, id: i64, attempts: i64, max_attempts: i64, last_error: []const u8, now: i64, retry_interval: i64) !void {
        const preds = self.client.task.predicates;
        var upd = self.client.task.Update();
        defer upd.deinit();
        if (attempts >= max_attempts) {
            _ = try upd.set("status", .{ .string = "failed" });
            _ = try upd.setFieldValue("finished_at", now);
            _ = try upd.set("last_error", .{ .string = last_error });
        } else {
            _ = try upd.set("status", .{ .string = "pending" });
            _ = try upd.setFieldValue("available_at", now + retry_interval);
            _ = try upd.set("last_error", .{ .string = last_error });
            _ = try upd.setFieldValue("started_at", 0);
        }
        _ = try upd.setFieldValue("updated_at", now);
        _ = try upd.Where(.{preds.idEQ(.{ .int = id })});
        _ = try upd.Save();
    }

    /// Re-queue tasks whose worker died mid-run (`claimed` but started too
    /// long ago). Fails tasks past their attempt budget.
    pub fn requeueStale(self: *TaskStore, now: i64, stale_after: i64) !usize {
        const preds = self.client.task.predicates;
        var q = self.client.task.Query();
        defer q.deinit();
        _ = try q.Where(.{preds.statusEQ(.{ .string = "claimed" })});
        _ = try q.Where(.{preds.started_atLT(.{ .int = now - stale_after })});
        var found = try q.All();
        defer {
            for (found.items) |*e| zent.codegen.deinitEntity(infos, TaskInfo, e, self.allocator);
            found.deinit();
        }

        var count: usize = 0;
        for (found.items) |e| {
            if (e.attempts >= e.max_attempts) {
                try self.markFailedOrRetry(e.id, e.attempts, e.max_attempts, "stale (worker died)", now, 0);
            } else {
                var upd = self.client.task.Update();
                defer upd.deinit();
                _ = try upd.set("status", .{ .string = "pending" });
                _ = try upd.setFieldValue("available_at", now);
                _ = try upd.setFieldValue("started_at", 0);
                _ = try upd.setFieldValue("updated_at", now);
                _ = try upd.Where(.{preds.idEQ(.{ .int = e.id })});
                _ = try upd.Save();
            }
            count += 1;
        }
        return count;
    }

    pub fn retryTask(self: *TaskStore, id: i64, now: i64) !bool {
        const preds = self.client.task.predicates;
        var upd = self.client.task.Update();
        defer upd.deinit();
        _ = try upd.set("status", .{ .string = "pending" });
        _ = try upd.setFieldValue("attempts", 0);
        _ = try upd.set("last_error", .{ .string = "" });
        _ = try upd.setFieldValue("available_at", now);
        _ = try upd.setFieldValue("started_at", 0);
        _ = try upd.setFieldValue("finished_at", 0);
        _ = try upd.setFieldValue("updated_at", now);
        _ = try upd.Where(.{preds.idEQ(.{ .int = id })});
        _ = try upd.Where(.{preds.statusNE(.{ .string = "pending" })});
        _ = try upd.Save();
        return true;
    }

    pub fn cancelTask(self: *TaskStore, id: i64, now: i64) !bool {
        const preds = self.client.task.predicates;
        var upd = self.client.task.Update();
        defer upd.deinit();
        _ = try upd.set("status", .{ .string = "canceled" });
        _ = try upd.setFieldValue("finished_at", now);
        _ = try upd.setFieldValue("updated_at", now);
        _ = try upd.Where(.{preds.idEQ(.{ .int = id })});
        _ = try upd.Where(.{preds.statusEQ(.{ .string = "pending" })});
        _ = try upd.Save();
        return true;
    }

    pub fn deleteTask(self: *TaskStore, id: i64) !void {
        const preds = self.client.task.predicates;
        var d = self.client.task.Delete();
        defer d.deinit();
        _ = try d.Where(.{preds.idEQ(.{ .int = id })});
        _ = try d.Exec();
    }

    pub fn purgeFinished(self: *TaskStore) !usize {
        const preds = self.client.task.predicates;
        const p1 = preds.statusEQ(.{ .string = "done" });
        const p2 = preds.statusEQ(.{ .string = "failed" });
        const p3 = preds.statusEQ(.{ .string = "canceled" });
        const or12 = zent.sql.Or(&p1, &p2);
        const or_pred = zent.sql.Or(&or12, &p3);
        var d = self.client.task.Delete();
        defer d.deinit();
        _ = try d.Where(.{or_pred});
        _ = try d.Exec();
        return 0;
    }

    pub fn countByStatus(self: *TaskStore) !StatusCounts {
        var counts: StatusCounts = .{};
        const preds = self.client.task.predicates;
        inline for (.{
            .{ "pending", &counts.pending },
            .{ "claimed", &counts.claimed },
            .{ "done", &counts.done },
            .{ "failed", &counts.failed },
            .{ "canceled", &counts.canceled },
        }) |pair| {
            var q = self.client.task.Query();
            defer q.deinit();
            _ = try q.Where(.{preds.statusEQ(.{ .string = pair[0] })});
            pair[1].* = @intCast(try q.Count());
        }
        return counts;
    }
};
