//! ZigModu module `iam` (zent-backed) - lifecycle hooks are no-ops because
//! the zent driver is owned by main.zig and shared via IamService pointers.
const zigmodu = @import("zigmodu");

pub const info = zigmodu.api.Module{
    .name = "iam",
    .description = "ZenaIAM kernel (projects, applications, roles, sessions, OAuth tokens)",
    .dependencies = &.{},
    .is_internal = false,
};

pub fn init() !void {}
pub fn deinit() void {}
