//! Persistence over the zent Client for the ZenaIAM kernel.
//!
//! Results are duped into plain DTOs (like the existing user/tenant stores)
//! so the zent entity lifecycle never leaks past this boundary.

const std = @import("std");
const zent = @import("zent");
const crud = zent.crud_helpers;
const model = @import("model.zig");
const schema = @import("../../schema.zig");

const graph = zent.codegen.graph.buildGraph(&.{
    model.Organization,
    model.Project,
    model.Application,
    model.Role,
    model.RoleAssignment,
    model.Session,
    model.AuthorizationCode,
    model.RefreshToken,
    model.Consent,
});
pub const infos = graph.types;
/// Shared, application-wide typed client (all schemas registered in schema.zig).
pub const Client = schema.Client;

pub const OrganizationInfo = infos[0];
pub const ProjectInfo = infos[1];
pub const ApplicationInfo = infos[2];
pub const RoleInfo = infos[3];
pub const RoleAssignmentInfo = infos[4];
pub const SessionInfo = infos[5];
pub const AuthorizationCodeInfo = infos[6];
pub const RefreshTokenInfo = infos[7];
pub const ConsentInfo = infos[8];

// ── Row DTOs ────────────────────────────────────────────────────────

pub const OrganizationRow = struct {
    id: i64,
    tenant_id: i64,
    name: []const u8,
    description: []const u8,
    domain: []const u8,
    active: bool,
    created_at: i64,
    updated_at: i64,

    pub fn free(self: OrganizationRow, a: std.mem.Allocator) void {
        a.free(self.name);
        a.free(self.description);
        a.free(self.domain);
    }
};

pub const ProjectRow = struct {
    id: i64,
    tenant_id: i64,
    org_id: i64,
    name: []const u8,
    description: []const u8,
    active: bool,
    created_at: i64,
    updated_at: i64,

    pub fn free(self: ProjectRow, a: std.mem.Allocator) void {
        a.free(self.name);
        a.free(self.description);
    }
};

pub const ApplicationRow = struct {
    id: i64,
    tenant_id: i64,
    project_id: i64,
    name: []const u8,
    type: []const u8,
    client_id: []const u8,
    client_secret_hash: []const u8,
    redirect_uris: []const u8,
    post_logout_redirect_uris: []const u8,
    allowed_origins: []const u8,
    grant_types: []const u8,
    response_types: []const u8,
    scopes: []const u8,
    access_token_ttl: i64,
    refresh_token_ttl: i64,
    pkce_required: bool,
    active: bool,
    created_at: i64,
    updated_at: i64,

    pub fn free(self: ApplicationRow, a: std.mem.Allocator) void {
        a.free(self.name);
        a.free(self.type);
        a.free(self.client_id);
        a.free(self.client_secret_hash);
        a.free(self.redirect_uris);
        a.free(self.post_logout_redirect_uris);
        a.free(self.allowed_origins);
        a.free(self.grant_types);
        a.free(self.response_types);
        a.free(self.scopes);
    }
};

pub const RoleRow = struct {
    id: i64,
    tenant_id: i64,
    project_id: i64,
    key: []const u8,
    name: []const u8,
    permissions: []const u8,
    created_at: i64,
    updated_at: i64,

    pub fn free(self: RoleRow, a: std.mem.Allocator) void {
        a.free(self.key);
        a.free(self.name);
        a.free(self.permissions);
    }
};

pub const RoleAssignmentRow = struct {
    id: i64,
    tenant_id: i64,
    user_id: i64,
    role_id: i64,
    project_id: i64,
    created_at: i64,
    updated_at: i64,
};

pub const SessionRow = struct {
    id: i64,
    tenant_id: i64,
    user_id: i64,
    client_id: i64,
    device_id: []const u8,
    ip: []const u8,
    user_agent: []const u8,
    auth_method: []const u8,
    last_seen_at: i64,
    expires_at: i64,
    revoked_at: i64,
    created_at: i64,
    updated_at: i64,

    pub fn free(self: SessionRow, a: std.mem.Allocator) void {
        a.free(self.device_id);
        a.free(self.ip);
        a.free(self.user_agent);
        a.free(self.auth_method);
    }
};

