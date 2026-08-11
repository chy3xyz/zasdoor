//! Persistence over the zent Client — all SQL lives in zent builders.
//!
//! Results are duped into plain DTOs (`UserRow`, `PasswordTokenRow`) so the
//! zent entity lifecycle never leaks past this boundary.

const std = @import("std");
const zent = @import("zent");
const crud = zent.crud_helpers;
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
    tenant_id: i64,
    token_version: i64,
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
            .tenant_id = e.tenant_id,
            .token_version = e.token_version,
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
        tenant_id: i64,
        now: i64,
    ) !i64 {
        var b = try self.client.user.Create();
        defer b.deinit();
        _ = try b.setFieldValue("name", name);
        _ = try b.setFieldValue("email", email);
        _ = try b.setFieldValue("password", password_hash);
        _ = try b.setFieldValue("verified", verified);
        _ = try b.setFieldValue("admin", admin);
        _ = try b.setFieldValue("tenant_id", tenant_id);
        _ = try b.setFieldValue("created_at", now);
        _ = try b.setFieldValue("updated_at", now);
        var row = try b.Save();
        defer zent.codegen.deinitEntity(infos, UserInfo, &row, self.allocator);
        return row.id;
    }

    /// zent.crud_helpers.get — 按主键查单行,生命周期由 helper 处理。
    pub fn getUserById(self: *UserStore, id: i64) !?UserRow {
        var entity = (try crud.get(self.client.user, id)) orelse return null;
        defer zent.codegen.deinitEntity(infos, UserInfo, &entity, self.allocator);
        return try self.dupUser(entity);
    }

    pub fn getUserByEmail(self: *UserStore, email: []const u8) !?UserRow {
        const preds = self.client.user.predicates;
        var entity = (try crud.first(self.client.user, .{preds.emailEQ(.{ .string = email })})) orelse return null;
        defer zent.codegen.deinitEntity(infos, UserInfo, &entity, self.allocator);
        return try self.dupUser(entity);
    }

    /// Fetch the stored password hash for a user (sensitive field is not in UserRow).
    pub fn getPasswordHashById(self: *UserStore, id: i64) !?[]const u8 {
        var entity = (try crud.get(self.client.user, id)) orelse return null;
        defer zent.codegen.deinitEntity(infos, UserInfo, &entity, self.allocator);
        return try self.allocator.dupe(u8, entity.password);
    }

    pub fn listUsers(self: *UserStore, page: usize, page_size: usize, keyword: ?[]const u8, tenant_id: ?i64, sort_col: ?[]const u8, sort_desc: bool) !UserListResult {
        var q = self.client.user.Query();
        defer q.deinit();
        const preds = self.client.user.predicates;
        if (tenant_id) |tid| _ = try q.Where(.{preds.tenant_idEQ(.{ .int = tid })});
        // ContainsEscaped renders LIKE '%…%' with wildcard/quote escaping —
        // user input stays literal, no temporary pattern allocation needed.
        if (keyword) |kw| {
            if (kw.len > 0) {
                const p1 = preds.nameContainsEscaped(kw);
                const p2 = preds.emailContainsEscaped(kw);
                _ = try q.Where(.{zent.sql.Or(&p1, &p2)});
            }
        }
        const order: zent.sql.Order = if (sort_col) |col| blk: {
            // Column whitelist — never interpolate caller input directly.
            if (!(std.mem.eql(u8, col, "name") or std.mem.eql(u8, col, "email") or std.mem.eql(u8, col, "created_at")))
                break :blk zent.sql.OrderAsc("email");
            break :blk if (sort_desc) zent.sql.OrderDesc(col) else zent.sql.OrderAsc(col);
        } else zent.sql.OrderAsc("email");
        _ = try q.OrderBy(&.{order});

        // One call: count + limit/offset + entity release (zent paged()).
        var paged = try q.paged(page, page_size);
        defer paged.deinit();

        var out = try self.allocator.alloc(UserRow, paged.items.items.len);
        var n: usize = 0;
        errdefer {
            for (out[0..n]) |r| r.free(self.allocator);
            self.allocator.free(out);
        }
        for (paged.items.items) |e| {
            out[n] = try self.dupUser(e);
            n += 1;
        }
        return .{ .items = out, .total = paged.total };
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
    /// Total user count (dashboard stats).
    pub fn countAll(self: *UserStore) !i64 {
        return @intCast(try crud.count(self.client.user, .{}));
    }

    /// Users registered in [start, end) — dashboard daily trend buckets.
    pub fn countRegisteredBetween(self: *UserStore, start: i64, end: i64) !i64 {
        const preds = self.client.user.predicates;
        return @intCast(try crud.count(self.client.user, .{
            preds.created_atGTE(.{ .int = start }),
            preds.created_atLT(.{ .int = end }),
        }));
    }

    /// 递增凭证版本(改密/踢下线),使之前签发的 JWT 全部失效。
    pub fn bumpTokenVersion(self: *UserStore, id: i64, now: i64) !void {
        const preds = self.client.user.predicates;
        const cur = (try self.getUserById(id)) orelse return error.UserNotFound;
        defer cur.free(self.allocator);
        var upd = self.client.user.Update();
        defer upd.deinit();
        _ = try upd.setFieldValue("token_version", cur.token_version + 1);
        _ = try upd.setFieldValue("updated_at", now);
        _ = try upd.Where(.{preds.idEQ(.{ .int = id })});
        _ = try upd.Save();
    }
};
