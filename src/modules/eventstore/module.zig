//! ZigModu module `eventstore`.
const zmodu = @import("zmodu");

pub const info = zmodu.api.Module{
    .name = "eventstore",
    .description = "append-only event store with optimistic concurrency",
    .dependencies = &.{},
    .is_internal = false,
};

pub fn init() !void {}
pub fn deinit() void {}
