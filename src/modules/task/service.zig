//! Task service + dispatcher — durable background task queue.
//!
//! `TaskService` is the write/query API (enqueue, retry, cancel, purge);
//! `Dispatcher` is the background loop that claims due tasks, runs their
//! registered handler and finalizes them (done / failed / scheduled retry).

const std = @import("std");
const zigmodu = @import("zigmodu");
const persist = @import("persistence.zig");
const scheduled = @import("../../scheduled.zig");

pub const TaskRow = persist.TaskRow;
pub const TaskListResult = persist.TaskListResult;
pub const StatusCounts = persist.StatusCounts;

pub const TaskService = struct {
    store: *persist.TaskStore,
    io: std.Io,
    max_attempts: i64,

    pub fn init(store: *persist.TaskStore, io: std.Io, max_attempts: i64) TaskService {
        return .{ .store = store, .io = io, .max_attempts = max_attempts };
    }

    /// Enqueue a task for immediate or delayed execution. Returns the new id.
    pub fn enqueue(self: *TaskService, name: []const u8, payload: []const u8, available_at: i64, tenant_id: i64) !i64 {
        const now = self.nowSeconds();
        return self.store.createTask(name, payload, "pending", tenant_id, 0, self.max_attempts, "", available_at, now);
    }

    pub fn enqueueNow(self: *TaskService, name: []const u8, payload: []const u8, tenant_id: i64) !i64 {
        return self.enqueue(name, payload, 0, tenant_id);
    }

    pub fn list(self: *TaskService, page: usize, page_size: usize, status: ?[]const u8) !TaskListResult {
        return self.store.listTasks(page, page_size, status);
    }

    pub fn get(self: *TaskService, id: i64) !?TaskRow {
        return self.store.getTaskById(id);
    }

    pub fn retry(self: *TaskService, id: i64) !bool {
        return self.store.retryTask(id, self.nowSeconds());
    }

    pub fn cancel(self: *TaskService, id: i64) !bool {
        return self.store.cancelTask(id, self.nowSeconds());
    }

    pub fn purge(self: *TaskService) !usize {
        return self.store.purgeFinished();
    }

    pub fn counts(self: *TaskService) !StatusCounts {
        return self.store.countByStatus();
    }

    pub fn delete(self: *TaskService, id: i64) !void {
        try self.store.deleteTask(id);
    }

    fn nowSeconds(self: *TaskService) i64 {
        return zigmodu.time.wallClockSeconds(self.io);
    }
};

// ── Dispatcher ─────────────────────────────────────────────────────

/// Task handler: `ctx` is the registered handler context (e.g. the Mailer),
/// `payload` is the JSON/plain string stored on the task row.
pub const TaskHandler = *const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, payload: []const u8) void;

pub const Handler = struct {
    name: []const u8,
    ctx: ?*anyopaque,
    run: TaskHandler,
};

pub const Dispatcher = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *persist.TaskStore,
    handlers: []const Handler,
    retry_interval_seconds: i64,
    stale_after_seconds: i64,
    scheduled: ?*scheduled.ScheduledRunner = null,
    running: std.atomic.Value(bool),
    thread: ?std.Thread = null,
    tick_interval_ms: u64 = 1000,
    processed: std.atomic.Value(u64),
    failed: std.atomic.Value(u64),

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        store: *persist.TaskStore,
        handlers: []const Handler,
        retry_interval_seconds: i64,
        stale_after_seconds: i64,
    ) Dispatcher {
        return .{
            .allocator = allocator,
            .io = io,
            .store = store,
            .handlers = handlers,
            .retry_interval_seconds = retry_interval_seconds,
            .stale_after_seconds = stale_after_seconds,
            .running = std.atomic.Value(bool).init(false),
            .thread = null,
            .processed = std.atomic.Value(u64).init(0),
            .failed = std.atomic.Value(u64).init(0),
        };
    }

    pub fn deinit(self: *Dispatcher) void {
        self.stop();
        self.* = undefined;
    }

    pub fn start(self: *Dispatcher) !void {
        if (self.running.load(.monotonic)) return;
        self.running.store(true, .monotonic);
        self.thread = try std.Thread.spawn(.{}, runLoop, .{self});
    }

    pub fn stop(self: *Dispatcher) void {
        self.running.store(false, .monotonic);
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    fn runLoop(self: *Dispatcher) void {
        while (self.running.load(.monotonic)) {
            self.tick();
            std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(@intCast(self.tick_interval_ms)), .real) catch {};
        }
    }

    /// One scheduling pass: requeue stale claims, then run every due task
    /// (sequentially; SQLite favours a single writer).
    pub fn tick(self: *Dispatcher) void {
        const now = @import("zigmodu").time.wallClockSeconds(self.io);
        _ = self.store.requeueStale(now, self.stale_after_seconds) catch {};
        if (self.scheduled) |s| s.tick(now);
        while (true) {
            const task_opt = self.store.claimNext(now) catch break;
            const task = task_opt orelse break;
            defer task.free(self.allocator);
            self.runTask(task);
        }
    }

    fn runTask(self: *Dispatcher, task: TaskRow) void {
        var found: ?Handler = null;
        for (self.handlers) |h| {
            if (std.mem.eql(u8, h.name, task.name)) {
                found = h;
                break;
            }
        }
        const handler = found orelse {
            // Unknown handler — fail so the row does not spin forever.
        self.store.markFailedOrRetry(task.id, task.attempts, task.max_attempts, "no handler registered", wallNow(self), 0) catch {};
            _ = self.failed.fetchAdd(1, .monotonic);
            return;
        };

        handler.run(handler.ctx, self.allocator, self.io, task.payload);
        // Handlers are synchronous and report failures through the shared
        // mail/notify sinks; a completed run is treated as done.
        self.store.markDone(task.id, wallNow(self)) catch {
            self.store.markFailedOrRetry(task.id, task.attempts, task.max_attempts, "store error", wallNow(self), self.retry_interval_seconds) catch {};
            _ = self.failed.fetchAdd(1, .monotonic);
            return;
        };
        _ = self.processed.fetchAdd(1, .monotonic);
    }

    fn wallNow(self: *Dispatcher) i64 {
        return @import("zigmodu").time.wallClockSeconds(self.io);
    }
};
