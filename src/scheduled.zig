//! Lightweight interval scheduler for background housekeeping.
//!
//! zigmodu ships a full cron `Scheduler`, but zent's SQLite driver is a
//! single connection, so all background DB work must stay on ONE thread —
//! the task dispatcher's loop. `ScheduledRunner` is embedded in that loop
//! and runs jobs at fixed intervals (cron semantics for our single-writer
//! constraint). For CPU-only jobs, prefer `zigmodu.cron.Scheduler`.

const std = @import("std");

pub const ScheduledJob = struct {
    name: []const u8,
    interval_seconds: i64,
    last_run: i64 = 0,
    run: *const fn (ctx: ?*anyopaque) void,
    ctx: ?*anyopaque = null,
};

pub const ScheduledRunner = struct {
    jobs: []ScheduledJob,

    pub fn tick(self: *ScheduledRunner, now: i64) void {
        for (self.jobs) |*job| {
            if (now - job.last_run >= job.interval_seconds) {
                job.run(job.ctx);
                job.last_run = now;
            }
        }
    }
};
