//! Admin diagnostics API — real runtime state, no hardcoded counters.

const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;
const mw = @import("../../middleware/auth.zig");
const user_svc = @import("../user/service.zig");
const task_persist = @import("../task/persistence.zig");

pub fn SystemApi(comptime CacheT: type, comptime TaskSvcT: type) type {
    return struct {
        const Self = @This();
        cache: *CacheT,
        tasks: *TaskSvcT,
        users_svc: *user_svc.UserService,
        io: std.Io,
        started_at: i64,
        db_kind: []const u8,
        smtp_enabled: bool,
        mail_console: bool,
        module_count: usize,

        pub fn init(
            cache: *CacheT,
            tasks: *TaskSvcT,
            users_svc: *user_svc.UserService,
            io: std.Io,
            started_at: i64,
            db_kind: []const u8,
            smtp_enabled: bool,
            mail_console: bool,
            module_count: usize,
        ) Self {
            return .{
                .cache = cache,
                .tasks = tasks,
                .users_svc = users_svc,
                .io = io,
                .started_at = started_at,
                .db_kind = db_kind,
                .smtp_enabled = smtp_enabled,
                .mail_console = mail_console,
                .module_count = module_count,
            };
        }

        pub fn registerRoutes(self: *Self, group: *http.RouteGroup) !void {
            var g = try group.use(mw.jwtAuth(self.users_svc.sec));
            try g.get("/system/info", info, @ptrCast(@alignCast(self)));
        }

        fn info(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const uid = mw.authUserId(ctx) orelse {
                try ctx.sendErrorResponse(401, 401, "未登录或登录已过期");
                return;
            };
            const row_opt = self.users_svc.getUserById(uid) catch {
                try ctx.sendErrorResponse(401, 401, "未登录或登录已过期");
                return;
            };
            const row = row_opt orelse {
                try ctx.sendErrorResponse(401, 401, "未登录或登录已过期");
                return;
            };
            defer row.free(ctx.allocator);
            if (!row.admin) {
                try ctx.sendErrorResponse(403, 403, "需要管理员权限");
                return;
            }

            const now = zigmodu.time.wallClockSeconds(self.io);
            const task_counts = self.tasks.counts() catch task_persist.StatusCounts{};
            try ctx.jsonStruct(200, .{
                .code = 0,
                .msg = "",
                .data = .{
                    .app = "zenaipa",
                    .version = "0.2.0",
                    .uptime_seconds = now - self.started_at,
                    .db = self.db_kind,
                    .mail = .{ .smtp = self.smtp_enabled, .console = self.mail_console },
                    .cache_entries = self.cache.count(),
                    .modules = self.module_count,
                    .tasks = task_counts,
                },
            });
        }
    };
}
