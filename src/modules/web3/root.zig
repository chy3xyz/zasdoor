//! Barrel re-exports for module `web3` (wallet identity + SIWE).
pub const model = @import("model.zig");
pub const persistence = @import("persistence.zig");
pub const service = @import("service.zig");
pub const api = @import("api.zig");
pub const module = @import("module.zig");
pub const siwe = @import("siwe.zig");
pub const siwe_message = @import("siwe_message.zig");
