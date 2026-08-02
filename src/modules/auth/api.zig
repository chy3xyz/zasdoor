//! Public auth HTTP API: register, login, logout, forgot/reset password,
//! and `me` (authenticated). Delegates to the user-domain service; keeps
//! mail delivery as a log-only skeleton (same posture as pagoda).

const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;
const mw = @import("../../middleware/auth.zig");
const rl = @import("../../middleware/rate_limit.zig");
const user_service = @import("../user/service.zig");

const RegisterReq = struct {
    name: []const u8,
    email: []const u8,
    password: []const u8,
};

const LoginReq = struct {
    email: []const u8,
    password: []const u8,
};

const ForgotPasswordReq = struct {
    email: []const u8,
};

const ResetPasswordReq = struct {
    user_id: i64,
    token: []const u8,
    new_password: []const u8,
};

const UserDto = struct {
    id: i64,
    name: []const u8,
    email: []const u8,
    verified: bool,
    admin: bool,
    created_at: i64,
    updated_at: i64,
};

fn toDto(row: user_service.UserRow) UserDto {
    return .{
        .id = row.id,
        .name = row.name,
        .email = row.email,
        .verified = row.verified,
        .admin = row.admin,
        .created_at = row.created_at,
        .updated_at = row.updated_at,
    };
}

pub fn AuthApi(comptime Service: type) type {
    return struct {
        const Self = @This();
        svc: *Service,
        app_host: []const u8,
        limiter: *zigmodu.RateLimiter,

        pub fn init(svc: *Service, app_host: []const u8, limiter: *zigmodu.RateLimiter) Self {
            return .{ .svc = svc, .app_host = app_host, .limiter = limiter };
        }

        pub fn registerRoutes(self: *Self, group: *http.RouteGroup) !void {
            // Public routes are rate-limited to blunt credential stuffing /
            // reset-token brute force; only `/auth/me` is protected by JWT.
            var limited = try group.use(rl.rateLimit(self.limiter));
            try limited.post("/auth/register", register, @ptrCast(@alignCast(self)));
            try limited.post("/auth/login", login, @ptrCast(@alignCast(self)));
            try limited.post("/auth/logout", logout, @ptrCast(@alignCast(self)));
            try limited.post("/auth/forgot-password", forgotPassword, @ptrCast(@alignCast(self)));
            try limited.post("/auth/reset-password", resetPassword, @ptrCast(@alignCast(self)));

            var g = try group.use(mw.jwtAuth(self.svc.sec));
            try g.get("/auth/me", me, @ptrCast(@alignCast(self)));
        }

        fn register(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const req = ctx.bindJson(RegisterReq) catch {
                try ctx.sendErrorResponse(400, 400, "请求体格式错误");
                return;
            };
            defer ctx.allocator.free(req.name);
            defer ctx.allocator.free(req.email);
            defer ctx.allocator.free(req.password);

            var session = self.svc.register(ctx.allocator, req.name, req.email, req.password, false) catch |err| switch (err) {
                error.InvalidName => {
                    try ctx.sendErrorResponse(400, 400, "姓名不能为空");
                    return;
                },
                error.InvalidEmail => {
                    try ctx.sendErrorResponse(400, 400, "邮箱格式不正确");
                    return;
                },
                error.InvalidPassword => {
                    try ctx.sendErrorResponse(400, 400, "密码至少 8 位");
                    return;
                },
                error.EmailTaken => {
                    try ctx.sendErrorResponse(409, 409, "该邮箱已被注册");
                    return;
                },
                error.Unexpected => {
                    try ctx.sendErrorResponse(500, 500, "服务器错误");
                    return;
                },
            };
            defer session.deinit(ctx.allocator);
            try ctx.jsonStruct(201, .{
                .code = 0,
                .msg = "注册成功",
                .data = .{
                    .token = session.token,
                    .user = toDto(session.row),
                },
            });
        }

        fn login(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const req = ctx.bindJson(LoginReq) catch {
                try ctx.sendErrorResponse(400, 400, "请求体格式错误");
                return;
            };
            defer ctx.allocator.free(req.email);
            defer ctx.allocator.free(req.password);

            const session_opt = self.svc.login(ctx.allocator, req.email, req.password) catch |err| switch (err) {
                error.InvalidCredentials => {
                    try ctx.sendErrorResponse(401, 401, "邮箱或密码错误");
                    return;
                },
            };
            const session = session_opt orelse {
                try ctx.sendErrorResponse(401, 401, "邮箱或密码错误");
                return;
            };
            defer session.deinit(ctx.allocator);
            try ctx.jsonStruct(200, .{
                .code = 0,
                .msg = "登录成功",
                .data = .{
                    .token = session.token,
                    .user = toDto(session.row),
                },
            });
        }

        /// Stateless JWT: logout is a client-side token discard. Responds ok
        /// so the SPA can always complete the flow.
        fn logout(ctx: *http.Context) !void {
            _ = ctx.user_data;
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "ok", .data = null });
        }

        fn me(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const uid = mw.authUserId(ctx) orelse {
                try ctx.sendErrorResponse(401, 401, "未登录或登录已过期");
                return;
            };
            const row_opt = self.svc.getUserById(uid) catch |err| {
                try ctx.sendErrorResponse(500, 500, @errorName(err));
                return;
            };
            const row = row_opt orelse {
                try ctx.sendErrorResponse(401, 401, "用户不存在");
                return;
            };
            defer row.free(ctx.allocator);
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "", .data = toDto(row) });
        }

        fn forgotPassword(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const req = ctx.bindJson(ForgotPasswordReq) catch {
                try ctx.sendErrorResponse(400, 400, "请求体格式错误");
                return;
            };
            defer ctx.allocator.free(req.email);

            const raw_opt = self.svc.createPasswordResetToken(ctx.allocator, req.email) catch {
                try ctx.sendErrorResponse(500, 500, "服务器错误");
                return;
            };
            if (raw_opt) |raw| {
                defer ctx.allocator.free(raw.raw);
                std.log.info("[mail-skeleton] password reset link for {s}: {s}/reset-password?user_id={d}&token={s}", .{ req.email, self.app_host, raw.user_id, raw.raw });
            }
            // Always respond ok to avoid user enumeration.
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "若该邮箱已注册，重置链接已发送", .data = null });
        }

        fn resetPassword(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const req = ctx.bindJson(ResetPasswordReq) catch {
                try ctx.sendErrorResponse(400, 400, "请求体格式错误");
                return;
            };
            defer ctx.allocator.free(req.token);
            defer ctx.allocator.free(req.new_password);

            self.svc.resetPassword(ctx.allocator, req.user_id, req.token, req.new_password) catch |err| switch (err) {
                error.InvalidPassword => {
                    try ctx.sendErrorResponse(400, 400, "密码至少 8 位");
                    return;
                },
                error.InvalidToken => {
                    try ctx.sendErrorResponse(400, 400, "重置链接无效");
                    return;
                },
                error.TokenExpired => {
                    try ctx.sendErrorResponse(400, 400, "重置链接已过期");
                    return;
                },
            };
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "密码已重置，请重新登录", .data = null });
        }
    };
}

pub const DefaultAuthApi = AuthApi(user_service.UserService);
