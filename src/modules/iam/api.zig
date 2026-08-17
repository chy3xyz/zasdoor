//! Admin-facing HTTP API for the ZenaIAM kernel: projects, applications
//! (OAuth clients), roles, role assignments, and sessions. All routes require
//! a valid JWT with an `admin` role.

const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;
const mw = @import("../../middleware/auth.zig");
const user_svc = @import("../user/service.zig");
const audit_svc = @import("../audit/service.zig");
const service = @import("service.zig");

pub fn IamApi(comptime Service: type, comptime UserService: type) type {
    return struct {
        const Self = @This();
        svc: *Service,
        user_svc: *UserService,
        audit: *audit_svc.AuditService,
        default_tenant_id: i64,

        pub fn init(svc: *Service, users: *UserService, audit: *audit_svc.AuditService, default_tenant_id: i64) Self {
            return .{ .svc = svc, .user_svc = users, .audit = audit, .default_tenant_id = default_tenant_id };
        }

        pub fn registerRoutes(self: *Self, group: *http.RouteGroup) !void {
            var g = try group.use(zigmodu.http.http_middleware.jwtAuthWithSecurity(&self.user_svc.sec.module));
            g = try g.use(mw.tokenVersionGuard(self.user_svc.sec, self.user_svc.store));

            // Projects
            try g.get("/iam/projects", listProjects, @ptrCast(@alignCast(self)));
            try g.get("/iam/projects/{id}", getProject, @ptrCast(@alignCast(self)));
            try g.post("/iam/projects", createProject, @ptrCast(@alignCast(self)));
            try g.delete("/iam/projects/{id}", deleteProject, @ptrCast(@alignCast(self)));

            // Applications (OAuth clients)
            try g.get("/iam/projects/{id}/applications", listApplications, @ptrCast(@alignCast(self)));
            try g.post("/iam/projects/{id}/applications", createApplication, @ptrCast(@alignCast(self)));
            try g.delete("/iam/applications/{id}", deleteApplication, @ptrCast(@alignCast(self)));

            // Roles
            try g.get("/iam/projects/{id}/roles", listRoles, @ptrCast(@alignCast(self)));
            try g.post("/iam/projects/{id}/roles", createRole, @ptrCast(@alignCast(self)));
            try g.delete("/iam/roles/{id}", deleteRole, @ptrCast(@alignCast(self)));

            // Role assignments
            try g.post("/iam/roles/{id}/assign", assignRole, @ptrCast(@alignCast(self)));

            // Sessions
            try g.get("/iam/users/{id}/sessions", listSessions, @ptrCast(@alignCast(self)));
            try g.post("/iam/sessions/{id}/revoke", revokeSession, @ptrCast(@alignCast(self)));
            try g.post("/iam/users/{id}/revoke-sessions", revokeAllSessions, @ptrCast(@alignCast(self)));
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

        // ── Projects ──────────────────────────────────────────

        const CreateProjectReq = struct { name: []const u8, description: ?[]const u8 = null };

        fn listProjects(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            _ = (try requireAdmin(ctx, self)) orelse return;
            const params = zigmodu.http.PageParams.parse(ctx, .{ .max_page_size = 100 });
            var result = self.svc.listProjects(params.page, params.page_size, null) catch |err| {
                std.log.err("internal error: {s}", .{@errorName(err)});
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            defer result.free(self.svc.allocator);
            const dtos = try zigmodu.http.Extract.toDtoList(ctx.allocator, result.items, ProjectDto, projectToDto);
            try zigmodu.http.sendPaged(ctx, dtos, @intCast(result.total), params, .ruoyi);
        }

        fn getProject(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            _ = (try requireAdmin(ctx, self)) orelse return;
            const id = ctx.paramInt(i64, "id") catch {
                try ctx.sendErrorResponse(400, 400, "无效的项目 ID");
                return;
            };
            const row_opt = self.svc.getProject(id) catch |err| {
                std.log.err("internal error: {s}", .{@errorName(err)});
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            const row = row_opt orelse {
                try ctx.sendErrorResponse(404, 404, "项目不存在");
                return;
            };
            defer row.free(self.svc.allocator);
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "", .data = projectToDto(row) });
        }

        fn createProject(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const admin_id = (try requireAdmin(ctx, self)) orelse return;
            const req = ctx.bindJson(CreateProjectReq) catch {
                try ctx.sendErrorResponse(400, 400, "请求体格式错误");
                return;
            };
            defer ctx.allocator.free(req.name);
            defer if (req.description) |d| ctx.allocator.free(d);
            const id = self.svc.createProject(self.default_tenant_id, req.name, req.description orelse "") catch |err| switch (err) {
                error.InvalidName => {
                    try ctx.sendErrorResponse(400, 400, "项目名称不能为空");
                    return;
                },
                else => {
                    std.log.err("internal error: {s}", .{@errorName(err)});
                    try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                    return;
                },
            };
            self.audit.log(admin_id, ctx.getAttr("audit_actor") orelse "", "iam.project.create", "project", id, req.name, zigmodu.http.RequestUtil.getRealIp(ctx), true, self.default_tenant_id);
            try ctx.jsonStruct(201, .{ .code = 0, .msg = "项目已创建", .data = .{ .id = id } });
        }

        fn deleteProject(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const admin_id = (try requireAdmin(ctx, self)) orelse return;
            const id = ctx.paramInt(i64, "id") catch {
                try ctx.sendErrorResponse(400, 400, "无效的项目 ID");
                return;
            };
            self.svc.deleteProject(id) catch |err| {
                std.log.err("internal error: {s}", .{@errorName(err)});
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            self.audit.log(admin_id, ctx.getAttr("audit_actor") orelse "", "iam.project.delete", "project", id, "", zigmodu.http.RequestUtil.getRealIp(ctx), true, self.default_tenant_id);
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "ok", .data = null });
        }

        // ── Applications ──────────────────────────────────────

        const CreateApplicationReq = struct {
            name: []const u8,
            type: ?[]const u8 = null, // web | spa | native | machine
            redirect_uris: ?[]const u8 = null,
            post_logout_redirect_uris: ?[]const u8 = null,
            allowed_origins: ?[]const u8 = null,
            grant_types: ?[]const u8 = null,
            response_types: ?[]const u8 = null,
            scopes: ?[]const u8 = null,
            access_token_ttl: ?i64 = null,
            refresh_token_ttl: ?i64 = null,
            pkce_required: ?bool = null,
        };

        fn listApplications(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            _ = (try requireAdmin(ctx, self)) orelse return;
            const project_id = ctx.paramInt(i64, "id") catch {
                try ctx.sendErrorResponse(400, 400, "无效的项目 ID");
                return;
            };
            var result = self.svc.listApplicationsByProject(project_id) catch |err| {
                std.log.err("internal error: {s}", .{@errorName(err)});
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            defer result.free(self.svc.allocator);
            // Application DTOs strip the secret hash.
            var dtos = std.ArrayList(ApplicationDto).empty;
            defer dtos.deinit(ctx.allocator);
            for (result.items) |row| {
                try dtos.append(ctx.allocator, appToDto(row, false));
                row.free(self.svc.allocator);
            }
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "", .data = dtos.items });
        }

        fn createApplication(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const admin_id = (try requireAdmin(ctx, self)) orelse return;
            const project_id = ctx.paramInt(i64, "id") catch {
                try ctx.sendErrorResponse(400, 400, "无效的项目 ID");
                return;
            };
            const req = ctx.bindJson(CreateApplicationReq) catch {
                try ctx.sendErrorResponse(400, 400, "请求体格式错误");
                return;
            };
            defer ctx.allocator.free(req.name);
            defer if (req.type) |v| ctx.allocator.free(v);
            defer if (req.redirect_uris) |v| ctx.allocator.free(v);
            defer if (req.post_logout_redirect_uris) |v| ctx.allocator.free(v);
            defer if (req.allowed_origins) |v| ctx.allocator.free(v);
            defer if (req.grant_types) |v| ctx.allocator.free(v);
            defer if (req.response_types) |v| ctx.allocator.free(v);
            defer if (req.scopes) |v| ctx.allocator.free(v);

            const app_type = req.type orelse "web";
            var creds = self.svc.createApplication(
                self.default_tenant_id,
                project_id,
                req.name,
                app_type,
                req.redirect_uris orelse "[]",
                req.post_logout_redirect_uris orelse "[]",
                req.allowed_origins orelse "[]",
                req.grant_types orelse "[\"authorization_code\",\"refresh_token\"]",
                req.response_types orelse "[\"code\"]",
                req.scopes orelse "openid profile email",
                req.access_token_ttl orelse 3600,
                req.refresh_token_ttl orelse 0,
                req.pkce_required orelse false,
            ) catch |err| switch (err) {
                error.InvalidName => {
                    try ctx.sendErrorResponse(400, 400, "应用名称不能为空");
                    return;
                },
                error.ProjectNotFound => {
                    try ctx.sendErrorResponse(404, 404, "项目不存在");
                    return;
                },
                else => {
                    std.log.err("internal error: {s}", .{@errorName(err)});
                    try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                    return;
                },
            };
            defer creds.deinit(self.svc.allocator);

            self.audit.log(admin_id, ctx.getAttr("audit_actor") orelse "", "iam.application.create", "application", 0, req.name, zigmodu.http.RequestUtil.getRealIp(ctx), true, self.default_tenant_id);
            try ctx.jsonStruct(201, .{
                .code = 0,
                .msg = "应用已创建",
                .data = .{
                    .client_id = creds.client_id,
                    .client_secret = creds.client_secret,
                },
            });
        }

        fn deleteApplication(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const admin_id = (try requireAdmin(ctx, self)) orelse return;
            const id = ctx.paramInt(i64, "id") catch {
                try ctx.sendErrorResponse(400, 400, "无效的应用 ID");
                return;
            };
            self.svc.deleteApplication(id) catch |err| {
                std.log.err("internal error: {s}", .{@errorName(err)});
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            self.audit.log(admin_id, ctx.getAttr("audit_actor") orelse "", "iam.application.delete", "application", id, "", zigmodu.http.RequestUtil.getRealIp(ctx), true, self.default_tenant_id);
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "ok", .data = null });
        }

        // ── Roles ─────────────────────────────────────────────

        const CreateRoleReq = struct { key: []const u8, name: []const u8, permissions: ?[]const u8 = null };

        fn listRoles(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            _ = (try requireAdmin(ctx, self)) orelse return;
            const project_id = ctx.paramInt(i64, "id") catch {
                try ctx.sendErrorResponse(400, 400, "无效的项目 ID");
                return;
            };
            var result = self.svc.listRolesByProject(project_id) catch |err| {
                std.log.err("internal error: {s}", .{@errorName(err)});
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            defer result.free(self.svc.allocator);
            var dtos = std.ArrayList(RoleDto).empty;
            defer dtos.deinit(ctx.allocator);
            for (result.items) |row| {
                try dtos.append(ctx.allocator, roleToDto(row));
                row.free(self.svc.allocator);
            }
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "", .data = dtos.items });
        }

        fn createRole(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const admin_id = (try requireAdmin(ctx, self)) orelse return;
            const project_id = ctx.paramInt(i64, "id") catch {
                try ctx.sendErrorResponse(400, 400, "无效的项目 ID");
                return;
            };
            const req = ctx.bindJson(CreateRoleReq) catch {
                try ctx.sendErrorResponse(400, 400, "请求体格式错误");
                return;
            };
            defer ctx.allocator.free(req.key);
            defer ctx.allocator.free(req.name);
            defer if (req.permissions) |v| ctx.allocator.free(v);
            const id = self.svc.createRole(self.default_tenant_id, project_id, req.key, req.name, req.permissions orelse "[]") catch |err| switch (err) {
                error.InvalidName => {
                    try ctx.sendErrorResponse(400, 400, "角色 key 不能为空");
                    return;
                },
                else => {
                    std.log.err("internal error: {s}", .{@errorName(err)});
                    try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                    return;
                },
            };
            self.audit.log(admin_id, ctx.getAttr("audit_actor") orelse "", "iam.role.create", "role", id, req.key, zigmodu.http.RequestUtil.getRealIp(ctx), true, self.default_tenant_id);
            try ctx.jsonStruct(201, .{ .code = 0, .msg = "角色已创建", .data = .{ .id = id } });
        }

        fn deleteRole(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const admin_id = (try requireAdmin(ctx, self)) orelse return;
            const id = ctx.paramInt(i64, "id") catch {
                try ctx.sendErrorResponse(400, 400, "无效的角色 ID");
                return;
            };
            self.svc.deleteRole(id) catch |err| {
                std.log.err("internal error: {s}", .{@errorName(err)});
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            self.audit.log(admin_id, ctx.getAttr("audit_actor") orelse "", "iam.role.delete", "role", id, "", zigmodu.http.RequestUtil.getRealIp(ctx), true, self.default_tenant_id);
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "ok", .data = null });
        }

        // ── Role assignments ──────────────────────────────────

        const AssignRoleReq = struct { user_id: i64, project_id: ?i64 = null };

        fn assignRole(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const admin_id = (try requireAdmin(ctx, self)) orelse return;
            const role_id = ctx.paramInt(i64, "id") catch {
                try ctx.sendErrorResponse(400, 400, "无效的角色 ID");
                return;
            };
            const req = ctx.bindJson(AssignRoleReq) catch {
                try ctx.sendErrorResponse(400, 400, "请求体格式错误");
                return;
            };
            const role_opt = self.svc.getRole(role_id) catch {
                try ctx.sendErrorResponse(500, 500, "服务器错误");
                return;
            };
            if (role_opt) |r| r.free(self.svc.allocator) else {
                try ctx.sendErrorResponse(404, 404, "角色不存在");
                return;
            }
            const assignment_id = self.svc.assignRole(self.default_tenant_id, req.user_id, role_id, req.project_id orelse 0) catch |err| {
                std.log.err("internal error: {s}", .{@errorName(err)});
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            self.audit.log(admin_id, ctx.getAttr("audit_actor") orelse "", "iam.role.assign", "role", role_id, "", zigmodu.http.RequestUtil.getRealIp(ctx), true, self.default_tenant_id);
            try ctx.jsonStruct(201, .{ .code = 0, .msg = "角色已分配", .data = .{ .id = assignment_id } });
        }

        // ── Sessions ──────────────────────────────────────────

        fn listSessions(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            _ = (try requireAdmin(ctx, self)) orelse return;
            const user_id = ctx.paramInt(i64, "id") catch {
                try ctx.sendErrorResponse(400, 400, "无效的用户 ID");
                return;
            };
            var result = self.svc.listSessionsForUser(user_id) catch |err| {
                std.log.err("internal error: {s}", .{@errorName(err)});
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            defer result.free(self.svc.allocator);
            var dtos = std.ArrayList(SessionDto).empty;
            defer dtos.deinit(ctx.allocator);
            for (result.items) |row| {
                try dtos.append(ctx.allocator, sessionToDto(row));
                row.free(self.svc.allocator);
            }
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "", .data = dtos.items });
        }

        fn revokeSession(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const admin_id = (try requireAdmin(ctx, self)) orelse return;
            const id = ctx.paramInt(i64, "id") catch {
                try ctx.sendErrorResponse(400, 400, "无效的会话 ID");
                return;
            };
            self.svc.revokeSession(id) catch |err| {
                std.log.err("internal error: {s}", .{@errorName(err)});
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            self.audit.log(admin_id, ctx.getAttr("audit_actor") orelse "", "iam.session.revoke", "session", id, "", zigmodu.http.RequestUtil.getRealIp(ctx), true, self.default_tenant_id);
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "ok", .data = null });
        }

        fn revokeAllSessions(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const admin_id = (try requireAdmin(ctx, self)) orelse return;
            const user_id = ctx.paramInt(i64, "id") catch {
                try ctx.sendErrorResponse(400, 400, "无效的用户 ID");
                return;
            };
            self.svc.revokeSessionsForUser(user_id) catch |err| {
                std.log.err("internal error: {s}", .{@errorName(err)});
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            self.audit.log(admin_id, ctx.getAttr("audit_actor") orelse "", "iam.session.revoke_all", "user", user_id, "", zigmodu.http.RequestUtil.getRealIp(ctx), true, self.default_tenant_id);
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "ok", .data = null });
        }
    };
}

