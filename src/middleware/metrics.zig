//! Prometheus HTTP metrics — request counter, status buckets, latency and
//! uptime, collected by zigmodu's HttpMetricsCollector middleware.

const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;

pub const Metrics = struct {
    collector: http.HttpMetricsCollector,
    started_at: i64,

    pub fn init(io: std.Io) Metrics {
        return .{
            .collector = .init(),
            .started_at = zigmodu.time.wallClockSeconds(io),
        };
    }

    pub fn middleware(self: *Metrics) http.Middleware {
        return .{
            .func = http.httpMetricsMiddleware(&self.collector),
            .user_data = &self.collector,
        };
    }

    /// Prometheus text exposition for the `/metrics` endpoint.
    pub fn renderPrometheus(self: *Metrics, allocator: std.mem.Allocator, now: i64) ![]const u8 {
        const c = &self.collector;
        var buf = std.ArrayList(u8).empty;
        defer buf.deinit(allocator);

        try buf.print(allocator, "# HELP zenaipa_http_requests_total Total HTTP requests processed.\n", .{});
        try buf.print(allocator, "# TYPE zenaipa_http_requests_total counter\n", .{});
        try buf.print(allocator, "zenaipa_http_requests_total {d}\n", .{c.request_count});
        try buf.print(allocator, "# HELP zenaipa_http_requests_in_flight Requests currently being processed.\n", .{});
        try buf.print(allocator, "# TYPE zenaipa_http_requests_in_flight gauge\n", .{});
        try buf.print(allocator, "zenaipa_http_requests_in_flight {d}\n", .{c.in_flight});
        inline for (.{
            .{ "2xx", 1 },
            .{ "3xx", 2 },
            .{ "4xx", 3 },
            .{ "5xx", 4 },
        }) |pair| {
            try buf.print(allocator, "zenaipa_http_requests_{s}{{class=\"{s}\"}} {d}\n", .{ pair[0], pair[0], c.status_counts[pair[1]] });
        }
        try buf.print(allocator, "# HELP zenaipa_http_request_duration_seconds Request latency summary.\n", .{});
        try buf.print(allocator, "# TYPE zenaipa_http_request_duration_seconds gauge\n", .{});
        try buf.print(allocator, "zenaipa_http_request_duration_seconds_avg {d:.6}\n", .{c.avgDuration()});
        try buf.print(allocator, "zenaipa_http_request_duration_seconds_max {d:.6}\n", .{if (c.max_duration_seconds == std.math.floatMax(f64)) 0 else c.max_duration_seconds});
        try buf.print(allocator, "# HELP zenaipa_uptime_seconds Process uptime.\n", .{});
        try buf.print(allocator, "# TYPE zenaipa_uptime_seconds gauge\n", .{});
        try buf.print(allocator, "zenaipa_uptime_seconds {d}\n", .{now - self.started_at});
        return buf.toOwnedSlice(allocator);
    }
};
