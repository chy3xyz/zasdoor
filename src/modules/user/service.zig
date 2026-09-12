//! Service layer for the user domain — validation, password hashing,
//! JWT issue, password-reset token lifecycle. No HTTP/SQL leakage.

const std = @import("std");
const zigmodu = @import("zigmodu");
const persist = @import("persistence.zig");

pub const UserRow = persist.UserRow;

pub const CreateError = error{
    InvalidName,
    InvalidEmail,
    /// Retained for backward compatibility; new code returns the specific
    /// policy errors below.
    InvalidPassword,
    PasswordTooShort,
    PasswordTooLong,
    PasswordTooCommon,
    PasswordContainsIdentity,
    EmailTaken,
    Unexpected,
};

pub const LoginError = error{
    InvalidCredentials,
    /// Too many consecutive failures: the account (or the attempted email)
    /// is temporarily locked out.
    AccountLocked,
};

pub const ResetTokenError = error{
    InvalidToken,
    TokenExpired,
    InvalidPassword,
    PasswordTooShort,
    PasswordTooLong,
    PasswordTooCommon,
    PasswordContainsIdentity,
};

pub const VerificationError = error{
    InvalidToken,
    TokenExpired,
};

pub const ChangePasswordError = error{
    InvalidCredentials,
    InvalidPassword,
    PasswordTooShort,
    PasswordTooLong,
    PasswordTooCommon,
    PasswordContainsIdentity,
    TokenInvalidationFailed,
};