pub const AuthorizationCodeRow = struct {
    id: i64,
    tenant_id: i64,
    application_id: i64,
    user_id: i64,
    code_hash: []const u8,
    redirect_uri: []const u8,
    scope: []const u8,
    nonce: []const u8,
    code_challenge: []const u8,
    code_challenge_method: []const u8,
    expires_at: i64,
    used_at: i64,
    created_at: i64,
    updated_at: i64,

    pub fn free(self: AuthorizationCodeRow, a: std.mem.Allocator) void {
        a.free(self.code_hash);
        a.free(self.redirect_uri);
        a.free(self.scope);
        a.free(self.nonce);
        a.free(self.code_challenge);
        a.free(self.code_challenge_method);
    }
};

pub const RefreshTokenRow = struct {
    id: i64,
    tenant_id: i64,
    application_id: i64,
    user_id: i64,
    session_id: i64,
    token_hash: []const u8,
    scope: []const u8,
    expires_at: i64,
    revoked_at: i64,
    created_at: i64,
    updated_at: i64,

    pub fn free(self: RefreshTokenRow, a: std.mem.Allocator) void {
        a.free(self.token_hash);
        a.free(self.scope);
    }
};

pub const ConsentRow = struct {
    id: i64,
    tenant_id: i64,
    application_id: i64,
    user_id: i64,
    scope: []const u8,
    granted_at: i64,
    created_at: i64,
    updated_at: i64,

    pub fn free(self: ConsentRow, a: std.mem.Allocator) void {
        a.free(self.scope);
    }
};

pub const OrgListResult = struct {
    items: []OrganizationRow,
    total: i64,

    pub fn free(self: *OrgListResult, a: std.mem.Allocator) void {
        for (self.items) |r| r.free(a);
        a.free(self.items);
    }
};

pub const ProjectListResult = struct {
    items: []ProjectRow,
    total: i64,

    pub fn free(self: *ProjectListResult, a: std.mem.Allocator) void {
        for (self.items) |r| r.free(a);
        a.free(self.items);
    }
};

pub const ApplicationListResult = struct {
    items: []ApplicationRow,
    total: i64,

    pub fn free(self: *ApplicationListResult, a: std.mem.Allocator) void {
        for (self.items) |r| r.free(a);
        a.free(self.items);
    }
};

pub const RoleListResult = struct {
    items: []RoleRow,
    total: i64,

    pub fn free(self: *RoleListResult, a: std.mem.Allocator) void {
        for (self.items) |r| r.free(a);
        a.free(self.items);
    }
};

pub const SessionListResult = struct {
    items: []SessionRow,
    total: i64,

    pub fn free(self: *SessionListResult, a: std.mem.Allocator) void {
        for (self.items) |r| r.free(a);
        a.free(self.items);
    }
};

// ── Store ───────────────────────────────────────────────────────────

