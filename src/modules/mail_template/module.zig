//! ZigModu module `mail_template` — configurable email templates.
const zigmodu = @import("zigmodu");

pub const info = zigmodu.api.Module{
    .name = "mail_template",
    .description = "configurable email templates (verify-email, reset-password)",
    .dependencies = &.{},
    .is_internal = true,
};

pub fn init() !void {}
pub fn deinit() void {}
