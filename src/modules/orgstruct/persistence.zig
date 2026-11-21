//! Persistence over the shared zent Client for the orgstruct domain.
//!
//! Results are duped into plain row DTOs (like the iam/user stores) so the
//! zent entity lifecycle never leaks past this boundary. Every lookup that
//! takes a tenant scope returns null when the row belongs to another tenant.

const std = @import("std");
const zent = @import("zent");
const crud = zent.crud_helpers;
const model = @import("model.zig");
const schema = @import("../../schema.zig");

const graph = zent.codegen.graph.buildGraph(&.{
    model.Instance,
    model.Group,
    model.GroupMember,
    model.Domain,
});
pub const infos = graph.types;

/// Shared, application-wide typed client (all schemas registered in schema.zig).
pub const Client = schema.Client;

pub const InstanceInfo = infos[0];
pub const GroupInfo = infos[1];
pub const GroupMemberInfo = infos[2];
pub const DomainInfo = infos[3];

// ── Row DTOs ────────────────────────────────────────────────────────

pub const InstanceRow = struct {
    id: i64,
    tenant_id: i64,
    name: []const u8,
    display_name: []const u8,
    global_domain: []const u8,
    active: bool,
    config_json: []const u8,
    signing_key_ref: []const u8,
    created_at: i64,
    updated_at: i64,

    pub fn free(self: InstanceRow, a: std.mem.Allocator) void {
        a.free(self.name);
        a.free(self.display_name);
        a.free(self.global_domain);
        a.free(self.config_json);
        a.free(self.signing_key_ref);
    }
};

pub const GroupRow = struct {
    id: i64,
    tenant_id: i64,
    org_id: i64,
    name: []const u8,
    description: []const u8,
    active: bool,
    created_at: i64,
    updated_at: i64,

    pub fn free(self: GroupRow, a: std.mem.Allocator) void {
        a.free(self.name);
        a.free(self.description);
    }
};

pub const GroupMemberRow = struct {
    id: i64,
    tenant_id: i64,
    org_id: i64,
    group_id: i64,
    user_id: i64,
    created_at: i64,
    updated_at: i64,
};

pub const DomainRow = struct {
    id: i64,
    tenant_id: i64,
    org_id: i64,
    name: []const u8,
    verified: bool,
    verification_token_hash: []const u8,
    verified_at: i64,
    created_at: i64,
    updated_at: i64,

    pub fn free(self: DomainRow, a: std.mem.Allocator) void {
        a.free(self.name);
        a.free(self.verification_token_hash);
    }
};

pub const InstanceListResult = struct {
    items: []InstanceRow,
    total: i64,
    pub fn free(self: *InstanceListResult, a: std.mem.Allocator) void {
        for (self.items) |r| r.free(a);
        a.free(self.items);
    }
};

pub const GroupListResult = struct {
    items: []GroupRow,
    total: i64,
    pub fn free(self: *GroupListResult, a: std.mem.Allocator) void {
        for (self.items) |r| r.free(a);
        a.free(self.items);
    }
};

pub const GroupMemberListResult = struct {
    items: []GroupMemberRow,
    total: i64,
    pub fn free(self: *GroupMemberListResult, a: std.mem.Allocator) void {
        a.free(self.items);
    }
};

pub const DomainListResult = struct {
    items: []DomainRow,
    total: i64,
    pub fn free(self: *DomainListResult, a: std.mem.Allocator) void {
        for (self.items) |r| r.free(a);
        a.free(self.items);
    }
};

// ── Store ───────────────────────────────────────────────────────────

