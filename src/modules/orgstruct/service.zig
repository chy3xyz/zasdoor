//! Service layer for orgstruct: validation, verification-token hashing and
//! matching, and group membership lifecycle. No HTTP/SQL leakage.
//!
//! Verification tokens are never stored in plaintext. `createDomain` hashes the
//! supplied challenge with the shared AppSecurity password hasher; a domain is
//! marked verified only when `verifyDomain` successfully matches the presented
//! token to that stored hash (see dev.md domain model).

const std = @import("std");
const zmodu = @import("zmodu");
const persist = @import("persistence.zig");

pub const InstanceRow = persist.InstanceRow;
pub const GroupRow = persist.GroupRow;
pub const GroupMemberRow = persist.GroupMemberRow;
pub const DomainRow = persist.DomainRow;
pub const InstanceListResult = persist.InstanceListResult;
pub const GroupListResult = persist.GroupListResult;
pub const GroupMemberListResult = persist.GroupMemberListResult;
pub const DomainListResult = persist.DomainListResult;

pub const OrgStructError = error{
    InvalidName,
    InvalidDomain,
    InstanceNotFound,
    GroupNotFound,
    DomainNotFound,
    DomainAlreadyVerified,
    InvalidVerificationToken,
    OutOfMemory,
    Unexpected,
};

/// A freshly-created domain verification challenge. `token` is the plaintext
/// shown exactly once (DNS TXT value / email); only its hash is persisted.
pub const DomainVerification = struct {
    domain_id: i64,
    token: []const u8,

    pub fn deinit(self: DomainVerification, a: std.mem.Allocator) void {
        a.free(self.token);
    }
};

