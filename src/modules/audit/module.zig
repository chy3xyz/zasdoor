//! ZigModu module `audit` — admin audit trail.
const zigmodu = @import("zigmodu");

pub const info = zigmodu.api.Module{
    .name = "audit",
    .description = "admin audit trail: who did what, when, from where",
    .dependencies = &.{},
    .is_internal = true,
};

pub fn init() !void {}
pub fn deinit() void {}
