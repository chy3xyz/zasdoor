//! SAML 2.0 Service Provider module.
pub const xml = @import("xml.zig");
pub const c14n = @import("c14n.zig");
pub const model = @import("model.zig");
pub const persistence = @import("persistence.zig");
pub const config = @import("config.zig");
pub const service = @import("service.zig");

comptime {
    _ = @import("xml.zig");
    _ = @import("c14n.zig");
    _ = @import("config.zig");
    _ = @import("service.zig");
}
