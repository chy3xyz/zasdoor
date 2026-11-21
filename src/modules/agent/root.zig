//! Barrel re-exports for module `agent` (AI Agent identity).
pub const model = @import("model.zig");
pub const persistence = @import("persistence.zig");
pub const service = @import("service.zig");
pub const api = @import("api.zig");
pub const module = @import("module.zig");

// Run the agent module's enforcement tests whenever this barrel is imported
// into a test build (src/tests.zig imports it as `modules/agent/root.zig`).
test {
    _ = @import("tests.zig");
}
