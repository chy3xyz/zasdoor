//! Background task handlers registered with the task Dispatcher.

const std = @import("std");
const mail = @import("services/mail.zig");
const task_svc = @import("modules/task/service.zig");

/// `mail.send` — payload is JSON: {"to": "...", "subject": "...", "text": "..."}.
///
/// Payload problems (invalid JSON / missing field / wrong type) must return an
/// error rather than silently returning: an error goes through
/// markFailedOrRetry (retry within budget + last_error), whereas a silent
/// return records the bad task as done. Field types are checked before any
/// dereference — taking `.string` on a wrong-typed field is null and would
/// kill the dispatcher thread, wedging the whole queue.
pub fn mailSend(ctx: ?*anyopaque, allocator: std.mem.Allocator, io: std.Io, payload: []const u8) anyerror!void {
    _ = io;
    const mailer: *mail.Mailer = @ptrCast(@alignCast(ctx orelse return error.NoHandlerContext));
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch return error.InvalidPayload;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidPayload;
    const obj = parsed.value.object;
    const to = obj.get("to") orelse return error.MissingField;
    const subject = obj.get("subject") orelse return error.MissingField;
    const text = obj.get("text") orelse return error.MissingField;
    if (to != .string or subject != .string or text != .string) return error.InvalidPayload;
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
            .ctx = @ptrCast(@alignCast(@constCast(mailer))),
            .run = mailSend,
        },
    };
}
