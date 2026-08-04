//! Auth helpers for zenaipa HTTP handlers.
//!
//! JWT verification uses zigmodu's built-in `jwtAuthWithSecurity` middleware
//! (mounted per route group in the module `api.zig` files). The helpers here
//! read the context attributes that middleware sets: `user_id` (JWT `sub`)
//! and `tenant_id` (JWT `aud`).

const std = @import("std");
const http = @import("zigmodu").http;

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
