//! Persistence over the zent Client — all SQL lives in zent builders.
//!
//! Results are duped into plain DTOs (`UserRow`, `PasswordTokenRow`) so the
//! zent entity lifecycle never leaks past this boundary.

const std = @import("std");
const zent = @import("zent");
const model = @import("model.zig");
const schema = @import("../../schema.zig");

const graph = zent.codegen.graph.buildGraph(&.{ model.User, model.PasswordToken, model.EmailVerification });
pub const infos = graph.types;
/// Shared, application-wide typed client (all schemas registered in schema.zig).
pub const Client = schema.Client;
pub const UserInfo = infos[0];
pub const PasswordTokenInfo = infos[1];
pub const EmailVerificationInfo = infos[2];

pub const UserRow = struct {
    id: i64,
    name: []const u8,
    email: []const u8,
    verified: bool,
    admin: bool,
    created_at: i64,
    updated_at: i64,

    pub fn free(self: UserRow, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.email);
    }
};

pub const PasswordTokenRow = struct {
    id: i64,
    user_id: i64,
    token: []const u8,
    created_at: i64,

    pub fn free(self: PasswordTokenRow, allocator: std.mem.Allocator) void {
        allocator.free(self.token);
    }
};

pub const UserListResult = struct {
    items: []UserRow,
    total: i64,

    pub fn free(self: *UserListResult, allocator: std.mem.Allocator) void {
        for (self.items) |r| r.free(allocator);
        allocator.free(self.items);
    }
};

