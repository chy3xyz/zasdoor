//! Authorization enforcement middleware.
//!
//! Mount after a module's JWT middleware (that sets the user_id attribute).
//! DENY decisions refuse the request. UNKNOWN is deferred to the route's
//! existing admin/business guards, so an installation with no policies keeps
//! its current behaviour. The kernel instance is installed once at startup
//! with install(); before that the middleware is a no-op.

const std = @import("std");
const zmodu = @import("zmodu");
const http = zmodu.http;
const mw = @import("./auth.zig");
const authz_service = @import("../modules/authz/service.zig");

var kernel: ?*authz_service.AuthzService = null;

pub fn install(svc: *authz_service.AuthzService) void {
    kernel = svc;
}

/// Middleware factory. Mount it after jwtAuthWithSecurity / tokenVersionGuard.
pub fn enforce() http.Middleware {
    return .{
        .func = struct {
            fn mw_fn(ctx: *http.Context, next: http.HandlerFn, _: ?*anyopaque) anyerror!void {
                const svc = kernel orelse {
                    try next(ctx);
                    return;
                };
                const uid_opt = mw.authUserId(ctx);
                if (uid_opt == null) {
                    try next(ctx);
                    return;
                }
                const uid = uid_opt.?;
                const resource = ctx.route_template orelse ctx.path;
                const action = actionFor(ctx.method);
                const info = svc.authorizeDetailed(
                    uid,
                    resource,
                    action,
                    .{
                        .tenant_id = mw.authTenantId(ctx),
                        .now = if (ctx.io) |io| zmodu.time.wallClockSeconds(io) else 0,
                    },
                ) catch {
                    try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                    return;
                };
                if (info.decision == .deny) {
                    try ctx.sendErrorResponse(403, 403, "策略拒绝该操作");
                    return;
                }
                try next(ctx);
            }
        }.mw_fn,
    };
}

pub fn actionFor(method: http.Method) []const u8 {
    return switch (method) {
        .GET, .HEAD => "read",
        .OPTIONS => "browse",
        else => "write",
    };
}
