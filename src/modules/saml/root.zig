//! SAML 2.0 Service Provider module.
pub const xml = @import("xml.zig");
pub const c14n = @import("c14n.zig");
pub const model = @import("model.zig");
pub const persistence = @import("persistence.zig");
pub const config = @import("config.zig");
pub const service = @import("service.zig");
pub const pem = @import("pem.zig");
pub const dsig = @import("dsig.zig");

comptime {
    _ = @import("xml.zig");
    _ = @import("c14n.zig");
    _ = @import("config.zig");
    _ = @import("service.zig");
    _ = @import("pem.zig");
    _ = @import("dsig.zig");
}