// ── DTOs ────────────────────────────────────────────────────────

const ProjectDto = struct {
    id: i64,
    name: []const u8,
    description: []const u8,
    active: bool,
    created_at: i64,
};

fn projectToDto(row: service.ProjectRow) ProjectDto {
    return .{ .id = row.id, .name = row.name, .description = row.description, .active = row.active, .created_at = row.created_at };
}

const ApplicationDto = struct {
    id: i64,
    project_id: i64,
    name: []const u8,
    type: []const u8,
    client_id: []const u8,
    redirect_uris: []const u8,
    grant_types: []const u8,
    response_types: []const u8,
    scopes: []const u8,
    access_token_ttl: i64,
    refresh_token_ttl: i64,
    pkce_required: bool,
    active: bool,
};

fn appToDto(row: service.ApplicationRow, include_secret: bool) ApplicationDto {
    _ = include_secret; // secret hash is never exposed
    return .{
        .id = row.id,
        .project_id = row.project_id,
        .name = row.name,
        .type = row.type,
        .client_id = row.client_id,
        .redirect_uris = row.redirect_uris,
        .grant_types = row.grant_types,
        .response_types = row.response_types,
        .scopes = row.scopes,
        .access_token_ttl = row.access_token_ttl,
        .refresh_token_ttl = row.refresh_token_ttl,
        .pkce_required = row.pkce_required,
        .active = row.active,
    };
}

const RoleDto = struct {
    id: i64,
    project_id: i64,
    key: []const u8,
    name: []const u8,
    permissions: []const u8,
};

fn roleToDto(row: service.RoleRow) RoleDto {
    return .{ .id = row.id, .project_id = row.project_id, .key = row.key, .name = row.name, .permissions = row.permissions };
}

const SessionDto = struct {
    id: i64,
    user_id: i64,
    client_id: i64,
    device_id: []const u8,
    ip: []const u8,
    user_agent: []const u8,
    auth_method: []const u8,
    last_seen_at: i64,
    expires_at: i64,
    revoked_at: i64,
};

fn sessionToDto(row: service.SessionRow) SessionDto {
    return .{
        .id = row.id,
        .user_id = row.user_id,
        .client_id = row.client_id,
        .device_id = row.device_id,
        .ip = row.ip,
        .user_agent = row.user_agent,
        .auth_method = row.auth_method,
        .last_seen_at = row.last_seen_at,
        .expires_at = row.expires_at,
        .revoked_at = row.revoked_at,
    };
}

pub const DefaultIamApi = IamApi(service.IamService, user_svc.UserService);
