//! ZigModu module `web3`.
const zmodu = @import("zmodu");

pub const info = zmodu.api.Module{
    .name = "web3",
    .description = "wallet identity + SIWE login (Web3 auth)",
    .dependencies = &.{},
    .is_internal = false,
};

pub fn init() !void {}
pub fn deinit() void {}
