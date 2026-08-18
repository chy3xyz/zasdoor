//! Web3 HTTP API - wallet binding and SIWE verification.

const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;
const mw = @import("../../middleware/auth.zig");
const user_svc = @import("../user/service.zig");
const service = @import("service.zig");

pub fn Web3Api(comptime Service: type, comptime UserService: type) type {
    return struct {
        const Self = @This();
        svc: *Service,
        users: *UserService,
        default_tenant_id: i64,

        pub fn init(svc: *Service, users: *UserService, default_tenant_id: i64) Self {
            return .{ .svc = svc, .users = users, .default_tenant_id = default_tenant_id };
        }

        pub fn registerRoutes(self: *Self, group: *http.RouteGroup) !void {
            // Public SIWE login endpoints (no JWT required).
            try group.post("/web3/siwe/nonce", siweNonce, @ptrCast(@alignCast(self)));
            try group.post("/web3/siwe/verify", siweVerify, @ptrCast(@alignCast(self)));

            var g = try group.use(zigmodu.http.http_middleware.jwtAuthWithSecurity(&self.users.sec.module));
            g = try g.use(mw.tokenVersionGuard(self.users.sec, self.users.store));
            try g.post("/web3/wallet/bind", bindWallet, @ptrCast(@alignCast(self)));
        }

        const SiweNonceReq = struct { address: []const u8, domain: []const u8 };

        fn siweNonce(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const req = ctx.bindJson(SiweNonceReq) catch {
                try ctx.sendErrorResponse(400, 400, "请求体格式错误");
                return;
            };
            defer ctx.allocator.free(req.address);
            defer ctx.allocator.free(req.domain);
            const nonce = self.svc.generateNonce() catch {
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            defer self.svc.allocator.free(nonce);
            // Reserve the nonce bound to (domain, address) for 10 minutes.
            self.svc.reserveNonce(self.default_tenant_id, nonce, req.domain, req.address, 600) catch {
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "", .data = .{ .nonce = nonce, .ttl = 600 } });
        }

        const SiweVerifyReq = struct {
            message: []const u8,
            signature: []const u8, // hex 130 chars: r(64) || s(64) || v(2)
            domain: []const u8,
        };

        fn siweVerify(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const req = ctx.bindJson(SiweVerifyReq) catch {
                try ctx.sendErrorResponse(400, 400, "请求体格式错误");
                return;
            };
            defer ctx.allocator.free(req.message);
            defer ctx.allocator.free(req.signature);
            defer ctx.allocator.free(req.domain);
            // Parse hex signature r||s||v (each byte as 2 hex chars).
            if (req.signature.len != 130) {
                try ctx.sendErrorResponse(400, 400, "签名格式错误(需 65 字节 hex)");
                return;
            }
            var sig = service.Signature{ .r = undefined, .s = undefined, .v = 0 };
            parseHex(req.signature[0..64], &sig.r) catch {
                try ctx.sendErrorResponse(400, 400, "签名 r 无效");
                return;
            };
            parseHex(req.signature[64..128], &sig.s) catch {
                try ctx.sendErrorResponse(400, 400, "签名 s 无效");
                return;
            };
            const v = std.fmt.parseInt(u8, req.signature[128..130], 16) catch {
                try ctx.sendErrorResponse(400, 400, "签名 v 无效");
                return;
            };
            sig.v = v;
            const result = self.svc.siweLogin(self.default_tenant_id, req.message, sig, req.domain) catch |err| switch (err) {
                error.InvalidSiweMessage => {
                    try ctx.sendErrorResponse(400, 400, "SIWE 消息无效或已过期");
                    return;
                },
                error.SignatureInvalid => {
                    try ctx.sendErrorResponse(401, 401, "签名无效");
                    return;
                },
                error.AddressMismatch => {
                    try ctx.sendErrorResponse(401, 401, "签名地址与消息地址不符");
                    return;
                },
                error.NonceUnavailable => {
                    try ctx.sendErrorResponse(400, 400, "nonce 无效或已使用");
                    return;
                },
                else => {
                    try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                    return;
                },
            };
            if (result.token) |tok| {
                defer self.svc.allocator.free(tok);
                try ctx.jsonStruct(200, .{ .code = 0, .msg = "登录成功", .data = .{ .token = tok, .user_id = result.user_id } });
            } else {
                try ctx.jsonStruct(200, .{ .code = 0, .msg = "钱包尚未绑定用户,请先绑定", .data = .{ .token = null, .user_id = 0, .needs_bind = true } });
            }
        }

        const BindReq = struct {
            chain: []const u8,
            address: []const u8,
        };

        fn bindWallet(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const uid = mw.authUserId(ctx) orelse {
                try ctx.sendErrorResponse(401, 401, "未登录或登录已过期");
                return;
            };
            const req = ctx.bindJson(BindReq) catch {
                try ctx.sendErrorResponse(400, 400, "请求体格式错误");
                return;
            };
            defer ctx.allocator.free(req.chain);
            defer ctx.allocator.free(req.address);
            const row_opt = self.svc.bindWallet(self.default_tenant_id, uid, req.chain, req.address) catch {
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            if (row_opt) |row| {
                defer row.free(self.svc.allocator);
                try ctx.jsonStruct(200, .{ .code = 0, .msg = "钱包已绑定", .data = .{ .address = row.address, .chain = row.chain } });
            } else {
                try ctx.sendErrorResponse(500, 500, "绑定失败");
            }
        }
    };
}

fn parseHex(hex: []const u8, out: *[32]u8) !void {
    if (hex.len != 64) return error.InvalidHex;
    for (0..32) |i| {
        const hi = hexNibble(hex[i * 2]) orelse return error.InvalidHex;
        const lo = hexNibble(hex[i * 2 + 1]) orelse return error.InvalidHex;
        out[i] = (hi << 4) | lo;
    }
}

fn hexNibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}
