//! Notification service — flash-style per-user messages.

const std = @import("std");
const zigmodu = @import("zigmodu");
const persist = @import("persistence.zig");

pub const NotificationRow = persist.NotificationRow;
pub const NotificationListResult = persist.NotificationListResult;

pub const NotificationService = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *persist.NotificationStore,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, store: *persist.NotificationStore) NotificationService {
        return .{ .allocator = allocator, .io = io, .store = store };
    }

    /// Create a notification for a user (e.g. task finished, system alert).
    pub fn notify(self: *NotificationService, user_id: i64, title: []const u8, body: []const u8, kind: []const u8) !i64 {
        return self.store.create(user_id, title, body, kind, zigmodu.time.wallClockSeconds(self.io));
    }

    pub fn list(self: *NotificationService, user_id: i64, page: usize, page_size: usize, unread_only: bool) !NotificationListResult {
        return self.store.listForUser(user_id, page, page_size, unread_only);
    }

    pub fn unreadCount(self: *NotificationService, user_id: i64) !i64 {
        return self.store.unreadCount(user_id);
    }

    pub fn markRead(self: *NotificationService, id: i64, user_id: i64) !bool {
        return self.store.markRead(id, user_id);
    }

    pub fn markAllRead(self: *NotificationService, user_id: i64) !void {
        try self.store.markAllRead(user_id);
    }

    pub fn delete(self: *NotificationService, id: i64, user_id: i64) !bool {
        return self.store.delete(id, user_id);
    }
};
