//! Cache service — thin wrapper over zigmodu's LRU CacheManager.
//!
//! Values are arbitrary bytes (JSON strings work well). Keys are
//! namespaced by the caller, e.g. `user:42`, `kv:<key>`. The manager is
//! single-threaded; the HTTP server handles one request per connection so
//! no extra locking is needed today.

const std = @import("std");
const zigmodu = @import("zigmodu");

pub const CacheService = struct {
    allocator: std.mem.Allocator,
    manager: zigmodu.data.CacheManager,

    pub fn init(allocator: std.mem.Allocator, max_entries: usize, ttl_seconds: u64) CacheService {
        return .{
            .allocator = allocator,
            .manager = zigmodu.data.CacheManager.init(allocator, max_entries, ttl_seconds, .LRU),
        };
    }

    pub fn deinit(self: *CacheService) void {
        self.manager.deinit();
        self.* = undefined;
    }

    pub fn set(self: *CacheService, key: []const u8, value: []const u8) !void {
        try self.manager.set(key, value);
    }

    /// Returns a cache-owned slice (do not free, do not keep across writes).
    pub fn get(self: *CacheService, key: []const u8) ?[]const u8 {
        return self.manager.get(key);
    }

    /// Read-through: return the cached value or run `loader`, store the
    /// result and return it.
    pub fn getOrSet(self: *CacheService, key: []const u8, loader: *const fn (allocator: std.mem.Allocator) anyerror![]const u8) ![]const u8 {
        if (self.manager.get(key)) |v| return v;
        const fresh = try loader(self.allocator);
        self.manager.set(key, fresh) catch {};
        return fresh;
    }

    pub fn remove(self: *CacheService, key: []const u8) bool {
        return self.manager.remove(key);
    }

    pub fn count(self: *CacheService) usize {
        return self.manager.count();
    }
};
