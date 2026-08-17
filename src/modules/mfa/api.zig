//! MFA HTTP API - TOTP enrollment/verification, recovery codes, IdP, policy.

const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;
const mw = @import("../../middleware/auth.zig");
const user_svc = @import("../user/service.zig");
const service = @import("service.zig");

pub fn MfaApi(comptime Service: type, comptime UserService: type) type {
    return struct {
        const Self = @This();
        svc: *Service,
        users: *UserService,
        default_tenant_id: i64,

        pub fn init(svc: *Service, users: *UserService, default_tenant_id: i64) Self {
            return .{ .svc = svc, .users = users, .default_tenant_id = default_tenant_id };
        }

        pub fn registerRoutes(self: *Self, group: *http.RouteGroup) !void {
            var g = try group.use(zigmodu.http.http_middleware.jwtAuthWithSecurity(&self.users.sec.module));
            g = try g.use(mw.tokenVersionGuard(self.users.sec, self.users.store));
            try g.post("/mfa/totp/enroll", enrollTotp, @ptrCast(@alignCast(self)));
            try g.post("/mfa/totp/verify", verifyTotp, @ptrCast(@alignCast(self)));
            try g.post("/mfa/verify", verifyFactor, @ptrCast(@alignCast(self)));
            try g.get("/mfa/recovery", listRecovery, @ptrCast(@alignCast(self)));
            try g.post("/mfa/recovery", generateRecovery, @ptrCast(@alignCast(self)));
            try g.get("/mfa/policy", getPolicy, @ptrCast(@alignCast(self)));
            try g.put("/mfa/policy", setPolicy, @ptrCast(@alignCast(self)));
        }

        fn requireUser(ctx: *http.Context, self: *Self) !?i64 {
            _ = self;
            const uid = mw.authUserId(ctx) orelse {
                try ctx.sendErrorResponse(401, 401, "未登录或登录已过期");
                return null;
            };
            return uid;
        }

        // ENROLL: returns the base32 secret to scan into an authenticator.
        fn enrollTotp(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const uid = (try requireUser(ctx, self)) orelse return;
            const secret = self.svc.enrollTotp(self.default_tenant_id, uid) catch {
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            defer self.svc.allocator.free(secret);
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "", .data = .{ .secret = secret } });
        }

        const VerifyCodeReq = struct { code: []const u8 };

        // VERIFY + ENABLE: first-time confirmation after scanning the secret.
        fn verifyTotp(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const uid = (try requireUser(ctx, self)) orelse return;
            const req = ctx.bindJson(VerifyCodeReq) catch {
                try ctx.sendErrorResponse(400, 400, "请求体格式错误");
                return;
            };
            defer ctx.allocator.free(req.code);
            self.svc.verifyAndEnable(uid, req.code) catch |err| switch (err) {
                error.NotConfigured => {
                    try ctx.sendErrorResponse(400, 400, "尚未配置 TOTP");
                    return;
                },
                error.InvalidCode => {
                    try ctx.sendErrorResponse(400, 400, "验证码无效");
                    return;
                },
                else => {
                    try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                    return;
                },
            };
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "TOTP 已启用", .data = null });
        }

        // VERIFY as a login factor (used during login MFA step).
        const VerifyFactorReq = struct { user_id: i64, code: []const u8 };
        fn verifyFactor(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            _ = (try requireUser(ctx, self)) orelse return;
            const req = ctx.bindJson(VerifyFactorReq) catch {
                try ctx.sendErrorResponse(400, 400, "请求体格式错误");
                return;
            };
            defer ctx.allocator.free(req.code);
            const ok = self.svc.verifyTotp(req.user_id, req.code) catch false;
            if (!ok) {
                try ctx.sendErrorResponse(401, 401, "MFA 验证码无效");
                return;
            }
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "MFA 校验通过", .data = .{ .verified = true } });
        }

        fn listRecovery(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            _ = (try requireUser(ctx, self)) orelse return;
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "", .data = .{ .note = "调用 POST /mfa/recovery 重新生成恢复码，旧码立即作废" } });
        }

        fn generateRecovery(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const uid = (try requireUser(ctx, self)) orelse return;
            const codes = self.svc.generateRecoveryCodes(self.default_tenant_id, uid, 10) catch {
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            defer {
                for (codes) |c| self.svc.allocator.free(c);
                self.svc.allocator.free(codes);
            }
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "恢复码已生成", .data = .{ .codes = codes } });
        }
        // MFA policy (tenant-wide requirement).
        fn getPolicy(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const p = self.svc.store.getPolicy(self.default_tenant_id) catch {
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "", .data = .{
                .require_mfa = p.require_mfa,
                .allow_recovery_codes = p.allow_recovery_codes,
                .allow_totp = p.allow_totp,
            } });
        }

        const SetPolicyReq = struct { require_mfa: ?bool = null, allow_recovery_codes: ?bool = null, allow_totp: ?bool = null };

        fn setPolicy(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const req = ctx.bindJson(SetPolicyReq) catch {
                try ctx.sendErrorResponse(400, 400, "请求体格式错误");
                return;
            };
            const cur = self.svc.store.getPolicy(self.default_tenant_id) catch {
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            const require_mfa = req.require_mfa orelse cur.require_mfa;
            const allow_recovery = req.allow_recovery_codes orelse cur.allow_recovery_codes;
            const allow_totp = req.allow_totp orelse cur.allow_totp;
            self.svc.store.upsertPolicy(self.default_tenant_id, require_mfa, allow_recovery, allow_totp, self.svc.now()) catch {
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "策略已更新", .data = null });
        }
    };
}
