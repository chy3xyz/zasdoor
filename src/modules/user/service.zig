//! Service layer for the user domain — validation, password hashing,
//! JWT issue, password-reset token lifecycle. No HTTP/SQL leakage.

const std = @import("std");
const zigmodu = @import("zigmodu");
const persist = @import("persistence.zig");

pub const UserRow = persist.UserRow;

pub const CreateError = error{
    InvalidName,
    InvalidEmail,
    InvalidPassword,
    EmailTaken,
    Unexpected,
};

pub const LoginError = error{ InvalidCredentials };

pub const ResetTokenError = error{
    InvalidToken,
    TokenExpired,
    InvalidPassword,
};

pub const VerificationError = error{
    InvalidToken,
    TokenExpired,
};

pub const ChangePasswordError = error{
    InvalidCredentials,
    InvalidPassword,
};

/// Raw reset token plus the owning user id (for the reset link).
pub const PasswordResetInfo = struct {
    user_id: i64,
    raw: []const u8,
};

/// Raw email-verification token plus the owning user id (for the link).
pub const VerificationInfo = struct {
    user_id: i64,
    raw: []const u8,
};

/// A signed-in identity: user row plus a fresh JWT.
pub const Session = struct {
    row: UserRow,
    token: []const u8,

    pub fn deinit(self: Session, allocator: std.mem.Allocator) void {
        allocator.free(self.token);
        self.row.free(allocator);
    }
};

