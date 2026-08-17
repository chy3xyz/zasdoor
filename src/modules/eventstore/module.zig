//! ZigModu module `eventstore`.
const zigmodu = @import("zigmodu");

pub const info = zigmodu.api.Module{
    .name = "eventstore",
    .description = "append-only event store with optimistic concurrency",
    .dependencies = &.{},
    .is_internal = false,
};

pub fn init() !void {}
pub fn deinit() void {}
