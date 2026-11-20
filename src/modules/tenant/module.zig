//! ZigModu module `tenant` — tenant management.
const zmodu = @import("zmodu");

pub const info = zmodu.api.Module{
    .name = "tenant",
    .description = "tenant management (multi-tenant isolation)",
    .dependencies = &.{},
    .is_internal = false,
};

pub fn init() !void {}
pub fn deinit() void {}
