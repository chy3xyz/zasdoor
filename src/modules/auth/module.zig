//! ZigModu module `auth` — pure BFF routing layer, no own DB tables.
const zigmodu = @import("zigmodu");

pub const info = zigmodu.api.Module{
    .name = "auth",
    .description = "authentication BFF (register/login/logout/password reset)",
    .dependencies = &.{"user"},
    .is_internal = false,
};

pub fn init() !void {}
pub fn deinit() void {}