pub const UserService = struct {
    store: *persist.UserStore,
    sec: *zigmodu.security.AppSecurity,
    io: std.Io,
    password_token_expiration_seconds: i64,
    verification_token_expiration_seconds: i64,

    pub fn init(
        store: *persist.UserStore,
        sec: *zigmodu.security.AppSecurity,
        io: std.Io,
        password_token_expiration_seconds: i64,
        verification_token_expiration_seconds: i64,
    ) UserService {
        return .{
            .store = store,
            .sec = sec,
            .io = io,
            .password_token_expiration_seconds = password_token_expiration_seconds,
            .verification_token_expiration_seconds = verification_token_expiration_seconds,
        };
    }

    fn normalizeEmail(allocator: std.mem.Allocator, email: []const u8) ![]const u8 {
        return std.ascii.allocLowerString(allocator, email);
    }

    fn validateEmail(email: []const u8) bool {
        if (email.len == 0) return false;
        return std.mem.indexOfScalar(u8, email, '@') != null;
    }

    /// Register a new user. Password must be at least 8 chars. On success a
    /// session JWT is issued (roles derived from `admin`).
    pub fn register(
        self: *UserService,
        allocator: std.mem.Allocator,
        name: []const u8,
        email: []const u8,
        password: []const u8,
        admin: bool,
        tenant_id: i64,
    ) CreateError!Session {
        const trimmed_name = std.mem.trim(u8, name, " \t");
        if (trimmed_name.len == 0) return error.InvalidName;
        if (!validateEmail(email)) return error.InvalidEmail;
        if (password.len < 8) return error.InvalidPassword;

        const norm_email = normalizeEmail(allocator, email) catch return error.InvalidEmail;
        defer allocator.free(norm_email);

        if (self.store.getUserByEmail(norm_email) catch return error.EmailTaken) |existing| {
            existing.free(allocator);
            return error.EmailTaken;
        }

        const hash = self.sec.module.hashPassword(password) catch return error.InvalidPassword;
        defer allocator.free(hash);

        const now = zigmodu.time.wallClockSeconds(self.io);
        // A prior `getUserByEmail` guard makes a create failure most likely
        // a unique-constraint race; re-check before blaming the DB.
        _ = self.store.createUser(trimmed_name, norm_email, hash, false, admin, tenant_id, now) catch {
            if (self.store.getUserByEmail(norm_email) catch null) |existing| {
                existing.free(allocator);
                return error.EmailTaken;
            }
            return error.Unexpected;
        };

        return self.issueSession(allocator, norm_email, admin, tenant_id) catch return error.Unexpected;
    }

    /// Authenticate email+password. Returns null on wrong credentials.
    pub fn login(self: *UserService, allocator: std.mem.Allocator, email: []const u8, password: []const u8) LoginError!?Session {
        const norm_email = normalizeEmail(allocator, email) catch return error.InvalidCredentials;
        defer allocator.free(norm_email);

        const row_opt = self.store.getUserByEmail(norm_email) catch return error.InvalidCredentials;
        const row = row_opt orelse return null;
        defer row.free(allocator);

        const hash_opt = self.store.getPasswordHashById(row.id) catch return error.InvalidCredentials;
        const hash = hash_opt orelse return null;
        defer allocator.free(hash);

        if (!self.sec.module.verifyPassword(password, hash)) return null;
        return self.issueSession(allocator, row.email, row.admin, row.tenant_id) catch return error.InvalidCredentials;
    }

    fn issueSession(self: *UserService, allocator: std.mem.Allocator, email: []const u8, admin: bool, tenant_id: i64) !Session {
        const row_opt = try self.store.getUserByEmail(email);
        const row = row_opt orelse return error.InvalidCredentials;
        errdefer row.free(allocator);

        const id_str = try std.fmt.allocPrint(allocator, "{d}", .{row.id});
        defer allocator.free(id_str);
        const tenant_str = try std.fmt.allocPrint(allocator, "{d}", .{tenant_id});
        defer allocator.free(tenant_str);

        const roles = if (admin) &[_][]const u8{"admin"} else &[_][]const u8{"user"};
        const token = try self.sec.module.generateTokenWithTenant(id_str, roles, tenant_str);
        return .{ .row = row, .token = token };
    }

    pub fn getUserById(self: *UserService, id: i64) !?UserRow {
        return try self.store.getUserById(id);
    }

    pub fn getUserByEmail(self: *UserService, allocator: std.mem.Allocator, email: []const u8) !?UserRow {
        const norm = normalizeEmail(allocator, email) catch return null;
        defer allocator.free(norm);
        return try self.store.getUserByEmail(norm);
    }

    pub fn listUsers(self: *UserService, page: usize, page_size: usize, keyword: ?[]const u8, tenant_id: ?i64, sort_col: ?[]const u8, sort_desc: bool) !persist.UserListResult {
        return try self.store.listUsers(page, page_size, keyword, tenant_id, sort_col, sort_desc);
    }

    pub fn freeList(self: *UserService, result: *persist.UserListResult) void {
        self.store.freeList(result);
    }

    pub fn updateProfile(self: *UserService, id: i64, name: []const u8, email: []const u8) !void {
        if (std.mem.trim(u8, name, " \t").len == 0) return error.InvalidName;
        const allocator = self.store.allocator;
        const norm_email = normalizeEmail(allocator, email) catch return error.InvalidEmail;
        defer allocator.free(norm_email);
        if (!validateEmail(norm_email)) return error.InvalidEmail;
        const now = zigmodu.time.wallClockSeconds(self.io);
        try self.store.updateProfile(id, name, norm_email, now);
    }

    /// True when another user (not `id`) already holds `email`.
    pub fn emailTakenByOther(self: *UserService, allocator: std.mem.Allocator, id: i64, email: []const u8) !bool {
        const norm = normalizeEmail(allocator, email) catch return false;
        defer allocator.free(norm);
        const row_opt = try self.store.getUserByEmail(norm);
        const row = row_opt orelse return false;
        defer row.free(allocator);
        return row.id != id;
    }

    pub fn setVerified(self: *UserService, id: i64, verified: bool) !void {
        const now = zigmodu.time.wallClockSeconds(self.io);
        try self.store.setVerified(id, verified, now);
    }

    pub fn setAdmin(self: *UserService, id: i64, admin: bool) !void {
        const now = zigmodu.time.wallClockSeconds(self.io);
        try self.store.setAdmin(id, admin, now);
    }

    pub fn setPassword(self: *UserService, allocator: std.mem.Allocator, id: i64, password: []const u8) !void {
        if (password.len < 8) return error.InvalidPassword;
        const hash = try self.sec.module.hashPassword(password);
        defer allocator.free(hash);
        const now = zigmodu.time.wallClockSeconds(self.io);
        try self.store.setPasswordHash(id, hash, now);
    }

    pub fn deleteUser(self: *UserService, id: i64) !void {
        try self.store.deleteUser(id);
    }

    // ── Password reset tokens ──────────────────────────────────────

    /// Create a reset token for the user and return the raw token (the store
    /// keeps only its hash). Returns null if the user does not exist.
    pub fn createPasswordResetToken(self: *UserService, allocator: std.mem.Allocator, email: []const u8) !?PasswordResetInfo {
        const norm = try normalizeEmail(allocator, email);
        defer allocator.free(norm);
        const row_opt = try self.store.getUserByEmail(norm);
        const row = row_opt orelse return null;
        defer row.free(allocator);

        const raw = try randomToken(allocator, self.io, 32);
        errdefer allocator.free(raw);
        const hash = try self.sec.module.hashPassword(raw);
        defer allocator.free(hash);
        const now = zigmodu.time.wallClockSeconds(self.io);
        // Housekeeping: drop this user's stale tokens before inserting a new
        // one so the table does not grow without bound.
        self.store.deleteExpiredPasswordTokens(row.id, now, self.password_token_expiration_seconds) catch {};
        _ = try self.store.createPasswordToken(row.id, hash, now);
        return .{ .user_id = row.id, .raw = raw };
    }

    /// Validate a raw reset token against the user's stored (hashed) token
    /// and its age. Returns the user id on success.
    pub fn validatePasswordResetToken(self: *UserService, allocator: std.mem.Allocator, user_id: i64, raw_token: []const u8) ResetTokenError!void {
        const tok_opt = self.store.getLatestPasswordToken(user_id) catch return error.InvalidToken;
        const tok = tok_opt orelse return error.InvalidToken;
        defer tok.free(allocator);

        const now = zigmodu.time.wallClockSeconds(self.io);
        if (now - tok.created_at > self.password_token_expiration_seconds) {
            // The token is dead — purge it (and any older siblings) now.
            self.store.deleteTokensForUser(user_id) catch {};
            return error.TokenExpired;
        }
        if (!self.sec.module.verifyPassword(raw_token, tok.token)) return error.InvalidToken;
    }

    /// Reset a user's password after a valid token; clears all their tokens.
    pub fn resetPassword(self: *UserService, allocator: std.mem.Allocator, user_id: i64, raw_token: []const u8, new_password: []const u8) ResetTokenError!void {
        if (new_password.len < 8) return error.InvalidPassword;
        try self.validatePasswordResetToken(allocator, user_id, raw_token);
        self.setPassword(allocator, user_id, new_password) catch return error.InvalidPassword;
        self.store.deleteTokensForUser(user_id) catch return error.InvalidToken;
    }

    // ── Email verification ────────────────────────────────────────

    /// Create a verification token for the user and return the raw token
    /// (only its hash is stored). Returns null if the user does not exist.
    pub fn createEmailVerification(self: *UserService, allocator: std.mem.Allocator, user_id: i64) !?VerificationInfo {
        const row_opt = try self.store.getUserById(user_id);
        const row = row_opt orelse return null;
        defer row.free(allocator);
        if (row.verified) return null;

        const raw = try randomToken(allocator, self.io, 32);
        errdefer allocator.free(raw);
        const hash = try self.sec.module.hashPassword(raw);
        defer allocator.free(hash);
        const now = zigmodu.time.wallClockSeconds(self.io);
        // Housekeeping: drop this user's stale tokens before inserting a new one.
        self.store.deleteExpiredEmailVerifications(user_id, now, self.verification_token_expiration_seconds) catch {};
        _ = try self.store.createEmailVerification(user_id, hash, now);
        return .{ .user_id = user_id, .raw = raw };
    }

    /// Validate a raw verification token and mark the user verified.
    pub fn verifyEmail(self: *UserService, allocator: std.mem.Allocator, user_id: i64, raw_token: []const u8) VerificationError!void {
        const tok_opt = self.store.getLatestEmailVerification(user_id) catch return error.InvalidToken;
        const tok = tok_opt orelse return error.InvalidToken;
        defer tok.free(allocator);

        const now = zigmodu.time.wallClockSeconds(self.io);
        if (now - tok.created_at > self.verification_token_expiration_seconds) {
            self.store.deleteEmailVerificationsForUser(user_id) catch {};
            return error.TokenExpired;
        }
        if (!self.sec.module.verifyPassword(raw_token, tok.token)) return error.InvalidToken;

        self.setVerified(user_id, true) catch return error.InvalidToken;
        self.store.deleteEmailVerificationsForUser(user_id) catch {};
    }

    /// Self-service password change: verify the current password, then set
    /// the new one.
    pub fn changePassword(self: *UserService, allocator: std.mem.Allocator, id: i64, old_password: []const u8, new_password: []const u8) ChangePasswordError!void {
        if (new_password.len < 8) return error.InvalidPassword;
        const hash_opt = self.store.getPasswordHashById(id) catch return error.InvalidCredentials;
        const hash = hash_opt orelse return error.InvalidCredentials;
        defer allocator.free(hash);
        if (!self.sec.module.verifyPassword(old_password, hash)) return error.InvalidCredentials;
        self.setPassword(allocator, id, new_password) catch return error.InvalidPassword;
    }
};

/// Random hex token (cryptographically secure).
///
/// Entropy is drawn from the OS (`/dev/urandom`) rather than a seeded
/// CSPRNG, so two processes can never generate the same token stream.
fn randomToken(allocator: std.mem.Allocator, io: std.Io, nbytes: usize) ![]const u8 {
    var buf: [64]u8 = undefined;
    if (nbytes > buf.len) return error.BufferTooSmall;
    try fillFromSystemEntropy(io, buf[0..nbytes]);
    return hexEncode(allocator, buf[0..nbytes]);
}

/// Fill `buf` with bytes from the operating system CSPRNG.
fn fillFromSystemEntropy(io: std.Io, buf: []u8) !void {
    var file = try std.Io.Dir.cwd().openFile(io, "/dev/urandom", .{});
    errdefer file.close(io);
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
