//! ZigModu module `notify` — per-user notifications.
const zmodu = @import("zmodu");

pub const info = zmodu.api.Module{
    .name = "notify",
    .description = "per-user notifications (flash messages, task events)",
    .dependencies = &.{},
    .is_internal = false,
};

pub fn init() !void {}
pub fn deinit() void {}
