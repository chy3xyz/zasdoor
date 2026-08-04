//! Admin-facing HTTP API for the background task queue. All routes require
//! a valid JWT and the `admin` role (checked against the DB).

const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;
const mw = @import("../../middleware/auth.zig");
const user_svc = @import("../user/service.zig");
const service = @import("service.zig");
const audit_svc = @import("../audit/service.zig");


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
        audit: *audit_svc.AuditService,

        pub fn init(svc: *Service, users: *UserService, audit: *audit_svc.AuditService) Self {
            return .{ .svc = svc, .user_svc = users, .audit = audit };
        }

        pub fn registerRoutes(self: *Self, group: *http.RouteGroup) !void {
            var g = try group.use(zigmodu.http.http_middleware.jwtAuthWithSecurity(&self.user_svc.sec.module));
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
            defer row.free(self.svc.store.allocator);
            if (!row.admin) {
                try ctx.sendErrorResponse(403, 403, "需要管理员权限");
                return null;
            }
            try ctx.setAttr("audit_actor", row.name);
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

            const params = zigmodu.http.PageParams.parse(ctx, .{ .max_page_size = 100 });
            const status = ctx.queryParam("status");

            var result = self.svc.list(params.page, params.page_size, status) catch |err| {
                try ctx.sendErrorResponse(500, 500, @errorName(err));
                return;
            };
            defer result.free(self.svc.store.allocator);

            const dtos = try zigmodu.http.Extract.toDtoList(ctx.allocator, result.items, TaskDto, toDto);
            try zigmodu.http.sendPaged(ctx, dtos, @intCast(result.total), params, .ruoyi);
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
            defer row.free(self.svc.store.allocator);
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "", .data = toDto(row) });
        }

        fn retry(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const admin_id = (try requireAdmin(ctx, self)) orelse return;
            const id = ctx.paramInt(i64, "id") catch {
                try ctx.sendErrorResponse(400, 400, "无效的任务 ID");
                return;
            };
            _ = self.svc.retry(id) catch |err| {
                try ctx.sendErrorResponse(500, 500, @errorName(err));
                return;
            };
            var d1: [96]u8 = undefined;
            const det1 = try std.fmt.bufPrint(&d1, "重试任务 #{d}", .{id});
            self.audit.log(admin_id, ctx.getAttr("audit_actor") orelse "", "task.retry", "task", id, det1, zigmodu.http.RequestUtil.getRealIp(ctx), true, 0);
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "任务已重新排队", .data = null });
        }

        fn cancel(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const admin_id = (try requireAdmin(ctx, self)) orelse return;
            const id = ctx.paramInt(i64, "id") catch {
                try ctx.sendErrorResponse(400, 400, "无效的任务 ID");
                return;
            };
            _ = self.svc.cancel(id) catch |err| {
                try ctx.sendErrorResponse(500, 500, @errorName(err));
                return;
            };
            var d2: [96]u8 = undefined;
            const det2 = try std.fmt.bufPrint(&d2, "取消任务 #{d}", .{id});
            self.audit.log(admin_id, ctx.getAttr("audit_actor") orelse "", "task.cancel", "task", id, det2, zigmodu.http.RequestUtil.getRealIp(ctx), true, 0);
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "任务已取消", .data = null });
        }

        fn purge(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const admin_id = (try requireAdmin(ctx, self)) orelse return;
            _ = self.svc.purge() catch |err| {
                try ctx.sendErrorResponse(500, 500, @errorName(err));
                return;
            };
            const det3 = "清理已完成任务";
            self.audit.log(admin_id, ctx.getAttr("audit_actor") orelse "", "task.purge", "task", 0, det3, zigmodu.http.RequestUtil.getRealIp(ctx), true, 0);
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "已完成任务已清理", .data = null });
        }

        fn delete(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const admin_id = (try requireAdmin(ctx, self)) orelse return;
            const id = ctx.paramInt(i64, "id") catch {
                try ctx.sendErrorResponse(400, 400, "无效的任务 ID");
                return;
            };
            self.svc.delete(id) catch |err| {
                try ctx.sendErrorResponse(500, 500, @errorName(err));
                return;
            };
            var d4: [96]u8 = undefined;
            const det4 = try std.fmt.bufPrint(&d4, "删除任务 #{d}", .{id});
            self.audit.log(admin_id, ctx.getAttr("audit_actor") orelse "", "task.delete", "task", id, det4, zigmodu.http.RequestUtil.getRealIp(ctx), true, 0);
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "ok", .data = null });
        }
    };
}

pub const DefaultTaskApi = TaskApi(service.TaskService, user_svc.UserService);
