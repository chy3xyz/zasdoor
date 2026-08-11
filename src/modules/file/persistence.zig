//! Persistence over the zent Client — uploaded file metadata.

const std = @import("std");
const zent = @import("zent");
const crud = zent.crud_helpers;
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

    /// zent.crud_helpers.get — 按主键查单行。
    pub fn getById(self: *FileStore, id: i64) !?FileRow {
        var entity = (try crud.get(self.client.file, id)) orelse return null;
        defer zent.codegen.deinitEntity(infos, FileInfo, &entity, self.allocator);
        return try self.dup(entity);
    }

    pub fn getByStorageKey(self: *FileStore, storage_key: []const u8) !?FileRow {
        const preds = self.client.file.predicates;
        var entity = (try crud.first(self.client.file, .{preds.storage_keyEQ(.{ .string = storage_key })})) orelse return null;
        defer zent.codegen.deinitEntity(infos, FileInfo, &entity, self.allocator);
        return try self.dup(entity);
    }

    pub fn list(self: *FileStore, page: usize, page_size: usize, uploader_id: ?i64, tenant_id: ?i64, sort_col: ?[]const u8, sort_desc: bool) !FileListResult {
        // zent v0.29.7:Where 支持动态 []sql.Predicate — 可选谓词交给 paginatedWithOptions。
        const preds = self.client.file.predicates;
        var preds_buf: [2]zent.sql.Predicate = undefined;
        var n_preds: usize = 0;
        if (uploader_id) |uid| {
            preds_buf[n_preds] = preds.uploader_idEQ(.{ .int = uid });
            n_preds += 1;
        }
        if (tenant_id) |tid| {
            preds_buf[n_preds] = preds.tenant_idEQ(.{ .int = tid });
            n_preds += 1;
        }
        // 排序列白名单(非法列回退 created_at desc,与改写前一致)。
        const sort_col_name: []const u8 = if (sort_col) |col| blk: {
            if (!(std.mem.eql(u8, col, "name") or std.mem.eql(u8, col, "size_bytes") or std.mem.eql(u8, col, "created_at")))
                break :blk "created_at";
            break :blk col;
        } else "created_at";
        const sort_desc_b: bool = if (sort_col) |col| blk: {
            if (!(std.mem.eql(u8, col, "name") or std.mem.eql(u8, col, "size_bytes") or std.mem.eql(u8, col, "created_at")))
                break :blk true;
            break :blk sort_desc;
        } else true;
        var result = try crud.paginatedWithOptions(self.client.file, preds_buf[0..n_preds], .{ .sort_col = sort_col_name, .desc = sort_desc_b }, page, page_size);
        defer result.deinit(infos, FileInfo, self.allocator);

        var out = try self.allocator.alloc(FileRow, result.items.items.len);
        var n: usize = 0;
        errdefer {
            for (out[0..n]) |r| r.free(self.allocator);
            self.allocator.free(out);
        }
        for (result.items.items) |e| {
            out[n] = try self.dup(e);
            n += 1;
        }
        return .{ .items = out, .total = result.total };
    }

    pub fn delete(self: *FileStore, id: i64) !void {
        const preds = self.client.file.predicates;
        var d = self.client.file.Delete();
        defer d.deinit();
        _ = try d.Where(.{preds.idEQ(.{ .int = id })});
        _ = try d.Exec();
    }
    /// Total file count (dashboard stats).
    pub fn countAll(self: *FileStore) !i64 {
        return @intCast(try crud.count(self.client.file, .{}));
    }
};
