//! JWT auth middleware + context helpers for zenaipa HTTP handlers.

const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;

pub const auth_user_id_attr = "auth_user_id";

/// Parses `Authorization: Bearer <token>`, verifies the JWT and stores the
/// subject (user id) as a context attribute. Responds 401 on any failure.
/// The security module is kept in module-scope storage because Zig inner
/// functions cannot capture enclosing function parameters.
pub fn jwtAuth(sec: *zigmodu.security.AppSecurity) http.Middleware {
    const S = struct {
        var stored: *zigmodu.security.AppSecurity = undefined;
    };
    S.stored = sec;
    return .{ .func = struct {
        fn mw(ctx: *http.Context, next: http.HandlerFn, _: ?*anyopaque) anyerror!void {
            const header = ctx.header("Authorization") orelse "";
            const token = zigmodu.security.SecurityModule.extractBearerToken(header) orelse {
                try ctx.sendErrorResponse(401, 401, "未登录或登录已过期");
                return;
            };
            const payload = S.stored.module.verifyToken(token) catch {
                try ctx.sendErrorResponse(401, 401, "未登录或登录已过期");
                return;
            };
            defer S.stored.module.freePayload(payload);
            try ctx.setAttr(auth_user_id_attr, payload.sub);
            try next(ctx);
        }
    }.mw };
}

/// The authenticated user id, or null when the JWT middleware did not run.
pub fn authUserId(ctx: *http.Context) ?i64 {
    const id_str = ctx.getAttr(auth_user_id_attr) orelse return null;
    return std.fmt.parseInt(i64, id_str, 10) catch null;
}