pub const UserStore = struct {
    allocator: std.mem.Allocator,
    client: Client,

    pub fn init(allocator: std.mem.Allocator, client: Client) UserStore {
        return .{ .allocator = allocator, .client = client };
    }

    fn dupUser(self: *UserStore, e: anytype) !UserRow {
        const name = try self.allocator.dupe(u8, e.name);
        errdefer self.allocator.free(name);
        const email = try self.allocator.dupe(u8, e.email);
        errdefer self.allocator.free(email);
        return .{
            .id = e.id,
            .name = name,
            .email = email,
            .verified = e.verified,
            .admin = e.admin,
            .created_at = e.created_at orelse 0,
            .updated_at = e.updated_at orelse 0,
        };
    }

    /// Create a user. Returns the new row id.
    pub fn createUser(
        self: *UserStore,
        name: []const u8,
        email: []const u8,
        password_hash: []const u8,
        verified: bool,
        admin: bool,
        now: i64,
    ) !i64 {
        var b = try self.client.user.Create();
        defer b.deinit();
        _ = try b.setFieldValue("name", name);
        _ = try b.setFieldValue("email", email);
        _ = try b.setFieldValue("password", password_hash);
        _ = try b.setFieldValue("verified", verified);
        _ = try b.setFieldValue("admin", admin);
        _ = try b.setFieldValue("created_at", now);
        _ = try b.setFieldValue("updated_at", now);
        var row = try b.Save();
        defer zent.codegen.deinitEntity(infos, UserInfo, &row, self.allocator);
        return row.id;
    }

    pub fn getUserById(self: *UserStore, id: i64) !?UserRow {
        var q = self.client.user.Query();
        defer q.deinit();
        const preds = self.client.user.predicates;
        _ = try q.Where(.{preds.idEQ(.{ .int = id })});
        const entity_opt = try q.First();
        var entity = entity_opt orelse return null;
        defer zent.codegen.deinitEntity(infos, UserInfo, &entity, self.allocator);
        return try self.dupUser(entity);
    }

    pub fn getUserByEmail(self: *UserStore, email: []const u8) !?UserRow {
        var q = self.client.user.Query();
        defer q.deinit();
        const preds = self.client.user.predicates;
        _ = try q.Where(.{preds.emailEQ(.{ .string = email })});
        const entity_opt = try q.First();
        var entity = entity_opt orelse return null;
        defer zent.codegen.deinitEntity(infos, UserInfo, &entity, self.allocator);
        return try self.dupUser(entity);
    }

    /// Fetch the stored password hash for a user (sensitive field is not in UserRow).
    pub fn getPasswordHashById(self: *UserStore, id: i64) !?[]const u8 {
        var q = self.client.user.Query();
        defer q.deinit();
        const preds = self.client.user.predicates;
        _ = try q.Where(.{preds.idEQ(.{ .int = id })});
        const entity_opt = try q.First();
        var entity = entity_opt orelse return null;
        defer zent.codegen.deinitEntity(infos, UserInfo, &entity, self.allocator);
        return try self.allocator.dupe(u8, entity.password);
    }

    pub fn listUsers(self: *UserStore, page: usize, page_size: usize, keyword: ?[]const u8) !UserListResult {
        const preds = self.client.user.predicates;

        // Build the keyword predicate once; zent's LIKE is exact-match, so
        // wrap the term in % wildcards for substring search.
        const pattern_opt = if (keyword) |kw|
            if (kw.len > 0) try std.fmt.allocPrint(self.allocator, "%{s}%", .{kw}) else null
        else
            null;
        defer if (pattern_opt) |p| self.allocator.free(p);
        const or_pred = if (pattern_opt) |pat| blk: {
            const p1 = preds.nameContains(pat);
            const p2 = preds.emailContains(pat);
            break :blk zent.sql.Or(&p1, &p2);
        } else null;

        // Count
        var count_q = self.client.user.Query();
        defer count_q.deinit();
        if (or_pred) |op| {
            _ = try count_q.Where(.{op});
        }
        const total: i64 = @intCast(try count_q.Count());

        // Page
        var q = self.client.user.Query();
        defer q.deinit();
        if (or_pred) |op| {
            _ = try q.Where(.{op});
        }
        if (page_size > 0) {
            _ = q.Limit(page_size);
            if (page > 1) _ = q.Offset((page - 1) * page_size);
        }
        _ = try q.OrderBy(&[_]zent.sql.Order{zent.sql.OrderAsc("email")});
        var found = try q.All();
        defer {
            for (found.items) |*e| {
                zent.codegen.deinitEntity(infos, UserInfo, e, self.allocator);
            }
            found.deinit();
        }

        var out = try self.allocator.alloc(UserRow, found.items.len);
        errdefer self.allocator.free(out);
        var n: usize = 0;
        for (found.items) |e| {
            out[n] = try self.dupUser(e);
            n += 1;
        }
        return .{ .items = out[0..n], .total = total };
    }

    /// Update a user's name/email/profile fields. Sensitive updates are
    /// separate methods.
    pub fn updateProfile(self: *UserStore, id: i64, name: []const u8, email: []const u8, now: i64) !void {
        var upd = self.client.user.Update();
        defer upd.deinit();
        _ = try upd.set("name", .{ .string = name });
        _ = try upd.set("email", .{ .string = email });
        _ = try upd.setFieldValue("updated_at", now);
        const preds = self.client.user.predicates;
        _ = try upd.Where(.{preds.idEQ(.{ .int = id })});
        _ = try upd.Save();
    }

    pub fn setVerified(self: *UserStore, id: i64, verified: bool, now: i64) !void {
        var upd = self.client.user.Update();
        defer upd.deinit();
        _ = try upd.setFieldValue("verified", verified);
        _ = try upd.setFieldValue("updated_at", now);
        const preds = self.client.user.predicates;
        _ = try upd.Where(.{preds.idEQ(.{ .int = id })});
        _ = try upd.Save();
    }

    pub fn setAdmin(self: *UserStore, id: i64, admin: bool, now: i64) !void {
        var upd = self.client.user.Update();
        defer upd.deinit();
        _ = try upd.setFieldValue("admin", admin);
        _ = try upd.setFieldValue("updated_at", now);
        const preds = self.client.user.predicates;
        _ = try upd.Where(.{preds.idEQ(.{ .int = id })});
        _ = try upd.Save();
    }

    pub fn setPasswordHash(self: *UserStore, id: i64, password_hash: []const u8, now: i64) !void {
        var upd = self.client.user.Update();
        defer upd.deinit();
        _ = try upd.set("password", .{ .string = password_hash });
        _ = try upd.setFieldValue("updated_at", now);
        const preds = self.client.user.predicates;
        _ = try upd.Where(.{preds.idEQ(.{ .int = id })});
        _ = try upd.Save();
    }

    pub fn freeList(self: *UserStore, result: *UserListResult) void {
        result.free(self.allocator);
    }

    pub fn deleteUser(self: *UserStore, id: i64) !void {
        const preds = self.client.user.predicates;
        var d = self.client.user.Delete();
        defer d.deinit();
        _ = try d.Where(.{preds.idEQ(.{ .int = id })});
        _ = try d.Exec();
    }

    // ── PasswordToken ──────────────────────────────────────────────

    pub fn createPasswordToken(self: *UserStore, user_id: i64, token_hash: []const u8, now: i64) !i64 {
        var b = try self.client.password_token.Create();
        defer b.deinit();
        _ = try b.setFieldValue("user_id", user_id);
        _ = try b.setFieldValue("token", token_hash);
        _ = try b.setFieldValue("created_at", now);
        var row = try b.Save();
        defer zent.codegen.deinitEntity(infos, PasswordTokenInfo, &row, self.allocator);
        return row.id;
    }

    /// Delete tokens for `user_id` older than `max_age` seconds. Keeps the
    /// table bounded: forgot-password no longer grows it without bound.
    pub fn deleteExpiredPasswordTokens(self: *UserStore, user_id: i64, now: i64, max_age: i64) !void {
        const preds = self.client.password_token.predicates;
        const cutoff = now - max_age;
        var d = self.client.password_token.Delete();
        defer d.deinit();
        _ = try d.Where(.{preds.user_idEQ(.{ .int = user_id })});
        _ = try d.Where(.{preds.created_atLT(.{ .int = cutoff })});
        _ = try d.Exec();
    }

    /// Find the most recent password token for a user, if any.
    pub fn getLatestPasswordToken(self: *UserStore, user_id: i64) !?PasswordTokenRow {
        var q = self.client.password_token.Query();
        defer q.deinit();
        const preds = self.client.password_token.predicates;
        _ = try q.Where(.{preds.user_idEQ(.{ .int = user_id })});
        _ = try q.OrderBy(&[_]zent.sql.Order{.{ .column = .{ .name = "created_at", .desc = true } }});
        _ = q.Limit(1);
        const entity_opt = try q.First();
        var entity = entity_opt orelse return null;
        defer zent.codegen.deinitEntity(infos, PasswordTokenInfo, &entity, self.allocator);
        const token_dup = try self.allocator.dupe(u8, entity.token);
        return .{
            .id = entity.id,
            .user_id = entity.user_id,
            .token = token_dup,
            .created_at = entity.created_at orelse 0,
        };
    }

    pub fn deleteTokensForUser(self: *UserStore, user_id: i64) !void {
        const preds = self.client.password_token.predicates;
        var d = self.client.password_token.Delete();
        defer d.deinit();
        _ = try d.Where(.{preds.user_idEQ(.{ .int = user_id })});
        _ = try d.Exec();
    }

    // ── EmailVerification ─────────────────────────────────────────

    pub fn createEmailVerification(self: *UserStore, user_id: i64, token_hash: []const u8, now: i64) !i64 {
        var b = try self.client.email_verification.Create();
        defer b.deinit();
        _ = try b.setFieldValue("user_id", user_id);
        _ = try b.setFieldValue("token", token_hash);
        _ = try b.setFieldValue("created_at", now);
        var row = try b.Save();
        defer zent.codegen.deinitEntity(infos, EmailVerificationInfo, &row, self.allocator);
        return row.id;
    }

    pub const EmailVerificationRow = struct {
        id: i64,
        user_id: i64,
        token: []const u8,
        created_at: i64,

        pub fn free(self: EmailVerificationRow, allocator: std.mem.Allocator) void {
            allocator.free(self.token);
        }
    };

    pub fn getLatestEmailVerification(self: *UserStore, user_id: i64) !?EmailVerificationRow {
        var q = self.client.email_verification.Query();
        defer q.deinit();
        const preds = self.client.email_verification.predicates;
        _ = try q.Where(.{preds.user_idEQ(.{ .int = user_id })});
        _ = try q.OrderBy(&[_]zent.sql.Order{.{ .column = .{ .name = "created_at", .desc = true } }});
        _ = q.Limit(1);
        const entity_opt = try q.First();
        var entity = entity_opt orelse return null;
        defer zent.codegen.deinitEntity(infos, EmailVerificationInfo, &entity, self.allocator);
        const token_dup = try self.allocator.dupe(u8, entity.token);
        return .{
            .id = entity.id,
            .user_id = entity.user_id,
            .token = token_dup,
            .created_at = entity.created_at orelse 0,
        };
    }

    pub fn deleteEmailVerificationsForUser(self: *UserStore, user_id: i64) !void {
        const preds = self.client.email_verification.predicates;
        var d = self.client.email_verification.Delete();
        defer d.deinit();
        _ = try d.Where(.{preds.user_idEQ(.{ .int = user_id })});
        _ = try d.Exec();
    }

    pub fn deleteExpiredEmailVerifications(self: *UserStore, user_id: i64, now: i64, max_age: i64) !void {
        const preds = self.client.email_verification.predicates;
        const cutoff = now - max_age;
        var d = self.client.email_verification.Delete();
        defer d.deinit();
        _ = try d.Where(.{preds.user_idEQ(.{ .int = user_id })});
        _ = try d.Where(.{preds.created_atLT(.{ .int = cutoff })});
        _ = try d.Exec();
    }

    /// Global sweep (cron): remove every expired password-reset token.
    pub fn purgeExpiredPasswordTokens(self: *UserStore, now: i64, max_age: i64) !usize {
        const preds = self.client.password_token.predicates;
        const cutoff = now - max_age;
        var d = self.client.password_token.Delete();
        defer d.deinit();
        _ = try d.Where(.{preds.created_atLT(.{ .int = cutoff })});
        _ = try d.Exec();
        return 0;
    }

    /// Global sweep (cron): remove every expired email-verification token.
    pub fn purgeExpiredEmailVerifications(self: *UserStore, now: i64, max_age: i64) !usize {
        const preds = self.client.email_verification.predicates;
        const cutoff = now - max_age;
        var d = self.client.email_verification.Delete();
        defer d.deinit();
        _ = try d.Where(.{preds.created_atLT(.{ .int = cutoff })});
        _ = try d.Exec();
        return 0;
    }
};
