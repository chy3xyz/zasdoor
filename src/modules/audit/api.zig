//! Admin audit-log API — query the audit trail (write side is the service).

const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;
const mw = @import("../../middleware/auth.zig");
const service = @import("service.zig");

const AuditDto = struct {
    id: i64,
    actor_user_id: i64,
    actor_name: []const u8,
    action: []const u8,
    target_type: []const u8,
    target_id: i64,
    detail: []const u8,
    ip: []const u8,
    success: bool,
    created_at: i64,
};

fn toDto(row: service.AuditRow) AuditDto {
    return .{
        .id = row.id,
        .actor_user_id = row.actor_user_id,
        .actor_name = row.actor_name,
        .action = row.action,
        .target_type = row.target_type,
        .target_id = row.target_id,
        .detail = row.detail,
        .ip = row.ip,
        .success = row.success,
        .created_at = row.created_at,
    };
}

pub fn AuditApi(comptime AuditServiceT: type, comptime UserService: type) type {
    return struct {
        const Self = @This();
        svc: *AuditServiceT,
        user_svc: *UserService,

        pub fn init(svc: *AuditServiceT, users: *UserService) Self {
            return .{ .svc = svc, .user_svc = users };
        }

        pub fn registerRoutes(self: *Self, group: *http.RouteGroup) !void {
            var g = try group.use(zigmodu.http.http_middleware.jwtAuthWithSecurity(&self.user_svc.sec.module));
            g = try g.use(mw.tokenVersionGuard(self.user_svc.sec, self.user_svc.store));            try g.get("/audit-logs", listLogs, @ptrCast(@alignCast(self)));
            try g.get("/audit-logs/export", exportLogs, @ptrCast(@alignCast(self)));
        }

        /// Returns the authenticated admin user id, or null after responding.
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
            defer row.free(self.svc.allocator);
            if (!row.admin) {
                try ctx.sendErrorResponse(403, 403, "需要管理员权限");
                return null;
            }
            return uid;
        }

        fn exportLogs(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            _ = (try requireAdmin(ctx, self)) orelse return;

            var result = self.svc.list(1, 10000, .{}) catch |err| {
                std.log.err("internal error: {s}", .{@errorName(err)});
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            defer result.free(ctx.allocator);

            var csv = zigmodu.csv.Writer.init(ctx.allocator);
            defer csv.deinit();
            try csv.writeHeader(&.{ "id", "action", "actor_user_id", "actor_name", "target_type", "target_id", "detail", "ip", "success", "created_at" });
            for (result.items) |r| {
                var buf: [64]u8 = undefined;
                const id_s = try std.fmt.bufPrint(&buf, "{d}", .{r.id});
                const aid_s = try std.fmt.bufPrint(&buf, "{d}", .{r.actor_user_id});
                const tid_s = try std.fmt.bufPrint(&buf, "{d}", .{r.target_id});
                const ts_s = try std.fmt.bufPrint(&buf, "{d}", .{r.created_at});
                const ok_s = if (r.success) "true" else "false";
                try csv.writeRow(&.{ id_s, r.action, aid_s, r.actor_name, r.target_type, tid_s, r.detail, r.ip, ok_s, ts_s });
            }
            try ctx.setHeader("Content-Type", "text/csv; charset=utf-8");
            try ctx.setHeader("Content-Disposition", "attachment; filename=audit-logs.csv");
            try ctx.text(200, csv.buf.items);
        }

        fn listLogs(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const admin_id = (try requireAdmin(ctx, self)) orelse return;
            _ = admin_id;

            const params = zigmodu.http.PageParams.parse(ctx, .{ .max_page_size = 200 });
            const actor = ctx.queryInt(i64, "actor", 0);
            const action_raw = ctx.queryParam("action");
            const keyword_raw = ctx.queryParam("keyword");

            // zigmodu percent-decodes query values at parse time — do not
            // decode again here (would corrupt literal %XX sequences).
            const filters: service.AuditFilters = .{
                .actor_user_id = if (actor > 0) actor else null,
                .action = action_raw,
                .keyword = keyword_raw,
            };
            var result = self.svc.list(params.page, params.page_size, filters) catch |err| {
                std.log.err("internal error: {s}", .{@errorName(err)});
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            defer result.free(self.svc.allocator);

            const dtos = try zigmodu.http.Extract.toDtoList(ctx.allocator, result.items, AuditDto, toDto);
            try zigmodu.http.sendPaged(ctx, dtos, @intCast(result.total), params, .ruoyi);
        }
    };
}

pub const DefaultAuditApi = AuditApi(service.AuditService, @import("../user/service.zig").UserService);
