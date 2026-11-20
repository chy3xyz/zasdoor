//! ZigModu module `authz`.
const zmodu = @import("zmodu");

pub const info = zmodu.api.Module{
    .name = "authz",
    .description = "authorization kernel (subject -> resource -> action -> ALLOW/DENY)",
    .dependencies = &.{},
    .is_internal = false,
};

pub fn init() !void {}
pub fn deinit() void {}
