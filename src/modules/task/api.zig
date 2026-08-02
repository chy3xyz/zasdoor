//! Admin-facing HTTP API for the background task queue. All routes require
//! a valid JWT and the `admin` role (checked against the DB).

const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;
const mw = @import("../../middleware/auth.zig");
const user_svc = @import("../user/service.zig");
const service = @import("service.zig");

const TaskDto = struct {
    id: i64,
    name: []const u8,
    payload: []const u8,
    status: []const u8,
    tenant_id: i64,
    attempts: i64,
    max_attempts: i64,
    last_error: []const u8,
    available_at: i64,
    started_at: i64,
    finished_at: i64,
    created_at: i64,
    updated_at: i64,
};

fn toDto(row: service.TaskRow) TaskDto {
    return .{
        .id = row.id,
        .name = row.name,
        .payload = row.payload,
        .status = row.status,
        .tenant_id = row.tenant_id,
        .attempts = row.attempts,
        .max_attempts = row.max_attempts,
        .last_error = row.last_error,
        .available_at = row.available_at,
        .started_at = row.started_at,
        .finished_at = row.finished_at,
        .created_at = row.created_at,
        .updated_at = row.updated_at,
    };
}

pub fn TaskApi(comptime Service: type, comptime UserService: type) type {
    return struct {
        const Self = @This();
        svc: *Service,
        user_svc: *UserService,

        pub fn init(svc: *Service, users: *UserService) Self {
            return .{ .svc = svc, .user_svc = users };
        }

        pub fn registerRoutes(self: *Self, group: *http.RouteGroup) !void {
            var g = try group.use(mw.jwtAuth(self.user_svc.sec));
            try g.get("/tasks/stats", stats, @ptrCast(@alignCast(self)));
            try g.get("/tasks", list, @ptrCast(@alignCast(self)));
            try g.get("/tasks/{id}", get, @ptrCast(@alignCast(self)));
            try g.post("/tasks/{id}/retry", retry, @ptrCast(@alignCast(self)));
            try g.post("/tasks/{id}/cancel", cancel, @ptrCast(@alignCast(self)));
            try g.post("/tasks/purge", purge, @ptrCast(@alignCast(self)));
            try g.delete("/tasks/{id}", delete, @ptrCast(@alignCast(self)));
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

        fn stats(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            _ = (try requireAdmin(ctx, self)) orelse return;
            const counts = self.svc.counts() catch |err| {
                try ctx.sendErrorResponse(500, 500, @errorName(err));
                return;
            };
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "", .data = counts });
        }

        fn list(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            _ = (try requireAdmin(ctx, self)) orelse return;

            const page = ctx.queryInt(usize, "page", 1);
            const page_size = ctx.queryInt(usize, "page_size", 20);
            const status = ctx.queryParam("status");

            var result = self.svc.list(page, page_size, status) catch |err| {
                try ctx.sendErrorResponse(500, 500, @errorName(err));
                return;
            };
            defer result.free(ctx.allocator);

            var items = std.ArrayList(TaskDto).empty;
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

        fn get(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            _ = (try requireAdmin(ctx, self)) orelse return;

            const id = ctx.paramInt(i64, "id") catch {
                try ctx.sendErrorResponse(400, 400, "无效的任务 ID");
                return;
            };
            const row_opt = self.svc.get(id) catch |err| {
                try ctx.sendErrorResponse(500, 500, @errorName(err));
                return;
            };
            const row = row_opt orelse {
                try ctx.sendErrorResponse(404, 404, "任务不存在");
                return;
            };
            defer row.free(ctx.allocator);
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "", .data = toDto(row) });
        }

        fn retry(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            _ = (try requireAdmin(ctx, self)) orelse return;
            const id = ctx.paramInt(i64, "id") catch {
                try ctx.sendErrorResponse(400, 400, "无效的任务 ID");
                return;
            };
            _ = self.svc.retry(id) catch |err| {
                try ctx.sendErrorResponse(500, 500, @errorName(err));
                return;
            };
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "任务已重新排队", .data = null });
        }

        fn cancel(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            _ = (try requireAdmin(ctx, self)) orelse return;
            const id = ctx.paramInt(i64, "id") catch {
                try ctx.sendErrorResponse(400, 400, "无效的任务 ID");
                return;
            };
            _ = self.svc.cancel(id) catch |err| {
                try ctx.sendErrorResponse(500, 500, @errorName(err));
                return;
            };
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "任务已取消", .data = null });
        }

        fn purge(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            _ = (try requireAdmin(ctx, self)) orelse return;
            _ = self.svc.purge() catch |err| {
                try ctx.sendErrorResponse(500, 500, @errorName(err));
                return;
            };
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "已完成任务已清理", .data = null });
        }

        fn delete(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            _ = (try requireAdmin(ctx, self)) orelse return;
            const id = ctx.paramInt(i64, "id") catch {
                try ctx.sendErrorResponse(400, 400, "无效的任务 ID");
                return;
            };
            self.svc.delete(id) catch |err| {
                try ctx.sendErrorResponse(500, 500, @errorName(err));
                return;
            };
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "ok", .data = null });
        }
    };
}

pub const DefaultTaskApi = TaskApi(service.TaskService, user_svc.UserService);
