//! Persistence for authorization policies and decision records.

const std = @import("std");
const zent = @import("zent");
const crud = zent.crud_helpers;
const model = @import("model.zig");
const schema = @import("../../schema.zig");

const graph = zent.codegen.graph.buildGraph(&.{ model.Policy, model.AuthzDecision });
pub const infos = graph.types;
pub const Client = schema.Client;
pub const PolicyInfo = infos[0];
pub const DecisionInfo = infos[1];

pub const PolicyRow = struct {
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

    pub fn free(self: PolicyRow, a: std.mem.Allocator) void {
        a.free(self.name);
        a.free(self.effect);
        a.free(self.subject);
        a.free(self.resource);
        a.free(self.action);
        a.free(self.condition);
    }
};

/// Partial update for a policy; null fields are left untouched.
pub const PolicyPatch = struct {
    name: ?[]const u8 = null,
    effect: ?[]const u8 = null,
    subject: ?[]const u8 = null,
    resource: ?[]const u8 = null,
    action: ?[]const u8 = null,
    condition: ?[]const u8 = null,
    priority: ?i64 = null,
    enabled: ?bool = null,
};

pub const DecisionRow = struct {
    id: i64,
    tenant_id: i64,
    subject_id: i64,
    resource: []const u8,
    action: []const u8,
    decision: []const u8,
    source: []const u8,
    policy_id: i64,
    created_at: i64,

    pub fn free(self: DecisionRow, a: std.mem.Allocator) void {
        a.free(self.resource);
        a.free(self.action);
        a.free(self.decision);
        a.free(self.source);
    }
};

