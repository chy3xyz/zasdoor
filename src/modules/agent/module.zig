//! ZigModu module `agent`.
const zmodu = @import("zmodu");

pub const info = zmodu.api.Module{
    .name = "agent",
    .description = "AI agent identity (owner, capabilities, budget, delegation)",
    .dependencies = &.{},
    .is_internal = false,
};

pub fn init() !void {}
pub fn deinit() void {}
