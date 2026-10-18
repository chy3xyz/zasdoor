//! Authorization kernel (dev.md section 10-12).
//!
//!     authorize(subject_id, resource, action, context) -> Decision
//!
//! Evaluation order:
//!   1. explicit enabled policies (deny-overrides): a matching deny wins;
//!      otherwise the first matching allow is returned;
//!   2. role permission set fallback (project/org-scoped role assignments);
//!   3. UNKNOWN when nothing applies (deny by default at the caller).
//!
//! Permission strings are "resource.action" and support "*" wildcards.
//! A policy may also carry a JSON condition on org_id/project_id/resource_id.

const std = @import("std");
const iam = @import("../iam/service.zig");
const persist = @import("persistence.zig");

pub const PolicyRow = persist.PolicyRow;
pub const PolicyPatch = persist.PolicyPatch;
pub const DecisionRow = persist.DecisionRow;
pub const AuthzStore = persist.AuthzStore;

pub const Decision = enum {
    allow,
    deny,
    unknown,
};

pub const DecisionSource = enum {
    none,
    role,
    policy,
};

pub const DecisionInfo = struct {
    decision: Decision,
    source: DecisionSource = .none,
    policy_id: ?i64 = null,
};

/// Context passed to authorize.
pub const AuthContext = struct {
    org_id: ?i64 = null,
    project_id: ?i64 = null,
    resource_id: ?i64 = null,
    /// Optional policy tenant filter; null evaluates policies from all tenants.
    tenant_id: ?i64 = null,
    /// Wall-clock seconds recorded with the decision log entry (0 in tests).
    now: i64 = 0,
};

/// A parsed permission: resource + action (with wildcard support).
const Permission = struct {
    resource: []const u8,
    action: []const u8,
};

fn hasPermissionHave(perm: []const u8, resource: []const u8, action: []const u8) bool {
    var it = std.mem.splitScalar(u8, perm, '.');
    const p_res = it.next() orelse return false;
    const p_act = it.next() orelse return std.mem.eql(u8, p_res, resource);
    const res_match = std.mem.eql(u8, p_res, resource) or std.mem.eql(u8, p_res, "*");
    const act_match = std.mem.eql(u8, p_act, action) or std.mem.eql(u8, p_act, "*");
    return res_match and act_match;
}

fn patternMatches(pattern: []const u8, value: []const u8) bool {
    return std.mem.eql(u8, pattern, "*") or std.mem.eql(u8, pattern, value);
}

