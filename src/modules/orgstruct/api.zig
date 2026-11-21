//! Admin-facing HTTP API for Instance / Group / Domain.
//!
//! All routes require a valid JWT with an `admin` role. Mirrors
//! `iam/api.zig`: jwtAuthWithSecurity + authorize_mw.enforce + tokenVersionGuard
//! group middleware, a `requireAdmin` handler guard, audit logging, and the
//! standard RuoYi `{ code, msg, data }` response envelope.

const std = @import("std");
const zmodu = @import("zmodu");
const http = zmodu.http;
const mw = @import("../../middleware/auth.zig");
const authorize_mw = @import("../../middleware/authorize.zig");
const user_svc = @import("../user/service.zig");
const audit_svc = @import("../audit/service.zig");
const service = @import("service.zig");

pub fn OrgStructApi(comptime Service: type, comptime UserService: type) type {
    return struct {
        const Self = @This();
        svc: *Service,
        user_svc: *UserService,
        audit: *audit_svc.AuditService,
        default_tenant_id: i64,

        pub fn init(svc: *Service, users: *UserService, audit: *audit_svc.AuditService, default_tenant_id: i64) Self {
            return .{ .svc = svc, .user_svc = users, .audit = audit, .default_tenant_id = default_tenant_id };
        }

        pub fn registerRoutes(self: *Self, group: anytype) !void {
            var g = try group.use(zmodu.http.http_middleware.jwtAuthWithSecurity(&self.user_svc.sec.module));
            g = try g.use(authorize_mw.enforce());
            g = try g.use(mw.tokenVersionGuard(self.user_svc.sec, self.user_svc.store));

            // Instances
            try g.get("/iam/instances", listInstances, @ptrCast(@alignCast(self)));
            try g.get("/iam/instances/{id}", getInstance, @ptrCast(@alignCast(self)));
            try g.post("/iam/instances", createInstance, @ptrCast(@alignCast(self)));
            try g.put("/iam/instances/{id}", updateInstance, @ptrCast(@alignCast(self)));
            try g.delete("/iam/instances/{id}", deleteInstance, @ptrCast(@alignCast(self)));

            // Groups
            try g.get("/iam/groups", listGroups, @ptrCast(@alignCast(self)));
            try g.get("/iam/groups/{id}", getGroup, @ptrCast(@alignCast(self)));
            try g.post("/iam/groups", createGroup, @ptrCast(@alignCast(self)));
            try g.put("/iam/groups/{id}", updateGroup, @ptrCast(@alignCast(self)));
            try g.delete("/iam/groups/{id}", deleteGroup, @ptrCast(@alignCast(self)));

            // Group membership
            try g.get("/iam/groups/{id}/members", listGroupMembers, @ptrCast(@alignCast(self)));
            try g.post("/iam/groups/{id}/members", addGroupMember, @ptrCast(@alignCast(self)));
            try g.delete("/iam/groups/{id}/members/{user_id}", removeGroupMember, @ptrCast(@alignCast(self)));

            // Domains
            try g.get("/iam/domains", listDomains, @ptrCast(@alignCast(self)));
            try g.get("/iam/domains/{id}", getDomain, @ptrCast(@alignCast(self)));
            try g.post("/iam/domains", createDomain, @ptrCast(@alignCast(self)));
            try g.post("/iam/domains/{id}/verify", verifyDomain, @ptrCast(@alignCast(self)));
            try g.delete("/iam/domains/{id}", deleteDomain, @ptrCast(@alignCast(self)));
        }

        fn requireAdmin(ctx: *http.Context, self: *Self) !?i64 {
            const uid = mw.authUserId(ctx) orelse {
                try ctx.sendErrorResponse(401, 401, "未登录或登录已过期");
                return null;
            };
            const row_opt = self.user_svc.getUserById(uid) catch {
                try ctx.sendErrorResponse(401, 401, "未登录或登录已过期");
                return null;
            };
            const row = row_opt orelse {
                try ctx.sendErrorResponse(401, 401, "未登录或登录已过期");
                return null;
            };
            defer row.free(self.svc.allocator);
            if (!row.admin) {
                try ctx.sendErrorResponse(403, 403, "需要管理员权限");
                return null;
            }
            try ctx.setAttr("audit_actor", row.name);
            return uid;
        }

        fn logAudit(
            self: *Self,
            ctx: *http.Context,
            admin_id: i64,
            action: []const u8,
            target_type: []const u8,
            target_id: i64,
            detail: []const u8,
        ) void {
            self.audit.log(admin_id, ctx.getAttr("audit_actor") orelse "", action, target_type, target_id, detail, zmodu.http.RequestUtil.getRealIp(ctx), true, self.default_tenant_id);
        }

        // ── Instances ─────────────────────────────────────────

        fn listInstances(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            _ = (try requireAdmin(ctx, self)) orelse return;
            const params = zmodu.http.PageParams.parse(ctx, .{ .max_page_size = 100 });
            var result = self.svc.listInstances(params.page, params.page_size, null) catch |err| {
                std.log.err("internal error: {s}", .{@errorName(err)});
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            defer result.free(self.svc.allocator);
            const dtos = try zmodu.http.Extract.toDtoList(ctx.allocator, result.items, InstanceDto, instanceToDto);
            try zmodu.http.sendPaged(ctx, dtos, @intCast(result.total), params, .ruoyi);
        }

        fn getInstance(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            _ = (try requireAdmin(ctx, self)) orelse return;
            const id = ctx.paramInt(i64, "id") catch {
                try ctx.sendErrorResponse(400, 400, "无效的 Instance ID");
                return;
            };
            const row_opt = self.svc.getInstanceForTenant(id, self.default_tenant_id) catch |err| {
                std.log.err("internal error: {s}", .{@errorName(err)});
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            const row = row_opt orelse {
                try ctx.sendErrorResponse(404, 404, "Instance 不存在");
                return;
            };
            defer row.free(self.svc.allocator);
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "", .data = instanceToDto(row) });
        }

        const CreateInstanceReq = struct {
            name: []const u8,
            display_name: ?[]const u8 = null,
            global_domain: ?[]const u8 = null,
            config_json: ?[]const u8 = null,
            signing_key_ref: ?[]const u8 = null,
        };

        fn createInstance(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const admin_id = (try requireAdmin(ctx, self)) orelse return;
            const req = ctx.bindJsonLoose(CreateInstanceReq) catch {
                try ctx.sendErrorResponse(400, 400, "请求体格式错误");
                return;
            };
            defer ctx.allocator.free(req.name);
            defer if (req.display_name) |v| ctx.allocator.free(v);
            defer if (req.global_domain) |v| ctx.allocator.free(v);
            defer if (req.config_json) |v| ctx.allocator.free(v);
            defer if (req.signing_key_ref) |v| ctx.allocator.free(v);

            const id = self.svc.createInstance(
                self.default_tenant_id,
                req.name,
                req.display_name orelse "",
                req.global_domain orelse "",
                req.config_json orelse "{}",
                req.signing_key_ref orelse "",
            ) catch |err| switch (err) {
                error.InvalidName => {
                    try ctx.sendErrorResponse(400, 400, "Instance 名称不能为空");
                    return;
                },
                else => {
                    std.log.err("internal error: {s}", .{@errorName(err)});
                    try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                    return;
                },
            };
            self.logAudit(ctx, admin_id, "orgstruct.instance.create", "instance", id, req.name);
            try ctx.jsonStruct(201, .{ .code = 0, .msg = "Instance 已创建", .data = .{ .id = id } });
        }

        const UpdateInstanceReq = struct {
            display_name: ?[]const u8 = null,
            global_domain: ?[]const u8 = null,
            config_json: ?[]const u8 = null,
            signing_key_ref: ?[]const u8 = null,
            active: ?bool = null,
        };

        fn updateInstance(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const admin_id = (try requireAdmin(ctx, self)) orelse return;
            const id = ctx.paramInt(i64, "id") catch {
                try ctx.sendErrorResponse(400, 400, "无效的 Instance ID");
                return;
            };
            const req = ctx.bindJsonLoose(UpdateInstanceReq) catch {
                try ctx.sendErrorResponse(400, 400, "请求体格式错误");
                return;
            };
            defer if (req.display_name) |v| ctx.allocator.free(v);
            defer if (req.global_domain) |v| ctx.allocator.free(v);
            defer if (req.config_json) |v| ctx.allocator.free(v);
            defer if (req.signing_key_ref) |v| ctx.allocator.free(v);

            // Read-modify-write keeps omitted fields unchanged.
            const existing_opt = self.svc.getInstanceForTenant(id, self.default_tenant_id) catch |err| {
                std.log.err("internal error: {s}", .{@errorName(err)});
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            const existing = existing_opt orelse {
                try ctx.sendErrorResponse(404, 404, "Instance 不存在");
                return;
            };
            defer existing.free(self.svc.allocator);

            _ = self.svc.updateInstance(
                id,
                self.default_tenant_id,
                req.display_name orelse existing.display_name,
                req.global_domain orelse existing.global_domain,
                req.config_json orelse existing.config_json,
                req.signing_key_ref orelse existing.signing_key_ref,
                req.active orelse existing.active,
            ) catch |err| switch (err) {
                error.InstanceNotFound => {
                    try ctx.sendErrorResponse(404, 404, "Instance 不存在");
                    return;
                },
                else => {
                    std.log.err("internal error: {s}", .{@errorName(err)});
                    try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                    return;
                },
            };
            self.logAudit(ctx, admin_id, "orgstruct.instance.update", "instance", id, "");
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "ok", .data = null });
        }

        fn deleteInstance(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const admin_id = (try requireAdmin(ctx, self)) orelse return;
            const id = ctx.paramInt(i64, "id") catch {
                try ctx.sendErrorResponse(400, 400, "无效的 Instance ID");
                return;
            };
            self.svc.deleteInstance(id, self.default_tenant_id) catch |err| {
                std.log.err("internal error: {s}", .{@errorName(err)});
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            self.logAudit(ctx, admin_id, "orgstruct.instance.delete", "instance", id, "");
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "ok", .data = null });
        }

        // ── Groups ────────────────────────────────────────────

        fn listGroups(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            _ = (try requireAdmin(ctx, self)) orelse return;
            const params = zmodu.http.PageParams.parse(ctx, .{ .max_page_size = 100 });
            var result = self.svc.listGroups(params.page, params.page_size, null, null) catch |err| {
                std.log.err("internal error: {s}", .{@errorName(err)});
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            defer result.free(self.svc.allocator);
            const dtos = try zmodu.http.Extract.toDtoList(ctx.allocator, result.items, GroupDto, groupToDto);
            try zmodu.http.sendPaged(ctx, dtos, @intCast(result.total), params, .ruoyi);
        }

        fn getGroup(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            _ = (try requireAdmin(ctx, self)) orelse return;
            const id = ctx.paramInt(i64, "id") catch {
                try ctx.sendErrorResponse(400, 400, "无效的 Group ID");
                return;
            };
            const row_opt = self.svc.getGroupForTenant(id, self.default_tenant_id) catch |err| {
                std.log.err("internal error: {s}", .{@errorName(err)});
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            const row = row_opt orelse {
                try ctx.sendErrorResponse(404, 404, "Group 不存在");
                return;
            };
            defer row.free(self.svc.allocator);
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "", .data = groupToDto(row) });
        }

        const CreateGroupReq = struct {
            name: []const u8,
            org_id: ?i64 = null,
            description: ?[]const u8 = null,
        };

        fn createGroup(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const admin_id = (try requireAdmin(ctx, self)) orelse return;
            const req = ctx.bindJsonLoose(CreateGroupReq) catch {
                try ctx.sendErrorResponse(400, 400, "请求体格式错误");
                return;
            };
            defer ctx.allocator.free(req.name);
            defer if (req.description) |v| ctx.allocator.free(v);
            const id = self.svc.createGroup(self.default_tenant_id, req.org_id orelse 0, req.name, req.description orelse "") catch |err| switch (err) {
                error.InvalidName => {
                    try ctx.sendErrorResponse(400, 400, "Group 名称不能为空");
                    return;
                },
                else => {
                    std.log.err("internal error: {s}", .{@errorName(err)});
                    try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                    return;
                },
            };
            self.logAudit(ctx, admin_id, "orgstruct.group.create", "group", id, req.name);
            try ctx.jsonStruct(201, .{ .code = 0, .msg = "Group 已创建", .data = .{ .id = id } });
        }

        const UpdateGroupReq = struct {
            name: ?[]const u8 = null,
            description: ?[]const u8 = null,
            active: ?bool = null,
        };

        fn updateGroup(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const admin_id = (try requireAdmin(ctx, self)) orelse return;
            const id = ctx.paramInt(i64, "id") catch {
                try ctx.sendErrorResponse(400, 400, "无效的 Group ID");
                return;
            };
            const req = ctx.bindJsonLoose(UpdateGroupReq) catch {
                try ctx.sendErrorResponse(400, 400, "请求体格式错误");
                return;
            };
            defer if (req.name) |v| ctx.allocator.free(v);
            defer if (req.description) |v| ctx.allocator.free(v);

            const existing_opt = self.svc.getGroupForTenant(id, self.default_tenant_id) catch |err| {
                std.log.err("internal error: {s}", .{@errorName(err)});
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            const existing = existing_opt orelse {
                try ctx.sendErrorResponse(404, 404, "Group 不存在");
                return;
            };
            defer existing.free(self.svc.allocator);

            _ = self.svc.updateGroup(
                id,
                self.default_tenant_id,
                req.name orelse existing.name,
                req.description orelse existing.description,
                req.active orelse existing.active,
            ) catch |err| switch (err) {
                error.InvalidName => {
                    try ctx.sendErrorResponse(400, 400, "Group 名称不能为空");
                    return;
                },
                error.GroupNotFound => {
                    try ctx.sendErrorResponse(404, 404, "Group 不存在");
                    return;
                },
                else => {
                    std.log.err("internal error: {s}", .{@errorName(err)});
                    try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                    return;
                },
            };
            self.logAudit(ctx, admin_id, "orgstruct.group.update", "group", id, "");
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "ok", .data = null });
        }

        fn deleteGroup(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const admin_id = (try requireAdmin(ctx, self)) orelse return;
            const id = ctx.paramInt(i64, "id") catch {
                try ctx.sendErrorResponse(400, 400, "无效的 Group ID");
                return;
            };
            self.svc.deleteGroup(id, self.default_tenant_id) catch |err| {
                std.log.err("internal error: {s}", .{@errorName(err)});
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            self.logAudit(ctx, admin_id, "orgstruct.group.delete", "group", id, "");
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "ok", .data = null });
        }

        // ── Group membership ──────────────────────────────────

        fn listGroupMembers(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            _ = (try requireAdmin(ctx, self)) orelse return;
            const group_id = ctx.paramInt(i64, "id") catch {
                try ctx.sendErrorResponse(400, 400, "无效的 Group ID");
                return;
            };
            var result = self.svc.listGroupMembers(self.default_tenant_id, group_id) catch |err| {
                std.log.err("internal error: {s}", .{@errorName(err)});
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            defer result.free(self.svc.allocator);
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "", .data = result.items });
        }

        const AddMemberReq = struct { user_id: i64 };

        fn addGroupMember(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const admin_id = (try requireAdmin(ctx, self)) orelse return;
            const group_id = ctx.paramInt(i64, "id") catch {
                try ctx.sendErrorResponse(400, 400, "无效的 Group ID");
                return;
            };
            const req = ctx.bindJsonLoose(AddMemberReq) catch {
                try ctx.sendErrorResponse(400, 400, "请求体格式错误");
                return;
            };
            const member_id = self.svc.addGroupMember(self.default_tenant_id, group_id, req.user_id) catch |err| switch (err) {
                error.GroupNotFound => {
                    try ctx.sendErrorResponse(404, 404, "Group 不存在");
                    return;
                },
                else => {
                    std.log.err("internal error: {s}", .{@errorName(err)});
                    try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                    return;
                },
            };
            self.logAudit(ctx, admin_id, "orgstruct.group.member_add", "group", group_id, "");
            try ctx.jsonStruct(201, .{ .code = 0, .msg = "成员已添加", .data = .{ .id = member_id } });
        }

        fn removeGroupMember(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const admin_id = (try requireAdmin(ctx, self)) orelse return;
            const group_id = ctx.paramInt(i64, "id") catch {
                try ctx.sendErrorResponse(400, 400, "无效的 Group ID");
                return;
            };
            const user_id = ctx.paramInt(i64, "user_id") catch {
                try ctx.sendErrorResponse(400, 400, "无效的用户 ID");
                return;
            };
            self.svc.removeGroupMember(self.default_tenant_id, group_id, user_id) catch |err| {
                std.log.err("internal error: {s}", .{@errorName(err)});
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            self.logAudit(ctx, admin_id, "orgstruct.group.member_remove", "group", group_id, "");
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "ok", .data = null });
        }

        // ── Domains ───────────────────────────────────────────

        fn listDomains(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            _ = (try requireAdmin(ctx, self)) orelse return;
            const params = zmodu.http.PageParams.parse(ctx, .{ .max_page_size = 100 });
            var result = self.svc.listDomains(params.page, params.page_size, null, null) catch |err| {
                std.log.err("internal error: {s}", .{@errorName(err)});
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            defer result.free(self.svc.allocator);
            const dtos = try zmodu.http.Extract.toDtoList(ctx.allocator, result.items, DomainDto, domainToDto);
            try zmodu.http.sendPaged(ctx, dtos, @intCast(result.total), params, .ruoyi);
        }

        fn getDomain(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            _ = (try requireAdmin(ctx, self)) orelse return;
            const id = ctx.paramInt(i64, "id") catch {
                try ctx.sendErrorResponse(400, 400, "无效的 Domain ID");
                return;
            };
            const row_opt = self.svc.getDomainForTenant(id, self.default_tenant_id) catch |err| {
                std.log.err("internal error: {s}", .{@errorName(err)});
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            const row = row_opt orelse {
                try ctx.sendErrorResponse(404, 404, "Domain 不存在");
                return;
            };
            defer row.free(self.svc.allocator);
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "", .data = domainToDto(row) });
        }

        const CreateDomainReq = struct { name: []const u8, org_id: ?i64 = null };

        fn createDomain(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const admin_id = (try requireAdmin(ctx, self)) orelse return;
            const req = ctx.bindJsonLoose(CreateDomainReq) catch {
                try ctx.sendErrorResponse(400, 400, "请求体格式错误");
                return;
            };
            defer ctx.allocator.free(req.name);

            var verification = self.svc.createDomain(self.default_tenant_id, req.org_id orelse 0, req.name) catch |err| switch (err) {
                error.InvalidDomain => {
                    try ctx.sendErrorResponse(400, 400, "域名格式无效");
                    return;
                },
                else => {
                    std.log.err("internal error: {s}", .{@errorName(err)});
                    try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                    return;
                },
            };
            defer verification.deinit(self.svc.allocator);

            self.logAudit(ctx, admin_id, "orgstruct.domain.create", "domain", verification.domain_id, req.name);
            // The plaintext verification token is returned exactly once.
            try ctx.jsonStruct(201, .{
                .code = 0,
                .msg = "Domain 已创建",
                .data = .{ .id = verification.domain_id, .verification_token = verification.token },
            });
        }

        const VerifyDomainReq = struct { token: []const u8 };

        fn verifyDomain(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const admin_id = (try requireAdmin(ctx, self)) orelse return;
            const id = ctx.paramInt(i64, "id") catch {
                try ctx.sendErrorResponse(400, 400, "无效的 Domain ID");
                return;
            };
            const req = ctx.bindJsonLoose(VerifyDomainReq) catch {
                try ctx.sendErrorResponse(400, 400, "请求体格式错误");
                return;
            };
            defer ctx.allocator.free(req.token);

            var row = self.svc.verifyDomain(id, self.default_tenant_id, req.token) catch |err| switch (err) {
                error.DomainNotFound => {
                    try ctx.sendErrorResponse(404, 404, "Domain 不存在");
                    return;
                },
                error.DomainAlreadyVerified => {
                    try ctx.sendErrorResponse(409, 409, "Domain 已验证");
                    return;
                },
                error.InvalidVerificationToken => {
                    try ctx.sendErrorResponse(400, 400, "验证令牌不匹配");
                    return;
                },
                else => {
                    std.log.err("internal error: {s}", .{@errorName(err)});
                    try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                    return;
                },
            };
            defer row.free(self.svc.allocator);

            self.logAudit(ctx, admin_id, "orgstruct.domain.verify", "domain", id, row.name);
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "Domain 已验证", .data = domainToDto(row) });
        }

        fn deleteDomain(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const admin_id = (try requireAdmin(ctx, self)) orelse return;
            const id = ctx.paramInt(i64, "id") catch {
                try ctx.sendErrorResponse(400, 400, "无效的 Domain ID");
                return;
            };
            self.svc.deleteDomain(id, self.default_tenant_id) catch |err| {
                std.log.err("internal error: {s}", .{@errorName(err)});
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            self.logAudit(ctx, admin_id, "orgstruct.domain.delete", "domain", id, "");
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "ok", .data = null });
        }
    };
}

