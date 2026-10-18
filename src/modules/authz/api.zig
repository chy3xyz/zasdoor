//! Admin-facing authorization API: permission checks (RBAC + explicit
//! policies), policy management and the decision log.

const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;
const mw = @import("../../middleware/auth.zig");
const user_svc = @import("../user/service.zig");
const service = @import("service.zig");

pub fn AuthzApi(comptime Service: type, comptime UserService: type) type {
    return struct {
        const Self = @This();
        svc: *Service,
        user_svc: *UserService,

        pub fn init(svc: *Service, users: *UserService) Self {
            return .{ .svc = svc, .user_svc = users };
        }

        pub fn registerRoutes(self: *Self, group: *http.RouteGroup) !void {
            var g = try group.use(zigmodu.http.http_middleware.jwtAuthWithSecurity(&self.user_svc.sec.module));
            g = try g.use(mw.tokenVersionGuard(self.user_svc.sec, self.user_svc.store));
            try g.post("/iam/authz/check", check, @ptrCast(@alignCast(self)));
            try g.get("/iam/authz/policies", listPolicies, @ptrCast(@alignCast(self)));
            try g.post("/iam/authz/policies", createPolicy, @ptrCast(@alignCast(self)));
            try g.put("/iam/authz/policies/{id}", updatePolicy, @ptrCast(@alignCast(self)));
            try g.delete("/iam/authz/policies/{id}", deletePolicy, @ptrCast(@alignCast(self)));
            try g.get("/iam/authz/decisions", listDecisions, @ptrCast(@alignCast(self)));
        }

        fn requireAdmin(self: *Self, ctx: *http.Context) !?i64 {
            const uid = mw.authUserId(ctx) orelse {
                try ctx.sendErrorResponse(401, 401, "未登录或登录已过期");
                return null;
            };
            const row_opt = self.user_svc.getUserById(uid) catch {
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return null;
            };
            const row = row_opt orelse {
                try ctx.sendErrorResponse(401, 401, "用户不存在");
                return null;
            };
            defer row.free(self.user_svc.store.allocator);
            if (!row.admin) {
                try ctx.sendErrorResponse(403, 403, "需要管理员权限");
                return null;
            }
            return uid;
        }

        /// Condition must be empty or a JSON object with org_id/project_id/
        /// resource_id integer fields only.
        fn validateCondition(allocator: std.mem.Allocator, condition: []const u8) bool {
            if (condition.len == 0) return true;
            var parsed = std.json.parseFromSlice(std.json.Value, allocator, condition, .{}) catch return false;
            defer parsed.deinit();
            const obj = switch (parsed.value) {
                .object => |o| o,
                else => return false,
            };
            var it = obj.iterator();
            while (it.next()) |entry| {
                const k = entry.key_ptr.*;
                if (!std.mem.eql(u8, k, "org_id") and !std.mem.eql(u8, k, "project_id") and !std.mem.eql(u8, k, "resource_id")) return false;
                switch (entry.value_ptr.*) {
                    .integer => {},
                    else => return false,
                }
            }
            return true;
        }

        const CheckReq = struct {
            subject_id: i64,
            resource: []const u8,
            action: []const u8,
            project_id: ?i64 = null,
            resource_id: ?i64 = null,
            tenant_id: ?i64 = null,
        };

        fn check(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const req = ctx.bindJsonLoose(CheckReq) catch {
                try ctx.sendErrorResponse(400, 400, "请求体格式错误");
                return;
            };
            defer ctx.allocator.free(req.resource);
            defer ctx.allocator.free(req.action);

            const context = service.AuthContext{
                .project_id = req.project_id,
                .resource_id = req.resource_id,
                .tenant_id = req.tenant_id,
                .now = zigmodu.time.wallClockSeconds(self.user_svc.io),
            };
            const info = self.svc.authorizeDetailed(req.subject_id, req.resource, req.action, context) catch {
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            const decision_label: []const u8 = switch (info.decision) {
                .allow => "allow",
                .deny => "deny",
                .unknown => "unknown",
            };
            const source_label: []const u8 = switch (info.source) {
                .none => "none",
                .role => "role",
                .policy => "policy",
            };
            try ctx.jsonStruct(200, .{
                .code = 0,
                .msg = "",
                .data = .{
                    .allowed = info.decision == .allow,
                    .decision = decision_label,
                    .source = source_label,
                    .policy_id = info.policy_id,
                },
            });
        }

        const PolicyReq = struct {
            name: []const u8,
            effect: []const u8 = "allow",
            subject: []const u8 = "*",
            resource: []const u8 = "*",
            action: []const u8 = "*",
            condition: []const u8 = "",
            priority: ?i64 = null,
            enabled: ?bool = null,
            tenant_id: ?i64 = null,
        };

        const PolicyPatchReq = struct {
            name: ?[]const u8 = null,
            effect: ?[]const u8 = null,
            subject: ?[]const u8 = null,
            resource: ?[]const u8 = null,
            action: ?[]const u8 = null,
            condition: ?[]const u8 = null,
            priority: ?i64 = null,
            enabled: ?bool = null,
        };

        const PolicyDto = struct {
            id: i64,
            tenant_id: i64,
            name: []const u8,
            effect: []const u8,
            subject: []const u8,
            resource: []const u8,
            action: []const u8,
            condition: []const u8,
            priority: i64,
            enabled: bool,
        };

        fn freePolicyReq(ctx: *http.Context, req: PolicyReq) void {
            ctx.allocator.free(req.name);
            ctx.allocator.free(req.effect);
            ctx.allocator.free(req.subject);
            ctx.allocator.free(req.resource);
            ctx.allocator.free(req.action);
            ctx.allocator.free(req.condition);
        }

        fn freePolicyPatch(ctx: *http.Context, req: PolicyPatchReq) void {
            if (req.name) |v| ctx.allocator.free(v);
            if (req.effect) |v| ctx.allocator.free(v);
            if (req.subject) |v| ctx.allocator.free(v);
            if (req.resource) |v| ctx.allocator.free(v);
            if (req.action) |v| ctx.allocator.free(v);
            if (req.condition) |v| ctx.allocator.free(v);
        }

        fn listPolicies(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            _ = (try requireAdmin(self, ctx)) orelse return;
            const store = self.svc.policyStore() orelse {
                try ctx.sendErrorResponse(500, 500, "策略存储未初始化");
                return;
            };
            const rows = store.listPolicies() catch {
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            defer {
                for (rows) |r| r.free(store.allocator);
                store.allocator.free(rows);
            }
            const dtos = ctx.allocator.alloc(PolicyDto, rows.len) catch {
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            defer ctx.allocator.free(dtos);
            for (rows, 0..) |r, i| {
                dtos[i] = .{
                    .id = r.id,
                    .tenant_id = r.tenant_id,
                    .name = r.name,
                    .effect = r.effect,
                    .subject = r.subject,
                    .resource = r.resource,
                    .action = r.action,
                    .condition = r.condition,
                    .priority = r.priority,
                    .enabled = r.enabled,
                };
            }
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "", .data = dtos });
        }

        fn createPolicy(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            _ = (try requireAdmin(self, ctx)) orelse return;
            const req = ctx.bindJsonLoose(PolicyReq) catch {
                try ctx.sendErrorResponse(400, 400, "请求体格式错误");
                return;
            };
            defer freePolicyReq(ctx, req);

            if (!std.mem.eql(u8, req.effect, "allow") and !std.mem.eql(u8, req.effect, "deny")) {
                try ctx.sendErrorResponse(400, 400, "effect 只能是 allow 或 deny");
                return;
            }
            if (req.name.len == 0 or req.subject.len == 0 or req.resource.len == 0 or req.action.len == 0) {
                try ctx.sendErrorResponse(400, 400, "name/subject/resource/action 不能为空");
                return;
            }
            if (!validateCondition(ctx.allocator, req.condition)) {
                try ctx.sendErrorResponse(400, 400, "condition 必须是 {org_id|project_id|resource_id: 整数} 的 JSON 对象");
                return;
            }
            const store = self.svc.policyStore() orelse {
                try ctx.sendErrorResponse(500, 500, "策略存储未初始化");
                return;
            };
            const id = store.createPolicy(
                req.tenant_id orelse 1,
                req.name,
                req.effect,
                req.subject,
                req.resource,
                req.action,
                req.condition,
                req.priority orelse 0,
                req.enabled orelse true,
                zigmodu.time.wallClockSeconds(self.user_svc.io),
            ) catch {
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "策略已创建", .data = .{ .id = id } });
        }

        fn updatePolicy(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            _ = (try requireAdmin(self, ctx)) orelse return;
            const id = ctx.paramInt(i64, "id") catch {
                try ctx.sendErrorResponse(400, 400, "无效的策略 ID");
                return;
            };
            const req = ctx.bindJsonLoose(PolicyPatchReq) catch {
                try ctx.sendErrorResponse(400, 400, "请求体格式错误");
                return;
            };
            defer freePolicyPatch(ctx, req);

            if (req.effect) |e| {
                if (!std.mem.eql(u8, e, "allow") and !std.mem.eql(u8, e, "deny")) {
                    try ctx.sendErrorResponse(400, 400, "effect 只能是 allow 或 deny");
                    return;
                }
            }
            if (req.condition) |c| {
                if (!validateCondition(ctx.allocator, c)) {
                    try ctx.sendErrorResponse(400, 400, "condition 必须是 {org_id|project_id|resource_id: 整数} 的 JSON 对象");
                    return;
                }
            }
            const store = self.svc.policyStore() orelse {
                try ctx.sendErrorResponse(500, 500, "策略存储未初始化");
                return;
            };
            const ok = store.updatePolicy(id, .{
                .name = req.name,
                .effect = req.effect,
                .subject = req.subject,
                .resource = req.resource,
                .action = req.action,
                .condition = req.condition,
                .priority = req.priority,
                .enabled = req.enabled,
            }, zigmodu.time.wallClockSeconds(self.user_svc.io)) catch {
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            if (!ok) {
                try ctx.sendErrorResponse(404, 404, "策略不存在");
                return;
            }
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "策略已更新", .data = null });
        }

        fn deletePolicy(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            _ = (try requireAdmin(self, ctx)) orelse return;
            const id = ctx.paramInt(i64, "id") catch {
                try ctx.sendErrorResponse(400, 400, "无效的策略 ID");
                return;
            };
            const store = self.svc.policyStore() orelse {
                try ctx.sendErrorResponse(500, 500, "策略存储未初始化");
                return;
            };
            const removed = store.deletePolicy(id) catch {
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            if (!removed) {
                try ctx.sendErrorResponse(404, 404, "策略不存在");
                return;
            }
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "已删除", .data = null });
        }

        const DecisionDto = struct {
            id: i64,
            tenant_id: i64,
            subject_id: i64,
            resource: []const u8,
            action: []const u8,
            decision: []const u8,
            source: []const u8,
            policy_id: i64,
            created_at: i64,
        };

        fn listDecisions(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            _ = (try requireAdmin(self, ctx)) orelse return;
            const store = self.svc.policyStore() orelse {
                try ctx.sendErrorResponse(500, 500, "策略存储未初始化");
                return;
            };
            const rows = store.listDecisions(100) catch {
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            defer {
                for (rows) |r| r.free(store.allocator);
                store.allocator.free(rows);
            }
            const dtos = ctx.allocator.alloc(DecisionDto, rows.len) catch {
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            defer ctx.allocator.free(dtos);
            for (rows, 0..) |r, i| {
                dtos[i] = .{
                    .id = r.id,
                    .tenant_id = r.tenant_id,
                    .subject_id = r.subject_id,
                    .resource = r.resource,
                    .action = r.action,
                    .decision = r.decision,
                    .source = r.source,
                    .policy_id = r.policy_id,
                    .created_at = r.created_at,
                };
            }
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "", .data = dtos });
        }
    };
}
