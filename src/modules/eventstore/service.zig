//! Event Store service - append + projection worker.
//!
//! Projections are simple `ProjectionFn` handlers: given an EventRow and the
//! current projection blob state, they produce a new blob and persist derived
//! rows to a query table. The worker advances each projection's high-water
//! mark (EventPosition) so replays are incremental.

const std = @import("std");
const zigmodu = @import("zigmodu");
const persist = @import("persistence.zig");

pub const EventRow = persist.EventRow;

/// A projection: consumes one event and returns the updated JSON blob.
/// `state` is the projection's current blob; the handler may return an owned
/// new blob (freed by the worker) or the same state to keep it unchanged.
pub const ProjectionFn = *const fn (
    allocator: std.mem.Allocator,
    store: *persist.EventStore,
    state: []const u8,
    ev: EventRow,
) anyerror![]const u8;

pub const Projection = struct {
    name: []const u8,
    run: ProjectionFn,
};

pub const EventService = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *persist.EventStore,
    projections: []const Projection,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        store: *persist.EventStore,
        projections: []const Projection,
    ) EventService {
        return .{ .allocator = allocator, .io = io, .store = store, .projections = projections };
    }

    fn now(self: *EventService) i64 {
        return zigmodu.time.wallClockSeconds(self.io);
    }

    /// Append a domain event with optimistic concurrency, returning the new id.
    pub fn append(
        self: *EventService,
        tenant_id: i64,
        aggregate_type: []const u8,
        aggregate_id: []const u8,
        expected_version: i64,
        event_type: []const u8,
        payload: []const u8,
        actor_id: i64,
    ) !i64 {
        return self.store.append(tenant_id, aggregate_type, aggregate_id, expected_version, event_type, payload, actor_id, self.now());
    }

    /// Run every projection forward until its high-water mark catches the tail.
    /// Called by the background worker on a timer.
    pub fn project(self: *EventService) !void {
        for (self.projections) |proj| {
            try self.runProjection(proj);
        }
    }

    fn runProjection(self: *EventService, proj: Projection) !void {
        var mark = self.store.getPosition(proj.name) catch 0;
        const batch: usize = 100;
        while (true) {
            const batch_events = self.store.eventsAfter(mark, batch) catch return;
            defer {
                for (batch_events) |r| r.free(self.allocator);
                self.allocator.free(batch_events);
            }
            if (batch_events.len == 0) break;
            // Owned projection blob (null = default "{}", never heap-freed).
            var owned: ?[]const u8 = null;
            for (batch_events) |ev| {
                const state_slice = owned orelse "{}";
                const new_state = proj.run(self.allocator, self.store, state_slice, ev) catch continue;
                if (new_state.ptr != state_slice.ptr) {
                    if (owned) |prev| self.allocator.free(prev);
                    owned = new_state;
                }
                mark = ev.id;
            }
            self.store.setPosition(proj.name, mark, self.now()) catch {};
            if (owned) |b| self.allocator.free(b);
            if (batch_events.len < batch) break;
        }
    }
};
