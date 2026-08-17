//! Barrel re-exports for module `eventstore` (append-only Event Store).
pub const model = @import("model.zig");
pub const persistence = @import("persistence.zig");
pub const service = @import("service.zig");
pub const module = @import("module.zig");
