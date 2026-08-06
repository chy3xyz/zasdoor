//! Notification HTTP API — any authenticated user manages their own inbox.

const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;
const mw = @import("../../middleware/auth.zig");
const user_svc = @import("../user/service.zig");
const service = @import("service.zig");

const NotificationDto = struct {
    id: i64,
    title: []const u8,
    body: []const u8,
    read: bool,
    kind: []const u8,
    created_at: i64,
};

fn toDto(row: service.NotificationRow) NotificationDto {
    return .{
        .id = row.id,
        .title = row.title,
        .body = row.body,
        .read = row.read,
        .kind = row.kind,
        .created_at = row.created_at,
    };
}

pub fn NotificationApi(comptime Service: type, comptime UserService: type) type {
    return struct {
        const Self = @This();
        svc: *Service,
        user_svc: *UserService,

        pub fn init(svc: *Service, users: *UserService) Self {
            return .{ .svc = svc, .user_svc = users };
        }

        pub fn registerRoutes(self: *Self, group: *http.RouteGroup) !void {
            var g = try group.use(zigmodu.http.http_middleware.jwtAuthWithSecurity(&self.user_svc.sec.module));
            try g.get("/notifications/unread-count", unreadCount, @ptrCast(@alignCast(self)));
            try g.get("/notifications", list, @ptrCast(@alignCast(self)));
            try g.post("/notifications/read-all", markAllRead, @ptrCast(@alignCast(self)));
            try g.post("/notifications/{id}/read", markRead, @ptrCast(@alignCast(self)));
            try g.delete("/notifications/{id}", delete, @ptrCast(@alignCast(self)));
        }

        fn authUserId(ctx: *http.Context) ?i64 {
            return mw.authUserId(ctx);
        }

        fn list(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const uid = authUserId(ctx) orelse {
                try ctx.sendErrorResponse(401, 401, "未登录或登录已过期");
                return;
            };
            const params = zigmodu.http.PageParams.parse(ctx, .{ .max_page_size = 100 });
            const unread = ctx.queryInt(usize, "unread", 0) == 1;

            var result = self.svc.list(uid, params.page, params.page_size, unread) catch |err| {
                std.log.err("internal error: {s}", .{@errorName(err)});
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            defer result.free(self.svc.allocator);

            const dtos = try zigmodu.http.Extract.toDtoList(ctx.allocator, result.items, NotificationDto, toDto);
            try zigmodu.http.sendPaged(ctx, dtos, @intCast(result.total), params, .ruoyi);
        }

        fn unreadCount(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const uid = authUserId(ctx) orelse {
                try ctx.sendErrorResponse(401, 401, "未登录或登录已过期");
                return;
            };
            const count = self.svc.unreadCount(uid) catch |err| {
                std.log.err("internal error: {s}", .{@errorName(err)});
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "", .data = .{ .unread = count } });
        }

        fn markRead(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const uid = authUserId(ctx) orelse {
                try ctx.sendErrorResponse(401, 401, "未登录或登录已过期");
                return;
            };
            const id = ctx.paramInt(i64, "id") catch {
                try ctx.sendErrorResponse(400, 400, "无效的通知 ID");
                return;
            };
            _ = self.svc.markRead(id, uid) catch |err| {
                std.log.err("internal error: {s}", .{@errorName(err)});
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "ok", .data = null });
        }

        fn markAllRead(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const uid = authUserId(ctx) orelse {
                try ctx.sendErrorResponse(401, 401, "未登录或登录已过期");
                return;
            };
            self.svc.markAllRead(uid) catch |err| {
                std.log.err("internal error: {s}", .{@errorName(err)});
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "ok", .data = null });
        }

        fn delete(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const uid = authUserId(ctx) orelse {
                try ctx.sendErrorResponse(401, 401, "未登录或登录已过期");
                return;
            };
            const id = ctx.paramInt(i64, "id") catch {
                try ctx.sendErrorResponse(400, 400, "无效的通知 ID");
                return;
            };
            _ = self.svc.delete(id, uid) catch |err| {
                std.log.err("internal error: {s}", .{@errorName(err)});
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "ok", .data = null });
        }
    };
}

pub const DefaultNotificationApi = NotificationApi(service.NotificationService, user_svc.UserService);
