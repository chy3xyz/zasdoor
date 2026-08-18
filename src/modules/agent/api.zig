//! Agent HTTP API - create/inspect/deactivate agents, issue + verify agent tokens.

const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;
const mw = @import("../../middleware/auth.zig");
const user_svc = @import("../user/service.zig");
const service = @import("service.zig");
const oauth_jwt = @import("../oauth/jwt.zig");

pub fn AgentApi(comptime Service: type, comptime UserService: type) type {
    return struct {
        const Self = @This();
        svc: *Service,
        users: *UserService,
        default_tenant_id: i64,

        pub fn init(svc: *Service, users: *UserService, default_tenant_id: i64) Self {
            return .{ .svc = svc, .users = users, .default_tenant_id = default_tenant_id };
        }

        pub fn registerRoutes(self: *Self, group: *http.RouteGroup) !void {
            var g = try group.use(zigmodu.http.http_middleware.jwtAuthWithSecurity(&self.users.sec.module));
            g = try g.use(mw.tokenVersionGuard(self.users.sec, self.users.store));
            try g.post("/agents", create, @ptrCast(@alignCast(self)));
            try g.get("/agents/{id}", get, @ptrCast(@alignCast(self)));
            try g.post("/agents/{id}/deactivate", deactivate, @ptrCast(@alignCast(self)));
            try g.post("/agents/{id}/token", issueToken, @ptrCast(@alignCast(self)));
            try g.post("/agents/token/verify", verifyToken, @ptrCast(@alignCast(self)));
        }

        fn requireUser(ctx: *http.Context) ?i64 {
            return mw.authUserId(ctx);
        }

        const CreateAgentReq = struct {
            name: []const u8,
            description: ?[]const u8 = null,
            capabilities: ?[]const u8 = null,
            scopes: ?[]const u8 = null,
            budget: ?i64 = null,
            period_seconds: ?i64 = null,
            expires_at: ?i64 = null,
        };

        fn create(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const uid = requireUser(ctx) orelse {
                try ctx.sendErrorResponse(401, 401, "未登录或登录已过期");
                return;
            };
            const req = ctx.bindJson(CreateAgentReq) catch {
                try ctx.sendErrorResponse(400, 400, "请求体格式错误");
                return;
            };
            defer ctx.allocator.free(req.name);
            defer if (req.description) |v| ctx.allocator.free(v);
            defer if (req.capabilities) |v| ctx.allocator.free(v);
            defer if (req.scopes) |v| ctx.allocator.free(v);
            const id = self.svc.createAgent(
                self.default_tenant_id,
                uid,
                req.name,
                req.description orelse "",
                req.capabilities orelse "[]",
                req.scopes orelse "[]",
                req.budget orelse 0,
                req.period_seconds orelse 86400,
                req.expires_at orelse 0,
            ) catch {
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            try ctx.jsonStruct(201, .{ .code = 0, .msg = "Agent 已创建", .data = .{ .id = id } });
        }

        fn get(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            _ = requireUser(ctx) orelse {
                try ctx.sendErrorResponse(401, 401, "未登录或登录已过期");
                return;
            };
            const id = ctx.paramInt(i64, "id") catch {
                try ctx.sendErrorResponse(400, 400, "无效的 Agent ID");
                return;
            };
            const row_opt = self.svc.getAgent(id) catch {
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            const row = row_opt orelse {
                try ctx.sendErrorResponse(404, 404, "Agent 不存在");
                return;
            };
            defer row.free(self.svc.allocator);
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "", .data = .{
                .id = row.id,
                .name = row.name,
                .owner_user_id = row.owner_user_id,
                .budget = row.budget,
                .budget_period_seconds = row.budget_period_seconds,
                .expires_at = row.expires_at,
                .active = row.active,
            } });
        }

        fn deactivate(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            _ = requireUser(ctx) orelse {
                try ctx.sendErrorResponse(401, 401, "未登录或登录已过期");
                return;
            };
            const id = ctx.paramInt(i64, "id") catch {
                try ctx.sendErrorResponse(400, 400, "无效的 Agent ID");
                return;
            };
            self.svc.setActive(id, false) catch {
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "Agent 已停用", .data = null });
        }

        const IssueTokenReq = struct { ttl: ?i64 = null };

        fn issueToken(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            _ = requireUser(ctx) orelse {
                try ctx.sendErrorResponse(401, 401, "未登录或登录已过期");
                return;
            };
            const id = ctx.paramInt(i64, "id") catch {
                try ctx.sendErrorResponse(400, 400, "无效的 Agent ID");
                return;
            };
            const req = ctx.bindJson(IssueTokenReq) catch IssueTokenReq{ .ttl = null };
            const ttl = req.ttl orelse 3600;
            const tok_opt = self.svc.issueAgentToken(id, ttl) catch {
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            const tok = tok_opt orelse {
                try ctx.sendErrorResponse(400, 400, "Agent 不可用(已停用或过期)");
                return;
            };
            defer self.svc.allocator.free(tok);
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "", .data = .{ .access_token = tok, .token_type = "Bearer" } });
        }

        const VerifyTokenReq = struct { token: []const u8 };

        fn verifyToken(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            _ = requireUser(ctx) orelse {
                try ctx.sendErrorResponse(401, 401, "未登录或登录已过期");
                return;
            };
            const req = ctx.bindJson(VerifyTokenReq) catch {
                try ctx.sendErrorResponse(400, 400, "请求体格式错误");
                return;
            };
            defer ctx.allocator.free(req.token);
            const payload = oauth_jwt.verify(ctx.allocator, self.users.sec.module.jwt_secret, req.token) catch {
                try ctx.jsonStruct(200, .{ .code = 0, .msg = "", .data = .{ .valid = false, .reason = "签名无效" } });
                return;
            };
            defer ctx.allocator.free(payload);
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "", .data = .{ .valid = true, .payload = payload } });
        }
    };
}