pub const IamStore = struct {
    allocator: std.mem.Allocator,
    client: Client,

    pub fn init(allocator: std.mem.Allocator, client: Client) IamStore {
        return .{ .allocator = allocator, .client = client };
    }

    fn ts(e: anytype) i64 {
        return @as(?i64, e) orelse 0;
    }

    // ── Organization ─────────────────────────────────────────

    fn dupOrg(self: *IamStore, e: anytype) !OrganizationRow {
        return .{
            .id = e.id,
            .tenant_id = e.tenant_id,
            .name = try self.allocator.dupe(u8, e.name),
            .description = try self.allocator.dupe(u8, e.description),
            .domain = try self.allocator.dupe(u8, e.domain),
            .active = e.active,
            .created_at = ts(e.created_at),
            .updated_at = ts(e.updated_at),
        };
    }

    pub fn createOrganization(self: *IamStore, tenant_id: i64, name: []const u8, description: []const u8, domain: []const u8, now: i64) !i64 {
        var b = try self.client.organization.Create();
        defer b.deinit();
        _ = try b.setFieldValue("tenant_id", tenant_id);
        _ = try b.setFieldValue("name", name);
        _ = try b.setFieldValue("description", description);
        _ = try b.setFieldValue("domain", domain);
        _ = try b.setFieldValue("active", true);
        _ = try b.setFieldValue("created_at", now);
        _ = try b.setFieldValue("updated_at", now);
        var row = try b.Save();
        defer zent.codegen.deinitEntity(infos, OrganizationInfo, &row, self.allocator);
        return row.id;
    }

    pub fn getOrganization(self: *IamStore, id: i64) !?OrganizationRow {
        var e = (try crud.get(self.client.organization, id)) orelse return null;
        defer zent.codegen.deinitEntity(infos, OrganizationInfo, &e, self.allocator);
        return try self.dupOrg(e);
    }

    pub fn listOrganizations(self: *IamStore, page: usize, page_size: usize, tenant_id: ?i64) !OrgListResult {
        const preds = self.client.organization.predicates;
        var preds_buf: [1]zent.sql.Predicate = undefined;
        var n: usize = 0;
        if (tenant_id) |tid| {
            preds_buf[0] = preds.tenant_idEQ(.{ .int = tid });
            n = 1;
        }
        var result = try crud.paginatedWithOptions(self.client.organization, preds_buf[0..n], .{ .sort_col = "id" }, page, page_size);
        defer result.deinit(infos, OrganizationInfo, self.allocator);
        var out = try self.allocator.alloc(OrganizationRow, result.items.items.len);
        var i: usize = 0;
        errdefer {
            for (out[0..i]) |r| r.free(self.allocator);
            self.allocator.free(out);
        }
        for (result.items.items) |e| {
            out[i] = try self.dupOrg(e);
            i += 1;
        }
        return .{ .items = out, .total = result.total };
    }

    pub fn deleteOrganization(self: *IamStore, id: i64) !void {
        const preds = self.client.organization.predicates;
        var d = self.client.organization.Delete();
        defer d.deinit();
        _ = try d.Where(.{preds.idEQ(.{ .int = id })});
        _ = try d.Exec();
    }

    // ── Project ──────────────────────────────────────────────

    fn dupProject(self: *IamStore, e: anytype) !ProjectRow {
        return .{
            .id = e.id,
            .tenant_id = e.tenant_id,
            .org_id = e.org_id,
            .name = try self.allocator.dupe(u8, e.name),
            .description = try self.allocator.dupe(u8, e.description),
            .active = e.active,
            .created_at = ts(e.created_at),
            .updated_at = ts(e.updated_at),
        };
    }

    pub fn createProject(self: *IamStore, tenant_id: i64, org_id: i64, name: []const u8, description: []const u8, now: i64) !i64 {
        var b = try self.client.project.Create();
        defer b.deinit();
        _ = try b.setFieldValue("tenant_id", tenant_id);
        _ = try b.setFieldValue("org_id", org_id);
        _ = try b.setFieldValue("name", name);
        _ = try b.setFieldValue("description", description);
        _ = try b.setFieldValue("active", true);
        _ = try b.setFieldValue("created_at", now);
        _ = try b.setFieldValue("updated_at", now);
        var row = try b.Save();
        defer zent.codegen.deinitEntity(infos, ProjectInfo, &row, self.allocator);
        return row.id;
    }

    pub fn getProject(self: *IamStore, id: i64) !?ProjectRow {
        var e = (try crud.get(self.client.project, id)) orelse return null;
        defer zent.codegen.deinitEntity(infos, ProjectInfo, &e, self.allocator);
        return try self.dupProject(e);
    }

    pub fn listProjects(self: *IamStore, page: usize, page_size: usize, tenant_id: ?i64) !ProjectListResult {
        const preds = self.client.project.predicates;
        var preds_buf: [1]zent.sql.Predicate = undefined;
        var n: usize = 0;
        if (tenant_id) |tid| {
            preds_buf[0] = preds.tenant_idEQ(.{ .int = tid });
            n = 1;
        }
        var result = try crud.paginatedWithOptions(self.client.project, preds_buf[0..n], .{ .sort_col = "id" }, page, page_size);
        defer result.deinit(infos, ProjectInfo, self.allocator);

        var out = try self.allocator.alloc(ProjectRow, result.items.items.len);
        var i: usize = 0;
        errdefer {
            for (out[0..i]) |r| r.free(self.allocator);
            self.allocator.free(out);
        }
        for (result.items.items) |e| {
            out[i] = try self.dupProject(e);
            i += 1;
        }
        return .{ .items = out, .total = result.total };
    }

    pub fn deleteProject(self: *IamStore, id: i64) !void {
        const preds = self.client.project.predicates;
        var d = self.client.project.Delete();
        defer d.deinit();
        _ = try d.Where(.{preds.idEQ(.{ .int = id })});
        _ = try d.Exec();
    }

    // ── Application ──────────────────────────────────────────

    fn dupApplication(self: *IamStore, e: anytype) !ApplicationRow {
        return .{
            .id = e.id,
            .tenant_id = e.tenant_id,
            .project_id = e.project_id,
            .name = try self.allocator.dupe(u8, e.name),
            .type = try self.allocator.dupe(u8, e.type),
            .client_id = try self.allocator.dupe(u8, e.client_id),
            .client_secret_hash = try self.allocator.dupe(u8, e.client_secret_hash),
            .redirect_uris = try self.allocator.dupe(u8, e.redirect_uris),
            .post_logout_redirect_uris = try self.allocator.dupe(u8, e.post_logout_redirect_uris),
            .allowed_origins = try self.allocator.dupe(u8, e.allowed_origins),
            .grant_types = try self.allocator.dupe(u8, e.grant_types),
            .response_types = try self.allocator.dupe(u8, e.response_types),
            .scopes = try self.allocator.dupe(u8, e.scopes),
            .access_token_ttl = e.access_token_ttl,
            .refresh_token_ttl = e.refresh_token_ttl,
            .pkce_required = e.pkce_required,
            .active = e.active,
            .created_at = ts(e.created_at),
            .updated_at = ts(e.updated_at),
        };
    }

    pub fn createApplication(
        self: *IamStore,
        tenant_id: i64,
        project_id: i64,
        name: []const u8,
        app_type: []const u8,
        client_id: []const u8,
        secret_hash: []const u8,
        redirect_uris: []const u8,
        post_logout_redirect_uris: []const u8,
        allowed_origins: []const u8,
        grant_types: []const u8,
        response_types: []const u8,
        scopes: []const u8,
        access_token_ttl: i64,
        refresh_token_ttl: i64,
        pkce_required: bool,
        now: i64,
    ) !i64 {
        var b = try self.client.application.Create();
        defer b.deinit();
        _ = try b.setFieldValue("tenant_id", tenant_id);
        _ = try b.setFieldValue("project_id", project_id);
        _ = try b.setFieldValue("name", name);
        _ = try b.setFieldValue("type", app_type);
        _ = try b.setFieldValue("client_id", client_id);
        _ = try b.setFieldValue("client_secret_hash", secret_hash);
        _ = try b.setFieldValue("redirect_uris", redirect_uris);
        _ = try b.setFieldValue("post_logout_redirect_uris", post_logout_redirect_uris);
        _ = try b.setFieldValue("allowed_origins", allowed_origins);
        _ = try b.setFieldValue("grant_types", grant_types);
        _ = try b.setFieldValue("response_types", response_types);
        _ = try b.setFieldValue("scopes", scopes);
        _ = try b.setFieldValue("access_token_ttl", access_token_ttl);
        _ = try b.setFieldValue("refresh_token_ttl", refresh_token_ttl);
        _ = try b.setFieldValue("pkce_required", pkce_required);
        _ = try b.setFieldValue("active", true);
        _ = try b.setFieldValue("created_at", now);
        _ = try b.setFieldValue("updated_at", now);
        var row = try b.Save();
        defer zent.codegen.deinitEntity(infos, ApplicationInfo, &row, self.allocator);
        return row.id;
    }

    pub fn getApplication(self: *IamStore, id: i64) !?ApplicationRow {
        var e = (try crud.get(self.client.application, id)) orelse return null;
        defer zent.codegen.deinitEntity(infos, ApplicationInfo, &e, self.allocator);
        return try self.dupApplication(e);
    }

    pub fn getApplicationByClientId(self: *IamStore, client_id: []const u8) !?ApplicationRow {
        const preds = self.client.application.predicates;
        var e = (try crud.first(self.client.application, .{preds.client_idEQ(.{ .string = client_id })})) orelse return null;
        defer zent.codegen.deinitEntity(infos, ApplicationInfo, &e, self.allocator);
        return try self.dupApplication(e);
    }

    pub fn listApplicationsByProject(self: *IamStore, project_id: i64) !ApplicationListResult {
        const preds = self.client.application.predicates;
        const rows = try crud.all(self.client.application, .{preds.project_idEQ(.{ .int = project_id })});
        defer zent.crud_helpers.deinitRows(infos, ApplicationInfo, rows, self.allocator);

        var out = try self.allocator.alloc(ApplicationRow, rows.items.len);
        var i: usize = 0;
        errdefer {
            for (out[0..i]) |r| r.free(self.allocator);
            self.allocator.free(out);
        }
        for (rows.items) |e| {
            out[i] = try self.dupApplication(e);
            i += 1;
        }
        return .{ .items = out, .total = @intCast(i) };
    }

    pub fn deleteApplication(self: *IamStore, id: i64) !void {
        const preds = self.client.application.predicates;
        var d = self.client.application.Delete();
        defer d.deinit();
        _ = try d.Where(.{preds.idEQ(.{ .int = id })});
        _ = try d.Exec();
    }

    // ── Role ─────────────────────────────────────────────────

    fn dupRole(self: *IamStore, e: anytype) !RoleRow {
        return .{
            .id = e.id,
            .tenant_id = e.tenant_id,
            .project_id = e.project_id,
            .key = try self.allocator.dupe(u8, e.key),
            .name = try self.allocator.dupe(u8, e.name),
            .permissions = try self.allocator.dupe(u8, e.permissions),
            .created_at = ts(e.created_at),
            .updated_at = ts(e.updated_at),
        };
    }

    pub fn createRole(self: *IamStore, tenant_id: i64, project_id: i64, key: []const u8, name: []const u8, permissions: []const u8, now: i64) !i64 {
        var b = try self.client.role.Create();
        defer b.deinit();
        _ = try b.setFieldValue("tenant_id", tenant_id);
        _ = try b.setFieldValue("project_id", project_id);
        _ = try b.setFieldValue("key", key);
        _ = try b.setFieldValue("name", name);
        _ = try b.setFieldValue("permissions", permissions);
        _ = try b.setFieldValue("created_at", now);
        _ = try b.setFieldValue("updated_at", now);
        var row = try b.Save();
        defer zent.codegen.deinitEntity(infos, RoleInfo, &row, self.allocator);
        return row.id;
    }

    pub fn getRole(self: *IamStore, id: i64) !?RoleRow {
        var e = (try crud.get(self.client.role, id)) orelse return null;
        defer zent.codegen.deinitEntity(infos, RoleInfo, &e, self.allocator);
        return try self.dupRole(e);
    }

    pub fn listRolesByProject(self: *IamStore, project_id: i64) !RoleListResult {
        const preds = self.client.role.predicates;
        const rows = try crud.all(self.client.role, .{preds.project_idEQ(.{ .int = project_id })});
        defer zent.crud_helpers.deinitRows(infos, RoleInfo, rows, self.allocator);

        var out = try self.allocator.alloc(RoleRow, rows.items.len);
        var i: usize = 0;
        errdefer {
            for (out[0..i]) |r| r.free(self.allocator);
            self.allocator.free(out);
        }
        for (rows.items) |e| {
            out[i] = try self.dupRole(e);
            i += 1;
        }
        return .{ .items = out, .total = @intCast(i) };
    }

    pub fn deleteRole(self: *IamStore, id: i64) !void {
        const preds = self.client.role.predicates;
        var d = self.client.role.Delete();
        defer d.deinit();
        _ = try d.Where(.{preds.idEQ(.{ .int = id })});
        _ = try d.Exec();
    }

    // ── RoleAssignment ───────────────────────────────────────

    pub fn assignRole(self: *IamStore, tenant_id: i64, user_id: i64, role_id: i64, project_id: i64, now: i64) !i64 {
        var b = try self.client.role_assignment.Create();
        defer b.deinit();
        _ = try b.setFieldValue("tenant_id", tenant_id);
        _ = try b.setFieldValue("user_id", user_id);
        _ = try b.setFieldValue("role_id", role_id);
        _ = try b.setFieldValue("project_id", project_id);
        _ = try b.setFieldValue("created_at", now);
        _ = try b.setFieldValue("updated_at", now);
        var row = try b.Save();
        defer zent.codegen.deinitEntity(infos, RoleAssignmentInfo, &row, self.allocator);
        return row.id;
    }

    /// Returns role ids assigned to a user (optionally scoped to a project).
    pub fn listRoleIdsForUser(self: *IamStore, user_id: i64, project_id: ?i64) ![]i64 {
        const preds = self.client.role_assignment.predicates;
        var buf: [2]zent.sql.Predicate = undefined;
        var n: usize = 0;
        buf[0] = preds.user_idEQ(.{ .int = user_id });
        n = 1;
        if (project_id) |pid| {
            buf[1] = preds.project_idEQ(.{ .int = pid });
            n = 2;
        }
        const rows = try crud.all(self.client.role_assignment, buf[0..n]);
        defer zent.crud_helpers.deinitRows(infos, RoleAssignmentInfo, rows, self.allocator);

        var out = try self.allocator.alloc(i64, rows.items.len);
        var i: usize = 0;
        for (rows.items) |e| {
            out[i] = e.role_id;
            i += 1;
        }
        return out[0..i];
    }

    pub fn removeRoleAssignment(self: *IamStore, id: i64) !void {
        const preds = self.client.role_assignment.predicates;
        var d = self.client.role_assignment.Delete();
        defer d.deinit();
        _ = try d.Where(.{preds.idEQ(.{ .int = id })});
        _ = try d.Exec();
    }

    // ── Session ──────────────────────────────────────────────

    fn dupSession(self: *IamStore, e: anytype) !SessionRow {
        return .{
            .id = e.id,
            .tenant_id = e.tenant_id,
            .user_id = e.user_id,
            .client_id = e.client_id,
            .device_id = try self.allocator.dupe(u8, e.device_id),
            .ip = try self.allocator.dupe(u8, e.ip),
            .user_agent = try self.allocator.dupe(u8, e.user_agent),
            .auth_method = try self.allocator.dupe(u8, e.auth_method),
            .last_seen_at = e.last_seen_at,
            .expires_at = e.expires_at,
            .revoked_at = e.revoked_at,
            .created_at = ts(e.created_at),
            .updated_at = ts(e.updated_at),
        };
    }

    pub fn createSession(
        self: *IamStore,
        tenant_id: i64,
        user_id: i64,
        client_id: i64,
        device_id: []const u8,
        ip: []const u8,
        user_agent: []const u8,
        auth_method: []const u8,
        expires_at: i64,
        now: i64,
    ) !i64 {
        var b = try self.client.session.Create();
        defer b.deinit();
        _ = try b.setFieldValue("tenant_id", tenant_id);
        _ = try b.setFieldValue("user_id", user_id);
        _ = try b.setFieldValue("client_id", client_id);
        _ = try b.setFieldValue("device_id", device_id);
        _ = try b.setFieldValue("ip", ip);
        _ = try b.setFieldValue("user_agent", user_agent);
        _ = try b.setFieldValue("auth_method", auth_method);
        _ = try b.setFieldValue("last_seen_at", now);
        _ = try b.setFieldValue("expires_at", expires_at);
        _ = try b.setFieldValue("revoked_at", 0);
        _ = try b.setFieldValue("created_at", now);
        _ = try b.setFieldValue("updated_at", now);
        var row = try b.Save();
        defer zent.codegen.deinitEntity(infos, SessionInfo, &row, self.allocator);
        return row.id;
    }

    pub fn getSession(self: *IamStore, id: i64) !?SessionRow {
        var e = (try crud.get(self.client.session, id)) orelse return null;
        defer zent.codegen.deinitEntity(infos, SessionInfo, &e, self.allocator);
        return try self.dupSession(e);
    }

    pub fn revokeSession(self: *IamStore, id: i64, now: i64) !void {
        const preds = self.client.session.predicates;
        var u = self.client.session.Update();
        defer u.deinit();
        _ = try u.setFieldValue("revoked_at", now);
        _ = try u.setFieldValue("updated_at", now);
        _ = try u.Where(.{preds.idEQ(.{ .int = id })});
        _ = try u.Save();
    }

    /// Revoke all active sessions for a user (password change / logout-all).
    pub fn revokeSessionsForUser(self: *IamStore, user_id: i64, now: i64) !void {
        const preds = self.client.session.predicates;
        const u_q = preds.user_idEQ(.{ .int = user_id });
        const r_q = preds.revoked_atEQ(.{ .int = 0 });
        const and_q = zent.sql.And(&u_q, &r_q);
        var u = self.client.session.Update();
        defer u.deinit();
        _ = try u.setFieldValue("revoked_at", now);
        _ = try u.setFieldValue("updated_at", now);
        _ = try u.Where(.{and_q});
        _ = try u.Save();
    }

    pub fn listSessionsForUser(self: *IamStore, user_id: i64) !SessionListResult {
        const preds = self.client.session.predicates;
        const rows = try crud.all(self.client.session, .{preds.user_idEQ(.{ .int = user_id })});
        defer zent.crud_helpers.deinitRows(infos, SessionInfo, rows, self.allocator);

        var out = try self.allocator.alloc(SessionRow, rows.items.len);
        var i: usize = 0;
        errdefer {
            for (out[0..i]) |r| r.free(self.allocator);
            self.allocator.free(out);
        }
        for (rows.items) |e| {
            out[i] = try self.dupSession(e);
            i += 1;
        }
        return .{ .items = out, .total = @intCast(i) };
    }

    // ── AuthorizationCode ────────────────────────────────────

    fn dupAuthCode(self: *IamStore, e: anytype) !AuthorizationCodeRow {
        return .{
            .id = e.id,
            .tenant_id = e.tenant_id,
            .application_id = e.application_id,
            .user_id = e.user_id,
            .code_hash = try self.allocator.dupe(u8, e.code_hash),
            .redirect_uri = try self.allocator.dupe(u8, e.redirect_uri),
            .scope = try self.allocator.dupe(u8, e.scope),
            .nonce = try self.allocator.dupe(u8, e.nonce),
            .code_challenge = try self.allocator.dupe(u8, e.code_challenge),
            .code_challenge_method = try self.allocator.dupe(u8, e.code_challenge_method),
            .expires_at = e.expires_at,
            .used_at = e.used_at,
            .created_at = ts(e.created_at),
            .updated_at = ts(e.updated_at),
        };
    }

    pub fn createAuthCode(
        self: *IamStore,
        tenant_id: i64,
        application_id: i64,
        user_id: i64,
        code_hash: []const u8,
        redirect_uri: []const u8,
        scope: []const u8,
        nonce: []const u8,
        code_challenge: []const u8,
        code_challenge_method: []const u8,
        expires_at: i64,
        now: i64,
    ) !i64 {
        var b = try self.client.authorization_code.Create();
        defer b.deinit();
        _ = try b.setFieldValue("tenant_id", tenant_id);
        _ = try b.setFieldValue("application_id", application_id);
        _ = try b.setFieldValue("user_id", user_id);
        _ = try b.setFieldValue("code_hash", code_hash);
        _ = try b.setFieldValue("redirect_uri", redirect_uri);
        _ = try b.setFieldValue("scope", scope);
        _ = try b.setFieldValue("nonce", nonce);
        _ = try b.setFieldValue("code_challenge", code_challenge);
        _ = try b.setFieldValue("code_challenge_method", code_challenge_method);
        _ = try b.setFieldValue("expires_at", expires_at);
        _ = try b.setFieldValue("used_at", 0);
        _ = try b.setFieldValue("created_at", now);
        _ = try b.setFieldValue("updated_at", now);
        var row = try b.Save();
        defer zent.codegen.deinitEntity(infos, AuthorizationCodeInfo, &row, self.allocator);
        return row.id;
    }

    /// Look up an authorization code by its stored (hashed) code value.
    pub fn getAuthCodeByHash(self: *IamStore, code_hash: []const u8) !?AuthorizationCodeRow {
        const preds = self.client.authorization_code.predicates;
        var e = (try crud.first(self.client.authorization_code, .{preds.code_hashEQ(.{ .string = code_hash })})) orelse return null;
        defer zent.codegen.deinitEntity(infos, AuthorizationCodeInfo, &e, self.allocator);
        return try self.dupAuthCode(e);
    }

    pub fn consumeAuthCode(self: *IamStore, id: i64, now: i64) !void {
        const preds = self.client.authorization_code.predicates;
        var u = self.client.authorization_code.Update();
        defer u.deinit();
        _ = try u.setFieldValue("used_at", now);
        _ = try u.setFieldValue("updated_at", now);
        _ = try u.Where(.{preds.idEQ(.{ .int = id })});
        _ = try u.Save();
    }

    pub fn purgeExpiredAuthCodes(self: *IamStore, now: i64) !void {
        const preds = self.client.authorization_code.predicates;
        var d = self.client.authorization_code.Delete();
        defer d.deinit();
        _ = try d.Where(.{preds.expires_atLT(.{ .int = now })});
        _ = try d.Exec();
    }

    // ── RefreshToken ─────────────────────────────────────────

    fn dupRefreshToken(self: *IamStore, e: anytype) !RefreshTokenRow {
        return .{
            .id = e.id,
            .tenant_id = e.tenant_id,
            .application_id = e.application_id,
            .user_id = e.user_id,
            .session_id = e.session_id,
            .token_hash = try self.allocator.dupe(u8, e.token_hash),
            .scope = try self.allocator.dupe(u8, e.scope),
            .expires_at = e.expires_at,
            .revoked_at = e.revoked_at,
            .created_at = ts(e.created_at),
            .updated_at = ts(e.updated_at),
        };
    }

    pub fn createRefreshToken(
        self: *IamStore,
        tenant_id: i64,
        application_id: i64,
        user_id: i64,
        session_id: i64,
        token_hash: []const u8,
        scope: []const u8,
        expires_at: i64,
        now: i64,
    ) !i64 {
        var b = try self.client.refresh_token.Create();
        defer b.deinit();
        _ = try b.setFieldValue("tenant_id", tenant_id);
        _ = try b.setFieldValue("application_id", application_id);
        _ = try b.setFieldValue("user_id", user_id);
        _ = try b.setFieldValue("session_id", session_id);
        _ = try b.setFieldValue("token_hash", token_hash);
        _ = try b.setFieldValue("scope", scope);
        _ = try b.setFieldValue("expires_at", expires_at);
        _ = try b.setFieldValue("revoked_at", 0);
        _ = try b.setFieldValue("created_at", now);
        _ = try b.setFieldValue("updated_at", now);
        var row = try b.Save();
        defer zent.codegen.deinitEntity(infos, RefreshTokenInfo, &row, self.allocator);
        return row.id;
    }

    pub fn findRefreshTokenByHash(self: *IamStore, token_hash: []const u8) !?RefreshTokenRow {
        const preds = self.client.refresh_token.predicates;
        const h_q = preds.token_hashEQ(.{ .string = token_hash });
        const r_q = preds.revoked_atEQ(.{ .int = 0 });
        const and_q = zent.sql.And(&h_q, &r_q);
        var e = (try crud.first(self.client.refresh_token, .{and_q})) orelse return null;
        defer zent.codegen.deinitEntity(infos, RefreshTokenInfo, &e, self.allocator);
        return try self.dupRefreshToken(e);
    }

    pub fn revokeRefreshToken(self: *IamStore, id: i64, now: i64) !void {
        const preds = self.client.refresh_token.predicates;
        var u = self.client.refresh_token.Update();
        defer u.deinit();
        _ = try u.setFieldValue("revoked_at", now);
        _ = try u.setFieldValue("updated_at", now);
        _ = try u.Where(.{preds.idEQ(.{ .int = id })});
        _ = try u.Save();
    }

    // ── Consent ──────────────────────────────────────────────

    fn dupConsent(self: *IamStore, e: anytype) !ConsentRow {
        return .{
            .id = e.id,
            .tenant_id = e.tenant_id,
            .application_id = e.application_id,
            .user_id = e.user_id,
            .scope = try self.allocator.dupe(u8, e.scope),
            .granted_at = e.granted_at,
            .created_at = ts(e.created_at),
            .updated_at = ts(e.updated_at),
        };
    }

    pub fn upsertConsent(self: *IamStore, tenant_id: i64, application_id: i64, user_id: i64, scope: []const u8, now: i64) !i64 {
        const preds = self.client.consent.predicates;
        var existing = try crud.first(self.client.consent, .{
            zent.sql.And(
                &preds.application_idEQ(.{ .int = application_id }),
                &preds.user_idEQ(.{ .int = user_id }),
            ),
        });
        if (existing) |*e| {
            defer zent.codegen.deinitEntity(infos, ConsentInfo, e, self.allocator);
            const id = e.id;
            var u = self.client.consent.Update();
            defer u.deinit();
            _ = try u.setFieldValue("scope", scope);
            _ = try u.setFieldValue("granted_at", now);
            _ = try u.setFieldValue("updated_at", now);
            _ = try u.Where(.{preds.idEQ(.{ .int = id })});
            _ = try u.Save();
            return id;
        }
        var b = try self.client.consent.Create();
        defer b.deinit();
        _ = try b.setFieldValue("tenant_id", tenant_id);
        _ = try b.setFieldValue("application_id", application_id);
        _ = try b.setFieldValue("user_id", user_id);
        _ = try b.setFieldValue("scope", scope);
        _ = try b.setFieldValue("granted_at", now);
        _ = try b.setFieldValue("created_at", now);
        _ = try b.setFieldValue("updated_at", now);
        var row = try b.Save();
        defer zent.codegen.deinitEntity(infos, ConsentInfo, &row, self.allocator);
        return row.id;
    }

    pub fn getConsent(self: *IamStore, application_id: i64, user_id: i64) !?ConsentRow {
        const preds = self.client.consent.predicates;
        var e = (try crud.first(self.client.consent, .{
            zent.sql.And(
                &preds.application_idEQ(.{ .int = application_id }),
                &preds.user_idEQ(.{ .int = user_id }),
            ),
        })) orelse return null;
        defer zent.codegen.deinitEntity(infos, ConsentInfo, &e, self.allocator);
        return try self.dupConsent(e);
    }
};
