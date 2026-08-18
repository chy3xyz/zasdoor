//! Web3 HTTP API - wallet binding and SIWE verification.

const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;
const mw = @import("../../middleware/auth.zig");
const user_svc = @import("../user/service.zig");
const service = @import("service.zig");

pub fn Web3Api(comptime Service: type, comptime UserService: type) type {
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
            try g.post("/web3/wallet/bind", bindWallet, @ptrCast(@alignCast(self)));
        }

        const BindReq = struct {
            chain: []const u8,
            address: []const u8,
        };

        fn bindWallet(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const uid = mw.authUserId(ctx) orelse {
                try ctx.sendErrorResponse(401, 401, "未登录或登录已过期");
                return;
            };
            const req = ctx.bindJson(BindReq) catch {
                try ctx.sendErrorResponse(400, 400, "请求体格式错误");
                return;
            };
            defer ctx.allocator.free(req.chain);
            defer ctx.allocator.free(req.address);
            const row_opt = self.svc.bindWallet(self.default_tenant_id, uid, req.chain, req.address) catch {
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            if (row_opt) |row| {
                defer row.free(self.svc.allocator);
                try ctx.jsonStruct(200, .{ .code = 0, .msg = "钱包已绑定", .data = .{ .address = row.address, .chain = row.chain } });
            } else {
                try ctx.sendErrorResponse(500, 500, "绑定失败");
            }
        }
    };
}
