//! ZigModu module `system` — runtime introspection (admin diagnostics).
const zigmodu = @import("zigmodu");

pub const info = zigmodu.api.Module{
    .name = "system",
    .description = "runtime introspection: uptime, db, mail, cache, tasks",
    .dependencies = &.{},
    .is_internal = true,
};

pub fn init() !void {}
pub fn deinit() void {}
