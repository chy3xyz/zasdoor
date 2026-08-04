//! Persistence over the zent Client — email templates.

const std = @import("std");
const zent = @import("zent");
const model = @import("model.zig");
const schema = @import("../../schema.zig");

const graph = zent.codegen.graph.buildGraph(&.{model.EmailTemplate});
pub const infos = graph.types;
pub const Client = schema.Client;
pub const EmailTemplateInfo = infos[0];

pub const TemplateRow = struct {
    id: i64,
    code: []const u8,
    subject: []const u8,
    body: []const u8,
    updated_at: i64,

    pub fn free(self: TemplateRow, allocator: std.mem.Allocator) void {
        allocator.free(self.code);
        allocator.free(self.subject);
        allocator.free(self.body);
    }
};

pub const TemplateListResult = struct {
    items: []TemplateRow,
    total: i64,

    pub fn free(self: *TemplateListResult, allocator: std.mem.Allocator) void {
        for (self.items) |r| r.free(allocator);
        allocator.free(self.items);
    }
};

pub const TemplateStore = struct {
    allocator: std.mem.Allocator,
    client: Client,

    pub fn init(allocator: std.mem.Allocator, client: Client) TemplateStore {
        return .{ .allocator = allocator, .client = client };
    }

    fn dup(self: *TemplateStore, e: anytype) !TemplateRow {
        const code = try self.allocator.dupe(u8, e.code);
        errdefer self.allocator.free(code);
        const subject = try self.allocator.dupe(u8, e.subject);
        errdefer self.allocator.free(subject);
        const body = try self.allocator.dupe(u8, e.body);
        errdefer self.allocator.free(body);
        return .{
            .id = e.id,
            .code = code,
            .subject = subject,
            .body = body,
            .updated_at = e.updated_at orelse 0,
        };
    }

    pub fn getByCode(self: *TemplateStore, code: []const u8) !?TemplateRow {
        const preds = self.client.email_template.predicates;
        var q = self.client.email_template.Query();
        defer q.deinit();
        _ = try q.Where(.{preds.codeEQ(.{ .string = code })});
        _ = q.Limit(1);
        var rows = try q.All();
        defer {
            for (rows.items) |*e| zent.codegen.deinitEntity(infos, EmailTemplateInfo, e, self.allocator);
            rows.deinit();
        }
        if (rows.items.len == 0) return null;
        return try self.dup(rows.items[0]);
    }

    /// Insert or update the template identified by `code` (upsert by query).
    pub fn upsert(self: *TemplateStore, code: []const u8, subject: []const u8, body: []const u8, now: i64) !void {
        const preds = self.client.email_template.predicates;
        var q = self.client.email_template.Query();
        defer q.deinit();
        _ = try q.Where(.{preds.codeEQ(.{ .string = code })});
        _ = q.Limit(1);
        var rows = try q.All();
        defer {
            for (rows.items) |*e| zent.codegen.deinitEntity(infos, EmailTemplateInfo, e, self.allocator);
            rows.deinit();
        }
        if (rows.items.len == 0) {
            var b = try self.client.email_template.Create();
            defer b.deinit();
            _ = try b.setFieldValue("code", code);
            _ = try b.setFieldValue("subject", subject);
            _ = try b.setFieldValue("body", body);
            _ = try b.setFieldValue("created_at", now);
            _ = try b.setFieldValue("updated_at", now);
            var row = try b.Save();
            defer zent.codegen.deinitEntity(infos, EmailTemplateInfo, &row, self.allocator);
            return;
        }
        var upd = self.client.email_template.Update();
        defer upd.deinit();
        _ = try upd.setFieldValue("subject", subject);
        _ = try upd.setFieldValue("body", body);
        _ = try upd.setFieldValue("updated_at", now);
        _ = try upd.Where(.{preds.codeEQ(.{ .string = code })});
        _ = try upd.Save();
    }

    pub fn list(self: *TemplateStore, page: usize, page_size: usize) !TemplateListResult {
        var q = self.client.email_template.Query();
        defer q.deinit();
        _ = try q.OrderBy(&[_]zent.sql.Order{.{ .column = .{ .name = "code", .desc = false } }});
        var paged = try q.paged(page, page_size);
        defer paged.deinit();

        var out = try self.allocator.alloc(TemplateRow, paged.items.items.len);
        var n: usize = 0;
        errdefer {
            for (out[0..n]) |r| r.free(self.allocator);
            self.allocator.free(out);
        }
        for (paged.items.items) |e| {
            out[n] = try self.dup(e);
            n += 1;
        }
        return .{ .items = out, .total = paged.total };
    }
};
