//! IdP (social login) HTTP API - manage providers and build login links.

const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;
const mw = @import("../../middleware/auth.zig");
const user_svc = @import("../user/service.zig");

pub fn IdpApi(comptime Service: type, comptime UserService: type) type {
    return struct {
        const Self = @This();
        svc: *Service,
        users: *UserService,
        default_tenant_id: i64,

        pub fn init(svc: *Service, users: *UserService, default_tenant_id: i64) Self {
            return .{ .svc = svc, .users = users, .default_tenant_id = default_tenant_id };
        }

        pub fn registerRoutes(self: *Self, group: *http.RouteGroup) !void {
            // Public social-login entry point + provider callback. The
            // callback is guarded by the persisted single-use state, not a
            // JWT: the browser arrives from the provider without one. All
            // existing admin routes stay behind the JWT group below.
            try group.post("/mfa/idps/{id}/start", start, @ptrCast(@alignCast(self)));
            try group.get("/mfa/idps/{id}/callback", callback, @ptrCast(@alignCast(self)));

            var g = try group.use(zigmodu.http.http_middleware.jwtAuthWithSecurity(&self.users.sec.module));
            g = try g.use(mw.tokenVersionGuard(self.users.sec, self.users.store));
            try g.get("/mfa/idps", list, @ptrCast(@alignCast(self)));
            try g.post("/mfa/idps", create, @ptrCast(@alignCast(self)));
            try g.post("/mfa/idps/{id}/link", loginLink, @ptrCast(@alignCast(self)));
        }

        const CreateIdpReq = struct { name: []const u8, provider_type: []const u8, config: []const u8 };

        fn create(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const req = ctx.bindJson(CreateIdpReq) catch {
                try ctx.sendErrorResponse(400, 400, "请求体格式错误");
                return;
            };
            defer ctx.allocator.free(req.name);
            defer ctx.allocator.free(req.provider_type);
            defer ctx.allocator.free(req.config);
            const id = self.svc.create(self.default_tenant_id, req.name, req.provider_type, req.config, 0) catch {
                try ctx.sendErrorResponse(400, 400, "IdP 配置无效");
                return;
            };
            try ctx.jsonStruct(201, .{ .code = 0, .msg = "IdP 已创建", .data = .{ .id = id } });
        }

        const IdpDto = struct { id: i64, name: []const u8, provider_type: []const u8, enabled: bool };

        fn list(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const rows = self.svc.list(self.default_tenant_id) catch {
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            defer {
                for (rows) |r| r.free(ctx.allocator);
                ctx.allocator.free(rows);
            }
            var dtos = std.ArrayList(IdpDto).empty;
            defer dtos.deinit(ctx.allocator);
            for (rows) |r| {
                const d: IdpDto = .{ .id = r.id, .name = r.name, .provider_type = r.provider_type, .enabled = r.enabled };
                try dtos.append(ctx.allocator, d);
            }
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "", .data = dtos.items });
        }

        const LinkReq = struct { config_json: []const u8, state: []const u8, code_challenge: ?[]const u8 = null };

        fn loginLink(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const req = ctx.bindJson(LinkReq) catch {
                try ctx.sendErrorResponse(400, 400, "请求体格式错误");
                return;
            };
            defer ctx.allocator.free(req.config_json);
            defer ctx.allocator.free(req.state);
            defer if (req.code_challenge) |c| ctx.allocator.free(c);
            const url = self.svc.buildAuthorizeUrl(req.config_json, req.state, req.code_challenge) catch {
                try ctx.sendErrorResponse(400, 400, "IdP 配置无效");
                return;
            };
            defer ctx.allocator.free(url);
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "", .data = .{ .url = url } });
        }

        const StartReq = struct { redirect_to: ?[]const u8 = null };

        /// POST /mfa/idps/{id}/start -> { authorize_url, state }. The state is
        /// persisted, single-use and TTL-bounded; the browser is sent to
        /// authorize_url and the provider echoes state back to the callback.
        fn start(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const provider_id = ctx.paramInt(i64, "id") catch {
                try ctx.sendErrorResponse(400, 400, "IdP 不存在");
                return;
            };
            const req_opt: ?StartReq = ctx.bindJson(StartReq) catch null;
            var redirect_to: []const u8 = "";
            var redir_owned: ?[]const u8 = null;
            if (req_opt) |req| {
                if (req.redirect_to) |r| {
                    redirect_to = r;
                    redir_owned = r;
                }
            }
            defer if (redir_owned) |r| ctx.allocator.free(r);

            const now = zigmodu.time.wallClockSeconds(self.users.io);
            const out = self.svc.startLogin(self.users.io, self.default_tenant_id, provider_id, redirect_to, now, 600) catch |err| switch (err) {
                error.NotFound => {
                    try ctx.sendErrorResponse(404, 404, "IdP 不存在");
                    return;
                },
                else => {
                    std.log.err("idp start failed: {s}", .{@errorName(err)});
                    try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                    return;
                },
            };
            defer out.deinit(self.svc.allocator);
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "", .data = .{ .authorize_url = out.authorize_url, .state = out.state } });
        }

        /// GET /mfa/idps/{id}/callback?code=&state= -> completes the flow and
        /// issues a platform JWT. Success transport is a JSON envelope
        /// {code,msg,data:{token,user}} (documented choice; the SPA reads the
        /// token and stores it). Errors are clear envelopes.
        fn callback(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const provider_id = ctx.paramInt(i64, "id") catch {
                try ctx.sendErrorResponse(400, 400, "IdP 不存在");
                return;
            };
            const code = ctx.queryParam("code") orelse {
                try ctx.sendErrorResponse(400, 400, "缺少 code");
                return;
            };
            const state = ctx.queryParam("state") orelse {
                try ctx.sendErrorResponse(400, 400, "缺少 state");
                return;
            };
            const now = zigmodu.time.wallClockSeconds(self.users.io);
            const user_id = self.svc.completeCallback(self.users.io, provider_id, code, state, now) catch |err| {
                switch (err) {
                    error.UnknownState => try ctx.sendErrorResponse(400, 400, "state 无效"),
                    error.ReusedState => try ctx.sendErrorResponse(400, 400, "state 已被使用"),
                    error.ExpiredState => try ctx.sendErrorResponse(400, 400, "state 已过期"),
                    error.TokenExchangeFailed => try ctx.sendErrorResponse(502, 502, "令牌交换失败"),
                    error.UserInfoFailed, error.MissingSubject => try ctx.sendErrorResponse(502, 502, "获取用户信息失败"),
                    error.NotFound => try ctx.sendErrorResponse(404, 404, "IdP 不存在"),
                    error.InvalidConfig => try ctx.sendErrorResponse(400, 400, "IdP 配置无效"),
                    error.EmailNotVerified => try ctx.sendErrorResponse(409, 409, "该邮箱已存在本地账号,但提供方未验证该邮箱;请先登录后在个人资料中绑定"),
                    else => {
                        std.log.err("idp callback failed: {s}", .{@errorName(err)});
                        try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                    },
                }
                return;
            };

            // Reuse the existing auth login path: load the user row and mint a
            // JWT with the same security module / tenant / token-version used
            // by UserService.login and register.
            const row_opt = self.users.getUserById(user_id) catch {
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            const row = row_opt orelse {
                try ctx.sendErrorResponse(500, 500, "用户不存在");
                return;
            };
            defer row.free(self.users.store.allocator);

            var id_buf: [32]u8 = undefined;
            const uid_str = try std.fmt.bufPrint(&id_buf, "{d}", .{row.id});
            var tenant_buf: [32]u8 = undefined;
            const tenant_str = try std.fmt.bufPrint(&tenant_buf, "{d}", .{row.tenant_id});
            const roles: []const []const u8 = if (row.admin) &[_][]const u8{"admin"} else &[_][]const u8{"user"};
            const token = self.users.sec.module.generateTokenWithTenantAndVersion(uid_str, roles, tenant_str, row.token_version) catch {
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            defer self.users.sec.module.allocator.free(token);

            try ctx.jsonStruct(200, .{
                .code = 0,
                .msg = "登录成功",
                .data = .{
                    .token = token,
                    .user = .{ .id = row.id, .name = row.name, .email = row.email, .admin = row.admin, .tenant_id = row.tenant_id },
                },
            });
        }
    };
}
