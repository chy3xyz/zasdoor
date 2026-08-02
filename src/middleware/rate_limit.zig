//! Rate-limit middleware for zenaipa HTTP handlers.
//!
//! Thin wrapper over zigmodu's token-bucket `RateLimiter`: consumes one
//! token per request and answers 429 while the bucket is empty. The limiter
//! is owned by `main.zig` and kept in module-scope storage (same pattern as
//! `jwtAuth`) because Zig inner functions cannot capture outer parameters.

const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;

/// Returns a middleware that consumes one token per request from `limiter`
/// and responds 429 when exhausted. Applies to a whole route group.
pub fn rateLimit(limiter: *zigmodu.RateLimiter) http.Middleware {
    const S = struct {
        var stored: *zigmodu.RateLimiter = undefined;
    };
    S.stored = limiter;
    return .{ .func = struct {
        fn mw(ctx: *http.Context, next: http.HandlerFn, _: ?*anyopaque) anyerror!void {
            if (!S.stored.tryAcquire()) {
                try ctx.sendErrorResponse(429, 429, "请求过于频繁，请稍后再试");
                return;
            }
            try next(ctx);
        }
    }.mw };
}
