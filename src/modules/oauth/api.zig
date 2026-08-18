//! OAuth2 / OIDC HTTP endpoints (public protocol surface).
//!
//! These routes implement the standard ZITADEL-compatible surface:
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
        }

        // ── Discovery ─────────────────────────────────────────

        fn discovery(self: *Self, ctx: *http.Context) !void {
            const iss = self.svc.issuer;
            const json = try std.fmt.allocPrint(
                ctx.allocator,
                "{{\"issuer\":\"{s}\",\"authorization_endpoint\":\"{s}/oauth/authorize\",\"token_endpoint\":\"{s}/oauth/token\",\"introspection_endpoint\":\"{s}/oauth/introspect\",\"revocation_endpoint\":\"{s}/oauth/revoke\",\"userinfo_endpoint\":\"{s}/oauth/userinfo\",\"jwks_uri\":\"{s}/.well-known/jwks.json\",\"response_types_supported\":[\"code\"],\"grant_types_supported\":[\"authorization_code\",\"client_credentials\",\"refresh_token\"],\"subject_types_supported\":[\"public\"],\"id_token_signing_alg_values_supported\":[\"HS256\"],\"scopes_supported\":[\"openid\",\"profile\",\"email\",\"offline_access\"],\"token_endpoint_auth_methods_supported\":[\"client_secret_basic\",\"client_secret_post\"],\"code_challenge_methods_supported\":[\"plain\",\"S256\"]}}",
                .{ iss, iss, iss, iss, iss, iss, iss },
            );
            defer ctx.allocator.free(json);
            try ctx.json(200, json);
        }

        fn jwks(self: *Self, ctx: *http.Context) !void {
            // HS256 is a symmetric algorithm; there is no public key to expose.
            // We publish an empty key set (standard for symmetric signing).
            _ = self;
            try ctx.json(200, "{\"keys\":[]}");
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

            // Resolve the currently-authenticated user, if any. For a first
            // implementation, a Bearer token identifies the user (resource-owner
            // style); otherwise this is treated as an unauthenticated request.
            const user_id = self.authenticatedUserId(ctx) orelse {
                try self.oauthError(ctx, 401, "unauthorized", "login required");
                return;
            };

            const result = self.svc.authorize(
                client_id,
                redirect_uri,
                response_type,
                scope,
                state,
                nonce,
                code_challenge,
                code_challenge_method,
                user_id,
            ) catch |err| {
                try self.oauthErrorFrom(ctx, err);
                return;
            };
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

            const issue = self.svc.token(grant_type, client_id, client_secret, code, redirect_uri, code_verifier, scope, refresh_token) catch |err| {
                try self.oauthErrorFrom(ctx, err);
                return;
            };
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
            const payload = jwt.verify(ctx.allocator, self.svc.sec.module.jwt_secret, tok) catch {
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
            const json = try std.fmt.allocPrint(
                ctx.allocator,
                "{{\"sub\":\"{s}\",\"name\":\"{s}\",\"email\":\"{s}\",\"email_verified\":{s}}}",
                .{ sub, row.name, row.email, if (row.verified) "true" else "false" },
            );
            _ = scope;
            defer ctx.allocator.free(json);
            try ctx.json(200, json);
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
                else => try self.oauthError(ctx, 500, "server_error", "internal error"),
            }
        }
    };
}
