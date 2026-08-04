//! Audit service — record and query the admin audit trail.

const std = @import("std");
const zigmodu = @import("zigmodu");
const persist = @import("persistence.zig");

pub const AuditRow = persist.AuditRow;
pub const AuditListResult = persist.AuditListResult;
pub const AuditFilters = persist.AuditFilters;

pub const AuditService = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *persist.AuditStore,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, store: *persist.AuditStore) AuditService {
        return .{ .allocator = allocator, .io = io, .store = store };
    }

    /// Record one audit entry. Never fails the caller — auditing is
    /// best-effort by design (a write hiccup must not break the action).
    pub fn log(
        self: *AuditService,
        actor_user_id: i64,
        actor_name: []const u8,
        action: []const u8,
        target_type: []const u8,
        target_id: i64,
        detail: []const u8,
        ip: []const u8,
        success: bool,
        tenant_id: i64,
    ) void {
        const now = zigmodu.time.wallClockSeconds(self.io);
        _ = self.store.create(actor_user_id, actor_name, action, target_type, target_id, detail, ip, success, tenant_id, now) catch |err| {
            std.log.err("[audit] write failed for action {s}: {s}", .{ action, @errorName(err) });
        };
    }

    pub fn list(self: *AuditService, page: usize, page_size: usize, filters: AuditFilters) !AuditListResult {
        return self.store.list(page, page_size, filters);
    }
};