/// Outcome of writing a password: policy violations plus storage failures.
pub const SetPasswordError = error{
    InvalidPassword,
    PasswordTooShort,
    PasswordTooLong,
    PasswordTooCommon,
    PasswordContainsIdentity,
    UserNotFound,
    Unexpected,
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

// ── Password policy ──────────────────────────────────────────────

/// Distinct reasons a chosen password fails the shared policy. All entry
/// points (register / change-password / reset-password) map these to the same
/// user-facing 400 messages so the rules never drift apart.
pub const PasswordPolicyError = error{
    PasswordTooShort,
    PasswordTooLong,
    PasswordTooCommon,
    PasswordContainsIdentity,
};

/// Tunable password policy. Defaults are defined here (env-var wiring is a
/// follow-up that would touch config.zig).
///
/// The single shared validate entry point is called from register and
/// setPassword; the latter is the choke point for change-password,
/// reset-password and the zasdoor-admin bootstrap path.
pub const PasswordPolicy = struct {
    /// Minimum length in bytes (default 10).
    min_length: usize = 10,
    /// Maximum length in bytes (default 128) to bound hashing cost.
    max_length: usize = 128,
    /// Identity fragments shorter than this are ignored so one-letter email
    /// local-parts (e.g. "t@example.com") do not reject every password.
    min_identity_length: usize = 3,

    pub fn validate(self: PasswordPolicy, password: []const u8, email: []const u8, name: []const u8) PasswordPolicyError!void {
        if (password.len < self.min_length) return error.PasswordTooShort;
        if (password.len > self.max_length) return error.PasswordTooLong;
        if (isCommonPassword(password)) return error.PasswordTooCommon;
        if (self.containsIdentity(password, email, name)) return error.PasswordContainsIdentity;
    }

    fn containsIdentity(self: PasswordPolicy, password: []const u8, email: []const u8, name: []const u8) bool {
        const at = std.mem.indexOfScalar(u8, email, '@') orelse email.len;
        const local = email[0..at];
        if (local.len >= self.min_identity_length and containsIgnoreCase(password, local)) return true;
        const trimmed = std.mem.trim(u8, name, " \t");
        if (trimmed.len >= self.min_identity_length and containsIgnoreCase(password, trimmed)) return true;
        return false;
    }
};

/// Case-insensitive substring test (std.ascii only provides eqlIgnoreCase).
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// Built-in denylist of very common passwords (exact, case-insensitive
/// match). Intentionally small and compiled in; a credential-stuffing defense
/// only needs to stop the top-of-the-list guesses before the length bound and
/// lockout take over.
const common_passwords = [_][]const u8{
    "123456",      "password",     "12345678",   "qwerty",     "123456789",
    "12345",       "1234",         "111111",     "1234567",    "dragon",
    "123123",      "baseball",     "abc123",     "football",   "monkey",
    "letmein",     "696969",       "shadow",     "master",     "666666",
    "qwertyuiop",  "123321",       "mustang",    "1234567890", "michael",
    "654321",      "superman",     "1qaz2wsx",   "7777777",    "121212",
    "000000",      "qazwsx",       "123qwe",     "killer",     "trustno1",
    "jordan",      "jennifer",     "zxcvbnm",    "asdfgh",     "hunter",
    "buster",      "soccer",       "harley",     "batman",     "andrew",
    "tigger",      "sunshine",     "iloveyou",   "welcome",    "admin",
    "qwerty12345", "1qaz2wsx3edc", "q1w2e3r4t5", "letmein123", "iloveyou123",
    "password12",  "123456789a",
};

fn isCommonPassword(password: []const u8) bool {
    for (common_passwords) |weak| {
        if (std.ascii.eqlIgnoreCase(password, weak)) return true;
    }
    return false;
}

// ── Account lockout ──────────────────────────────────────────────

/// Tunables for the in-process login lockout: lock after max_failures
/// attempts within window_seconds, for lockout_seconds.
pub const LockoutConfig = struct {
    max_failures: u32 = 5,
    window_seconds: i64 = 15 * 60,
    lockout_seconds: i64 = 15 * 60,
};

/// One account's failed-login state.
const LockoutEntry = struct {
    failures: u32,
    window_start: i64,
    locked_until: i64,
};

/// Per-process, in-memory failed-login tracker keyed by normalized email.
///
/// NOTE: this lockout is per-process (single-instance). A multi-instance
/// deployment would need shared storage (Redis/DB) so counters and cooldowns
/// stay consistent across nodes; that is deliberately out of scope here.
pub const LoginLockout = struct {
    config: LockoutConfig = .{},
    mutex: std.Io.Mutex = std.Io.Mutex.init,
    entries: std.StringHashMapUnmanaged(LockoutEntry) = .empty,
    allocator: ?std.mem.Allocator = null,

    /// True when the key is inside its cooldown at now. Expired entries are
    /// dropped so the failure window restarts cleanly.
    pub fn isLocked(self: *LoginLockout, io: std.Io, key: []const u8, now: i64) bool {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const entry = self.entries.getPtr(key) orelse return false;
        if (entry.locked_until == 0) return false;
        if (now >= entry.locked_until) {
            self.removeEntryLocked(key);
            return false;
        }
        return true;
    }

    /// Record one failed attempt, locking the key once it crosses the
    /// threshold within the rolling window.
    pub fn recordFailure(self: *LoginLockout, io: std.Io, key: []const u8, now: i64) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const allocator = self.allocator orelse return;

        if (self.entries.getPtr(key)) |entry| {
            if (entry.locked_until > now) return; // already locked
            if (now - entry.window_start > self.config.window_seconds) {
                entry.failures = 1;
                entry.window_start = now;
                entry.locked_until = 0;
                return;
            }
            entry.failures += 1;
            if (entry.failures >= self.config.max_failures) {
                entry.locked_until = now + self.config.lockout_seconds;
            }
            return;
        }

        const key_copy = allocator.dupe(u8, key) catch return;
        self.entries.put(allocator, key_copy, .{
            .failures = 1,
            .window_start = now,
            .locked_until = if (self.config.max_failures <= 1) now + self.config.lockout_seconds else 0,
        }) catch {
            allocator.free(key_copy);
        };
    }

    /// Clear failure state after a successful login.
    pub fn clear(self: *LoginLockout, io: std.Io, key: []const u8) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.removeEntryLocked(key);
    }

    /// Caller must hold the mutex.
    fn removeEntryLocked(self: *LoginLockout, key: []const u8) void {
        const allocator = self.allocator orelse return;
        if (self.entries.fetchRemove(key)) |kv| allocator.free(kv.key);
    }

    /// Free every tracked key (tests / process teardown).
    pub fn reset(self: *LoginLockout, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const allocator = self.allocator orelse return;
        var it = self.entries.iterator();
        while (it.next()) |kv| allocator.free(kv.key_ptr.*);
        self.entries.deinit(allocator);
        self.entries = .empty;
    }
};

/// Process-wide lockout store. The page allocator is used so the map lives as
/// long as the process (it is intentionally never torn down in production);
/// tests reset it explicitly with resetLoginLockout.
pub var login_lockout: LoginLockout = .{ .allocator = std.heap.page_allocator };

/// Clear the process-wide lockout store (used by tests).
pub fn resetLoginLockout(io: std.Io) void {
    login_lockout.reset(io);
}