pub const AuthzStore = struct {
    allocator: std.mem.Allocator,
    client: Client,

    pub fn init(allocator: std.mem.Allocator, client: Client) AuthzStore {
        return .{ .allocator = allocator, .client = client };
    }

    fn dupPolicy(self: *AuthzStore, e: anytype) !PolicyRow {
        return .{
            .id = e.id,
            .tenant_id = e.tenant_id,
            .name = try self.allocator.dupe(u8, e.name),
            .effect = try self.allocator.dupe(u8, e.effect),
            .subject = try self.allocator.dupe(u8, e.subject),
            .resource = try self.allocator.dupe(u8, e.resource),
            .action = try self.allocator.dupe(u8, e.action),
            .condition = try self.allocator.dupe(u8, e.condition),
            .priority = e.priority,
            .enabled = e.enabled,
        };
    }

    pub fn createPolicy(
        self: *AuthzStore,
        tenant_id: i64,
        name: []const u8,
        effect: []const u8,
        subject: []const u8,
        resource: []const u8,
        action: []const u8,
        condition: []const u8,
        priority: i64,
        enabled: bool,
        now: i64,
    ) !i64 {
        var b = try self.client.policy.Create();
        defer b.deinit();
        _ = try b.setFieldValue("tenant_id", tenant_id);
        _ = try b.setFieldValue("name", name);
        _ = try b.setFieldValue("effect", effect);
        _ = try b.setFieldValue("subject", subject);
        _ = try b.setFieldValue("resource", resource);
        _ = try b.setFieldValue("action", action);
        _ = try b.setFieldValue("condition", condition);
        _ = try b.setFieldValue("priority", priority);
        _ = try b.setFieldValue("enabled", enabled);
        _ = try b.setFieldValue("created_at", now);
        _ = try b.setFieldValue("updated_at", now);
        var row = try b.Save();
        defer zent.codegen.deinitEntity(infos, PolicyInfo, &row, self.allocator);
        return row.id;
    }

    pub fn updatePolicy(self: *AuthzStore, id: i64, patch: PolicyPatch, now: i64) !bool {
        const preds = self.client.policy.predicates;
        var e = (try crud.get(self.client.policy, id)) orelse return false;
        defer zent.codegen.deinitEntity(infos, PolicyInfo, &e, self.allocator);
        var u = self.client.policy.Update();
        defer u.deinit();
        if (patch.name) |v| _ = try u.setFieldValue("name", v);
        if (patch.effect) |v| _ = try u.setFieldValue("effect", v);
        if (patch.subject) |v| _ = try u.setFieldValue("subject", v);
        if (patch.resource) |v| _ = try u.setFieldValue("resource", v);
        if (patch.action) |v| _ = try u.setFieldValue("action", v);
        if (patch.condition) |v| _ = try u.setFieldValue("condition", v);
        if (patch.priority) |v| _ = try u.setFieldValue("priority", v);
        if (patch.enabled) |v| _ = try u.setFieldValue("enabled", v);
        _ = try u.setFieldValue("updated_at", now);
        _ = try u.Where(.{preds.idEQ(.{ .int = id })});
        _ = try u.Save();
        return true;
    }

    fn collect(self: *AuthzStore, rows: anytype) ![]PolicyRow {
        var out = try self.allocator.alloc(PolicyRow, rows.items.len);
        var i: usize = 0;
        errdefer {
            for (out[0..i]) |p| p.free(self.allocator);
            self.allocator.free(out);
        }
        for (rows.items) |e| {
            out[i] = try self.dupPolicy(e);
            i += 1;
        }
        std.mem.sort(PolicyRow, out, {}, struct {
            fn lt(_: void, a: PolicyRow, b: PolicyRow) bool {
                return a.priority > b.priority;
            }
        }.lt);
        return out;
    }

    pub fn listEnabledPolicies(self: *AuthzStore) ![]PolicyRow {
        const preds = self.client.policy.predicates;
        const rows = try crud.all(self.client.policy, .{preds.enabledEQ(.{ .bool = true })});
        defer zent.crud_helpers.deinitRows(infos, PolicyInfo, rows, self.allocator);
        return self.collect(rows);
    }

    pub fn listPolicies(self: *AuthzStore) ![]PolicyRow {
        const rows = try crud.all(self.client.policy, .{});
        defer zent.crud_helpers.deinitRows(infos, PolicyInfo, rows, self.allocator);
        return self.collect(rows);
    }

    pub fn deletePolicy(self: *AuthzStore, id: i64) !bool {
        const preds = self.client.policy.predicates;
        var d = self.client.policy.Delete();
        defer d.deinit();
        _ = try d.Where(.{preds.idEQ(.{ .int = id })});
        return (try d.Exec()) > 0;
    }

    // ---- Decision log ----

    pub fn recordDecision(
        self: *AuthzStore,
        tenant_id: i64,
        subject_id: i64,
        resource: []const u8,
        action: []const u8,
        decision: []const u8,
        source: []const u8,
        policy_id: i64,
        now: i64,
    ) !void {
        var b = try self.client.authz_decision.Create();
        defer b.deinit();
        _ = try b.setFieldValue("tenant_id", tenant_id);
        _ = try b.setFieldValue("subject_id", subject_id);
        _ = try b.setFieldValue("resource", resource);
        _ = try b.setFieldValue("action", action);
        _ = try b.setFieldValue("decision", decision);
        _ = try b.setFieldValue("source", source);
        _ = try b.setFieldValue("policy_id", policy_id);
        _ = try b.setFieldValue("created_at", now);
        _ = try b.setFieldValue("updated_at", now);
        var row = try b.Save();
        defer zent.codegen.deinitEntity(infos, DecisionInfo, &row, self.allocator);
    }

    /// Most recent decisions first, capped at the given limit.
    pub fn listDecisions(self: *AuthzStore, limit: usize) ![]DecisionRow {
        const rows = try crud.all(self.client.authz_decision, .{});
        defer zent.crud_helpers.deinitRows(infos, DecisionInfo, rows, self.allocator);
        var out = try self.allocator.alloc(DecisionRow, rows.items.len);
        var i: usize = 0;
        errdefer {
            for (out[0..i]) |d| d.free(self.allocator);
            self.allocator.free(out);
        }
        for (rows.items) |e| {
            out[i] = .{
                .id = e.id,
                .tenant_id = e.tenant_id,
                .subject_id = e.subject_id,
                .resource = try self.allocator.dupe(u8, e.resource),
                .action = try self.allocator.dupe(u8, e.action),
                .decision = try self.allocator.dupe(u8, e.decision),
                .source = try self.allocator.dupe(u8, e.source),
                .policy_id = e.policy_id,
                .created_at = @as(?i64, e.created_at) orelse 0,
            };
            i += 1;
        }
        std.mem.sort(DecisionRow, out, {}, struct {
            fn lt(_: void, a: DecisionRow, b: DecisionRow) bool {
                return a.id > b.id;
            }
        }.lt);
        if (out.len <= limit) return out;
        const truncated = try self.allocator.alloc(DecisionRow, limit);
        @memcpy(truncated, out[0..limit]);
        for (out[limit..]) |d| d.free(self.allocator);
        self.allocator.free(out);
        return truncated;
    }

    pub fn purgeDecisionsBefore(self: *AuthzStore, cutoff: i64) !usize {
        const preds = self.client.authz_decision.predicates;
        var d = self.client.authz_decision.Delete();
        defer d.deinit();
        _ = try d.Where(.{preds.created_atLT(.{ .int = cutoff })});
        return try d.Exec();
    }
};
