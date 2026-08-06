//! Public + authenticated auth HTTP API: register, login, logout,
//! forgot/reset password, email verification, `me`, profile and password
//! management. Delegates to the user-domain service; mail delivery goes
//! through the shared Mailer (console sink in dev, SMTP in prod).

const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;
const mw = @import("../../middleware/auth.zig");
const user_service = @import("../user/service.zig");
const task_service = @import("../task/service.zig");
const notify_service = @import("../notify/service.zig");
const mail = @import("../../services/mail.zig");
const audit_svc = @import("../audit/service.zig");
const mail_template_svc = @import("../mail_template/service.zig");

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

const VerifyEmailReq = struct {
    user_id: i64,
    token: []const u8,
};

const SendVerificationReq = struct {};

const UpdateProfileReq = struct {
    name: ?[]const u8 = null,
    email: ?[]const u8 = null,
};

const ChangePasswordReq = struct {
    old_password: []const u8,
    new_password: []const u8,
};

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

fn toDto(row: user_service.UserRow) UserDto {
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

pub fn AuthApi(comptime Service: type) type {
    return struct {
        const Self = @This();
        svc: *Service,
        app_host: []const u8,
        registry: *zigmodu.RateLimiterRegistry,
        mailer: *const mail.Mailer,
        task_svc: *task_service.TaskService,
        notify_svc: *notify_service.NotificationService,
        audit: *audit_svc.AuditService,
        templates: *mail_template_svc.MailTemplateService,
        default_tenant_id: i64,

        pub fn init(
            svc: *Service,
            app_host: []const u8,
            registry: *zigmodu.RateLimiterRegistry,
            mailer: *const mail.Mailer,
            task_svc: *task_service.TaskService,
            notify_svc: *notify_service.NotificationService,
            audit: *audit_svc.AuditService,
            templates: *mail_template_svc.MailTemplateService,
            default_tenant_id: i64,
        ) Self {
            return .{
                .svc = svc,
                .app_host = app_host,
                .registry = registry,
                .mailer = mailer,
                .task_svc = task_svc,
                .notify_svc = notify_svc,
                .audit = audit,
                .templates = templates,
                .default_tenant_id = default_tenant_id,
            };
        }

        pub fn registerRoutes(self: *Self, group: *http.RouteGroup) !void {
            // Public routes are rate-limited to blunt credential stuffing /
            // reset-token brute force.
            // per-IP 限流(攻击者无法耗尽全局桶误伤他人)。
            var limited = try group.use(zigmodu.http.tracing_middleware.rateLimitPerClient(self.registry, clientIpKey));
            try limited.post("/auth/register", register, @ptrCast(@alignCast(self)));
            try limited.post("/auth/login", login, @ptrCast(@alignCast(self)));
            try limited.post("/auth/logout", logout, @ptrCast(@alignCast(self)));
            try limited.post("/auth/forgot-password", forgotPassword, @ptrCast(@alignCast(self)));
            try limited.post("/auth/reset-password", resetPassword, @ptrCast(@alignCast(self)));
            try limited.post("/auth/verify-email", verifyEmail, @ptrCast(@alignCast(self)));

            var g = try group.use(zigmodu.http.http_middleware.jwtAuthWithSecurity(&self.svc.sec.module));
            g = try g.use(mw.tokenVersionGuard(self.svc.sec, self.svc.store));            try g.get("/auth/me", me, @ptrCast(@alignCast(self)));
            try g.post("/auth/send-verification", sendVerification, @ptrCast(@alignCast(self)));
            try g.put("/auth/profile", updateProfile, @ptrCast(@alignCast(self)));
            try g.put("/auth/password", changePassword, @ptrCast(@alignCast(self)));
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

            const tenant_id = parseTenantHeader(ctx) orelse self.default_tenant_id;
            var session = self.svc.register(ctx.allocator, req.name, req.email, req.password, false, tenant_id) catch |err| switch (err) {
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
            defer session.deinit(self.svc.store.allocator);
            // Email verification is a background courtesy: never block the
            // registration response on mail delivery.
            if (!session.row.verified) self.sendVerificationMail(ctx, session.row.id);
            var d1: [128]u8 = undefined;
            const det1 = try std.fmt.bufPrint(&d1, "注册账号 {s}", .{req.email});
            self.audit.log(session.row.id, session.row.name, "auth.register", "user", session.row.id, det1, zigmodu.http.RequestUtil.getRealIp(ctx), true, tenant_id);
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
                    var d2: [160]u8 = undefined;
                    const det2 = try std.fmt.bufPrint(&d2, "登录失败: {s}", .{req.email});
                    self.audit.log(0, "", "auth.login.fail", "user", 0, det2, zigmodu.http.RequestUtil.getRealIp(ctx), false, 0);
                    try ctx.sendErrorResponse(401, 401, "邮箱或密码错误");
                    return;
                },
            };
            const session = session_opt orelse {
                var d3: [160]u8 = undefined;
                const det3 = try std.fmt.bufPrint(&d3, "登录失败: {s}", .{req.email});
                self.audit.log(0, "", "auth.login.fail", "user", 0, det3, zigmodu.http.RequestUtil.getRealIp(ctx), false, 0);
                try ctx.sendErrorResponse(401, 401, "邮箱或密码错误");
                return;
            };
            defer session.deinit(self.svc.store.allocator);
            var d4: [128]u8 = undefined;
            const det4 = try std.fmt.bufPrint(&d4, "登录成功: {s}", .{req.email});
            self.audit.log(session.row.id, session.row.name, "auth.login", "user", session.row.id, det4, zigmodu.http.RequestUtil.getRealIp(ctx), true, session.row.tenant_id);
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
                std.log.err("internal error: {s}", .{@errorName(err)});
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            const row = row_opt orelse {
                try ctx.sendErrorResponse(401, 401, "用户不存在");
                return;
            };
            defer row.free(self.svc.store.allocator);
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
                var link_buf: [1024]u8 = undefined;
                const link = std.fmt.bufPrint(&link_buf, "{s}/reset-password?user_id={d}&token={s}", .{ self.app_host, raw.user_id, raw.raw }) catch return;
                const rendered = (try self.templates.render("reset_password", .{ .link = link, .email = req.email })) orelse return;
                defer rendered.free(self.svc.store.allocator);
                const payload = jsonPayload(ctx.allocator, req.email, rendered.subject, rendered.body) catch return;
                defer ctx.allocator.free(payload);
                _ = self.task_svc.enqueue("mail.send", payload, 0, self.default_tenant_id) catch {};
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

            self.svc.resetPassword(req.user_id, req.token, req.new_password) catch |err| switch (err) {
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

        /// Send an email-verification link to the authenticated user.
        fn sendVerification(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const uid = mw.authUserId(ctx) orelse {
                try ctx.sendErrorResponse(401, 401, "未登录或登录已过期");
                return;
            };
            self.sendVerificationMail(ctx, uid);
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "验证邮件已发送", .data = null });
        }

        fn verifyEmail(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const req = ctx.bindJson(VerifyEmailReq) catch {
                try ctx.sendErrorResponse(400, 400, "请求体格式错误");
                return;
            };
            defer ctx.allocator.free(req.token);

            self.svc.verifyEmail(req.user_id, req.token) catch |err| switch (err) {
                error.InvalidToken => {
                    try ctx.sendErrorResponse(400, 400, "验证链接无效");
                    return;
                },
                error.TokenExpired => {
                    try ctx.sendErrorResponse(400, 400, "验证链接已过期，请重新发送");
                    return;
                },
            };
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "邮箱验证成功", .data = null });
            _ = self.notify_svc.notify(req.user_id, "邮箱验证成功", "你的邮箱已通过验证。", "success") catch {};
        }

        /// Self-service profile update (name / email). Delegates to the
        /// same validation path as the admin user API.
        fn updateProfile(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const uid = mw.authUserId(ctx) orelse {
                try ctx.sendErrorResponse(401, 401, "未登录或登录已过期");
                return;
            };
            const req = ctx.bindJson(UpdateProfileReq) catch {
                try ctx.sendErrorResponse(400, 400, "请求体格式错误");
                return;
            };
            defer {
                if (req.name) |n| ctx.allocator.free(n);
                if (req.email) |e| ctx.allocator.free(e);
            }

            const cur_opt = self.svc.getUserById(uid) catch {
                try ctx.sendErrorResponse(500, 500, "服务器错误");
                return;
            };
            const cur = cur_opt orelse {
                try ctx.sendErrorResponse(401, 401, "用户不存在");
                return;
            };
            defer cur.free(self.svc.store.allocator);

            if (req.email) |new_email| {
                const taken = self.svc.emailTakenByOther(ctx.allocator, uid, new_email) catch {
                    try ctx.sendErrorResponse(500, 500, "服务器错误");
                    return;
                };
                if (taken) {
                    try ctx.sendErrorResponse(409, 409, "该邮箱已被其他用户使用");
                    return;
                }
            }
            self.svc.updateProfile(uid, req.name orelse cur.name, req.email orelse cur.email) catch |err| switch (err) {
                error.InvalidName => {
                    try ctx.sendErrorResponse(400, 400, "姓名不能为空");
                    return;
                },
                error.InvalidEmail => {
                    try ctx.sendErrorResponse(400, 400, "邮箱格式不正确");
                    return;
                },
                else => {
                    try ctx.sendErrorResponse(500, 500, "服务器错误");
                    return;
                },
            };

            const fresh_opt = self.svc.getUserById(uid) catch {
                try ctx.sendErrorResponse(500, 500, "服务器错误");
                return;
            };
            const fresh = fresh_opt orelse {
                try ctx.sendErrorResponse(500, 500, "服务器错误");
                return;
            };
            defer fresh.free(self.svc.store.allocator);
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "ok", .data = toDto(fresh) });
        }

        /// Self-service password change (requires the current password).
        fn changePassword(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const uid = mw.authUserId(ctx) orelse {
                try ctx.sendErrorResponse(401, 401, "未登录或登录已过期");
                return;
            };
            const req = ctx.bindJson(ChangePasswordReq) catch {
                try ctx.sendErrorResponse(400, 400, "请求体格式错误");
                return;
            };
            defer ctx.allocator.free(req.old_password);
            defer ctx.allocator.free(req.new_password);

            self.svc.changePassword(uid, req.old_password, req.new_password) catch |err| switch (err) {
                error.InvalidCredentials => {
                    try ctx.sendErrorResponse(400, 400, "当前密码不正确");
                    return;
                },
                error.InvalidPassword => {
                    try ctx.sendErrorResponse(400, 400, "新密码至少 8 位");
                    return;
                },
            };
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "密码已更新", .data = null });
            _ = self.notify_svc.notify(uid, "密码已修改", "你的登录密码已更新。", "info") catch {};
        }

        /// Best-effort verification mail: token creation + Mailer.send are
        /// fire-and-forget from the request's perspective.
        fn sendVerificationMail(self: *Self, ctx: *http.Context, user_id: i64) void {
            const raw_opt = self.svc.createEmailVerification(ctx.allocator, user_id) catch return;
            const raw = raw_opt orelse return;
            defer ctx.allocator.free(raw.raw);

            const row_opt = self.svc.getUserById(user_id) catch return;
            const row = row_opt orelse return;
            defer row.free(self.svc.store.allocator);

            var link_buf: [1024]u8 = undefined;
            const link = std.fmt.bufPrint(&link_buf, "{s}/verify-email?user_id={d}&token={s}", .{ self.app_host, user_id, raw.raw }) catch return;
            const rendered = (self.templates.render("verify_email", .{ .link = link, .email = row.email }) catch return) orelse return;
            defer rendered.free(self.svc.store.allocator);
            const payload = jsonPayload(ctx.allocator, row.email, rendered.subject, rendered.body) catch return;
            defer ctx.allocator.free(payload);
            _ = self.task_svc.enqueue("mail.send", payload, 0, row.tenant_id) catch {};
            _ = self.notify_svc.notify(user_id, "验证邮件已发送", "请查收邮件并点击验证链接。", "info") catch {};
        }
    };
}

/// 按客户端 IP 限流的 key(优先级 X-Real-IP > X-Forwarded-For > 远端地址)。
fn clientIpKey(ctx: *http.Context) []const u8 {
    return zigmodu.http.RequestUtil.getRealIp(ctx);
}

fn parseTenantHeader(ctx: *http.Context) ?i64 {
    const raw = ctx.header("X-Tenant-ID") orelse return null;
    return std.fmt.parseInt(i64, raw, 10) catch null;
}

/// Build the JSON payload the `mail.send` task handler expects. Subjects and
/// bodies come from admin-editable templates, so values are JSON-serialized
/// (quotes/newlines in template content must not break the payload).
fn jsonPayload(allocator: std.mem.Allocator, to: []const u8, subject: []const u8, text: []const u8) ![]const u8 {
    return try std.fmt.allocPrint(allocator, "{f}", .{std.json.fmt(.{ .to = to, .subject = subject, .text = text }, .{})});
}

pub const DefaultAuthApi = AuthApi(user_service.UserService);
