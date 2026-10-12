//! Cache service — thin wrapper over zigmodu's LRU CacheManager.
//!
//! Values are arbitrary bytes (JSON strings work well). Keys are namespaced by
//! the caller, e.g. `user:42`, `kv:<key>`.
//!
//! Thread safety: CacheManager is designed single-threaded, while the HTTP
//! server's connections arrive concurrently — every manager access is
//! serialized behind this service's mutex. Loaders run outside the lock so a
//! slow loader cannot stall other requests.

const std = @import("std");
const zigmodu = @import("zigmodu");

pub const CacheService = struct {
    allocator: std.mem.Allocator,
    manager: zigmodu.data.CacheManager,
    mutex: std.Io.Mutex,
    io: std.Io,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, max_entries: usize, ttl_seconds: u64) CacheService {
        return .{
            .allocator = allocator,
            .manager = zigmodu.data.CacheManager.init(allocator, max_entries, ttl_seconds, .LRU),
            .mutex = std.Io.Mutex.init,
            .io = io,
        };
    }

    pub fn deinit(self: *CacheService) void {
        // Unlock before poisoning self: a defer unlock would read the corrupt
        // mutex after `self.* = undefined`. The critical section is an O(1)
        // map teardown.
        self.mutex.lockUncancelable(self.io);
        self.manager.deinit();
        self.mutex.unlock(self.io);
        self.* = undefined;
    }

    pub fn set(self: *CacheService, key: []const u8, value: []const u8) !void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try self.manager.set(key, value);
    }

    /// Returns a cache-owned slice (do not free, do not keep across writes).
    pub fn get(self: *CacheService, key: []const u8) ?[]const u8 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.manager.get(key);
    }

    /// Read-through: return the cached value or run `loader` (outside the
    /// lock), store the result and return it.
    pub fn getOrSet(self: *CacheService, key: []const u8, loader: *const fn (allocator: std.mem.Allocator) anyerror![]const u8) ![]const u8 {
        if (self.get(key)) |v| return v;
        const fresh = try loader(self.allocator);
        self.set(key, fresh) catch |err| {
            // Read-through semantics: a failed store must not mask the loaded
            // value, but it must leave a trace (the value is still returned).
            std.log.warn("[cache] set '{s}' failed after loader: {s}", .{ key, @errorName(err) });
        };
        return fresh;
    }

    pub fn remove(self: *CacheService, key: []const u8) bool {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.manager.remove(key);
    }

    pub fn count(self: *CacheService) usize {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.manager.count();
    }
};
