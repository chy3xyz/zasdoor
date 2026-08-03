//! Admin-facing HTTP API for the user domain. All routes require a valid
//! JWT and an `admin` role (checked against the DB, not the token claim).

const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;
const mw = @import("../../middleware/auth.zig");
const service = @import("service.zig");

const UserRow = service.UserRow;

const UserDto = struct {
    id: i64,
    name: []const u8,
    email: []const u8,
    verified: bool,
    admin: bool,
    tenant_id: i64,
    created_at: i64,
    updated_at: i64,
};

fn toDto(row: UserRow) UserDto {
    return .{
        .id = row.id,
        .name = row.name,
        .email = row.email,
        .verified = row.verified,
        .admin = row.admin,
        .tenant_id = row.tenant_id,
        .created_at = row.created_at,
        .updated_at = row.updated_at,
    };
}

const CreateUserReq = struct {
    name: []const u8,
    email: []const u8,
    password: []const u8,
    admin: ?bool = null,
    tenant_id: ?i64 = null,
};

const UpdateUserReq = struct {
    name: ?[]const u8 = null,
    email: ?[]const u8 = null,
    verified: ?bool = null,
    admin: ?bool = null,
};

pub fn UserApi(comptime Service: type) type {
    return struct {
        const Self = @This();
        svc: *Service,
        default_tenant_id: i64,

        pub fn init(svc: *Service, default_tenant_id: i64) Self {
            return .{ .svc = svc, .default_tenant_id = default_tenant_id };
        }

        pub fn registerRoutes(self: *Self, group: *http.RouteGroup) !void {
            var g = try group.use(mw.jwtAuth(self.svc.sec));
            try g.get("/users", listUsers, @ptrCast(@alignCast(self)));
            try g.get("/users/{id}", getUser, @ptrCast(@alignCast(self)));
            try g.post("/users", createUser, @ptrCast(@alignCast(self)));
            try g.put("/users/{id}", updateUser, @ptrCast(@alignCast(self)));
            try g.delete("/users/{id}", deleteUser, @ptrCast(@alignCast(self)));
        }

        /// Returns the authenticated admin user id, or null after responding.
        fn requireAdmin(ctx: *http.Context, self: *Self) !?i64 {
            const uid = mw.authUserId(ctx) orelse {
                try ctx.sendErrorResponse(401, 401, "未登录或登录已过期");
                return null;
            };
            const row_opt = self.svc.getUserById(uid) catch {
                try ctx.sendErrorResponse(401, 401, "未登录或登录已过期");
                return null;
            };
            const row = row_opt orelse {
                try ctx.sendErrorResponse(401, 401, "未登录或登录已过期");
                return null;
            };
            defer row.free(ctx.allocator);
            if (!row.admin) {
                try ctx.sendErrorResponse(403, 403, "需要管理员权限");
                return null;
            }
            return uid;
        }

        fn listUsers(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const admin_id = (try requireAdmin(ctx, self)) orelse return;
            _ = admin_id;

            const params = zigmodu.http.PageParams.parse(ctx, .{ .max_page_size = 100 });
            const keyword_raw = ctx.queryParam("keyword");
            const tenant_query = ctx.queryInt(i64, "tenant_id", 0);
            const tenant_filter: ?i64 = if (tenant_query > 0) tenant_query else null;

            // zigmodu does not percent-decode query values; decode for
            // non-ASCII (e.g. CJK) searches.
            var keyword_decoded: ?[]u8 = null;
            defer if (keyword_decoded) |d| ctx.allocator.free(d);
            if (keyword_raw) |kw| {
                if (kw.len > 0) {
                    if (ctx.allocator.dupe(u8, kw)) |buf| {
                        keyword_decoded = std.Uri.percentDecodeInPlace(buf);
                    } else |_| {}
                }
            }

            var result = self.svc.listUsers(params.page, params.page_size, keyword_decoded, tenant_filter) catch |err| {
                try ctx.sendErrorResponse(500, 500, @errorName(err));
                return;
            };
            defer self.svc.freeList(&result);

            const dtos = try zigmodu.http.Extract.toDtoList(ctx.allocator, result.items, UserDto, toDto);
            try zigmodu.http.sendPaged(ctx, dtos, @intCast(result.total), params, .ruoyi);
        }

        fn getUser(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const admin_id = (try requireAdmin(ctx, self)) orelse return;
            _ = admin_id;

            const id = ctx.paramInt(i64, "id") catch {
                try ctx.sendErrorResponse(400, 400, "无效的用户 ID");
                return;
            };
            const row_opt = self.svc.getUserById(id) catch |err| {
                try ctx.sendErrorResponse(500, 500, @errorName(err));
                return;
            };
            const row = row_opt orelse {
                try ctx.sendErrorResponse(404, 404, "用户不存在");
                return;
            };
            defer row.free(ctx.allocator);
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "", .data = toDto(row) });
        }

        fn createUser(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const admin_id = (try requireAdmin(ctx, self)) orelse return;
            _ = admin_id;

            const req = ctx.bindJson(CreateUserReq) catch {
                try ctx.sendErrorResponse(400, 400, "请求体格式错误");
                return;
            };
            defer ctx.allocator.free(req.name);
            defer ctx.allocator.free(req.email);
            defer ctx.allocator.free(req.password);

            const is_admin = req.admin orelse false;
            const tenant_id = req.tenant_id orelse self.default_tenant_id;
            var session = self.svc.register(ctx.allocator, req.name, req.email, req.password, is_admin, tenant_id) catch |err| {
                try sendCreateError(ctx, err);
                return;
            };
            defer session.deinit(ctx.allocator);

            try ctx.jsonStruct(201, .{
                .code = 0,
                .msg = "",
                .data = .{
                    .id = session.row.id,
                    .token = session.token,
                },
            });
        }

        fn updateUser(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const admin_id = (try requireAdmin(ctx, self)) orelse return;

            const id = ctx.paramInt(i64, "id") catch {
                try ctx.sendErrorResponse(400, 400, "无效的用户 ID");
                return;
            };
            const req = ctx.bindJson(UpdateUserReq) catch {
                try ctx.sendErrorResponse(400, 400, "请求体格式错误");
                return;
            };
            defer {
                if (req.name) |n| ctx.allocator.free(n);
                if (req.email) |e| ctx.allocator.free(e);
            }

            // An admin cannot demote themselves or revoke their own verified
            // flag — otherwise the last admin could lock everyone out.
            if (id == admin_id) {
                if (req.admin) |a| if (!a) {
                    try ctx.sendErrorResponse(400, 400, "不能取消自己的管理员权限");
                    return;
                };
                if (req.verified) |v| if (!v) {
                    try ctx.sendErrorResponse(400, 400, "不能取消自己的已验证状态");
                    return;
                };
            }

            // Name/email update is optional and independent: missing fields
            // keep the current stored values.
            if (req.name != null or req.email != null) {
                const cur_opt = self.svc.getUserById(id) catch |err| {
                    try ctx.sendErrorResponse(500, 500, @errorName(err));
                    return;
                };
                const cur = cur_opt orelse {
                    try ctx.sendErrorResponse(404, 404, "用户不存在");
                    return;
                };
                defer cur.free(ctx.allocator);

                if (req.email) |new_email| {
                    const taken = self.svc.emailTakenByOther(ctx.allocator, id, new_email) catch {
                        try ctx.sendErrorResponse(500, 500, "服务器错误");
                        return;
                    };
                    if (taken) {
                        try ctx.sendErrorResponse(409, 409, "该邮箱已被其他用户使用");
                        return;
                    }
                }

                self.svc.updateProfile(id, req.name orelse cur.name, req.email orelse cur.email) catch |err| {
                    try sendUpdateError(ctx, err);
                    return;
                };
            }
            if (req.verified) |v| {
                self.svc.setVerified(id, v) catch |err| {
                    try ctx.sendErrorResponse(500, 500, @errorName(err));
                    return;
                };
            }
            if (req.admin) |a| {
                self.svc.setAdmin(id, a) catch |err| {
                    try ctx.sendErrorResponse(500, 500, @errorName(err));
                    return;
                };
            }
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "ok", .data = null });
        }

        fn deleteUser(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const admin_id = (try requireAdmin(ctx, self)) orelse return;

            const id = ctx.paramInt(i64, "id") catch {
                try ctx.sendErrorResponse(400, 400, "无效的用户 ID");
                return;
            };
            if (id == admin_id) {
                try ctx.sendErrorResponse(400, 400, "不能删除当前登录账号");
                return;
            }
            self.svc.deleteUser(id) catch |err| {
                try ctx.sendErrorResponse(500, 500, @errorName(err));
                return;
            };
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "ok", .data = null });
        }

        fn sendCreateError(ctx: *http.Context, err: anyerror) !void {
            switch (err) {
                error.InvalidName => try ctx.sendErrorResponse(400, 400, "姓名不能为空"),
                error.InvalidEmail => try ctx.sendErrorResponse(400, 400, "邮箱格式不正确"),
                error.InvalidPassword => try ctx.sendErrorResponse(400, 400, "密码至少 8 位"),
                error.EmailTaken => try ctx.sendErrorResponse(409, 409, "该邮箱已被注册"),
                else => try ctx.sendErrorResponse(500, 500, @errorName(err)),
            }
        }

        fn sendUpdateError(ctx: *http.Context, err: anyerror) !void {
            switch (err) {
                error.InvalidName => try ctx.sendErrorResponse(400, 400, "姓名不能为空"),
                error.InvalidEmail => try ctx.sendErrorResponse(400, 400, "邮箱格式不正确"),
                else => try ctx.sendErrorResponse(500, 500, @errorName(err)),
            }
        }
    };
}

pub const DefaultUserApi = UserApi(service.UserService);