pub const OrgStructStore = struct {
    allocator: std.mem.Allocator,
    client: Client,

    pub fn init(allocator: std.mem.Allocator, client: Client) OrgStructStore {
        return .{ .allocator = allocator, .client = client };
    }

    fn ts(e: anytype) i64 {
        return @as(?i64, e) orelse 0;
    }

    // ── Instance ──────────────────────────────────────────────

    fn dupInstance(self: *OrgStructStore, e: anytype) !InstanceRow {
        return .{
            .id = e.id,
            .tenant_id = e.tenant_id,
            .name = try self.allocator.dupe(u8, e.name),
            .display_name = try self.allocator.dupe(u8, e.display_name),
            .global_domain = try self.allocator.dupe(u8, e.global_domain),
            .active = e.active,
            .config_json = try self.allocator.dupe(u8, e.config_json),
            .signing_key_ref = try self.allocator.dupe(u8, e.signing_key_ref),
            .created_at = ts(e.created_at),
            .updated_at = ts(e.updated_at),
        };
    }

    pub fn createInstance(
        self: *OrgStructStore,
        tenant_id: i64,
        name: []const u8,
        display_name: []const u8,
        global_domain: []const u8,
        config_json: []const u8,
        signing_key_ref: []const u8,
        now: i64,
    ) !i64 {
        var b = try self.client.instance.Create();
        defer b.deinit();
        _ = try b.setFieldValue("tenant_id", tenant_id);
        _ = try b.setFieldValue("name", name);
        _ = try b.setFieldValue("display_name", display_name);
        _ = try b.setFieldValue("global_domain", global_domain);
        _ = try b.setFieldValue("active", true);
        _ = try b.setFieldValue("config_json", config_json);
        _ = try b.setFieldValue("signing_key_ref", signing_key_ref);
        _ = try b.setFieldValue("created_at", now);
        _ = try b.setFieldValue("updated_at", now);
        var row = try b.Save();
        defer zent.codegen.deinitEntity(infos, InstanceInfo, &row, self.allocator);
        return row.id;
    }

    pub fn getInstanceForTenant(self: *OrgStructStore, id: i64, tenant_id: i64) !?InstanceRow {
        const preds = self.client.instance.predicates;
        const id_q = preds.idEQ(.{ .int = id });
        const tenant_q = preds.tenant_idEQ(.{ .int = tenant_id });
        var e = (try crud.first(self.client.instance, .{zent.sql.And(&id_q, &tenant_q)})) orelse return null;
        defer zent.codegen.deinitEntity(infos, InstanceInfo, &e, self.allocator);
        return try self.dupInstance(e);
    }

    pub fn getInstance(self: *OrgStructStore, id: i64) !?InstanceRow {
        var e = (try crud.get(self.client.instance, id)) orelse return null;
        defer zent.codegen.deinitEntity(infos, InstanceInfo, &e, self.allocator);
        return try self.dupInstance(e);
    }

    pub fn listInstances(self: *OrgStructStore, page: usize, page_size: usize, tenant_id: ?i64) !InstanceListResult {
        const preds = self.client.instance.predicates;
        var preds_buf: [1]zent.sql.Predicate = undefined;
        var n: usize = 0;
        if (tenant_id) |tid| {
            preds_buf[0] = preds.tenant_idEQ(.{ .int = tid });
            n = 1;
        }
        var result = try crud.paginatedWithOptions(self.client.instance, preds_buf[0..n], .{ .sort_col = "id" }, page, page_size);
        defer result.deinit(infos, InstanceInfo, self.allocator);
        var out = try self.allocator.alloc(InstanceRow, result.items.items.len);
        var i: usize = 0;
        errdefer {
            for (out[0..i]) |r| r.free(self.allocator);
            self.allocator.free(out);
        }
        for (result.items.items) |e| {
            out[i] = try self.dupInstance(e);
            i += 1;
        }
        return .{ .items = out, .total = result.total };
    }

    pub fn updateInstance(
        self: *OrgStructStore,
        id: i64,
        tenant_id: i64,
        display_name: []const u8,
        global_domain: []const u8,
        config_json: []const u8,
        signing_key_ref: []const u8,
        active: bool,
        now: i64,
    ) !bool {
        const preds = self.client.instance.predicates;
        const id_q = preds.idEQ(.{ .int = id });
        const tenant_q = preds.tenant_idEQ(.{ .int = tenant_id });
        var u = self.client.instance.Update();
        defer u.deinit();
        _ = try u.setFieldValue("display_name", display_name);
        _ = try u.setFieldValue("global_domain", global_domain);
        _ = try u.setFieldValue("config_json", config_json);
        _ = try u.setFieldValue("signing_key_ref", signing_key_ref);
        _ = try u.setFieldValue("active", active);
        _ = try u.setFieldValue("updated_at", now);
        _ = try u.Where(.{zent.sql.And(&id_q, &tenant_q)});
        const affected = try u.Save();
        return affected > 0;
    }

    pub fn deleteInstance(self: *OrgStructStore, id: i64, tenant_id: i64) !void {
        const preds = self.client.instance.predicates;
        const id_q = preds.idEQ(.{ .int = id });
        const tenant_q = preds.tenant_idEQ(.{ .int = tenant_id });
        var d = self.client.instance.Delete();
        defer d.deinit();
        _ = try d.Where(.{zent.sql.And(&id_q, &tenant_q)});
        _ = try d.Exec();
    }

    // ── Group ─────────────────────────────────────────────────

    fn dupGroup(self: *OrgStructStore, e: anytype) !GroupRow {
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

    pub fn createGroup(self: *OrgStructStore, tenant_id: i64, org_id: i64, name: []const u8, description: []const u8, now: i64) !i64 {
        var b = try self.client.group.Create();
        defer b.deinit();
        _ = try b.setFieldValue("tenant_id", tenant_id);
        _ = try b.setFieldValue("org_id", org_id);
        _ = try b.setFieldValue("name", name);
        _ = try b.setFieldValue("description", description);
        _ = try b.setFieldValue("active", true);
        _ = try b.setFieldValue("created_at", now);
        _ = try b.setFieldValue("updated_at", now);
        var row = try b.Save();
        defer zent.codegen.deinitEntity(infos, GroupInfo, &row, self.allocator);
        return row.id;
    }

    pub fn getGroupForTenant(self: *OrgStructStore, id: i64, tenant_id: i64) !?GroupRow {
        const preds = self.client.group.predicates;
        const id_q = preds.idEQ(.{ .int = id });
        const tenant_q = preds.tenant_idEQ(.{ .int = tenant_id });
        var e = (try crud.first(self.client.group, .{zent.sql.And(&id_q, &tenant_q)})) orelse return null;
        defer zent.codegen.deinitEntity(infos, GroupInfo, &e, self.allocator);
        return try self.dupGroup(e);
    }

    pub fn getGroup(self: *OrgStructStore, id: i64) !?GroupRow {
        var e = (try crud.get(self.client.group, id)) orelse return null;
        defer zent.codegen.deinitEntity(infos, GroupInfo, &e, self.allocator);
        return try self.dupGroup(e);
    }

    pub fn listGroups(self: *OrgStructStore, page: usize, page_size: usize, tenant_id: ?i64, org_id: ?i64) !GroupListResult {
        const preds = self.client.group.predicates;
        var preds_buf: [2]zent.sql.Predicate = undefined;
        var n: usize = 0;
        if (tenant_id) |tid| {
            preds_buf[n] = preds.tenant_idEQ(.{ .int = tid });
            n += 1;
        }
        if (org_id) |oid| {
            preds_buf[n] = preds.org_idEQ(.{ .int = oid });
            n += 1;
        }
        var result = try crud.paginatedWithOptions(self.client.group, preds_buf[0..n], .{ .sort_col = "id" }, page, page_size);
        defer result.deinit(infos, GroupInfo, self.allocator);
        var out = try self.allocator.alloc(GroupRow, result.items.items.len);
        var i: usize = 0;
        errdefer {
            for (out[0..i]) |r| r.free(self.allocator);
            self.allocator.free(out);
        }
        for (result.items.items) |e| {
            out[i] = try self.dupGroup(e);
            i += 1;
        }
        return .{ .items = out, .total = result.total };
    }

    pub fn updateGroup(
        self: *OrgStructStore,
        id: i64,
        tenant_id: i64,
        name: []const u8,
        description: []const u8,
        active: bool,
        now: i64,
    ) !bool {
        const preds = self.client.group.predicates;
        const id_q = preds.idEQ(.{ .int = id });
        const tenant_q = preds.tenant_idEQ(.{ .int = tenant_id });
        var u = self.client.group.Update();
        defer u.deinit();
        _ = try u.setFieldValue("name", name);
        _ = try u.setFieldValue("description", description);
        _ = try u.setFieldValue("active", active);
        _ = try u.setFieldValue("updated_at", now);
        _ = try u.Where(.{zent.sql.And(&id_q, &tenant_q)});
        const affected = try u.Save();
        return affected > 0;
    }

    pub fn deleteGroup(self: *OrgStructStore, id: i64, tenant_id: i64) !void {
        const preds = self.client.group.predicates;
        const id_q = preds.idEQ(.{ .int = id });
        const tenant_q = preds.tenant_idEQ(.{ .int = tenant_id });
        var d = self.client.group.Delete();
        defer d.deinit();
        _ = try d.Where(.{zent.sql.And(&id_q, &tenant_q)});
        _ = try d.Exec();
        // Remove membership edges belonging to this group.
        const mpreds = self.client.group_member.predicates;
        const g_q = mpreds.group_idEQ(.{ .int = id });
        var md = self.client.group_member.Delete();
        defer md.deinit();
        _ = try md.Where(.{g_q});
        _ = try md.Exec();
    }

    // ── GroupMember ───────────────────────────────────────────

    fn dupGroupMember(self: *OrgStructStore, e: anytype) GroupMemberRow {
        _ = self;
        return .{
            .id = e.id,
            .tenant_id = e.tenant_id,
            .org_id = e.org_id,
            .group_id = e.group_id,
            .user_id = e.user_id,
            .created_at = ts(e.created_at),
            .updated_at = ts(e.updated_at),
        };
    }

    pub fn addGroupMember(
        self: *OrgStructStore,
        tenant_id: i64,
        org_id: i64,
        group_id: i64,
        user_id: i64,
        now: i64,
    ) !i64 {
        // Avoid duplicate edges.
        const existing = try self.findGroupMember(tenant_id, group_id, user_id);
        if (existing) |id| return id;

        var b = try self.client.group_member.Create();
        defer b.deinit();
        _ = try b.setFieldValue("tenant_id", tenant_id);
        _ = try b.setFieldValue("org_id", org_id);
        _ = try b.setFieldValue("group_id", group_id);
        _ = try b.setFieldValue("user_id", user_id);
        _ = try b.setFieldValue("created_at", now);
        _ = try b.setFieldValue("updated_at", now);
        var row = try b.Save();
        defer zent.codegen.deinitEntity(infos, GroupMemberInfo, &row, self.allocator);
        return row.id;
    }

    pub fn findGroupMember(self: *OrgStructStore, tenant_id: i64, group_id: i64, user_id: i64) !?i64 {
        const preds = self.client.group_member.predicates;
        const tenant_q = preds.tenant_idEQ(.{ .int = tenant_id });
        const group_q = preds.group_idEQ(.{ .int = group_id });
        const user_q = preds.user_idEQ(.{ .int = user_id });
        const and1 = zent.sql.And(&tenant_q, &group_q);
        const and2 = zent.sql.And(&and1, &user_q);
        var e = (try crud.first(self.client.group_member, .{and2})) orelse return null;
        defer zent.codegen.deinitEntity(infos, GroupMemberInfo, &e, self.allocator);
        return e.id;
    }

    pub fn listGroupMembers(self: *OrgStructStore, tenant_id: i64, group_id: i64) !GroupMemberListResult {
        const preds = self.client.group_member.predicates;
        const tenant_q = preds.tenant_idEQ(.{ .int = tenant_id });
        const group_q = preds.group_idEQ(.{ .int = group_id });
        const rows = try crud.all(self.client.group_member, .{zent.sql.And(&tenant_q, &group_q)});
        defer zent.crud_helpers.deinitRows(infos, GroupMemberInfo, rows, self.allocator);
        var out = try self.allocator.alloc(GroupMemberRow, rows.items.len);
        for (rows.items, 0..) |e, i| out[i] = self.dupGroupMember(e);
        return .{ .items = out, .total = @intCast(out.len) };
    }

    pub fn removeGroupMember(self: *OrgStructStore, tenant_id: i64, group_id: i64, user_id: i64) !void {
        const preds = self.client.group_member.predicates;
        const tenant_q = preds.tenant_idEQ(.{ .int = tenant_id });
        const group_q = preds.group_idEQ(.{ .int = group_id });
        const user_q = preds.user_idEQ(.{ .int = user_id });
        const and1 = zent.sql.And(&tenant_q, &group_q);
        const and2 = zent.sql.And(&and1, &user_q);
        var d = self.client.group_member.Delete();
        defer d.deinit();
        _ = try d.Where(.{and2});
        _ = try d.Exec();
    }

    // ── Domain ────────────────────────────────────────────────

    fn dupDomain(self: *OrgStructStore, e: anytype) !DomainRow {
        return .{
            .id = e.id,
            .tenant_id = e.tenant_id,
            .org_id = e.org_id,
            .name = try self.allocator.dupe(u8, e.name),
            .verified = e.verified,
            .verification_token_hash = try self.allocator.dupe(u8, e.verification_token_hash),
            .verified_at = e.verified_at,
            .created_at = ts(e.created_at),
            .updated_at = ts(e.updated_at),
        };
    }

    pub fn createDomain(
        self: *OrgStructStore,
        tenant_id: i64,
        org_id: i64,
        name: []const u8,
        token_hash: []const u8,
        now: i64,
    ) !i64 {
        var b = try self.client.domain.Create();
        defer b.deinit();
        _ = try b.setFieldValue("tenant_id", tenant_id);
        _ = try b.setFieldValue("org_id", org_id);
        _ = try b.setFieldValue("name", name);
        _ = try b.setFieldValue("verified", false);
        _ = try b.setFieldValue("verification_token_hash", token_hash);
        _ = try b.setFieldValue("verified_at", 0);
        _ = try b.setFieldValue("created_at", now);
        _ = try b.setFieldValue("updated_at", now);
        var row = try b.Save();
        defer zent.codegen.deinitEntity(infos, DomainInfo, &row, self.allocator);
        return row.id;
    }

    pub fn getDomainForTenant(self: *OrgStructStore, id: i64, tenant_id: i64) !?DomainRow {
        const preds = self.client.domain.predicates;
        const id_q = preds.idEQ(.{ .int = id });
        const tenant_q = preds.tenant_idEQ(.{ .int = tenant_id });
        var e = (try crud.first(self.client.domain, .{zent.sql.And(&id_q, &tenant_q)})) orelse return null;
        defer zent.codegen.deinitEntity(infos, DomainInfo, &e, self.allocator);
        return try self.dupDomain(e);
    }

    pub fn getDomain(self: *OrgStructStore, id: i64) !?DomainRow {
        var e = (try crud.get(self.client.domain, id)) orelse return null;
        defer zent.codegen.deinitEntity(infos, DomainInfo, &e, self.allocator);
        return try self.dupDomain(e);
    }

    pub fn listDomains(self: *OrgStructStore, page: usize, page_size: usize, tenant_id: ?i64, org_id: ?i64) !DomainListResult {
        const preds = self.client.domain.predicates;
        var preds_buf: [2]zent.sql.Predicate = undefined;
        var n: usize = 0;
        if (tenant_id) |tid| {
            preds_buf[n] = preds.tenant_idEQ(.{ .int = tid });
            n += 1;
        }
        if (org_id) |oid| {
            preds_buf[n] = preds.org_idEQ(.{ .int = oid });
            n += 1;
        }
        var result = try crud.paginatedWithOptions(self.client.domain, preds_buf[0..n], .{ .sort_col = "id" }, page, page_size);
        defer result.deinit(infos, DomainInfo, self.allocator);
        var out = try self.allocator.alloc(DomainRow, result.items.items.len);
        var i: usize = 0;
        errdefer {
            for (out[0..i]) |r| r.free(self.allocator);
            self.allocator.free(out);
        }
        for (result.items.items) |e| {
            out[i] = try self.dupDomain(e);
            i += 1;
        }
        return .{ .items = out, .total = result.total };
    }

    /// Mark a domain verified. Only called after the service layer has matched
    /// the presented token to the stored hash.
    pub fn markDomainVerified(self: *OrgStructStore, id: i64, tenant_id: i64, now: i64) !bool {
        const preds = self.client.domain.predicates;
        const id_q = preds.idEQ(.{ .int = id });
        const tenant_q = preds.tenant_idEQ(.{ .int = tenant_id });
        var u = self.client.domain.Update();
        defer u.deinit();
        _ = try u.setFieldValue("verified", true);
        _ = try u.setFieldValue("verified_at", now);
        _ = try u.setFieldValue("updated_at", now);
        _ = try u.Where(.{zent.sql.And(&id_q, &tenant_q)});
        const affected = try u.Save();
        return affected > 0;
    }

    pub fn deleteDomain(self: *OrgStructStore, id: i64, tenant_id: i64) !void {
        const preds = self.client.domain.predicates;
        const id_q = preds.idEQ(.{ .int = id });
        const tenant_q = preds.tenant_idEQ(.{ .int = tenant_id });
        var d = self.client.domain.Delete();
        defer d.deinit();
        _ = try d.Where(.{zent.sql.And(&id_q, &tenant_q)});
        _ = try d.Exec();
    }
};
