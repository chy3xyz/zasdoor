//! ZigModu module `ai` — agentic assistant over platform skills.
const zigmodu = @import("zigmodu");

pub const info = zigmodu.api.Module{
    .name = "ai",
    .description = "agentic assistant: providers, skills, chat, approvals, workflow",
    .dependencies = &.{},
    .is_internal = false,
};

pub fn init() !void {}
pub fn deinit() void {}
