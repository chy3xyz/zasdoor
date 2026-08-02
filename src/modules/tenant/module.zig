//! ZigModu module `tenant` — tenant management.
const zigmodu = @import("zigmodu");

pub const info = zigmodu.api.Module{
    .name = "tenant",
    .description = "tenant management (multi-tenant isolation)",
    .dependencies = &.{},
    .is_internal = false,
};

pub fn init() !void {}
pub fn deinit() void {}
