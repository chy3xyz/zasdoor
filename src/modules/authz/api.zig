//! Admin-facing authorization API - check whether a subject holds a
//! permission for a resource:action (RBAC via roles).

const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;
const mw = @import("../../middleware/auth.zig");
const user_svc = @import("../user/service.zig");
const service = @import("service.zig");

pub fn AuthzApi(comptime Service: type, comptime UserService: type) type {
    return struct {
        const Self = @This();
        svc: *Service,
        user_svc: *UserService,

        pub fn init(svc: *Service, users: *UserService) Self {
            return .{ .svc = svc, .user_svc = users };
        }

        pub fn registerRoutes(self: *Self, group: *http.RouteGroup) !void {
            var g = try group.use(zigmodu.http.http_middleware.jwtAuthWithSecurity(&self.user_svc.sec.module));
            g = try g.use(mw.tokenVersionGuard(self.user_svc.sec, self.user_svc.store));
            try g.post("/iam/authz/check", check, @ptrCast(@alignCast(self)));
        }

        const CheckReq = struct {
            subject_id: i64,
            resource: []const u8,
            action: []const u8,
            project_id: ?i64 = null,
        };

        fn check(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const req = ctx.bindJson(CheckReq) catch {
                try ctx.sendErrorResponse(400, 400, "请求体格式错误");
                return;
            };
            defer ctx.allocator.free(req.resource);
            defer ctx.allocator.free(req.action);

            const context = service.AuthContext{ .project_id = req.project_id };
            const decision = self.svc.authorize(req.subject_id, req.resource, req.action, context) catch {
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            const allowed = decision == .allow;
            const label: []const u8 = switch (decision) {
                .allow => "allow",
                .deny => "deny",
                .unknown => "unknown",
            };
            try ctx.jsonStruct(200, .{
                .code = 0,
                .msg = "",
                .data = .{ .allowed = allowed, .decision = label }
            });
        }
    };
}
