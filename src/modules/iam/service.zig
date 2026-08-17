//! Service layer for the ZenaIAM kernel - validation, client-secret
//! generation, role resolution, session lifecycle. No HTTP/SQL leakage.

const std = @import("std");
const zigmodu = @import("zigmodu");
const persist = @import("persistence.zig");

pub const OrganizationRow = persist.OrganizationRow;
pub const OrgListResult = persist.OrgListResult;
pub const ProjectRow = persist.ProjectRow;
pub const ApplicationRow = persist.ApplicationRow;
pub const RoleRow = persist.RoleRow;
pub const SessionRow = persist.SessionRow;
pub const ProjectListResult = persist.ProjectListResult;
pub const ApplicationListResult = persist.ApplicationListResult;
pub const RoleListResult = persist.RoleListResult;
pub const SessionListResult = persist.SessionListResult;

pub const IamError = error{
    InvalidName,
    InvalidClientId,
    ProjectNotFound,
    ApplicationNotFound,
    RoleNotFound,
    RedirectUriMismatch,
    Unexpected,
};

/// A freshly-created OAuth client: the client_id plus the *plaintext*
/// client_secret (shown exactly once; only its hash is persisted).
pub const ClientCredentials = struct {
    client_id: []const u8,
    client_secret: []const u8,

    pub fn deinit(self: ClientCredentials, a: std.mem.Allocator) void {
        a.free(self.client_id);
        a.free(self.client_secret);
    }
};

