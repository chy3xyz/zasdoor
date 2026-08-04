//! Background task handlers registered with the task Dispatcher.

const std = @import("std");
const mail = @import("services/mail.zig");
const task_svc = @import("modules/task/service.zig");

/// `mail.send` — payload is JSON: {"to": "...", "subject": "...", "text": "..."}.
pub fn mailSend(ctx: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, payload: []const u8) void {
    _ = io;
    const mailer: *mail.Mailer = @ptrCast(@alignCast(ctx orelse return));
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch return;
    defer parsed.deinit();
    const obj = parsed.value.object;
    const to = obj.get("to") orelse return;
    const subject = obj.get("subject") orelse return;
    const text = obj.get("text") orelse return;
    mailer.send(.{
        .to = to.string,
        .subject = subject.string,
        .text = text.string,
    });
}

/// The handler registry for this application. `mailer` must outlive the
/// dispatcher.
pub fn handlers(mailer: *const mail.Mailer) [1]task_svc.Handler {
    return .{
        .{
            .name = "mail.send",
            .ctx = @ptrCast(@constCast(@alignCast(mailer))),
            .run = mailSend,
        },
    };
}
