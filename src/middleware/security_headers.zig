//! Security response headers (HSTS, X-Frame-Options, nosniff, referrer
//! policy, download/ DNS protections) — zigmodu defaults, one call.

const zigmodu = @import("zigmodu");
const http = zigmodu.http;

pub fn securityHeaders() http.Middleware {
    return http.http_middleware.securityHeaders(null);
}
