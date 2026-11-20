//! ZigModu module `file` — uploads & static file serving.
const zmodu = @import("zmodu");

pub const info = zmodu.api.Module{
    .name = "file",
    .description = "file uploads with local-disk storage",
    .dependencies = &.{},
    .is_internal = false,
};

pub fn init() !void {}
pub fn deinit() void {}
