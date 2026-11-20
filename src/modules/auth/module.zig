//! ZigModu module `auth` — pure BFF routing layer, no own DB tables.
const zmodu = @import("zmodu");

pub const info = zmodu.api.Module{
    .name = "auth",
    .description = "authentication BFF (register/login/logout/password reset)",
    .dependencies = &.{"user"},
    .is_internal = false,
};

pub fn init() !void {}
pub fn deinit() void {}
