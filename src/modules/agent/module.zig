//! ZigModu module `agent`.
const zigmodu = @import("zigmodu");

pub const info = zigmodu.api.Module{
    .name = "agent",
    .description = "AI agent identity (owner, capabilities, budget, delegation)",
    .dependencies = &.{},
    .is_internal = false,
};

pub fn init() !void {}
pub fn deinit() void {}
