//! ZigModu module `audit` — admin audit trail.
const zmodu = @import("zmodu");

pub const info = zmodu.api.Module{
    .name = "audit",
    .description = "admin audit trail: who did what, when, from where",
    .dependencies = &.{},
    .is_internal = true,
};

pub fn init() !void {}
pub fn deinit() void {}
