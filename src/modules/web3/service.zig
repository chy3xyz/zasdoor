//! Web3 service: SIWE wallet verification, binding, and address-based login.

const std = @import("std");
const zigmodu = @import("zigmodu");
const persist = @import("persistence.zig");
const siwe = @import("siwe.zig");
const user_svc = @import("../user/service.zig");

pub const WalletRow = persist.WalletRow;

pub const Web3Error = error{
    SignatureInvalid,
    AddressMismatch,
    WalletNotFound,
    Unexpected,
};

pub const Web3Service = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *persist.WalletStore,
    users: *user_svc.UserService,
    sec: *zigmodu.security.AppSecurity,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        store: *persist.WalletStore,
        users: *user_svc.UserService,
        sec: *zigmodu.security.AppSecurity,
    ) Web3Service {
        return .{ .allocator = allocator, .io = io, .store = store, .users = users, .sec = sec };
    }

    fn now(self: *Web3Service) i64 {
        return zigmodu.time.wallClockSeconds(self.io);
    }

    /// Verify an EIP-191 (personal_sign) SIWE signature over a message and
    /// derive the signer's Ethereum address (20 bytes).
    pub fn verifySignature(message: []const u8, sig: siwe.Signature, out_addr: *[20]u8) bool {
        var digest: [32]u8 = undefined;
        siwe.personalSignDigest(message, &digest) catch return false;
        return siwe.recoverAddress(digest, sig, out_addr);
    }

    /// Find a wallet by (chain, address).
    pub fn findWallet(self: *Web3Service, chain: []const u8, address: []const u8) !?WalletRow {
        return self.store.findByAddress(chain, address);
    }

    /// Bind a wallet address to a user (creating the wallet if needed).
    pub fn bindWallet(
        self: *Web3Service,
        tenant_id: i64,
        user_id: i64,
        chain: []const u8,
        address: []const u8,
    ) !?WalletRow {
        const row_opt = try self.store.findByAddress(chain, address);
        if (row_opt) |row| {
            errdefer row.free(self.allocator);
            _ = self.store.bindUser(row.id, user_id, self.now()) catch return error.Unexpected;
            return row;
        }
        const id = try self.store.create(tenant_id, chain, address, self.now());
        _ = try self.store.bindUser(id, user_id, self.now());
        return self.store.findByAddress(chain, address);
    }
};
