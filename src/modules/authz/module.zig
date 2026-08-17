//! ZigModu module `authz`.
const zigmodu = @import("zigmodu");

pub const info = zigmodu.api.Module{
    .name = "authz",
    .description = "authorization kernel (subject -> resource -> action -> ALLOW/DENY)",
    .dependencies = &.{},
    .is_internal = false,
};

pub fn init() !void {}
pub fn deinit() void {}