pub const AuthzService = struct {
    allocator: std.mem.Allocator,
    iam_svc: *iam.IamService,
    /// Policy store; null keeps the legacy role-only behaviour (tests/tools).
    store: ?*AuthzStore = null,

    pub fn init(allocator: std.mem.Allocator, iam_svc: *iam.IamService) AuthzService {
        return .{ .allocator = allocator, .iam_svc = iam_svc };
    }

    pub fn initWithStore(allocator: std.mem.Allocator, iam_svc: *iam.IamService, store: *AuthzStore) AuthzService {
        return .{ .allocator = allocator, .iam_svc = iam_svc, .store = store };
    }

    pub fn policyStore(self: *AuthzService) ?*AuthzStore {
        return self.store;
    }

    fn subjectMatches(self: *AuthzService, subject: []const u8, subject_id: i64, role_ids: []const i64) bool {
        if (std.mem.eql(u8, subject, "*")) return true;
        if (std.mem.startsWith(u8, subject, "user:")) {
            const id = std.fmt.parseInt(i64, subject["user:".len..], 10) catch return false;
            return id == subject_id;
        }
        if (std.mem.startsWith(u8, subject, "role:")) {
            const key = subject["role:".len..];
            for (role_ids) |rid| {
                const role_opt = self.iam_svc.getRole(rid) catch continue;
                const role = role_opt orelse continue;
                defer role.free(self.iam_svc.allocator);
                if (std.mem.eql(u8, role.key, key)) return true;
            }
            return false;
        }
        return false;
    }

    /// Evaluate a policy condition JSON object against the request context.
    /// An empty condition always matches; unknown keys/values never match.
    fn conditionMatches(self: *AuthzService, condition: []const u8, context: AuthContext) bool {
        if (condition.len == 0) return true;
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, condition, .{}) catch return false;
        defer parsed.deinit();
        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return false,
        };
        var it = obj.iterator();
        while (it.next()) |entry| {
            const actual: ?i64 = if (std.mem.eql(u8, entry.key_ptr.*, "org_id"))
                context.org_id
            else if (std.mem.eql(u8, entry.key_ptr.*, "project_id"))
                context.project_id
            else if (std.mem.eql(u8, entry.key_ptr.*, "resource_id"))
                context.resource_id
            else
                return false;
            const want = switch (entry.value_ptr.*) {
                .integer => |i| i,
                else => return false,
            };
            if (actual == null or actual.? != want) return false;
        }
        return true;
    }

    /// Full decision with the source and (for policies) the matched policy id.
    pub fn authorizeDetailed(
        self: *AuthzService,
        subject_id: i64,
        resource: []const u8,
        action: []const u8,
        context: AuthContext,
    ) !DecisionInfo {
        const role_ids = try self.iam_svc.store.listRoleIdsForUser(subject_id, context.project_id);
        defer self.allocator.free(role_ids);

        var info: ?DecisionInfo = null;
        if (self.store) |store| {
            const policies = store.listEnabledPolicies() catch return error.Unexpected;
            defer {
                for (policies) |p| p.free(store.allocator);
                store.allocator.free(policies);
            }
            var allow_id: ?i64 = null;
            for (policies) |p| {
                if (context.tenant_id) |t| {
                    if (p.tenant_id != t) continue;
                }
                if (!patternMatches(p.resource, resource)) continue;
                if (!patternMatches(p.action, action)) continue;
                if (!self.conditionMatches(p.condition, context)) continue;
                if (!self.subjectMatches(p.subject, subject_id, role_ids)) continue;
                if (std.mem.eql(u8, p.effect, "deny")) {
                    info = .{ .decision = .deny, .source = .policy, .policy_id = p.id };
                    break;
                }
                if (allow_id == null) allow_id = p.id;
            }
            if (info == null) {
                if (allow_id) |id| info = .{ .decision = .allow, .source = .policy, .policy_id = id };
            }
        }

        if (info == null) {
            // Role permission fallback.
            var matched = false;
            for (role_ids) |rid| {
                const role_opt = try self.iam_svc.getRole(rid);
                const role = role_opt orelse continue;
                defer role.free(self.iam_svc.allocator);
                var it = std.mem.tokenizeAny(u8, role.permissions, "[],\" \t\n");
                while (it.next()) |perm| {
                    if (hasPermissionHave(perm, resource, action)) {
                        matched = true;
                        break;
                    }
                }
                if (matched) break;
            }
            info = .{ .decision = if (matched) .allow else .unknown, .source = if (matched) .role else .none };
        }

        const result = info.?;
        if (self.store) |store| {
            store.recordDecision(
                context.tenant_id orelse 1,
                subject_id,
                resource,
                action,
                @tagName(result.decision),
                @tagName(result.source),
                result.policy_id orelse 0,
                context.now,
            ) catch {};
        }
        return result;
    }

    /// Backwards-compatible decision-only API.
    pub fn authorize(
        self: *AuthzService,
        subject_id: i64,
        resource: []const u8,
        action: []const u8,
        context: AuthContext,
    ) !Decision {
        return (try self.authorizeDetailed(subject_id, resource, action, context)).decision;
    }

    pub fn allows(
        self: *AuthzService,
        subject_id: i64,
        resource: []const u8,
        action: []const u8,
        context: AuthContext,
    ) !bool {
        return (try self.authorizeDetailed(subject_id, resource, action, context)).decision == .allow;
    }
};
