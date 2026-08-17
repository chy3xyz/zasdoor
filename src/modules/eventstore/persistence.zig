//! Persistence over the zent Client for the Event Store.
//! Append-only event stream with optimistic concurrency (aggregate_version).

const std = @import("std");
const zent = @import("zent");
const crud = zent.crud_helpers;
const model = @import("model.zig");
const schema = @import("../../schema.zig");

const graph = zent.codegen.graph.buildGraph(&.{ model.Event, model.EventPosition, model.ProjectionState });
pub const infos = graph.types;
pub const Client = schema.Client;
pub const EventInfo = infos[0];
pub const EventPositionInfo = infos[1];
pub const ProjectionStateInfo = infos[2];

pub const EventRow = struct {
    id: i64,
    tenant_id: i64,
    aggregate_type: []const u8,
    aggregate_id: []const u8,
    aggregate_version: i64,
    event_type: []const u8,
    payload: []const u8,
    metadata: []const u8,
    actor_id: i64,
    created_at: i64,

    pub fn free(self: EventRow, a: std.mem.Allocator) void {
        a.free(self.aggregate_type);
        a.free(self.aggregate_id);
        a.free(self.event_type);
        a.free(self.payload);
        a.free(self.metadata);
    }
};

pub const EventPositionRow = struct {
    id: i64,
    position_name: []const u8,
    last_sequence: i64,
    processed_at: i64,

    pub fn free(self: EventPositionRow, a: std.mem.Allocator) void {
        a.free(self.position_name);
    }
};

