//! Tenant service — tenant CRUD plus default-tenant bootstrap.

const std = @import("std");
const zigmodu = @import("zigmodu");
const persist = @import("persistence.zig");

pub const TenantRow = persist.TenantRow;
pub const TenantListResult = persist.TenantListResult;

pub const TenantService = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *persist.TenantStore,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, store: *persist.TenantStore) TenantService {
        return .{ .allocator = allocator, .io = io, .store = store };
    }

    pub fn create(self: *TenantService, name: []const u8) !i64 {
        return self.store.create(name, "active", zigmodu.time.wallClockSeconds(self.io));
    }

    pub fn get(self: *TenantService, id: i64) !?TenantRow {
        return self.store.getById(id);
    }

    pub fn list(self: *TenantService, page: usize, page_size: usize) !TenantListResult {
        return self.store.list(page, page_size);
    }

    pub fn update(self: *TenantService, id: i64, name: []const u8, status: []const u8) !bool {
        return self.store.update(id, name, status, zigmodu.time.wallClockSeconds(self.io));
    }

    /// Create the bootstrap tenant when none exists (idempotent). Returns
    /// the default tenant id — every user/row without an explicit tenant
    /// context lands here (single-tenant compatibility).
    pub fn ensureDefault(self: *TenantService) !i64 {
        var result = try self.store.list(1, 1);
        defer result.free(self.allocator);
        if (result.items.len > 0) return result.items[0].id;
        return self.store.create("Default", "active", zigmodu.time.wallClockSeconds(self.io));
    }
};
