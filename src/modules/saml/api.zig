//! SAML 2.0 SP HTTP API (server-root protocol endpoints + exchange).
const std = @import("std");
const zmodu = @import("zmodu");
const http = zmodu.http;
const mw = @import("../../middleware/auth.zig");
const service = @import("service.zig");
const config = @import("config.zig");
const idp_persist = @import("../mfa/persistence.zig");

pub fn SamlApi(comptime Service: type) type {
    return struct {
        const Self = @This();
        svc: *Service,
        mfa_store: *idp_persist.MfaStore,
        default_tenant_id: i64,

        pub fn init(svc: *Service, mfa_store: *idp_persist.MfaStore, default_tenant_id: i64) Self {
            return .{ .svc = svc, .mfa_store = mfa_store, .default_tenant_id = default_tenant_id };
        }

        pub fn registerRoutes(self: *Self, root: *http.Server) !void {
            try root.addRoute(.{ .method = .GET, .path = "saml/{id}/metadata", .handler = metadata, .user_data = @ptrCast(@alignCast(self)) });
            try root.addRoute(.{ .method = .GET, .path = "saml/{id}/login", .handler = login, .user_data = @ptrCast(@alignCast(self)) });
            try root.addRoute(.{ .method = .POST, .path = "saml/{id}/acs", .handler = acs, .user_data = @ptrCast(@alignCast(self)) });
            try root.addRoute(.{ .method = .GET, .path = "saml/{id}/acs", .handler = acsGet, .user_data = @ptrCast(@alignCast(self)) });
        }

        fn selfFrom(ctx: *http.Context) *Self {
            return @ptrCast(@alignCast(ctx.user_data orelse unreachable));
        }

        fn loadConfig(self: *Self, provider_id: i64) !?config.SamlConfig {
            const json = (try self.mfa_store.getIdpConfig(provider_id)) orelse return null;
            defer self.svc.allocator.free(json);
            return config.fromJson(self.svc.allocator, json) catch return null;
        }

        fn metadata(ctx: *http.Context) !void {
            const self = selfFrom(ctx);
            const id = ctx.paramInt(i64, "id") catch {
                ctx.status_code = 404;
                return;
            };
            const cfg = (try self.loadConfig(id)) orelse {
                ctx.status_code = 404;
                return;
            };
            defer cfg.deinit();
            const xml = try self.svc.metadataXml(id);
            defer self.svc.allocator.free(xml);
            try ctx.setHeader("Content-Type", "application/samlmetadata+xml; charset=utf-8");
            try ctx.setHeader("Cache-Control", "public, max-age=300");
            try ctx.text(200, xml);
        }

        fn login(ctx: *http.Context) !void {
            const self = selfFrom(ctx);
            const id = ctx.paramInt(i64, "id") catch {
                ctx.status_code = 404;
                return;
            };
            const cfg = (try self.loadConfig(id)) orelse {
                ctx.status_code = 404;
                return;
            };
            defer cfg.deinit();
            const redirect_to = ctx.queryParam("redirect_to") orelse "/";
            if (redirect_to.len > 1024 or !std.mem.startsWith(u8, redirect_to, "/") or std.mem.startsWith(u8, redirect_to, "//")) {
                ctx.status_code = 400;
                return;
            }
            // request id doubles as RelayState and FederatedState.state.
            var idbuf: [16]u8 = undefined;
            std.Io.randomSecure(self.svc.io, &idbuf) catch {
                ctx.status_code = 500;
                return;
            };
            const state = try std.fmt.allocPrint(self.svc.allocator, "_{s}", .{std.fmt.fmtSliceHexLower(&idbuf)});
            defer self.svc.allocator.free(state);
            const now = zmodu.time.wallClockSeconds(self.svc.io);
            try self.mfa_store.createFederatedState(self.default_tenant_id, id, state, redirect_to, now + 600, now);
            const req_b64 = try self.svc.buildAuthnRequest(cfg.sso_url, state, now, cfg.name_id_format);
            defer self.svc.allocator.free(req_b64);
            const sep: []const u8 = if (std.mem.indexOfScalar(u8, cfg.sso_url, '?') != null) "&" else "?";
            const url = try std.fmt.allocPrint(self.svc.allocator, "{s}{s}SAMLRequest={s}&RelayState={s}", .{ cfg.sso_url, sep, req_b64, state });
            defer self.svc.allocator.free(url);
            try ctx.setHeader("Location", url);
            try ctx.setHeader("Cache-Control", "no-store");
            try ctx.text(302, "");
        }

        fn acsGet(ctx: *http.Context) !void {
            ctx.status_code = 405;
            try ctx.text(405, "Method Not Allowed");
        }

        /// Assertion validation (XML-DSig) is not implemented yet. Fail closed.
        fn acs(ctx: *http.Context) !void {
            _ = ctx.user_data;
            try ctx.setHeader("Cache-Control", "no-store");
            ctx.status_code = 501;
            try ctx.text(501, "SAML assertion validation is not enabled");
        }
    };
}
