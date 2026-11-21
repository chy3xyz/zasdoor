//! SAML 2.0 SP protocol primitives (P0 spike: XML + exclusive c14n).
//!
//! This module is not yet wired into the application; the parser and
//! canonicalizer are exercised via the unit-test tree. See docs/saml.md.
pub const xml = @import("xml.zig");
pub const c14n = @import("c14n.zig");

comptime {
    _ = @import("xml.zig");
    _ = @import("c14n.zig");
}
