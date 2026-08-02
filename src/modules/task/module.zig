//! ZigModu module `task` — durable background task queue.
const zigmodu = @import("zigmodu");

pub const info = zigmodu.api.Module{
    .name = "task",
    .description = "durable background task queue (enqueue/claim/retry)",
    .dependencies = &.{},
    .is_internal = false,
};

pub fn init() !void {}
pub fn deinit() void {}