// ── DTOs (never expose verification_token_hash) ─────────────────────

const InstanceDto = struct {
    id: i64,
    name: []const u8,
    display_name: []const u8,
    global_domain: []const u8,
    active: bool,
    config_json: []const u8,
    signing_key_ref: []const u8,
    created_at: i64,
};

fn instanceToDto(row: service.InstanceRow) InstanceDto {
    return .{
        .id = row.id,
        .name = row.name,
        .display_name = row.display_name,
        .global_domain = row.global_domain,
        .active = row.active,
        .config_json = row.config_json,
        .signing_key_ref = row.signing_key_ref,
        .created_at = row.created_at,
    };
}

const GroupDto = struct {
    id: i64,
    org_id: i64,
    name: []const u8,
    description: []const u8,
    active: bool,
    created_at: i64,
};

fn groupToDto(row: service.GroupRow) GroupDto {
    return .{ .id = row.id, .org_id = row.org_id, .name = row.name, .description = row.description, .active = row.active, .created_at = row.created_at };
}

const DomainDto = struct {
    id: i64,
    org_id: i64,
    name: []const u8,
    verified: bool,
    verified_at: i64,
    created_at: i64,
};

fn domainToDto(row: service.DomainRow) DomainDto {
    return .{ .id = row.id, .org_id = row.org_id, .name = row.name, .verified = row.verified, .verified_at = row.verified_at, .created_at = row.created_at };
}

pub const DefaultOrgStructApi = OrgStructApi(service.OrgStructService, user_svc.UserService);
