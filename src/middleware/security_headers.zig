//! Security response headers (HSTS, X-Frame-Options, nosniff, referrer
//! policy, download/ DNS protections) — zmodu defaults, one call.

const zmodu = @import("zmodu");
const http = zmodu.http;

// zmodu v0.39 allocates a per-instance header store, so the factory is
// fallible; callers use `try` (see main.zig).
pub fn securityHeaders() error{OutOfMemory}!http.Middleware {
    return http.http_middleware.securityHeaders(null);
}
