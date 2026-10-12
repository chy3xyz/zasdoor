//! File service — local-disk storage with DB metadata.

const std = @import("std");
const zigmodu = @import("zigmodu");
const persist = @import("persistence.zig");

pub const FileRow = persist.FileRow;
pub const FileListResult = persist.FileListResult;

pub const LoadedFile = struct {
    row: FileRow,
    bytes: []u8,

    pub fn free(self: *LoadedFile, allocator: std.mem.Allocator) void {
        self.row.free(allocator);
        allocator.free(self.bytes);
    }
};

pub const FileService = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *persist.FileStore,
    upload_dir: []const u8,
    max_bytes: usize,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, store: *persist.FileStore, upload_dir: []const u8, max_bytes: usize) FileService {
        return .{ .allocator = allocator, .io = io, .store = store, .upload_dir = upload_dir, .max_bytes = max_bytes };
    }

    pub fn ensureDir(self: *FileService) !void {
        var dir = std.Io.Dir.cwd();
        dir.createDir(self.io, self.upload_dir, .default_dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    /// Persist raw bytes to disk and record metadata. `filename` is the
    /// user-facing name; the on-disk name is a generated storage key. Content
    /// is validated by zigmodu `UploadGuard.check`: bytes are sniffed, so
    /// active content (SVG/HTML) renamed to `.txt` is refused — an extension
    /// allowlist alone cannot stop a rename bypass.
    pub fn save(self: *FileService, uploader_id: i64, tenant_id: i64, filename: []const u8, mime: []const u8, data: []const u8) !FileRow {
        _ = zigmodu.http.UploadGuard.check(filename, data, .{
            .extensions = &allowed_extensions,
            .max_bytes = self.max_bytes,
            // General-purpose store: docx/xlsx/pptx sniff as zip and tar/mov
            // carry no magic number, so a strict extension<->content match
            // would reject legitimate files. The core defense is refusing
            // active content.
            .require_extension_match = false,
        }) catch |err| switch (err) {
            error.FileTooLarge => return error.FileTooLarge,
            // Active content / disallowed extension are caller errors, mapped
            // to 400 by the API layer.
            error.ActiveContentNotAllowed,
            error.ExtensionNotAllowed,
            error.ContentNotAllowed,
            error.ExtensionContentMismatch,
            => return error.FileTypeNotAllowed,
        };
        try self.ensureDir();

        const key = try self.storageKey(filename);
        defer self.allocator.free(key);

        const path = try self.pathFor(key);
        defer self.allocator.free(path);

        var file = try std.Io.Dir.cwd().createFile(self.io, path, .{ .exclusive = true });
        errdefer file.close(self.io);
        try file.writePositionalAll(self.io, data, 0);
        file.close(self.io);

        const now = wallNow(self.io);
        const id = self.store.create(filename, key, mime, @intCast(data.len), uploader_id, tenant_id, now) catch |err| {
            // Roll back the orphaned disk file on metadata failure.
            std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
            return err;
        };
        return (self.store.getById(id) catch return error.Unexpected) orelse return error.Unexpected;
    }

    /// Read file bytes back from disk.
    pub fn load(self: *FileService, id: i64) !?LoadedFile {
        const row_opt = try self.store.getById(id);
        const row = row_opt orelse return null;
        errdefer row.free(self.allocator);

        const path = try self.pathFor(row.storage_key);
        defer self.allocator.free(path);

        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(self.max_bytes)) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        return .{ .row = row, .bytes = bytes };
    }

    pub fn list(self: *FileService, page: usize, page_size: usize, uploader_id: ?i64, tenant_id: ?i64, sort_col: ?[]const u8, sort_desc: bool) !FileListResult {
        return self.store.list(page, page_size, uploader_id, tenant_id, sort_col, sort_desc);
    }

    pub fn get(self: *FileService, id: i64) !?FileRow {
        return self.store.getById(id);
    }

    /// Delete metadata and the disk file.
    pub fn delete(self: *FileService, id: i64) !void {
        const row_opt = try self.store.getById(id);
        const row = row_opt orelse return;
        defer row.free(self.allocator);
        try self.store.delete(id);
        const path = try self.pathFor(row.storage_key);
        defer self.allocator.free(path);
        // Metadata is already gone; the disk file is best-effort. A failure
        // only leaves an orphan for operators to clean up.
        std.Io.Dir.cwd().deleteFile(self.io, path) catch |err| {
            std.log.warn("[file] orphan disk file delete failed ({s}): {s}", .{ path, @errorName(err) });
        };
    }

    fn storageKey(self: *FileService, filename: []const u8) ![]const u8 {
        const now = wallNow(self.io);
        const ext = extensionOf(filename);
        return std.fmt.allocPrint(self.allocator, "{d}-{x}-{s}", .{ now, randomU32(self.io), ext });
    }

    fn pathFor(self: *FileService, storage_key: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.upload_dir, storage_key });
    }
};

fn wallNow(io: std.Io) i64 {
    return zigmodu.time.wallClockSeconds(io);
}

/// 允许上传的扩展名白名单(排除 html/svg/脚本等可执行内容)。
/// 内容层校验由 `FileService.save` 内的 `UploadGuard.check` 完成。
const allowed_extensions = [_][]const u8{
    "txt", "md",   "csv", "json", "log",  "pdf", "doc",  "docx", "xls", "xlsx",
    "ppt", "pptx", "png", "jpg",  "jpeg", "gif", "webp", "zip",  "gz",  "tar",
    "7z",  "mp4",  "mov", "mp3",  "wav",  "bin",
};

fn extensionOf(filename: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, filename, '.')) |i| {
        const ext = filename[i + 1 ..];
        // Alphanumeric extensions only: a tail like "png/../../etc" must not
        // end up in the storage key (pathFor concatenates upload_dir).
        if (ext.len > 0 and ext.len <= 16) {
            var ok = true;
            for (ext) |c| {
                if (!std.ascii.isAlphanumeric(c)) {
                    ok = false;
                    break;
                }
            }
            if (ok) return ext;
        }
    }
    return "bin";
}

fn randomU32(io: std.Io) u32 {
    var buf: [4]u8 = undefined;
    var file = std.Io.Dir.cwd().openFile(io, "/dev/urandom", .{}) catch return 0;
    defer file.close(io);
    _ = file.readPositionalAll(io, &buf, 0) catch return 0;
    return std.mem.readInt(u32, &buf, .big);
}
