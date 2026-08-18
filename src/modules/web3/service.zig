//! Web3 service: SIWE wallet verification + EIP-4361 validation + binding.

const std = @import("std");
const zigmodu = @import("zigmodu");
const persist = @import("persistence.zig");
const siwe = @import("siwe.zig");
const siwe_msg = @import("siwe_message.zig");
const user_svc = @import("../user/service.zig");

pub const WalletRow = persist.WalletRow;
pub const SiweNonceRow = persist.SiweNonceRow;

pub const VerifySiweError = error{
    InvalidSiweMessage,
    SignatureInvalid,
    AddressMismatch,
    NonceUnavailable,
    WalletNotFound,
    Unexpected,
};

pub const VerifySiweResult = struct {
    address: [20]u8,
    message: siwe_msg.SiweMessage,
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

    /// Verify an EIP-191 (personal_sign) SIWE signature and derive the address.
    pub fn verifySignature(self: *Web3Service, message: []const u8, sig: siwe.Signature, out_addr: *[20]u8) bool {
        _ = self;
        var digest: [32]u8 = undefined;
        siwe.personalSignDigest(message, &digest) catch return false;
        return siwe.recoverAddress(digest, sig, out_addr);
    }

    /// Reserve a fresh single-use SIWE nonce bound to (domain, address).
    pub fn reserveNonce(
        self: *Web3Service,
        tenant_id: i64,
        nonce: []const u8,
        domain: []const u8,
        address: []const u8,
        ttl_seconds: i64,
    ) !void {
        const exp = self.now() + ttl_seconds;
        _ = try self.store.reserveNonce(tenant_id, nonce, domain, address, exp, self.now());
    }

    /// Full SIWE (EIP-4361) verification: parse the message, enforce the time
    /// window, consume the nonce (single-use), recover the address from the
    /// signature, and confirm it matches the message's `address` field.
    /// The returned `SiweMessage` is owned by the caller; free with
    /// `result.message.free(allocator)`.
    pub fn verifySiwe(
        self: *Web3Service,
        tenant_id: i64,
        message: []const u8,
        sig: siwe.Signature,
        expected_domain: []const u8,
    ) VerifySiweError!VerifySiweResult {
        var parsed = siwe_msg.parse(self.allocator, message) catch return error.InvalidSiweMessage;
        defer parsed.free(self.allocator);
        const now_s = self.now();
        if (parsed.expiration_time) |exp| {
            if (now_s > exp) return error.ParseError; // Expired
        }
        if (parsed.not_before) |nb| {
            if (now_s < nb) return error.ParseError; // NotYetValid
        }
        if (!std.mem.eql(u8, parsed.domain, expected_domain)) return error.ParseError; // DomainMismatch
        // Recover signer from the personal_sign digest.
        var recovered: [20]u8 = undefined;
        if (!self.verifySignature(parsed.raw, sig, &recovered)) return error.SignatureInvalid;
        // Lower-case compare (hex addresses are case-insensitive).
        if (!std.ascii.eqlIgnoreCase(parsed.address, &recovered)) return error.AddressMismatch;
        // Single-use nonce: must match the reserved (domain, address).
        const nonce_row = self.store.consumeNonce(tenant_id, parsed.nonce, parsed.domain, parsed.address, now_s) catch return error.Unexpected;
        const row = nonce_row orelse return error.NonceUnavailable;
        defer row.free(self.allocator);
        return .{ .address = recovered, .message = parsed };
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
        const id = try self.store.create(tenant_id, chain, address);
        _ = try self.store.bindUser(id, user_id, self.now());
        return self.store.findByAddress(chain, address);
    }
};
