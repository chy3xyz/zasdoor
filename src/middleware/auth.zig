//! Auth helpers for zenaipa HTTP handlers.
//!
//! JWT verification uses zigmodu's built-in `jwtAuthWithSecurity` middleware
//! (mounted per route group in the module `api.zig` files). The helpers here
//! read the context attributes that middleware sets: `user_id` (JWT `sub`)
//! and `tenant_id` (JWT `aud`).

const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;
const user_persist = @import("../modules/user/persistence.zig");

/// Context attribute names set by zigmodu's built-in JWT middleware
/// (`verifyJwtLoadPermsAndNext` in `api/Middleware.zig`).
pub const user_id_attr = "user_id";
pub const tenant_id_attr = "tenant_id";

/// The authenticated user id, or null when the JWT middleware did not run.
pub fn authUserId(ctx: *http.Context) ?i64 {
    const id_str = ctx.getAttr(user_id_attr) orelse return null;
    return std.fmt.parseInt(i64, id_str, 10) catch null;
}

/// The authenticated user's tenant id (from the JWT `aud` claim), or null
/// when the token predates tenant support.
pub fn authTenantId(ctx: *http.Context) ?i64 {
    const id_str = ctx.getAttr(tenant_id_attr) orelse return null;
    return std.fmt.parseInt(i64, id_str, 10) catch null;
}

/// 挂载在 `jwtAuthWithSecurity` 之后:比对 JWT 的 `ver` claim 与数据库中的
/// 用户凭证版本;改密/踢下线(版本递增)后旧 token 立即失效(401)。
pub fn tokenVersionGuard(sec: *zigmodu.security.AppSecurity, user_store: *user_persist.UserStore) http.Middleware {
    // 模块级 static:Zig 内嵌 fn 无法捕获外层参数(与 zigmodu 中间件同模式)。
    const S = struct {
        var stored_sec: *zigmodu.security.AppSecurity = undefined;
        var stored_store: *user_persist.UserStore = undefined;
    };
    S.stored_sec = sec;
    S.stored_store = user_store;
    return .{ .func = struct {
        fn mw(ctx: *http.Context, next: http.HandlerFn, _: ?*anyopaque) anyerror!void {
            const uid = authUserId(ctx) orelse {
                try ctx.sendErrorResponse(401, 401, "未登录或登录已过期");
                return;
            };
            const hdr = ctx.header("authorization") orelse {
                try ctx.sendErrorResponse(401, 401, "未登录或登录已过期");
                return;
            };
            const token = zigmodu.security.SecurityModule.extractBearerToken(hdr) orelse {
                try ctx.sendErrorResponse(401, 401, "未登录或登录已过期");
                return;
            };
            const payload = S.stored_sec.module.verifyToken(token) catch {
                try ctx.sendErrorResponse(401, 401, "未登录或登录已过期");
                return;
            };
            defer S.stored_sec.module.freePayload(payload);
            const row_opt = S.stored_store.getUserById(uid) catch {
                try ctx.sendErrorResponse(401, 401, "未登录或登录已过期");
                return;
            };
            const row = row_opt orelse {
                try ctx.sendErrorResponse(401, 401, "未登录或登录已过期");
                return;
            };
            defer row.free(ctx.allocator);
            if (payload.ver != row.token_version) {
                try ctx.sendErrorResponse(401, 401, "登录已失效,请重新登录");
                return;
            }
            try next(ctx);
        }
    }.mw };
}
