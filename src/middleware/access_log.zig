//! Access-log middleware — structured per-request logs backed by zigmodu's
//! AccessLogger (which redacts Authorization/Cookie headers).

const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;

pub const AccessLog = struct {
    logger: http.AccessLogger,

    pub fn init(allocator: std.mem.Allocator, max_entries: usize) AccessLog {
        return .{ .logger = http.AccessLogger.init(allocator, max_entries) };
    }

    pub fn deinit(self: *AccessLog) void {
        self.logger.deinit();
    }

    pub fn middleware(self: *AccessLog) http.Middleware {
        return .{
            .func = http.accessLogMiddleware(&self.logger),
            .user_data = &self.logger,
        };
    }
};
