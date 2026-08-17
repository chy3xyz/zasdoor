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
    };
}