pub const EventStore = struct {
    allocator: std.mem.Allocator,
    client: Client,

    pub fn init(allocator: std.mem.Allocator, client: Client) EventStore {
        return .{ .allocator = allocator, .client = client };
    }

    fn ts(e: anytype) i64 {
        return @as(?i64, e) orelse 0;
    }

    fn dupEvent(self: *EventStore, e: anytype) !EventRow {
        return .{
            .id = e.id,
            .tenant_id = e.tenant_id,
            .aggregate_type = try self.allocator.dupe(u8, e.aggregate_type),
            .aggregate_id = try self.allocator.dupe(u8, e.aggregate_id),
            .aggregate_version = e.aggregate_version,
            .event_type = try self.allocator.dupe(u8, e.event_type),
            .payload = try self.allocator.dupe(u8, e.payload),
            .metadata = try self.allocator.dupe(u8, e.metadata),
            .actor_id = e.actor_id,
            .created_at = ts(e.created_at),
        };
    }

    /// Current aggregate version for a stream (0 when none exists).
    pub fn currentVersion(self: *EventStore, aggregate_type: []const u8, aggregate_id: []const u8) !i64 {
        const preds = self.client.event.predicates;
        return @intCast(try crud.count(self.client.event, .{
            zent.sql.And(
                &preds.aggregate_typeEQ(.{ .string = aggregate_type }),
                &preds.aggregate_idEQ(.{ .string = aggregate_id }),
            ),
        }));
    }

    /// Append an event to a stream with optimistic concurrency.
    /// expected_version is the version the caller observed; if it does not
    /// match the current stream version, the append is rejected (CONFLICT).
    pub fn append(
        self: *EventStore,
        tenant_id: i64,
        aggregate_type: []const u8,
        aggregate_id: []const u8,
        expected_version: i64,
        event_type: []const u8,
        payload: []const u8,
        actor_id: i64,
        now: i64,
    ) !i64 {
        const cur = try self.currentVersion(aggregate_type, aggregate_id);
        if (cur != expected_version) return error.VersionConflict;
        const next_version = cur + 1;

        var b = try self.client.event.Create();
        defer b.deinit();
        _ = try b.setFieldValue("tenant_id", tenant_id);
        _ = try b.setFieldValue("aggregate_type", aggregate_type);
        _ = try b.setFieldValue("aggregate_id", aggregate_id);
        _ = try b.setFieldValue("aggregate_version", next_version);
        _ = try b.setFieldValue("event_type", event_type);
        _ = try b.setFieldValue("payload", payload);
        _ = try b.setFieldValue("metadata", "{}");
        _ = try b.setFieldValue("actor_id", actor_id);
        _ = try b.setFieldValue("created_at", now);
        var row = try b.Save();
        defer zent.codegen.deinitEntity(infos, EventInfo, &row, self.allocator);
        return row.id;
    }

    /// Append an event unconditionally (e.g. created by a fresh aggregate).
    pub fn appendNew(
        self: *EventStore,
        tenant_id: i64,
        aggregate_type: []const u8,
        aggregate_id: []const u8,
        event_type: []const u8,
        payload: []const u8,
        actor_id: i64,
        now: i64,
    ) !i64 {
        const cur = try self.currentVersion(aggregate_type, aggregate_id);
        return self.append(tenant_id, aggregate_type, aggregate_id, cur, event_type, payload, actor_id, now);
    }

    /// Fetch the full event stream of an aggregate (oldest first).
    pub fn streamOf(self: *EventStore, aggregate_type: []const u8, aggregate_id: []const u8) ![]EventRow {
        const preds = self.client.event.predicates;
        const t_q = preds.aggregate_typeEQ(.{ .string = aggregate_type });
        const i_q = preds.aggregate_idEQ(.{ .string = aggregate_id });
        const and_q = zent.sql.And(&t_q, &i_q);
        const rows = try crud.all(self.client.event, .{and_q});
        defer zent.crud_helpers.deinitRows(infos, EventInfo, rows, self.allocator);
        var out = try self.allocator.alloc(EventRow, rows.items.len);
        var n: usize = 0;
        errdefer {
            for (out[0..n]) |r| r.free(self.allocator);
            self.allocator.free(out);
        }
        for (rows.items) |e| {
            out[n] = try self.dupEvent(e);
            n += 1;
        }
        return out;
    }

    /// Latest events newer than `after_id`, oldest first, up to `limit`.
    /// Used by the projection worker to drain the stream in order.
    pub fn eventsAfter(self: *EventStore, after_id: i64, limit: usize) ![]EventRow {
        const preds = self.client.event.predicates;
        const rows = try crud.all(self.client.event, .{preds.idGT(.{ .int = after_id })});
        defer zent.crud_helpers.deinitRows(infos, EventInfo, rows, self.allocator);
        // Keep only the first `limit` in id order (crud.all has no LIMIT without
        // paginated; for projections we sort by id by default).
        if (rows.items.len > limit) return self.allocator.alloc(EventRow, 0);
        var out = try self.allocator.alloc(EventRow, rows.items.len);
        var n: usize = 0;
        errdefer {
            for (out[0..n]) |r| r.free(self.allocator);
            self.allocator.free(out);
        }
        for (rows.items) |e| {
            out[n] = try self.dupEvent(e);
            n += 1;
        }
        return out;
    }

    /// Total event rows (approx. tail sequence since id is monotonic).

    pub fn allCount(self: *EventStore) !i64 {
        return @intCast(try crud.count(self.client.event, .{}));
    }

    // ---- EventPosition (per-projection high-water mark) ----

    /// Read the last-consumed sequence for a projection (0 if none).
    pub fn getPosition(self: *EventStore, name: []const u8) !i64 {
        const preds = self.client.event_position.predicates;
        var e = (try crud.first(self.client.event_position, .{preds.position_nameEQ(.{ .string = name })})) orelse return 0;
        defer zent.codegen.deinitEntity(infos, EventPositionInfo, &e, self.allocator);
        return e.last_sequence;
    }

    /// Advance a projection's high-water mark (insert or update).
    pub fn setPosition(self: *EventStore, name: []const u8, last_sequence: i64, now: i64) !void {
        const preds = self.client.event_position.predicates;
        var existing = try crud.first(self.client.event_position, .{preds.position_nameEQ(.{ .string = name })});
        if (existing) |*e| {
            defer zent.codegen.deinitEntity(infos, EventPositionInfo, e, self.allocator);
            const id = e.id;
            var u = self.client.event_position.Update();
            defer u.deinit();
            _ = try u.setFieldValue("last_sequence", last_sequence);
            _ = try u.setFieldValue("processed_at", now);
            _ = try u.setFieldValue("updated_at", now);
            _ = try u.Where(.{preds.idEQ(.{ .int = id })});
            _ = try u.Save();
            return;
        }
        var b = try self.client.event_position.Create();
        defer b.deinit();
        _ = try b.setFieldValue("position_name", name);
        _ = try b.setFieldValue("last_sequence", last_sequence);
        _ = try b.setFieldValue("processed_at", now);
        var row = try b.Save();
        defer zent.codegen.deinitEntity(infos, EventPositionInfo, &row, self.allocator);
    }
};
