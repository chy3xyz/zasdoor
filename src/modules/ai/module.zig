//! ZigModu module `ai` — agentic assistant over platform skills.
const zmodu = @import("zmodu");

pub const info = zmodu.api.Module{
    .name = "ai",
    .description = "agentic assistant: providers, skills, chat, approvals, workflow",
    .dependencies = &.{},
    .is_internal = false,
};

pub fn init() !void {}
pub fn deinit() void {}
