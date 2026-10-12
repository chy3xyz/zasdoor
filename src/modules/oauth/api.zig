//! OAuth2 / OIDC HTTP endpoints (public protocol surface).
//!
//! These routes implement the standard OAuth2 / OIDC protocol surface:
//! discovery, jwks, authorize, token, introspect, revoke, userinfo.

const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;
const service = @import("service.zig");
const user_svc = @import("../user/service.zig");
const jwt = @import("jwt.zig");

pub fn OAuthApi(comptime Service: type, comptime UserService: type) type {
    return struct {
        const Self = @This();
        svc: *Service,
        users: *UserService,

        /// Live instance pointer for the static handler closures.
        const Stored = struct {
            var instance: ?*Self = null;
        };

        pub fn init(svc: *Service, users: *UserService) Self {
            return .{ .svc = svc, .users = users };
        }

        pub fn registerRoutes(self: *Self, server: *http.Server) !void {
            // Store the live instance so the static handler closures can reach it.
            Stored.instance = self;
            // Discovery + JWKS (public, no auth).
            try server.addRoute(.{
                .method = .GET,
                .path = ".well-known/openid-configuration",
                .handler = struct {
                    fn h(ctx: *http.Context) !void {
                        const s = Stored.instance orelse return error.UnexpectedError;
                        try s.discovery(ctx);
                    }
                }.h,
                .user_data = self,
            });
            try server.addRoute(.{
                .method = .GET,
                .path = ".well-known/jwks.json",
                .handler = struct {
                    fn h(ctx: *http.Context) !void {
                        const s = Stored.instance orelse return error.UnexpectedError;
                        try s.jwks(ctx);
                    }
                }.h,
                .user_data = self,
            });
            try server.addRoute(.{
                .method = .GET,
                .path = "oauth/authorize",
                .handler = struct {
                    fn h(ctx: *http.Context) !void {
                        const s = Stored.instance orelse return error.UnexpectedError;
                        try s.authorize(ctx);
                    }
                }.h,
                .user_data = self,
            });
            try server.addRoute(.{
                .method = .POST,
                .path = "oauth/authorize",
                .handler = struct {
                    fn h(ctx: *http.Context) !void {
                        const s = Stored.instance orelse return error.UnexpectedError;
                        try s.authorize(ctx);
                    }
                }.h,
                .user_data = self,
            });
            try server.addRoute(.{
                .method = .POST,
                .path = "oauth/token",
                .handler = struct {
                    fn h(ctx: *http.Context) !void {
                        const s = Stored.instance orelse return error.UnexpectedError;
                        try s.token(ctx);
                    }
                }.h,
                .user_data = self,
            });
            try server.addRoute(.{
                .method = .POST,
                .path = "oauth/introspect",
                .handler = struct {
                    fn h(ctx: *http.Context) !void {
                        const s = Stored.instance orelse return error.UnexpectedError;
                        try s.introspect(ctx);
                    }
                }.h,
                .user_data = self,
            });
            try server.addRoute(.{
                .method = .POST,
                .path = "oauth/revoke",
                .handler = struct {
                    fn h(ctx: *http.Context) !void {
                        const s = Stored.instance orelse return error.UnexpectedError;
                        try s.revoke(ctx);
                    }
                }.h,
                .user_data = self,
            });
            try server.addRoute(.{
                .method = .GET,
                .path = "oauth/userinfo",
                .handler = struct {
                    fn h(ctx: *http.Context) !void {
                        const s = Stored.instance orelse return error.UnexpectedError;
                        try s.userinfo(ctx);
                    }
                }.h,
                .user_data = self,
            });
            // RP-initiated logout (OIDC end_session).
            inline for (.{ .GET, .POST }) |method| {
                try server.addRoute(.{
                    .method = method,
                    .path = "oauth/end-session",
                    .handler = struct {
                        fn h(ctx: *http.Context) !void {
                            const s = Stored.instance orelse return error.UnexpectedError;
                            try s.endSession(ctx);
                        }
                    }.h,
                    .user_data = self,
                });
            }
            // RFC 8628 device authorization grant.
            try server.addRoute(.{
                .method = .POST,
                .path = "oauth/device_authorization",
                .handler = struct {
                    fn h(ctx: *http.Context) !void {
                        const s = Stored.instance orelse return error.UnexpectedError;
                        try s.deviceAuthorization(ctx);
                    }
                }.h,
                .user_data = self,
            });
            try server.addRoute(.{
                .method = .POST,
                .path = "oauth/device",
                .handler = struct {
                    fn h(ctx: *http.Context) !void {
                        const s = Stored.instance orelse return error.UnexpectedError;
                        try s.deviceConfirm(ctx);
                    }
                }.h,
                .user_data = self,
            });
        }

        // ── Discovery ─────────────────────────────────────────

        fn discovery(self: *Self, ctx: *http.Context) !void {
            const json = try discoveryJson(ctx.allocator, self.svc.issuer, self.svc.ring.alg().name());
            defer ctx.allocator.free(json);
            try ctx.json(200, json);
        }

        fn jwks(self: *Self, ctx: *http.Context) !void {
            // Publish the real asymmetric public key (never private material).
            const json = try self.svc.ring.jwksJson(ctx.allocator);
            defer ctx.allocator.free(json);
            try ctx.json(200, json);
        }

        // ── Authorize ─────────────────────────────────────────

        fn authorize(self: *Self, ctx: *http.Context) !void {
            const client_id = ctx.queryParam("client_id") orelse {
                try self.oauthError(ctx, 400, "invalid_request", "missing client_id");
                return;
            };
            const redirect_uri = ctx.queryParam("redirect_uri") orelse {
                try self.oauthError(ctx, 400, "invalid_request", "missing redirect_uri");
                return;
            };
            const response_type = ctx.queryParam("response_type") orelse "code";
            const scope = ctx.queryParam("scope") orelse "openid";
            const state = ctx.queryParam("state");
            const nonce = ctx.queryParam("nonce");
            const code_challenge = ctx.queryParam("code_challenge");
            const code_challenge_method = ctx.queryParam("code_challenge_method");

            const consent_granted = truthyParam(ctx.formValue("consent_granted") orelse ctx.queryParam("consent_granted"));

            // Resolve the currently-authenticated user, if any. For a first
            // implementation, a Bearer token identifies the user (resource-owner
            // style); otherwise this is treated as an unauthenticated request.
            const user_id = self.authenticatedUserId(ctx) orelse {
                try self.oauthError(ctx, 401, "unauthorized", "login required");
                return;
            };

            const outcome = self.svc.authorizeWithConsent(
                client_id,
                redirect_uri,
                response_type,
                scope,
                state,
                nonce,
                code_challenge,
                code_challenge_method,
                user_id,
                consent_granted,
            ) catch |err| {
                try self.oauthErrorFrom(ctx, err);
                return;
            };

            switch (outcome) {
                .consent_required => |cr| {
                    // Envelope consent challenge: retry with consent_granted=true.
                    defer ctx.allocator.free(cr.scopes);
                    const json = try consentRequiredJson(ctx.allocator, cr.scopes);
                    defer ctx.allocator.free(json);
                    try ctx.json(200, json);
                },
                .issued => |result| {
                    defer ctx.allocator.free(result.code);
                    defer ctx.allocator.free(result.redirect_uri);
                    defer if (result.state) |st| ctx.allocator.free(st);

                    // Build the redirect URL: redirect_uri?code=...&state=...
                    var url: []const u8 = undefined;
                    if (result.state) |st| {
                        url = try std.fmt.allocPrint(ctx.allocator, "{s}?code={s}&state={s}", .{ result.redirect_uri, result.code, st });
                    } else {
                        url = try std.fmt.allocPrint(ctx.allocator, "{s}?code={s}", .{ result.redirect_uri, result.code });
                    }
                    defer ctx.allocator.free(url);
                    try ctx.setHeader("Location", url);
                    try ctx.text(302, "");
                },
            }
        }

        fn authenticatedUserId(self: *Self, ctx: *http.Context) ?i64 {
            const hdr = ctx.header("authorization") orelse return null;
            const tok = zigmodu.security.SecurityModule.extractBearerToken(hdr) orelse return null;
            const payload = self.svc.sec.module.verifyToken(tok) catch return null;
            defer self.svc.sec.module.freePayload(payload);
            return std.fmt.parseInt(i64, payload.sub, 10) catch null;
        }

        // ── Token ─────────────────────────────────────────────

        fn token(self: *Self, ctx: *http.Context) !void {
            const grant_type = ctx.formValue("grant_type") orelse {
                try self.oauthError(ctx, 400, "invalid_request", "missing grant_type");
                return;
            };
            const client_id = ctx.formValue("client_id") orelse "";
            const client_secret = ctx.formValue("client_secret") orelse "";
            const code = ctx.formValue("code");
            const redirect_uri = ctx.formValue("redirect_uri");
            const code_verifier = ctx.formValue("code_verifier");
            const scope = ctx.formValue("scope");
            const refresh_token = ctx.formValue("refresh_token");
            const device_code = ctx.formValue("device_code");

            var issue: service.OAuthService.TokenIssue = undefined;
            if (std.mem.eql(u8, grant_type, service.OAuthService.token_exchange_grant)) {
                issue = self.svc.tokenExchange(
                    client_id,
                    client_secret,
                    ctx.formValue("subject_token") orelse "",
                    ctx.formValue("subject_token_type") orelse "",
                    ctx.formValue("actor_token"),
                    ctx.formValue("actor_token_type"),
                    ctx.formValue("requested_token_type"),
                    ctx.formValue("audience"),
                    scope,
                ) catch |err| {
                    try self.oauthErrorFrom(ctx, err);
                    return;
                };
            } else {
                issue = self.svc.token(grant_type, client_id, client_secret, code, redirect_uri, code_verifier, scope, refresh_token, device_code) catch |err| {
                    try self.oauthErrorFrom(ctx, err);
                    return;
                };
            }
            defer self.freeTokenIssue(ctx.allocator, issue);

            // Serialize the token response (raw OAuth JSON, not the envelope).
            const json = try self.tokenResponseJson(ctx.allocator, issue);
            defer ctx.allocator.free(json);
            try ctx.json(200, json);
        }

        fn tokenResponseJson(self: *Self, a: std.mem.Allocator, t: service.OAuthService.TokenIssue) ![]const u8 {
            _ = self;
            var buf = std.ArrayList(u8).empty;
            errdefer buf.deinit(a);
            var num_buf: [24]u8 = undefined;
            const exp_s = try std.fmt.bufPrint(&num_buf, "{d}", .{t.expires_in});
            try buf.appendSlice(a, "{\"access_token\":\"");
            try buf.appendSlice(a, t.access_token);
            try buf.appendSlice(a, "\",\"token_type\":\"Bearer\",\"expires_in\":");
            try buf.appendSlice(a, exp_s);
            if (t.id_token) |it| {
                try buf.appendSlice(a, ",\"id_token\":\"");
                try buf.appendSlice(a, it);
                try buf.appendSlice(a, "\"");
            }
            if (t.refresh_token) |rt| {
                try buf.appendSlice(a, ",\"refresh_token\":\"");
                try buf.appendSlice(a, rt);
                try buf.appendSlice(a, "\"");
            }
            try buf.appendSlice(a, ",\"scope\":\"");
            try buf.appendSlice(a, t.scope);
            if (t.issued_token_type) |it| {
                try buf.appendSlice(a, "\",\"issued_token_type\":\"");
                try buf.appendSlice(a, it);
                try buf.appendSlice(a, "\"");
            }
            try buf.appendSlice(a, "\"}");
            return try buf.toOwnedSlice(a);
        }

        fn freeTokenIssue(self: *Self, a: std.mem.Allocator, t: service.OAuthService.TokenIssue) void {
            _ = self;
            a.free(t.access_token);
            if (t.id_token) |it| a.free(it);
            if (t.refresh_token) |rt| a.free(rt);
            a.free(t.scope);
        }

        // ── Introspect ────────────────────────────────────────

        fn introspect(self: *Self, ctx: *http.Context) !void {
            const tok = ctx.formValue("token") orelse {
                try ctx.json(200, "{\"active\":false}");
                return;
            };
            const r = self.svc.introspect(tok);
            const json = try std.fmt.allocPrint(
                ctx.allocator,
                "{{\"active\":{s},\"sub\":{s},\"scope\":{s},\"client_id\":{s},\"exp\":{s}}}",
                .{
                    if (r.active) "true" else "false",
                    r.sub orelse "null",
                    r.scope orelse "null",
                    r.client_id orelse "null",
                    if (r.exp) |e| try std.fmt.allocPrint(ctx.allocator, "{d}", .{e}) else "null",
                },
            );
            defer ctx.allocator.free(json);
            try ctx.json(200, json);
        }

        // ── Revoke ────────────────────────────────────────────

        fn revoke(self: *Self, ctx: *http.Context) !void {
            // Refresh-token revocation: hash and mark revoked (best-effort).
            const tok = ctx.formValue("token") orelse {
                try ctx.text(200, "");
                return;
            };
            const hash = service.hashToken(ctx.allocator, tok) catch {
                try ctx.text(200, "");
                return;
            };
            defer ctx.allocator.free(hash);
            const row_opt = self.svc.iam_svc.store.findRefreshTokenByHash(hash) catch null;
            if (row_opt) |row| {
                row.free(self.svc.iam_svc.allocator);
                self.svc.iam_svc.store.revokeRefreshToken(row.id, zigmodu.time.wallClockSeconds(self.svc.io)) catch {};
            }
            try ctx.text(200, "");
        }

        // ── Userinfo ──────────────────────────────────────────

        fn userinfo(self: *Self, ctx: *http.Context) !void {
            const hdr = ctx.header("authorization") orelse {
                try ctx.setHeader("WWW-Authenticate", "Bearer");
                try ctx.text(401, "");
                return;
            };
            const tok = zigmodu.security.SecurityModule.extractBearerToken(hdr) orelse {
                try ctx.setHeader("WWW-Authenticate", "Bearer");
                try ctx.text(401, "");
                return;
            };
            const payload = self.svc.verifyToken(ctx.allocator, tok) catch {
                try ctx.setHeader("WWW-Authenticate", "Bearer");
                try ctx.text(401, "");
                return;
            };
            defer ctx.allocator.free(payload);

            const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, payload, .{}) catch {
                try ctx.setHeader("WWW-Authenticate", "Bearer");
                try ctx.text(401, "");
                return;
            };
            defer parsed.deinit();
            const root = parsed.value;
            const sub = self.objStr(root, "sub") orelse {
                try ctx.text(400, "");
                return;
            };
            const uid = std.fmt.parseInt(i64, sub, 10) catch {
                try ctx.text(400, "");
                return;
            };
            const row_opt = self.users.getUserById(uid) catch null;
            const row = row_opt orelse {
                try ctx.text(400, "");
                return;
            };
            defer row.free(self.users.store.allocator);

            const scope = self.objStr(root, "scope") orelse "";
            var buf = std.ArrayList(u8).empty;
            defer buf.deinit(ctx.allocator);
            try buf.appendSlice(ctx.allocator, "{\"sub\":\"");
            try buf.appendSlice(ctx.allocator, sub);
            try buf.appendSlice(ctx.allocator, "\",\"name\":\"");
            try buf.appendSlice(ctx.allocator, row.name);
            try buf.appendSlice(ctx.allocator, "\",\"email\":\"");
            try buf.appendSlice(ctx.allocator, row.email);
            try buf.appendSlice(ctx.allocator, "\",\"email_verified\":");
            try buf.appendSlice(ctx.allocator, if (row.verified) "true" else "false");
            if (std.mem.indexOf(u8, scope, "phone") != null and row.phone.len > 0) {
                try buf.appendSlice(ctx.allocator, ",\"phone_number\":\"");
                try buf.appendSlice(ctx.allocator, row.phone);
                try buf.appendSlice(ctx.allocator, "\",\"phone_number_verified\":false");
            }
            if (std.mem.indexOf(u8, scope, "address") != null and row.address.len > 0) {
                try buf.appendSlice(ctx.allocator, ",\"address\":{\"formatted\":\"");
                try buf.appendSlice(ctx.allocator, row.address);
                try buf.appendSlice(ctx.allocator, "\"}");
            }
            try buf.append(ctx.allocator, '}');
            try ctx.json(200, buf.items);
        }

        /// OIDC RP-initiated logout: revoke the user's sessions (token version)
        /// and, when a registered post_logout_redirect_uri is supplied, redirect.
        fn endSession(self: *Self, ctx: *http.Context) !void {
            const post_logout = ctx.formValue("post_logout_redirect_uri") orelse ctx.queryParam("post_logout_redirect_uri");
            const state = ctx.formValue("state") orelse ctx.queryParam("state");
            const client_id_param = ctx.formValue("client_id") orelse ctx.queryParam("client_id");
            const id_token_hint = ctx.formValue("id_token_hint") orelse ctx.queryParam("id_token_hint");

            var user_id: ?i64 = null;
            var aud: ?[]const u8 = null;
            if (id_token_hint) |hint| {
                if (self.svc.verifyToken(ctx.allocator, hint)) |payload| {
                    defer ctx.allocator.free(payload);
                    if (std.json.parseFromSlice(std.json.Value, ctx.allocator, payload, .{})) |parsed| {
                        defer parsed.deinit();
                        if (self.objStr(parsed.value, "sub")) |s| user_id = std.fmt.parseInt(i64, s, 10) catch null;
                        aud = self.objStr(parsed.value, "aud");
                    } else |_| {}
                } else |_| {}
            }

            if (user_id) |uid| {
                self.svc.users.store.bumpTokenVersion(uid, self.svc.now()) catch |err| {
                    std.log.warn("[oauth] end-session token-version bump failed (user {d}): {s}", .{ uid, @errorName(err) });
                };
            }

            const client_id = client_id_param orelse (aud orelse "");
            if (post_logout) |uri| {
                if (client_id.len == 0) {
                    try self.oauthError(ctx, 400, "invalid_request", "post_logout_redirect_uri requires client_id or id_token_hint");
                    return;
                }
                const app_opt = self.svc.iam_svc.getApplicationByClientId(client_id) catch null;
                if (app_opt) |app| {
                    defer app.free(self.svc.iam_svc.allocator);
                    if (service.jsonListContains(app.post_logout_redirect_uris, uri)) {
                        const loc = if (state) |st|
                            try std.fmt.allocPrint(ctx.allocator, "{s}?state={s}", .{ uri, st })
                        else
                            try std.fmt.allocPrint(ctx.allocator, "{s}", .{uri});
                        defer ctx.allocator.free(loc);
                        try ctx.setHeader("Location", loc);
                        try ctx.text(302, "");
                        return;
                    }
                }
                try self.oauthError(ctx, 400, "invalid_request", "post_logout_redirect_uri not registered");
                return;
            }
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "logged out", .data = null });
        }

        /// POST /oauth/device_authorization — start a device grant.
        fn deviceAuthorization(self: *Self, ctx: *http.Context) !void {
            const client_id = ctx.formValue("client_id") orelse ctx.queryParam("client_id") orelse {
                try self.oauthError(ctx, 400, "invalid_request", "missing client_id");
                return;
            };
            const scope = ctx.formValue("scope") orelse ctx.queryParam("scope") orelse "";
            const da = self.svc.deviceAuthorization(client_id, scope) catch |err| {
                try self.oauthErrorFrom(ctx, err);
                return;
            };
            defer self.svc.freeDeviceAuthorization(da);
            const json = try std.fmt.allocPrint(
                ctx.allocator,
                "{{\"device_code\":\"{s}\",\"user_code\":\"{s}\",\"verification_uri\":\"{s}\",\"verification_uri_complete\":\"{s}\",\"expires_in\":{d},\"interval\":{d}}}",
                .{ da.device_code, da.user_code, da.verification_uri, da.verification_uri_complete, da.expires_in, da.interval },
            );
            defer ctx.allocator.free(json);
            try ctx.json(200, json);
        }

        /// POST /oauth/device — approve (default) or deny a user_code while
        /// signed in. Body/query: user_code, approve=true|false (or deny=true).
        fn deviceConfirm(self: *Self, ctx: *http.Context) !void {
            const uid = self.authenticatedUserId(ctx) orelse {
                try self.oauthError(ctx, 401, "unauthorized", "login required");
                return;
            };
            const user_code = ctx.formValue("user_code") orelse ctx.queryParam("user_code") orelse {
                try self.oauthError(ctx, 400, "invalid_request", "missing user_code");
                return;
            };
            const deny_raw = ctx.formValue("deny") orelse ctx.queryParam("deny");
            const approve_raw = ctx.formValue("approve") orelse ctx.queryParam("approve");
            const approve = if (deny_raw) |d|
                !truthyParam(d)
            else if (approve_raw) |a|
                truthyParam(a)
            else
                true;
            self.svc.deviceResolve(user_code, uid, approve) catch |err| {
                try self.oauthErrorFrom(ctx, err);
                return;
            };
            try ctx.jsonStruct(200, .{ .code = 0, .msg = if (approve) "approved" else "denied", .data = null });
        }

        fn objStr(self: *Self, v: std.json.Value, k: []const u8) ?[]const u8 {
            _ = self;
            if (v != .object) return null;
            const m = v.object;
            const val = m.get(k) orelse return null;
            return switch (val) {
                .string => |s| s,
                else => null,
            };
        }

        // ── Error helpers ─────────────────────────────────────

        fn oauthError(self: *Self, ctx: *http.Context, status: u16, err_code: []const u8, desc: []const u8) !void {
            _ = self;
            const json = try std.fmt.allocPrint(ctx.allocator, "{{\"error\":\"{s}\",\"error_description\":\"{s}\"}}", .{ err_code, desc });
            defer ctx.allocator.free(json);
            try ctx.json(status, json);
        }

        fn oauthErrorFrom(self: *Self, ctx: *http.Context, err: anyerror) !void {
            switch (err) {
                error.InvalidRequest => try self.oauthError(ctx, 400, "invalid_request", "invalid request"),
                error.InvalidClient => try self.oauthError(ctx, 401, "invalid_client", "invalid client"),
                error.UnauthorizedClient => try self.oauthError(ctx, 400, "unauthorized_client", "unauthorized client"),
                error.UnsupportedGrantType => try self.oauthError(ctx, 400, "unsupported_grant_type", "unsupported grant type"),
                error.InvalidGrant => try self.oauthError(ctx, 400, "invalid_grant", "invalid grant"),
                error.InvalidScope => try self.oauthError(ctx, 400, "invalid_scope", "invalid scope"),
                error.AuthorizationPending => try self.oauthError(ctx, 400, "authorization_pending", "authorization pending"),
                error.SlowDown => try self.oauthError(ctx, 400, "slow_down", "polling too frequently"),
                error.AccessDenied => try self.oauthError(ctx, 400, "access_denied", "user denied the request"),
                error.ExpiredToken => try self.oauthError(ctx, 400, "expired_token", "device code expired"),
                else => try self.oauthError(ctx, 500, "server_error", "internal error"),
            }
        }
    };
}
/// Render the OIDC discovery document. `signing_alg` must match the key
/// published at /.well-known/jwks.json.
pub fn discoveryJson(allocator: std.mem.Allocator, issuer: []const u8, signing_alg: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"issuer\":\"{s}\",\"authorization_endpoint\":\"{s}/oauth/authorize\",\"token_endpoint\":\"{s}/oauth/token\",\"introspection_endpoint\":\"{s}/oauth/introspect\",\"revocation_endpoint\":\"{s}/oauth/revoke\",\"userinfo_endpoint\":\"{s}/oauth/userinfo\",\"end_session_endpoint\":\"{s}/oauth/end-session\",\"device_authorization_endpoint\":\"{s}/oauth/device_authorization\",\"jwks_uri\":\"{s}/.well-known/jwks.json\",\"response_types_supported\":[\"code\"],\"grant_types_supported\":[\"authorization_code\",\"client_credentials\",\"refresh_token\",\"urn:ietf:params:oauth:grant-type:device_code\",\"urn:ietf:params:oauth:grant-type:token-exchange\"],\"subject_types_supported\":[\"public\"],\"id_token_signing_alg_values_supported\":[\"{s}\"],\"scopes_supported\":[\"openid\",\"profile\",\"email\",\"address\",\"phone\",\"offline_access\"],\"token_endpoint_auth_methods_supported\":[\"client_secret_basic\",\"client_secret_post\"],\"code_challenge_methods_supported\":[\"plain\",\"S256\"]}}",
        .{ issuer, issuer, issuer, issuer, issuer, issuer, issuer, issuer, issuer, signing_alg },
    );
}

/// Truthy query/form flag ("true", "1", "yes").
fn truthyParam(v: ?[]const u8) bool {
    const s = v orelse return false;
    return std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "1") or std.mem.eql(u8, s, "yes");
}

/// Envelope-shaped consent challenge:
/// {"code":0,"msg":"consent_required","data":{"consent_required":true,"scopes":[...]}}.
fn consentRequiredJson(a: std.mem.Allocator, scopes: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(a);
    try buf.appendSlice(a, "{\"code\":0,\"msg\":\"consent_required\",\"data\":{\"consent_required\":true,\"scopes\":[");
    var it = std.mem.tokenizeAny(u8, scopes, " \t");
    var first = true;
    while (it.next()) |s| {
        if (!first) try buf.appendSlice(a, ",");
        first = false;
        try buf.appendSlice(a, "\"");
        try buf.appendSlice(a, s);
        try buf.appendSlice(a, "\"");
    }
    try buf.appendSlice(a, "]}}");
    return buf.toOwnedSlice(a);
}
