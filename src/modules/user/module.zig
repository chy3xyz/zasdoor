//! ZigModu module `user` (zent-backed) — lifecycle hooks are no-ops
//! because the zent driver is owned by `main.zig` and shared through the
//! `UserStore` / `UserService` pointers.
const zigmodu = @import("zigmodu");

pub const info = zigmodu.api.Module{
    .name = "user",
    .description = "user domain (users + password reset tokens)",
    .dependencies = &.{},
    .is_internal = false,
};

pub fn init() !void {}
pub fn deinit() void {}
