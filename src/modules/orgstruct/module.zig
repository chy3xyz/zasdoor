//! ZigModu module `orgstruct` (zent-backed) - lifecycle hooks are no-ops because
//! the zent driver is owned by main.zig and shared via service pointers.
const zmodu = @import("zmodu");

pub const info = zmodu.api.Module{
    .name = "orgstruct",
    .description = "Instance, Group/GroupMember and verified Domain layers",
    .dependencies = &.{},
    .is_internal = false,
};

pub fn init() !void {}
pub fn deinit() void {}