pub const OrgStructService = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *persist.OrgStructStore,
    sec: *zmodu.security.AppSecurity,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, store: *persist.OrgStructStore, sec: *zmodu.security.AppSecurity) OrgStructService {
        return .{ .allocator = allocator, .io = io, .store = store, .sec = sec };
    }

    fn now(self: *OrgStructService) i64 {
        return zmodu.time.wallClockSeconds(self.io);
    }

    /// Generate a cryptographically-random base64url string of `n` bytes.
    pub fn randomToken(self: *OrgStructService, n: usize) ![]const u8 {
        const buf = try self.allocator.alloc(u8, n);
        defer self.allocator.free(buf);
        var file = try std.Io.Dir.cwd().openFile(self.io, "/dev/urandom", .{});
        defer file.close(self.io);
        const read = try file.readPositionalAll(self.io, buf, 0);
        if (read != buf.len) return error.Unexpected;
        const enc = std.base64.url_safe_no_pad.Encoder;
        const out = try self.allocator.alloc(u8, enc.calcSize(n));
        errdefer self.allocator.free(out);
        _ = enc.encode(out, buf);
        return out;
    }

    // ── Instance ─────────────────────────────────────────────

    pub fn createInstance(
        self: *OrgStructService,
        tenant_id: i64,
        name: []const u8,
        display_name: []const u8,
        global_domain: []const u8,
        config_json: []const u8,
        signing_key_ref: []const u8,
    ) OrgStructError!i64 {
        if (std.mem.trim(u8, name, " \t").len == 0) return error.InvalidName;
        return self.store.createInstance(tenant_id, name, display_name, global_domain, config_json, signing_key_ref, self.now()) catch return error.Unexpected;
    }

    pub fn getInstance(self: *OrgStructService, id: i64) !?InstanceRow {
        return self.store.getInstance(id);
    }

    pub fn getInstanceForTenant(self: *OrgStructService, id: i64, tenant_id: i64) !?InstanceRow {
        return self.store.getInstanceForTenant(id, tenant_id);
    }

    pub fn listInstances(self: *OrgStructService, page: usize, page_size: usize, tenant_id: ?i64) !InstanceListResult {
        return self.store.listInstances(page, page_size, tenant_id);
    }

    pub fn updateInstance(
        self: *OrgStructService,
        id: i64,
        tenant_id: i64,
        display_name: []const u8,
        global_domain: []const u8,
        config_json: []const u8,
        signing_key_ref: []const u8,
        active: bool,
    ) OrgStructError!bool {
        const ok = self.store.updateInstance(id, tenant_id, display_name, global_domain, config_json, signing_key_ref, active, self.now()) catch return error.Unexpected;
        if (!ok) return error.InstanceNotFound;
        return true;
    }

    pub fn deleteInstance(self: *OrgStructService, id: i64, tenant_id: i64) OrgStructError!void {
        self.store.deleteInstance(id, tenant_id) catch return error.Unexpected;
    }

    // ── Group ────────────────────────────────────────────────

    pub fn createGroup(self: *OrgStructService, tenant_id: i64, org_id: i64, name: []const u8, description: []const u8) OrgStructError!i64 {
        const trimmed = std.mem.trim(u8, name, " \t");
        if (trimmed.len == 0) return error.InvalidName;
        return self.store.createGroup(tenant_id, org_id, trimmed, description, self.now()) catch return error.Unexpected;
    }

    pub fn getGroup(self: *OrgStructService, id: i64) !?GroupRow {
        return self.store.getGroup(id);
    }

    pub fn getGroupForTenant(self: *OrgStructService, id: i64, tenant_id: i64) !?GroupRow {
        return self.store.getGroupForTenant(id, tenant_id);
    }

    pub fn listGroups(self: *OrgStructService, page: usize, page_size: usize, tenant_id: ?i64, org_id: ?i64) !GroupListResult {
        return self.store.listGroups(page, page_size, tenant_id, org_id);
    }

    pub fn updateGroup(
        self: *OrgStructService,
        id: i64,
        tenant_id: i64,
        name: []const u8,
        description: []const u8,
        active: bool,
    ) OrgStructError!bool {
        if (std.mem.trim(u8, name, " \t").len == 0) return error.InvalidName;
        const ok = self.store.updateGroup(id, tenant_id, name, description, active, self.now()) catch return error.Unexpected;
        if (!ok) return error.GroupNotFound;
        return true;
    }

    pub fn deleteGroup(self: *OrgStructService, id: i64, tenant_id: i64) OrgStructError!void {
        self.store.deleteGroup(id, tenant_id) catch return error.Unexpected;
    }

    // ── Group membership ─────────────────────────────────────

    /// Add a user to a group. The group must exist in the caller's tenant so a
    /// guessed group id cannot create a cross-tenant membership edge.
    pub fn addGroupMember(
        self: *OrgStructService,
        tenant_id: i64,
        group_id: i64,
        user_id: i64,
    ) OrgStructError!i64 {
        const group_opt = self.store.getGroupForTenant(group_id, tenant_id) catch return error.Unexpected;
        const group = group_opt orelse return error.GroupNotFound;
        defer group.free(self.allocator);
        return self.store.addGroupMember(tenant_id, group.org_id, group_id, user_id, self.now()) catch return error.Unexpected;
    }

    pub fn listGroupMembers(self: *OrgStructService, tenant_id: i64, group_id: i64) !GroupMemberListResult {
        return self.store.listGroupMembers(tenant_id, group_id);
    }

    pub fn removeGroupMember(self: *OrgStructService, tenant_id: i64, group_id: i64, user_id: i64) OrgStructError!void {
        self.store.removeGroupMember(tenant_id, group_id, user_id) catch return error.Unexpected;
    }

    // ── Domain ───────────────────────────────────────────────

    /// Create a domain with a freshly generated verification token. The plaintext
    /// token is returned exactly once; only its hash is stored.
    pub fn createDomain(
        self: *OrgStructService,
        tenant_id: i64,
        org_id: i64,
        name: []const u8,
    ) OrgStructError!DomainVerification {
        const trimmed = std.mem.trim(u8, name, " \t");
        if (trimmed.len == 0 or std.mem.indexOfScalar(u8, trimmed, ' ') != null) return error.InvalidDomain;

        const token = self.randomToken(24) catch return error.Unexpected;
        errdefer self.allocator.free(token);
        const hash = self.sec.module.hashPassword(token) catch return error.Unexpected;
        defer self.sec.module.allocator.free(hash);

        const id = self.store.createDomain(tenant_id, org_id, trimmed, hash, self.now()) catch return error.Unexpected;
        return .{ .domain_id = id, .token = token };
    }

    pub fn getDomain(self: *OrgStructService, id: i64) !?DomainRow {
        return self.store.getDomain(id);
    }

    pub fn getDomainForTenant(self: *OrgStructService, id: i64, tenant_id: i64) !?DomainRow {
        return self.store.getDomainForTenant(id, tenant_id);
    }

    pub fn listDomains(self: *OrgStructService, page: usize, page_size: usize, tenant_id: ?i64, org_id: ?i64) !DomainListResult {
        return self.store.listDomains(page, page_size, tenant_id, org_id);
    }

    /// Verify a domain. `verified` and `verified_at` are written only when the
    /// presented token matches the stored hash. A mismatch, an already-verified
    /// domain, or a cross-tenant id never mutates the row.
    pub fn verifyDomain(self: *OrgStructService, id: i64, tenant_id: i64, token: []const u8) OrgStructError!DomainRow {
        const row_opt = self.store.getDomainForTenant(id, tenant_id) catch return error.Unexpected;
        const row = row_opt orelse return error.DomainNotFound;
        defer row.free(self.allocator);
        if (row.verified) return error.DomainAlreadyVerified;

        const matches = self.sec.module.verifyPassword(token, row.verification_token_hash) catch return error.Unexpected;
        if (!matches) return error.InvalidVerificationToken;

        const stamp = self.now();
        const ok = self.store.markDomainVerified(id, tenant_id, stamp) catch return error.Unexpected;
        if (!ok) return error.DomainNotFound;

        return .{
            .id = row.id,
            .tenant_id = row.tenant_id,
            .org_id = row.org_id,
            .name = try self.allocator.dupe(u8, row.name),
            .verified = true,
            .verification_token_hash = try self.allocator.dupe(u8, row.verification_token_hash),
            .verified_at = stamp,
            .created_at = row.created_at,
            .updated_at = stamp,
        };
    }

    pub fn deleteDomain(self: *OrgStructService, id: i64, tenant_id: i64) OrgStructError!void {
        self.store.deleteDomain(id, tenant_id) catch return error.Unexpected;
    }
};