pub const IamService = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *persist.IamStore,
    sec: *zigmodu.security.AppSecurity,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, store: *persist.IamStore, sec: *zigmodu.security.AppSecurity) IamService {
        return .{ .allocator = allocator, .io = io, .store = store, .sec = sec };
    }

    fn now(self: *IamService) i64 {
        return zigmodu.time.wallClockSeconds(self.io);
    }

    // ── Organization ─────────────────────────────────────────

    pub fn createOrganization(self: *IamService, tenant_id: i64, name: []const u8, description: []const u8, domain: []const u8) IamError!i64 {
        const trimmed = std.mem.trim(u8, name, " \t");
        if (trimmed.len == 0) return error.InvalidName;
        return self.store.createOrganization(tenant_id, trimmed, description, domain, self.now()) catch return error.Unexpected;
    }

    pub fn getOrganization(self: *IamService, id: i64) !?OrganizationRow {
        return self.store.getOrganization(id);
    }

    pub fn listOrganizations(self: *IamService, page: usize, page_size: usize, tenant_id: ?i64) !OrgListResult {
        return self.store.listOrganizations(page, page_size, tenant_id);
    }

    pub fn deleteOrganization(self: *IamService, id: i64) !void {
        try self.store.deleteOrganization(id);
    }

    // ── Project ──────────────────────────────────────────────


    pub fn createProject(self: *IamService, tenant_id: i64, org_id: i64, name: []const u8, description: []const u8) IamError!i64 {
        const trimmed = std.mem.trim(u8, name, " \t");
        if (trimmed.len == 0) return error.InvalidName;
        return self.store.createProject(tenant_id, org_id, trimmed, description, self.now()) catch return error.Unexpected;
    }

    pub fn getProject(self: *IamService, id: i64) !?ProjectRow {
        return self.store.getProject(id);
    }

    pub fn listProjects(self: *IamService, page: usize, page_size: usize, tenant_id: ?i64) !ProjectListResult {
        return self.store.listProjects(page, page_size, tenant_id);
    }

    pub fn deleteProject(self: *IamService, id: i64) !void {
        try self.store.deleteProject(id);
    }

    // ── Application ──────────────────────────────────────────

    /// Generate a cryptographically-random base64url string of `n` bytes.
    fn randomB64(self: *IamService, n: usize) ![]const u8 {
        const buf = try self.allocator.alloc(u8, n);
        defer self.allocator.free(buf);
        try self.fillEntropy(buf);
        const enc = std.base64.url_safe_no_pad.Encoder;
        const out_len = enc.calcSize(n);
        const out = try self.allocator.alloc(u8, out_len);
        errdefer self.allocator.free(out);
        _ = enc.encode(out, buf);
        return out;
    }

    fn fillEntropy(self: *IamService, buf: []u8) !void {
        var file = try std.Io.Dir.cwd().openFile(self.io, "/dev/urandom", .{});
        defer file.close(self.io);
        const read = try file.readPositionalAll(self.io, buf, 0);
        if (read != buf.len) return error.Unexpected;
    }

    pub fn createApplication(
        self: *IamService,
        tenant_id: i64,
        project_id: i64,
        name: []const u8,
        app_type: []const u8,
        redirect_uris: []const u8,
        post_logout_redirect_uris: []const u8,
        allowed_origins: []const u8,
        grant_types: []const u8,
        response_types: []const u8,
        scopes: []const u8,
        access_token_ttl: i64,
        refresh_token_ttl: i64,
        pkce_required: bool,
    ) IamError!ClientCredentials {
        const trimmed = std.mem.trim(u8, name, " \t");
        if (trimmed.len == 0) return error.InvalidName;

        // Verify the owning project exists.
        const proj_opt = self.store.getProject(project_id) catch return error.Unexpected;
        if (proj_opt) |p| {
            p.free(self.allocator);
        } else {
            return error.ProjectNotFound;
        }

        const client_id = self.randomB64(16) catch return error.Unexpected;
        errdefer self.allocator.free(client_id);
        const secret = self.randomB64(24) catch return error.Unexpected;
        errdefer self.allocator.free(secret);

        const secret_hash = self.sec.module.hashPassword(secret) catch return error.Unexpected;
        defer self.sec.module.allocator.free(secret_hash);

        _ = self.store.createApplication(
            tenant_id,
            project_id,
            trimmed,
            app_type,
            client_id,
            secret_hash,
            redirect_uris,
            post_logout_redirect_uris,
            allowed_origins,
            grant_types,
            response_types,
            scopes,
            access_token_ttl,
            refresh_token_ttl,
            pkce_required,
            self.now(),
        ) catch return error.Unexpected;

        return .{ .client_id = client_id, .client_secret = secret };
    }

    /// Authenticate a client by client_id + secret. Returns the app row on
    /// success, null when the secret is wrong or the client is unknown.
    pub fn authenticateClient(self: *IamService, client_id: []const u8, client_secret: []const u8) !?ApplicationRow {
        const row_opt = try self.store.getApplicationByClientId(client_id);
        const row = row_opt orelse return null;
        errdefer row.free(self.allocator);
        if (!row.active) {
            row.free(self.allocator);
            return null;
        }
        if (!self.sec.module.verifyPassword(client_secret, row.client_secret_hash)) {
            row.free(self.allocator);
            return null;
        }
        return row;
    }

    pub fn getApplication(self: *IamService, id: i64) !?ApplicationRow {
        return self.store.getApplication(id);
    }

    pub fn getApplicationByClientId(self: *IamService, client_id: []const u8) !?ApplicationRow {
        return self.store.getApplicationByClientId(client_id);
    }

    pub fn listApplicationsByProject(self: *IamService, project_id: i64) !ApplicationListResult {
        return self.store.listApplicationsByProject(project_id);
    }

    pub fn deleteApplication(self: *IamService, id: i64) !void {
        try self.store.deleteApplication(id);
    }

    // ── Role + assignment ────────────────────────────────────

    pub fn createRole(self: *IamService, tenant_id: i64, project_id: i64, key: []const u8, name: []const u8, permissions: []const u8) IamError!i64 {
        if (std.mem.trim(u8, key, " \t").len == 0) return error.InvalidName;
        return self.store.createRole(tenant_id, project_id, key, name, permissions, self.now()) catch return error.Unexpected;
    }

    pub fn getRole(self: *IamService, id: i64) !?RoleRow {
        return self.store.getRole(id);
    }

    pub fn listRolesByProject(self: *IamService, project_id: i64) !RoleListResult {
        return self.store.listRolesByProject(project_id);
    }

    pub fn deleteRole(self: *IamService, id: i64) !void {
        try self.store.deleteRole(id);
    }

    pub fn assignRole(self: *IamService, tenant_id: i64, user_id: i64, role_id: i64, project_id: i64) !i64 {
        return self.store.assignRole(tenant_id, user_id, role_id, project_id, self.now());
    }

    /// Resolve the role *keys* for a user (optionally scoped to a project).
    pub fn roleKeysForUser(self: *IamService, user_id: i64, project_id: ?i64) ![][]const u8 {
        const ids = try self.store.listRoleIdsForUser(user_id, project_id);
        defer self.allocator.free(ids);
        var out = std.ArrayList([]const u8).empty;
        errdefer {
            for (out.items) |k| self.allocator.free(k);
            out.deinit(self.allocator);
        }
        for (ids) |id| {
            const role_opt = try self.store.getRole(id);
            if (role_opt) |r| {
                try out.append(self.allocator, try self.allocator.dupe(u8, r.key));
                r.free(self.allocator);
            }
        }
        return try out.toOwnedSlice(self.allocator);
    }

    // ── Session ──────────────────────────────────────────────

    pub fn createSession(
        self: *IamService,
        tenant_id: i64,
        user_id: i64,
        client_id: i64,
        device_id: []const u8,
        ip: []const u8,
        user_agent: []const u8,
        auth_method: []const u8,
        ttl_seconds: i64,
    ) !i64 {
        const exp = self.now() + ttl_seconds;
        return self.store.createSession(tenant_id, user_id, client_id, device_id, ip, user_agent, auth_method, exp, self.now());
    }

    pub fn getSession(self: *IamService, id: i64) !?SessionRow {
        return self.store.getSession(id);
    }

    pub fn revokeSession(self: *IamService, id: i64) !void {
        try self.store.revokeSession(id, self.now());
    }

    pub fn revokeSessionsForUser(self: *IamService, user_id: i64) !void {
        try self.store.revokeSessionsForUser(user_id, self.now());
    }

    pub fn listSessionsForUser(self: *IamService, user_id: i64) !SessionListResult {
        return self.store.listSessionsForUser(user_id);
    }
};
