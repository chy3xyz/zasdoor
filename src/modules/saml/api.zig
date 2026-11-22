//! SAML 2.0 SP HTTP API (server-root protocol endpoints + exchange).
const std = @import("std");
const zmodu = @import("zmodu");
const http = zmodu.http;
const mw = @import("../../middleware/auth.zig");
const service = @import("service.zig");
const config = @import("config.zig");
const idp_persist = @import("../mfa/persistence.zig");
const xml = @import("xml.zig");
const pem = @import("pem.zig");
const dsig = @import("dsig.zig");

pub fn SamlApi(comptime Service: type, comptime UserService: type) type {
    return struct {
        const Self = @This();
        svc: *Service,
        mfa_store: *idp_persist.MfaStore,
        users: *UserService,
        default_tenant_id: i64,

        pub fn init(svc: *Service, mfa_store: *idp_persist.MfaStore, users: *UserService, default_tenant_id: i64) Self {
            return .{ .svc = svc, .mfa_store = mfa_store, .users = users, .default_tenant_id = default_tenant_id };
        }

        pub fn registerRoutes(self: *Self, root: *http.Server, v1: *http.RouteGroup) !void {
            try root.addRoute(.{ .method = .GET, .path = "saml/{id}/metadata", .handler = metadata, .user_data = @ptrCast(@alignCast(self)) });
            try root.addRoute(.{ .method = .GET, .path = "saml/{id}/login", .handler = login, .user_data = @ptrCast(@alignCast(self)) });
            try root.addRoute(.{ .method = .POST, .path = "saml/{id}/acs", .handler = acs, .user_data = @ptrCast(@alignCast(self)) });
            try root.addRoute(.{ .method = .GET, .path = "saml/{id}/acs", .handler = acsGet, .user_data = @ptrCast(@alignCast(self)) });
            try v1.post("/auth/saml/exchange", exchange, @ptrCast(@alignCast(self)));
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

        /// Assertion Consumer Service: verify the enveloped signature against
        /// pinned certs, extract facts, claim the assertion id once and issue
        /// a one-time ticket for the SPA exchange.
        fn acs(ctx: *http.Context) !void {
            const self = selfFrom(ctx);
            try ctx.setHeader("Cache-Control", "no-store");
            const id = ctx.paramInt(i64, "id") catch {
                ctx.status_code = 404;
                return;
            };
            const cfg = (try self.loadConfig(id)) orelse {
                ctx.status_code = 404;
                return;
            };
            defer cfg.deinit();

            const raw_b64 = ctx.formValue("SAMLResponse") orelse {
                ctx.status_code = 400;
                return;
            };
            const relay = ctx.formValue("RelayState");
            const dec = std.base64.standard.Decoder;
            const n = dec.calcSizeForSlice(raw_b64) catch {
                ctx.status_code = 400;
                return;
            };
            if (n > cfg.max_assertion_bytes) {
                ctx.status_code = 413;
                return;
            }
            const xml_bytes = self.svc.allocator.alloc(u8, n) catch {
                ctx.status_code = 500;
                return;
            };
            defer self.svc.allocator.free(xml_bytes);
            dec.decode(xml_bytes, raw_b64) catch {
                ctx.status_code = 400;
                return;
            };
            var doc = xml.parse(self.svc.allocator, xml_bytes, .{ .max_bytes = cfg.max_assertion_bytes }) catch {
                ctx.status_code = 400;
                return;
            };
            defer doc.deinit();

            // Decode pinned certificates (PEM -> DER) and verify SignedInfo.
            var pins = std.ArrayList(pem.Pin).empty;
            defer {
                for (pins.items) |p| p.free(self.svc.allocator);
                pins.deinit(self.svc.allocator);
            }
            for (cfg.pinned_certs) |pem_text| {
                const pin = pem.decodeCertificate(self.svc.allocator, pem_text) catch {
                    ctx.status_code = 500; // bad configuration, not a client error
                    return;
                };
                pins.append(self.svc.allocator, pin) catch {
                    pin.free(self.svc.allocator);
                    ctx.status_code = 500;
                    return;
                };
            }
            var ders = std.ArrayList([]const u8).empty;
            defer ders.deinit(self.svc.allocator);
            for (pins.items) |p| ders.append(self.svc.allocator, p.der) catch {
                ctx.status_code = 500;
                return;
            };
            dsig.verifySignature(self.svc.allocator, doc.root, ders.items, false) catch {
                ctx.status_code = 400;
                return;
            };

            // Consume the single-use login state (RelayState = request id).
            if (relay) |state| {
                const row = self.mfa_store.findFederatedState(state) catch {
                    ctx.status_code = 400;
                    return;
                };
                if (row == null) {
                    ctx.status_code = 400;
                    return;
                }
                var st = row.?;
                defer st.free(self.svc.allocator);
                if (st.provider_id != id or st.used or st.expires_at < zmodu.time.wallClockSeconds(self.svc.io)) {
                    ctx.status_code = 400;
                    return;
                }
                self.mfa_store.markFederatedStateUsed(st.id, zmodu.time.wallClockSeconds(self.svc.io)) catch {
                    ctx.status_code = 500;
                    return;
                };
            }

            const facts = self.svc.extractAssertion(doc.root, &cfg) catch {
                ctx.status_code = 400;
                return;
            };
            defer facts.deinit(self.svc.allocator);

            // Resolve a local user by cached email (linking by NameID will be
            // added with full attribute mapping). Fail closed when absent.
            const email = facts.email;
            if (email.len == 0) {
                ctx.status_code = 400;
                return;
            }
            const row_opt = self.svc.store.getUserByEmail(email) catch {
                ctx.status_code = 500;
                return;
            };
            const user = row_opt orelse {
                ctx.status_code = 400;
                return;
            };
            defer user.free(self.svc.allocator);

            const now = zmodu.time.wallClockSeconds(self.svc.io);
            if (!(try self.svc.store.claimAssertion(self.default_tenant_id, id, facts.name_id, now + 300, now))) {
                ctx.status_code = 400;
                return;
            }
            const ticket = try self.svc.createTicket(self.default_tenant_id, id, user.id, "/", now);
            defer self.svc.allocator.free(ticket);
            const loc = try std.fmt.allocPrint(self.svc.allocator, "{s}/saml/complete?ticket={s}", .{ self.svc.app_host, ticket });
            defer self.svc.allocator.free(loc);
            try ctx.setHeader("Location", loc);
            try ctx.text(303, "");
        }

        /// Exchange a one-time SAML ticket for the normal platform JWT.
        fn exchange(ctx: *http.Context) !void {
            const self = selfFrom(ctx);
            const Req = struct { ticket: []const u8 };
            const req = ctx.bindJsonLoose(Req) catch {
                try ctx.sendErrorResponse(400, 400, "请求体格式错误");
                return;
            };
            defer ctx.allocator.free(req.ticket);
            const row_opt = self.svc.store.consumeTicket(req.ticket, zmodu.time.wallClockSeconds(self.svc.io)) catch {
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            const ticket = row_opt orelse {
                try ctx.sendErrorResponse(400, 400, "登录凭证无效或已过期");
                return;
            };
            defer ticket.free(self.svc.allocator);
            const row_opt2 = self.users.getUserById(ticket.user_id) catch {
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            const user = row_opt2 orelse {
                try ctx.sendErrorResponse(400, 400, "登录凭证无效或已过期");
                return;
            };
            defer user.free(self.users.store.allocator);
            var idbuf: [32]u8 = undefined;
            const uid_str = try std.fmt.bufPrint(&idbuf, "{d}", .{user.id});
            var tbuf: [32]u8 = undefined;
            const tenant_str = try std.fmt.bufPrint(&tbuf, "{d}", .{user.tenant_id});
            const roles: []const []const u8 = if (user.admin) &[_][]const u8{"admin"} else &[_][]const u8{"user"};
            const token = self.users.sec.module.generateTokenWithTenantAndVersion(uid_str, roles, tenant_str, user.token_version) catch {
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            defer self.users.sec.module.allocator.free(token);
            try ctx.jsonStruct(200, .{
                .code = 0,
                .msg = "登录成功",
                .data = .{
                    .token = token,
                    .user = .{ .id = user.id, .name = user.name, .email = user.email, .admin = user.admin, .tenant_id = user.tenant_id },
                    .redirect_to = ticket.redirect_to,
                },
            });
        }
    };
}
