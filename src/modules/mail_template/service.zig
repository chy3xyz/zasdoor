//! Email-template service — variable rendering + CRUD over the store.

const std = @import("std");
const zigmodu = @import("zigmodu");
const persist = @import("persistence.zig");

pub const TemplateRow = persist.TemplateRow;
pub const TemplateListResult = persist.TemplateListResult;

/// Variables available in template bodies/subjects:
/// `{app_name}` — product name, `{link}` — the action URL, `{email}` — recipient.
pub const app_name = "zenaipa";

pub const RenderVars = struct {
    link: []const u8,
    email: []const u8,
};

pub const Rendered = struct {
    subject: []u8,
    body: []u8,

    pub fn free(self: Rendered, allocator: std.mem.Allocator) void {
        allocator.free(self.subject);
        allocator.free(self.body);
    }
};

/// Per-code defaults used when an admin has not customized the template yet.
const Default = struct { subject: []const u8, body: []const u8 };
const defaults = std.StaticStringMap(Default).initComptime(.{
    .{ "verify_email", Default{ .subject = "验证你的 {app_name} 邮箱", .body = "你好 {email},\n\n请点击以下链接完成邮箱验证：\n{link}" } },
    .{ "reset_password", Default{ .subject = "重置你的 {app_name} 密码", .body = "你好 {email},\n\n请点击以下链接重置密码：\n{link}" } },
});

pub const MailTemplateService = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *persist.TemplateStore,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, store: *persist.TemplateStore) MailTemplateService {
        return .{ .allocator = allocator, .io = io, .store = store };
    }

    fn replaceVars(self: *MailTemplateService, template: []const u8, vars: RenderVars) ![]u8 {
        // Single `errdefer` bound to the current buffer: each step frees the
        // previous value before rebinding, so at any error point exactly one
        // allocation remains outstanding (no double-free), and on success the
        // final buffer's ownership transfers to the caller.
        var cur = try self.allocator.dupe(u8, template);
        errdefer self.allocator.free(cur);

        const next1 = try std.mem.replaceOwned(u8, self.allocator, cur, "{app_name}", app_name);
        self.allocator.free(cur);
        cur = next1;

        const next2 = try std.mem.replaceOwned(u8, self.allocator, cur, "{link}", vars.link);
        self.allocator.free(cur);
        cur = next2;

        const next3 = try std.mem.replaceOwned(u8, self.allocator, cur, "{email}", vars.email);
        self.allocator.free(cur);
        return next3;
    }

    /// Render a template by code. Falls back to built-in defaults when no
    /// admin override exists. Returns null only when the code is unknown.
    pub fn render(self: *MailTemplateService, code: []const u8, vars: RenderVars) !?Rendered {
        var subject_src: []const u8 = undefined;
        var body_src: []const u8 = undefined;
        var owned: ?TemplateRow = null;

        if (try self.store.getByCode(code)) |row| {
            owned = row;
            subject_src = row.subject;
            body_src = row.body;
        } else if (defaults.get(code)) |d| {
            subject_src = d.subject;
            body_src = d.body;
        } else return null;
        defer if (owned) |r| r.free(self.allocator);

        const subject = try self.replaceVars(subject_src, vars);
        errdefer self.allocator.free(subject);
        const body = try self.replaceVars(body_src, vars);
        return .{ .subject = subject, .body = body };
    }

    pub fn getByCode(self: *MailTemplateService, code: []const u8) !?TemplateRow {
        return self.store.getByCode(code);
    }

    pub fn upsert(self: *MailTemplateService, code: []const u8, subject: []const u8, body: []const u8) !void {
        const now = zigmodu.time.wallClockSeconds(self.io);
        return self.store.upsert(code, subject, body, now);
    }

    pub fn list(self: *MailTemplateService, page: usize, page_size: usize) !TemplateListResult {
        return self.store.list(page, page_size);
    }
};
