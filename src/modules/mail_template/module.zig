//! ZigModu module `mail_template` — configurable email templates.
const zmodu = @import("zmodu");

pub const info = zmodu.api.Module{
    .name = "mail_template",
    .description = "configurable email templates (verify-email, reset-password)",
    .dependencies = &.{},
    .is_internal = true,
};

pub fn init() !void {}
pub fn deinit() void {}
