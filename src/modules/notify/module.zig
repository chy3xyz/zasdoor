//! ZigModu module `notify` — per-user notifications.
const zigmodu = @import("zigmodu");

pub const info = zigmodu.api.Module{
    .name = "notify",
    .description = "per-user notifications (flash messages, task events)",
    .dependencies = &.{},
    .is_internal = false,
};

pub fn init() !void {}
pub fn deinit() void {}