pub const UserService = struct {
    store: *persist.UserStore,
    sec: *zigmodu.security.AppSecurity,
    io: std.Io,
    password_token_expiration_seconds: i64,
    verification_token_expiration_seconds: i64,
    /// Password policy enforced on register and every password write.
    policy: PasswordPolicy = .{},

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

    /// Register a new user. The password must satisfy the shared
    /// PasswordPolicy. On success a session JWT is issued (roles derived from
    /// the admin flag).
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
        try self.policy.validate(password, email, trimmed_name);

        const norm_email = normalizeEmail(allocator, email) catch return error.InvalidEmail;
        defer allocator.free(norm_email);

        if (self.store.getUserByEmail(norm_email) catch return error.EmailTaken) |existing| {
            existing.free(self.store.allocator);
            return error.EmailTaken;
        }

        const hash = self.sec.module.hashPassword(password) catch return error.InvalidPassword;
        defer self.sec.module.allocator.free(hash);

        const now = zigmodu.time.wallClockSeconds(self.io);
        // A prior `getUserByEmail` guard makes a create failure most likely
        // a unique-constraint race; re-check before blaming the DB.
        _ = self.store.createUser(trimmed_name, norm_email, hash, false, admin, tenant_id, now) catch {
            if (self.store.getUserByEmail(norm_email) catch null) |existing| {
                existing.free(self.store.allocator);
                return error.EmailTaken;
            }
            return error.Unexpected;
        };

        return self.issueSession(allocator, norm_email, admin, tenant_id) catch return error.Unexpected;
    }

    /// Authenticate email+password. Returns null on wrong credentials and
    /// error.AccountLocked while the per-process lockout is active.
    pub fn login(self: *UserService, allocator: std.mem.Allocator, email: []const u8, password: []const u8) LoginError!?Session {
        return self.loginAt(allocator, email, password, zigmodu.time.wallClockSeconds(self.io));
    }

    /// login with an injected clock: keeps the lockout window/cooldown logic
    /// deterministically testable without sleeping.
    pub fn loginAt(self: *UserService, allocator: std.mem.Allocator, email: []const u8, password: []const u8, now: i64) LoginError!?Session {
        const norm_email = normalizeEmail(allocator, email) catch return error.InvalidCredentials;
        defer allocator.free(norm_email);

        // Check the lockout before touching the DB and regardless of whether
        // the account exists, so unknown and known emails behave identically
        // (the lockout must not become a user-enumeration oracle).
        if (login_lockout.isLocked(self.io, norm_email, now)) return error.AccountLocked;

        const row_opt = self.store.getUserByEmail(norm_email) catch {
            login_lockout.recordFailure(self.io, norm_email, now);
            return error.InvalidCredentials;
        };
        const row = row_opt orelse {
            login_lockout.recordFailure(self.io, norm_email, now);
            return null;
        };
        defer row.free(self.store.allocator);

        const hash_opt = self.store.getPasswordHashById(row.id) catch {
            login_lockout.recordFailure(self.io, norm_email, now);
            return error.InvalidCredentials;
        };
        const hash = hash_opt orelse {
            login_lockout.recordFailure(self.io, norm_email, now);
            return null;
        };
        defer allocator.free(hash);

        if (!self.sec.module.verifyPassword(password, hash)) {
            login_lockout.recordFailure(self.io, norm_email, now);
            return null;
        }
        login_lockout.clear(self.io, norm_email);
        return self.issueSession(allocator, row.email, row.admin, row.tenant_id) catch return error.InvalidCredentials;
    }

    fn issueSession(self: *UserService, allocator: std.mem.Allocator, email: []const u8, admin: bool, tenant_id: i64) !Session {
        const row_opt = try self.store.getUserByEmail(email);
        const row = row_opt orelse return error.InvalidCredentials;
        errdefer row.free(self.store.allocator);

        const id_str = try std.fmt.allocPrint(allocator, "{d}", .{row.id});
        defer allocator.free(id_str);
        const tenant_str = try std.fmt.allocPrint(allocator, "{d}", .{tenant_id});
        defer allocator.free(tenant_str);

        const roles = if (admin) &[_][]const u8{"admin"} else &[_][]const u8{"user"};
        const token = try self.sec.module.generateTokenWithTenantAndVersion(id_str, roles, tenant_str, row.token_version);
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
        defer row.free(self.store.allocator);
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

    /// Single write path for passwords (change, reset and the admin CLI
    /// bootstrap). Enforces the shared PasswordPolicy against the stored
    /// name/email before hashing.
    pub fn setPassword(self: *UserService, id: i64, password: []const u8) SetPasswordError!void {
        const row_opt = self.store.getUserById(id) catch return error.Unexpected;
        const row = row_opt orelse return error.UserNotFound;
        defer row.free(self.store.allocator);
        try self.policy.validate(password, row.email, row.name);
        const hash = self.sec.module.hashPassword(password) catch return error.Unexpected;
        defer self.sec.module.allocator.free(hash);
        const now = zigmodu.time.wallClockSeconds(self.io);
        self.store.setPasswordHash(id, hash, now) catch return error.Unexpected;
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
        defer row.free(self.store.allocator);

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
    pub fn validatePasswordResetToken(self: *UserService, user_id: i64, raw_token: []const u8) ResetTokenError!void {
        const tok_opt = self.store.getLatestPasswordToken(user_id) catch return error.InvalidToken;
        const tok = tok_opt orelse return error.InvalidToken;
        defer tok.free(self.store.allocator);

        const now = zigmodu.time.wallClockSeconds(self.io);
        if (now - tok.created_at > self.password_token_expiration_seconds) {
            // The token is dead — purge it (and any older siblings) now.
            self.store.deleteTokensForUser(user_id) catch {};
            return error.TokenExpired;
        }
        if (!self.sec.module.verifyPassword(raw_token, tok.token)) return error.InvalidToken;
    }

    /// Reset a password after a valid token; clears all their tokens.
    pub fn resetPassword(self: *UserService, user_id: i64, raw_token: []const u8, new_password: []const u8) ResetTokenError!void {
        // Token is validated first so an invalid link never leaks policy
        // details; the shared policy still runs through setPassword.
        try self.validatePasswordResetToken(user_id, raw_token);
        self.setPassword(user_id, new_password) catch |err| switch (err) {
            error.InvalidPassword => return error.InvalidPassword,
            error.PasswordTooShort => return error.PasswordTooShort,
            error.PasswordTooLong => return error.PasswordTooLong,
            error.PasswordTooCommon => return error.PasswordTooCommon,
            error.PasswordContainsIdentity => return error.PasswordContainsIdentity,
            error.UserNotFound, error.Unexpected => return error.InvalidToken,
        };
        self.store.deleteTokensForUser(user_id) catch return error.InvalidToken;
    }

    // ── Email verification ────────────────────────────────────────

    /// Create a verification token for the user and return the raw token
    /// (only its hash is stored). Returns null if the user does not exist.
    pub fn createEmailVerification(self: *UserService, allocator: std.mem.Allocator, user_id: i64) !?VerificationInfo {
        const row_opt = try self.store.getUserById(user_id);
        const row = row_opt orelse return null;
        defer row.free(self.store.allocator);
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
    pub fn verifyEmail(self: *UserService, user_id: i64, raw_token: []const u8) VerificationError!void {
        const tok_opt = self.store.getLatestEmailVerification(user_id) catch return error.InvalidToken;
        const tok = tok_opt orelse return error.InvalidToken;
        defer tok.free(self.store.allocator);

        const now = zigmodu.time.wallClockSeconds(self.io);
        if (now - tok.created_at > self.verification_token_expiration_seconds) {
            self.store.deleteEmailVerificationsForUser(user_id) catch {};
            return error.TokenExpired;
        }
        if (!self.sec.module.verifyPassword(raw_token, tok.token)) return error.InvalidToken;

        self.setVerified(user_id, true) catch return error.InvalidToken;
        self.store.deleteEmailVerificationsForUser(user_id) catch {};
    }

    /// Self-service password change: verify the current password, then apply
    /// the shared PasswordPolicy to the new one.
    pub fn changePassword(self: *UserService, id: i64, old_password: []const u8, new_password: []const u8) ChangePasswordError!void {
        if (new_password.len < 8) return error.InvalidPassword;
        const hash_opt = self.store.getPasswordHashById(id) catch return error.InvalidCredentials;
        const hash = hash_opt orelse return error.InvalidCredentials;
        defer self.sec.module.allocator.free(hash);
        if (!self.sec.module.verifyPassword(old_password, hash)) return error.InvalidCredentials;
        self.setPassword(id, new_password) catch |err| switch (err) {
            error.InvalidPassword => return error.InvalidPassword,
            error.PasswordTooShort => return error.PasswordTooShort,
            error.PasswordTooLong => return error.PasswordTooLong,
            error.PasswordTooCommon => return error.PasswordTooCommon,
            error.PasswordContainsIdentity => return error.PasswordContainsIdentity,
            error.UserNotFound, error.Unexpected => return error.InvalidPassword,
        };
        const now_s = zigmodu.time.wallClockSeconds(self.io);
        // 改密后必须 bump 凭证版本使旧 JWT 失效;失败不能静默吞掉。
        self.store.bumpTokenVersion(id, now_s) catch return error.TokenInvalidationFailed;
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
