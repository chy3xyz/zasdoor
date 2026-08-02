//! Admin-facing tenant API — platform administrators manage tenants.

const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;
const mw = @import("../../middleware/auth.zig");
const user_svc = @import("../user/service.zig");
const service = @import("service.zig");

const TenantDto = struct {
    id: i64,
    name: []const u8,
    status: []const u8,
    created_at: i64,
    updated_at: i64,
};

fn toDto(row: service.TenantRow) TenantDto {
    return .{
        .id = row.id,
        .name = row.name,
        .status = row.status,
        .created_at = row.created_at,
        .updated_at = row.updated_at,
    };
}

const CreateTenantReq = struct {
    name: []const u8,
};

const UpdateTenantReq = struct {
    name: ?[]const u8 = null,
    status: ?[]const u8 = null,
};

pub fn TenantApi(comptime Service: type, comptime UserService: type) type {
    return struct {
        const Self = @This();
        svc: *Service,
        user_svc: *UserService,

        pub fn init(svc: *Service, users: *UserService) Self {
            return .{ .svc = svc, .user_svc = users };
        }

        pub fn registerRoutes(self: *Self, group: *http.RouteGroup) !void {
            var g = try group.use(mw.jwtAuth(self.user_svc.sec));
            try g.get("/tenants", list, @ptrCast(@alignCast(self)));
            try g.post("/tenants", create, @ptrCast(@alignCast(self)));
            try g.put("/tenants/{id}", update, @ptrCast(@alignCast(self)));
        }

        fn requireAdmin(ctx: *http.Context, self: *Self) !?i64 {
            const uid = mw.authUserId(ctx) orelse {
                try ctx.sendErrorResponse(401, 401, "未登录或登录已过期");
                return null;
            };
            const row_opt = self.user_svc.getUserById(uid) catch {
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

        fn list(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            _ = (try requireAdmin(ctx, self)) orelse return;

            const page = ctx.queryInt(usize, "page", 1);
            const page_size = ctx.queryInt(usize, "page_size", 20);
            var result = self.svc.list(page, page_size) catch |err| {
                try ctx.sendErrorResponse(500, 500, @errorName(err));
                return;
            };
            defer result.free(ctx.allocator);

            var items = std.ArrayList(TenantDto).empty;
            defer items.deinit(ctx.allocator);
            for (result.items) |r| try items.append(ctx.allocator, toDto(r));

            try ctx.jsonStruct(200, .{
                .code = 0,
                .msg = "",
                .data = .{
                    .list = items.items,
                    .total = result.total,
                    .page = page,
                    .pageSize = page_size,
                },
            });
        }

        fn create(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            _ = (try requireAdmin(ctx, self)) orelse return;

            const req = ctx.bindJson(CreateTenantReq) catch {
                try ctx.sendErrorResponse(400, 400, "请求体格式错误");
                return;
            };
            defer ctx.allocator.free(req.name);
            if (std.mem.trim(u8, req.name, " \t").len == 0) {
                try ctx.sendErrorResponse(400, 400, "租户名称不能为空");
                return;
            }
            const id = self.svc.create(req.name) catch |err| {
                try ctx.sendErrorResponse(500, 500, @errorName(err));
                return;
            };
            try ctx.jsonStruct(201, .{ .code = 0, .msg = "租户已创建", .data = .{ .id = id } });
        }

        fn update(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            _ = (try requireAdmin(ctx, self)) orelse return;

            const id = ctx.paramInt(i64, "id") catch {
                try ctx.sendErrorResponse(400, 400, "无效的租户 ID");
                return;
            };
            const req = ctx.bindJson(UpdateTenantReq) catch {
                try ctx.sendErrorResponse(400, 400, "请求体格式错误");
                return;
            };
            defer {
                if (req.name) |n| ctx.allocator.free(n);
                if (req.status) |s| ctx.allocator.free(s);
            }
            const cur_opt = self.svc.get(id) catch {
                try ctx.sendErrorResponse(500, 500, "服务器错误");
                return;
            };
            const cur = cur_opt orelse {
                try ctx.sendErrorResponse(404, 404, "租户不存在");
                return;
            };
            defer cur.free(ctx.allocator);

            const name = req.name orelse cur.name;
            const status = req.status orelse cur.status;
            if (!std.mem.eql(u8, status, "active") and !std.mem.eql(u8, status, "disabled")) {
                try ctx.sendErrorResponse(400, 400, "状态仅支持 active/disabled");
                return;
            }
            _ = self.svc.update(id, name, status) catch |err| {
                try ctx.sendErrorResponse(500, 500, @errorName(err));
                return;
            };
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "ok", .data = null });
        }
    };
}

pub const DefaultTenantApi = TenantApi(service.TenantService, user_svc.UserService);
