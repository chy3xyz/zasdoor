//! ZigModu module `mfa`.
const zmodu = @import("zmodu");

pub const info = zmodu.api.Module{
    .name = "mfa",
    .description = "multi-factor auth (TOTP, recovery codes, IdP, MFA policy)",
    .dependencies = &.{},
    .is_internal = false,
};

pub fn init() !void {}
pub fn deinit() void {}
