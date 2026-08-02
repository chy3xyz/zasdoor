//! Persistence over the zent Client — uploaded file metadata.

const std = @import("std");
const zent = @import("zent");
const model = @import("model.zig");
const schema = @import("../../schema.zig");

const graph = zent.codegen.graph.buildGraph(&.{model.File});
pub const infos = graph.types;
pub const Client = schema.Client;
pub const FileInfo = infos[0];

pub const FileRow = struct {
    id: i64,
    name: []const u8,
    storage_key: []const u8,
    mime: []const u8,
    size_bytes: i64,
    uploader_id: i64,
    tenant_id: i64,
    created_at: i64,
    updated_at: i64,

    pub fn free(self: FileRow, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.storage_key);
        allocator.free(self.mime);
    }
};

pub const FileListResult = struct {
    items: []FileRow,
    total: i64,

    pub fn free(self: *FileListResult, allocator: std.mem.Allocator) void {
        for (self.items) |r| r.free(allocator);
        allocator.free(self.items);
    }
};

pub const FileStore = struct {
    allocator: std.mem.Allocator,
    client: Client,

    pub fn init(allocator: std.mem.Allocator, client: Client) FileStore {
        return .{ .allocator = allocator, .client = client };
    }

    fn dup(self: *FileStore, e: anytype) !FileRow {
        const name = try self.allocator.dupe(u8, e.name);
        errdefer self.allocator.free(name);
        const storage_key = try self.allocator.dupe(u8, e.storage_key);
        errdefer self.allocator.free(storage_key);
        const mime = try self.allocator.dupe(u8, e.mime);
        errdefer self.allocator.free(mime);
        return .{
            .id = e.id,
            .name = name,
            .storage_key = storage_key,
            .mime = mime,
            .size_bytes = e.size_bytes,
            .uploader_id = e.uploader_id,
            .tenant_id = e.tenant_id,
            .created_at = e.created_at orelse 0,
            .updated_at = e.updated_at orelse 0,
        };
    }

    pub fn create(self: *FileStore, name: []const u8, storage_key: []const u8, mime: []const u8, size_bytes: i64, uploader_id: i64, tenant_id: i64, now: i64) !i64 {
        var b = try self.client.file.Create();
        defer b.deinit();
        _ = try b.setFieldValue("name", name);
        _ = try b.setFieldValue("storage_key", storage_key);
        _ = try b.setFieldValue("mime", mime);
        _ = try b.setFieldValue("size_bytes", size_bytes);
        _ = try b.setFieldValue("uploader_id", uploader_id);
        _ = try b.setFieldValue("tenant_id", tenant_id);
        _ = try b.setFieldValue("created_at", now);
        _ = try b.setFieldValue("updated_at", now);
        var row = try b.Save();
        defer zent.codegen.deinitEntity(infos, FileInfo, &row, self.allocator);
        return row.id;
    }

    pub fn getById(self: *FileStore, id: i64) !?FileRow {
        var q = self.client.file.Query();
        defer q.deinit();
        const preds = self.client.file.predicates;
        _ = try q.Where(.{preds.idEQ(.{ .int = id })});
        const entity_opt = try q.First();
        var entity = entity_opt orelse return null;
        defer zent.codegen.deinitEntity(infos, FileInfo, &entity, self.allocator);
        return try self.dup(entity);
    }

    pub fn getByStorageKey(self: *FileStore, storage_key: []const u8) !?FileRow {
        var q = self.client.file.Query();
        defer q.deinit();
        const preds = self.client.file.predicates;
        _ = try q.Where(.{preds.storage_keyEQ(.{ .string = storage_key })});
        const entity_opt = try q.First();
        var entity = entity_opt orelse return null;
        defer zent.codegen.deinitEntity(infos, FileInfo, &entity, self.allocator);
        return try self.dup(entity);
    }

    pub fn list(self: *FileStore, page: usize, page_size: usize, uploader_id: ?i64, tenant_id: ?i64) !FileListResult {
        const preds = self.client.file.predicates;
        const owner_pred = if (uploader_id) |uid| preds.uploader_idEQ(.{ .int = uid }) else null;
        const tenant_pred = if (tenant_id) |tid| preds.tenant_idEQ(.{ .int = tid }) else null;

        var count_q = self.client.file.Query();
        defer count_q.deinit();
        if (owner_pred) |op| _ = try count_q.Where(.{op});
        if (tenant_pred) |tp| _ = try count_q.Where(.{tp});
        const total: i64 = @intCast(try count_q.Count());

        var q = self.client.file.Query();
        defer q.deinit();
        if (owner_pred) |op| _ = try q.Where(.{op});
        if (tenant_pred) |tp| _ = try q.Where(.{tp});
        if (page_size > 0) {
            _ = q.Limit(page_size);
            if (page > 1) _ = q.Offset((page - 1) * page_size);
        }
        _ = try q.OrderBy(&[_]zent.sql.Order{.{ .column = .{ .name = "created_at", .desc = true } }});
        var found = try q.All();
        defer {
            for (found.items) |*e| zent.codegen.deinitEntity(infos, FileInfo, e, self.allocator);
            found.deinit();
        }

        var out = try self.allocator.alloc(FileRow, found.items.len);
        errdefer self.allocator.free(out);
        var n: usize = 0;
        for (found.items) |e| {
            out[n] = try self.dup(e);
            n += 1;
        }
        return .{ .items = out[0..n], .total = total };
    }

    pub fn delete(self: *FileStore, id: i64) !void {
        const preds = self.client.file.predicates;
        var d = self.client.file.Delete();
        defer d.deinit();
        _ = try d.Where(.{preds.idEQ(.{ .int = id })});
        _ = try d.Exec();
    }
};
