//! ZigModu module `task` — durable background task queue.
const zmodu = @import("zmodu");

pub const info = zmodu.api.Module{
    .name = "task",
    .description = "durable background task queue (enqueue/claim/retry)",
    .dependencies = &.{},
    .is_internal = false,
};

pub fn init() !void {}
pub fn deinit() void {}
