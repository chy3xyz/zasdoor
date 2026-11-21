//! User projection: builds an append-only activity query model from user
//! domain events. The blob is a JSON array of recent facts, a genuine derived
//! read model independent of the mutable user table.

const std = @import("std");
const persist = @import("persistence.zig");
const service = @import("service.zig");

pub fn project(
    allocator: std.mem.Allocator,
    store: *persist.EventStore,
    state: []const u8,
    ev: service.EventRow,
) ![]const u8 {
    _ = store;
    if (!std.mem.startsWith(u8, ev.event_type, "user.")) return state;

    // Keep the blob bounded and valid JSON: drop the trailing "]" of the
    // existing array, append one fact, close it again.
    var body: []const u8 = "[";
    if (state.len > 1 and state[0] == '[') body = state[0 .. state.len - 1];
    const prefix: []const u8 = if (std.mem.eql(u8, body, "[")) "" else ",";
    return std.fmt.allocPrint(
        allocator,
        "{s}{s}{{\"seq\":{d},\"type\":\"{s}\",\"aggregate\":\"{s}\"}}]",
        .{ body, prefix, ev.id, ev.event_type, ev.aggregate_id },
    );
}
