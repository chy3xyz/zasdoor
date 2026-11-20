//! ZigModu module `oauth` (stateless protocol endpoints).
const zmodu = @import("zmodu");

pub const info = zmodu.api.Module{
    .name = "oauth",
    .description = "oauth2 / oidc endpoints (authorize, token, introspection, discovery)",
    .dependencies = &.{},
    .is_internal = false,
};

pub fn init() !void {}
pub fn deinit() void {}
