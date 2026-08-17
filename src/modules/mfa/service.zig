//! MFA / account-security service: TOTP, recovery codes, IdP and MFA policy.

const std = @import("std");
const zigmodu = @import("zigmodu");
const totp = @import("totp.zig");
const persist = @import("persistence.zig");

pub const MfaError = error{
    NotConfigured,
    InvalidCode,
    RecoveryMismatch,
    Unexpected,
};

pub const MfaService = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *persist.MfaStore,
    sec: *zigmodu.security.AppSecurity,
    time_step_seconds: i64,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, store: *persist.MfaStore, sec: *zigmodu.security.AppSecurity) MfaService {
        return .{
            .allocator = allocator,
            .io = io,
            .store = store,
            .sec = sec,
            .time_step_seconds = 30,
        };
    }

    pub fn now(self: *MfaService) i64 {
        return zigmodu.time.wallClockSeconds(self.io);
    }

    /// Start TOTP enrollment: generate a fresh secret and persist it (disabled).
    /// Returns the base32 secret for the user to scan into an authenticator.
    pub fn enrollTotp(self: *MfaService, tenant_id: i64, user_id: i64) ![]const u8 {
        const secret = totp.generateSecret(self.allocator, self.io, 20) catch return error.Unexpected;
        errdefer self.allocator.free(secret);
        self.store.saveTotpSecret(tenant_id, user_id, secret, self.now()) catch return error.Unexpected;
        return secret;
    }

    /// Verify a code against the stored secret and, on success, enable it.
    pub fn verifyAndEnable(self: *MfaService, user_id: i64, code: []const u8) MfaError!void {
        const secret = self.store.getTotpSecret(user_id) catch return error.NotConfigured;
        const s = secret orelse return error.NotConfigured;
        defer self.allocator.free(s);
        const counter = totp.counterAt(self.now(), self.time_step_seconds);
        const ok = totp.verify(self.allocator, s, code, counter, 1) catch return error.Unexpected;
        if (!ok) return error.InvalidCode;
        self.store.setTotpEnabled(user_id, true, self.now()) catch return error.Unexpected;
    }

    /// Verify a TOTP code as a login factor (credential must already be enabled).
    pub fn verifyTotp(self: *MfaService, user_id: i64, code: []const u8) MfaError!bool {
        const enabled = self.store.getTotpEnabled(user_id) catch return error.NotConfigured;
        if (!enabled) return error.NotConfigured;
        const secret = self.store.getTotpSecret(user_id) catch return error.NotConfigured;
        const s = secret orelse return error.NotConfigured;
        defer self.allocator.free(s);
        const counter = totp.counterAt(self.now(), self.time_step_seconds);
        const ok = totp.verify(self.allocator, s, code, counter, 1) catch return false;
        return ok;
    }

    /// Generate a fresh set of recovery codes (hashed) for a user.
    pub fn generateRecoveryCodes(self: *MfaService, tenant_id: i64, user_id: i64, count: usize) ![][]const u8 {
        const n = if (count == 0) 10 else count;
        var out = try self.allocator.alloc([]const u8, n);
        var made: usize = 0;
        errdefer {
            for (out[0..made]) |c| self.allocator.free(c);
            self.allocator.free(out);
        }
        for (0..n) |i| {
            const raw = self.randomCode() catch return error.Unexpected;
            errdefer self.allocator.free(raw);
            const hash = recoveryHash(self.allocator, raw) catch return error.Unexpected;
            defer self.allocator.free(hash);
            _ = self.store.createRecoveryCode(tenant_id, user_id, hash, 0, self.now()) catch return error.Unexpected;
            out[i] = raw;
            made += 1;
        }
        return out;
    }

    /// Validate a recovery code; marks it used on success.
    pub fn verifyRecoveryCode(self: *MfaService, user_id: i64, code: []const u8) MfaError!bool {
        const hash = recoveryHash(self.allocator, code) catch return error.Unexpected;
        defer self.allocator.free(hash);
        const id = self.store.findRecoveryByHash(user_id, hash) catch return error.RecoveryMismatch;
        const rid = id orelse return error.RecoveryMismatch;
        self.store.markRecoveryUsed(rid, self.now()) catch {};
        return true;
    }

    /// True when the tenant's MFA policy requires a second factor.
    pub fn mfaRequired(self: *MfaService, tenant_id: i64) bool {
        const p = self.store.getPolicy(tenant_id) catch return false;
        return p.require_mfa;
    }

    /// True when the user has TOTP enabled (i.e. is MFA capable).
    pub fn userHasMfa(self: *MfaService, user_id: i64) bool {
        const enabled = self.store.getTotpEnabled(user_id) catch return false;
        return enabled;
    }

    fn randomCode(self: *MfaService) ![]const u8 {
        var buf: [8]u8 = undefined;
        try fillEntropy(self.io, &buf);
        return hexEncode(self.allocator, &buf);
    }
};


fn fillEntropy(io: std.Io, buf: []u8) !void {
    var file = try std.Io.Dir.cwd().openFile(io, "/dev/urandom", .{});
    defer file.close(io);
    const read = try file.readPositionalAll(io, buf, 0);
    if (read != buf.len) return error.Unexpected;
}

fn hexEncode(allocator: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const hex_chars = "0123456789abcdef";
    const out = try allocator.alloc(u8, bytes.len * 2);
    for (bytes, 0..) |b, i| {
        out[i * 2] = hex_chars[b >> 4];
        out[i * 2 + 1] = hex_chars[b & 0xf];
    }
    return out;
}

/// Deterministic (non-salted) hash for single-use recovery codes, so the
/// plaintext code always hashes to the same value for lookup.
fn recoveryHash(a: std.mem.Allocator, code: []const u8) ![]const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(code, &digest, .{});
    const enc = std.base64.url_safe_no_pad.Encoder;
    const n = enc.calcSize(32);
    const out = try a.alloc(u8, n);
    _ = enc.encode(out, &digest);
    return out;
}
