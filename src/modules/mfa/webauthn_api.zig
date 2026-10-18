//! WebAuthn / passkey HTTP API.
//!
//! Public passkey login: POST /mfa/webauthn/login/begin|finish (raw options /
//! session JWT). Registration and credential management require a session.

const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;
const mw = @import("../../middleware/auth.zig");
const service = @import("webauthn.zig");

pub fn WebauthnApi(comptime Service: type, comptime UserService: type) type {
    return struct {
        const Self = @This();
        svc: *Service,
        users: *UserService,
        registry: *zigmodu.RateLimiterRegistry,
        default_tenant_id: i64,

        pub fn init(svc: *Service, users: *UserService, registry: *zigmodu.RateLimiterRegistry, default_tenant_id: i64) Self {
            return .{ .svc = svc, .users = users, .registry = registry, .default_tenant_id = default_tenant_id };
        }

        pub fn registerRoutes(self: *Self, group: *http.RouteGroup) !void {
            // Public: passkey login (challenge + assertion). Rate-limited per
            // client IP so challenge rows cannot be farmed without bound.
            var public_group = try group.use(try zigmodu.http.tracing_middleware.rateLimitPerClient(self.registry, clientIpKey));
            try public_group.post("/mfa/webauthn/login/begin", loginBegin, @ptrCast(@alignCast(self)));
            try public_group.post("/mfa/webauthn/login/finish", loginFinish, @ptrCast(@alignCast(self)));

            var g = try group.use(zigmodu.http.http_middleware.jwtAuthWithSecurity(&self.users.sec.module));
            g = try g.use(mw.tokenVersionGuard(self.users.sec, self.users.store));
            try g.post("/mfa/webauthn/register/begin", registerBegin, @ptrCast(@alignCast(self)));
            try g.post("/mfa/webauthn/register/finish", registerFinish, @ptrCast(@alignCast(self)));
            try g.get("/mfa/webauthn/credentials", listCredentials, @ptrCast(@alignCast(self)));
            try g.delete("/mfa/webauthn/credentials/{id}", deleteCredential, @ptrCast(@alignCast(self)));
        }

        const LoginBeginReq = struct { email: []const u8 };

        const FinishRegistrationReq = struct {
            credential_id: []const u8,
            client_data_json: []const u8,
            attestation_object: []const u8,
            name: []const u8 = "",
        };

        const FinishLoginReq = struct {
            email: []const u8,
            credential_id: []const u8,
            client_data_json: []const u8,
            authenticator_data: []const u8,
            signature: []const u8,
        };

        const CredentialDto = struct {
            id: i64,
            name: []const u8,
            credential_id: []const u8,
            last_used_at: i64,
        };

        fn uidOf(ctx: *http.Context) !?i64 {
            const uid = mw.authUserId(ctx) orelse {
                try ctx.sendErrorResponse(401, 401, "未登录或登录已过期");
                return null;
            };
            return uid;
        }

        fn sendRegisterErr(ctx: *http.Context, err: service.Error) !void {
            switch (err) {
                error.OutOfMemory => try ctx.sendErrorResponse(500, 500, "服务器内部错误"),
                error.Unexpected => try ctx.sendErrorResponse(500, 500, "服务器内部错误"),
                error.UserNotFound => try ctx.sendErrorResponse(401, 401, "用户不存在"),
                error.DuplicateCredential => try ctx.sendErrorResponse(409, 409, "该通行密钥已注册"),
                else => try ctx.sendErrorResponse(400, 400, "通行密钥注册失败"),
            }
        }

        fn sendLoginErr(ctx: *http.Context, err: service.Error) !void {
            switch (err) {
                error.OutOfMemory, error.Unexpected => try ctx.sendErrorResponse(500, 500, "服务器内部错误"),
                // Everything else is an authentication failure; keep it uniform
                // so the endpoint is not a credential/user oracle.
                else => try ctx.sendErrorResponse(401, 401, "通行密钥验证失败"),
            }
        }

        fn registerBegin(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const uid = (try uidOf(ctx)) orelse return;
            const opts = self.svc.beginRegistration(uid) catch |err| {
                try sendRegisterErr(ctx, err);
                return;
            };
            defer self.svc.freeRegistrationOptions(opts);
            const json = self.svc.registrationOptionsJson(ctx.allocator, opts) catch {
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            defer ctx.allocator.free(json);
            try ctx.json(200, json);
        }

        fn registerFinish(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const uid = (try uidOf(ctx)) orelse return;
            const req = ctx.bindJsonLoose(FinishRegistrationReq) catch {
                try ctx.sendErrorResponse(400, 400, "请求体格式错误");
                return;
            };
            defer {
                ctx.allocator.free(req.credential_id);
                ctx.allocator.free(req.client_data_json);
                ctx.allocator.free(req.attestation_object);
                ctx.allocator.free(req.name);
            }
            self.svc.finishRegistration(uid, .{
                .credential_id = req.credential_id,
                .client_data_json = req.client_data_json,
                .attestation_object = req.attestation_object,
                .name = req.name,
            }) catch |err| {
                try sendRegisterErr(ctx, err);
                return;
            };
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "通行密钥已注册", .data = null });
        }

        fn loginBegin(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const req = ctx.bindJsonLoose(LoginBeginReq) catch {
                try ctx.sendErrorResponse(400, 400, "请求体格式错误");
                return;
            };
            defer ctx.allocator.free(req.email);
            const opts = self.svc.beginLogin(req.email) catch |err| {
                try sendLoginErr(ctx, err);
                return;
            };
            defer self.svc.freeLoginOptions(opts);
            const json = self.svc.loginOptionsJson(ctx.allocator, opts) catch {
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            defer ctx.allocator.free(json);
            try ctx.json(200, json);
        }

        fn loginFinish(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const req = ctx.bindJsonLoose(FinishLoginReq) catch {
                try ctx.sendErrorResponse(400, 400, "请求体格式错误");
                return;
            };
            defer {
                ctx.allocator.free(req.email);
                ctx.allocator.free(req.credential_id);
                ctx.allocator.free(req.client_data_json);
                ctx.allocator.free(req.authenticator_data);
                ctx.allocator.free(req.signature);
            }
            const session = self.svc.finishLogin(req.email, .{
                .credential_id = req.credential_id,
                .client_data_json = req.client_data_json,
                .authenticator_data = req.authenticator_data,
                .signature = req.signature,
            }) catch |err| {
                try sendLoginErr(ctx, err);
                return;
            };
            defer self.users.freeSession(session);
            try ctx.jsonStruct(200, .{
                .code = 0,
                .msg = "登录成功",
                .data = .{
                    .token = session.token,
                    .user = .{
                        .id = session.row.id,
                        .name = session.row.name,
                        .email = session.row.email,
                        .verified = session.row.verified,
                        .admin = session.row.admin,
                        .tenant_id = session.row.tenant_id,
                        .created_at = session.row.created_at,
                        .updated_at = session.row.updated_at,
                    },
                },
            });
        }

        fn listCredentials(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const uid = (try uidOf(ctx)) orelse return;
            const items = self.svc.listCredentials(ctx.allocator, uid) catch |err| {
                try sendRegisterErr(ctx, err);
                return;
            };
            defer self.svc.freeCredentialInfos(ctx.allocator, items);
            const dtos = ctx.allocator.alloc(CredentialDto, items.len) catch {
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            defer ctx.allocator.free(dtos);
            for (items, 0..) |c, i| {
                dtos[i] = .{ .id = c.id, .name = c.name, .credential_id = c.credential_id, .last_used_at = c.last_used_at };
            }
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "", .data = dtos });
        }

        fn deleteCredential(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const uid = (try uidOf(ctx)) orelse return;
            const id = ctx.paramInt(i64, "id") catch {
                try ctx.sendErrorResponse(400, 400, "无效的凭证 ID");
                return;
            };
            const removed = self.svc.deleteCredential(uid, id) catch {
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            if (!removed) {
                try ctx.sendErrorResponse(404, 404, "凭证不存在");
                return;
            }
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "已删除", .data = null });
        }
    };
}

fn clientIpKey(ctx: *http.Context) []const u8 {
    return zigmodu.http.RequestUtil.getRealIp(ctx);
}
