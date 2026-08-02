//! CORS middleware for zenaipa.
//!
//! zigmodu's built-in `cors` matches the request Origin with a case-sensitive
//! map lookup, so a browser's `Origin:` header is never seen and every origin
//! is silently treated as same-origin. This implementation reads the header
//! case-insensitively and enforces the configured allow-list: unknown origins
//! are rejected with 403.
//!
//! `allow_origins` accepts `"*"` (reflect `*`, dev only) or an exact
//! allow-list (reflect the request origin back).

const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;

pub fn cors(allow_origins: []const []const u8) http.Middleware {
    const S = struct {
        var stored: []const []const u8 = &.{};
    };
    S.stored = allow_origins;
    return .{ .func = struct {
        fn mw(ctx: *http.Context, next: http.HandlerFn, _: ?*anyopaque) anyerror!void {
            const origin = ctx.header("Origin") orelse "";

            var allowed = false;
            if (origin.len == 0) {
                allowed = true; // non-browser / same-origin request
            } else {
                for (S.stored) |o| {
                    if (std.mem.eql(u8, o, "*") or std.mem.eql(u8, o, origin)) {
                        allowed = true;
                        break;
                    }
                }
            }
            if (!allowed) {
                ctx.status_code = 403;
                ctx.responded = true;
                return;
            }

            const wildcard = S.stored.len == 1 and std.mem.eql(u8, S.stored[0], "*");
            if (origin.len > 0) {
                try ctx.setHeader("Access-Control-Allow-Origin", if (wildcard) "*" else origin);
                try ctx.setHeader("Vary", "Origin");
            }
            try ctx.setHeader("Access-Control-Allow-Methods", "GET,POST,PUT,DELETE,PATCH,HEAD,OPTIONS");
            try ctx.setHeader("Access-Control-Allow-Headers", "Content-Type,Authorization");
            try ctx.setHeader("Access-Control-Max-Age", "86400");

            if (ctx.method == .OPTIONS) {
                ctx.status_code = 204;
                ctx.responded = true;
                return;
            }
            try next(ctx);
        }
    }.mw };
}
