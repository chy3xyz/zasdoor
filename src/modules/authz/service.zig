//! Authorization kernel (dev.md section 10-12).
//!
//! A unified API:
//!     authorize(subject_id, resource, action, context) -> Decision
//!
//! Backed by project/org-scoped role assignments resolving to a permission
//! set. Supports exact and wildcard permissions (e.g. `user.read` and `user.*`).
//! Decisions: ALLOW | DENY | UNKNOWN (no applicable policy).

const std = @import("std");
const iam = @import("../iam/service.zig");

pub const Decision = enum {
    allow,
    deny,
    unknown,
};

/// Context passed to `authorize` (dev.md section 10 example shows org/project
/// and attribute conditions usable by future ABAC).
pub const AuthContext = struct {
    org_id: ?i64 = null,
    project_id: ?i64 = null,
};

/// A parsed permission: resource + action (with wildcard support).
const Permission = struct {
    resource: []const u8,
    action: []const u8,
};

fn hasPermissionHave(perm: []const u8, resource: []const u8, action: []const u8) bool {
    // Split "resource:action".
    var it = std.mem.splitScalar(u8, perm, '.');
    const p_res = it.next() orelse return false;
    const p_act = it.next() orelse return std.mem.eql(u8, p_res, resource);
    const res_match = std.mem.eql(u8, p_res, resource) or std.mem.eql(u8, p_res, "*");
    const act_match = std.mem.eql(u8, p_act, action) or std.mem.eql(u8, p_act, "*");
    return res_match and act_match;
}

pub const AuthzService = struct {
    allocator: std.mem.Allocator,
    iam_svc: *iam.IamService,

    pub fn init(allocator: std.mem.Allocator, iam_svc: *iam.IamService) AuthzService {
        return .{ .allocator = allocator, .iam_svc = iam_svc };
    }

    /// Does `subject` hold the permission for `resource:action`?
    /// Scoped to a project when context.project_id is set.
    pub fn authorize(
        self: *AuthzService,
        subject_id: i64,
        resource: []const u8,
        action: []const u8,
        context: AuthContext,
    ) !Decision {
        // Resolve the user's roles (project-scoped when given).
        const role_ids = try self.iam_svc.store.listRoleIdsForUser(subject_id, context.project_id);
        defer self.allocator.free(role_ids);
        if (role_ids.len == 0) return .unknown;

        var matched = false;
        for (role_ids) |rid| {
            const role_opt = try self.iam_svc.getRole(rid);
            const role = role_opt orelse continue;
            defer role.free(self.allocator);
            // role.permissions is a JSON string array like ["user.read","user.write"].
            var it = std.mem.tokenizeAny(u8, role.permissions, "[],\" \t\n");
            while (it.next()) |perm| {
                if (hasPermissionHave(perm, resource, action)) {
                    matched = true;
                    break;
                }
            }
            if (matched) break;
        }
        return if (matched) .allow else .unknown;
    }

    /// Convenience boolean wrapper.
    pub fn allows(
        self: *AuthzService,
        subject_id: i64,
        resource: []const u8,
        action: []const u8,
        context: AuthContext,
    ) !bool {
        const d = try self.authorize(subject_id, resource, action, context);
        return d == .allow;
    }
};
