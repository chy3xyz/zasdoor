//! File HTTP API — upload/download/list/delete. Uploads require any
//! authenticated user; admins see all files, users see their own.

const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;
const mw = @import("../../middleware/auth.zig");
const user_svc = @import("../user/service.zig");
const audit_svc = @import("../audit/service.zig");
const service = @import("service.zig");

const FileDto = struct {
    id: i64,
    name: []const u8,
    mime: []const u8,
    size_bytes: i64,
    uploader_id: i64,
    tenant_id: i64,
    created_at: i64,
};

fn toDto(row: service.FileRow) FileDto {
    return .{
        .id = row.id,
        .name = row.name,
        .mime = row.mime,
        .size_bytes = row.size_bytes,
        .uploader_id = row.uploader_id,
        .tenant_id = row.tenant_id,
        .created_at = row.created_at,
    };
}

pub fn FileApi(comptime Service: type, comptime UserService: type) type {
    return struct {
        const Self = @This();
        svc: *Service,
        user_svc: *UserService,
        audit: *audit_svc.AuditService,
        default_tenant_id: i64,

        pub fn init(svc: *Service, users: *UserService, audit: *audit_svc.AuditService, default_tenant_id: i64) Self {
            return .{ .svc = svc, .user_svc = users, .audit = audit, .default_tenant_id = default_tenant_id };
        }

        pub fn registerRoutes(self: *Self, group: *http.RouteGroup) !void {
            var g = try group.use(zigmodu.http.http_middleware.jwtAuthWithSecurity(&self.user_svc.sec.module));
            try g.post("/files", upload, @ptrCast(@alignCast(self)));
            try g.get("/files", list, @ptrCast(@alignCast(self)));
            try g.get("/files/{id}", download, @ptrCast(@alignCast(self)));
            try g.delete("/files/{id}", delete, @ptrCast(@alignCast(self)));
        }

        fn authUser(ctx: *http.Context, self: *Self) !?struct { id: i64, admin: bool } {
            const uid = mw.authUserId(ctx) orelse {
                try ctx.sendErrorResponse(401, 401, "未登录或登录已过期");
                return null;
            };
            const row_opt = self.user_svc.getUserById(uid) catch {
                try ctx.sendErrorResponse(401, 401, "未登录或登录已过期");
                return null;
            };
            const row = row_opt orelse {
                try ctx.sendErrorResponse(401, 401, "未登录或登录已过期");
                return null;
            };
            defer row.free(self.svc.allocator);
            try ctx.setAttr("audit_actor", row.name);
            return .{ .id = uid, .admin = row.admin };
        }

        fn upload(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const actor = (try authUser(ctx, self)) orelse return;

            const body = ctx.body orelse {
                try ctx.sendErrorResponse(400, 400, "缺少文件内容");
                return;
            };
            const filename = ctx.header("X-File-Name") orelse "upload.bin";
            const mime = ctx.header("Content-Type") orelse "application/octet-stream";

            const tenant_id = mw.authTenantId(ctx) orelse self.default_tenant_id;
            const row = self.svc.save(actor.id, tenant_id, filename, mime, body) catch |err| switch (err) {
                error.FileTooLarge => {
                    try ctx.sendErrorResponse(413, 413, "文件超过大小限制");
                    return;
                },
                else => {
                    std.log.err("internal error: {s}", .{@errorName(err)});
                    try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                    return;
                },
            };
            defer row.free(self.svc.allocator);
            try ctx.jsonStruct(201, .{ .code = 0, .msg = "上传成功", .data = toDto(row) });
        }

        fn list(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const actor = (try authUser(ctx, self)) orelse return;

            const params = zigmodu.http.PageParams.parse(ctx, .{ .max_page_size = 100 });
            const current_tenant = mw.authTenantId(ctx) orelse self.default_tenant_id;
            const owner: ?i64 = if (actor.admin) null else actor.id;
            const tenant_filter: ?i64 = if (actor.admin) blk: {
                const tid = ctx.queryInt(i64, "tenant_id", 0);
                break :blk if (tid > 0) tid else null;
            } else current_tenant;
            const sort = zigmodu.http.page.parseSort(ctx, &.{ "name", "size_bytes", "created_at" });
            const sort_col: ?[]const u8 = if (sort) |s| s.column else null;
            const sort_desc = if (sort) |s| s.desc else false;

            var result = self.svc.list(params.page, params.page_size, owner, tenant_filter, sort_col, sort_desc) catch |err| {
                std.log.err("internal error: {s}", .{@errorName(err)});
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            defer result.free(self.svc.allocator);

            const dtos = try zigmodu.http.Extract.toDtoList(ctx.allocator, result.items, FileDto, toDto);
            try zigmodu.http.sendPaged(ctx, dtos, @intCast(result.total), params, .ruoyi);
        }

        fn download(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const actor = (try authUser(ctx, self)) orelse return;

            const id = ctx.paramInt(i64, "id") catch {
                try ctx.sendErrorResponse(400, 400, "无效的文件 ID");
                return;
            };
            const loaded_opt = self.svc.load(id) catch |err| {
                std.log.err("internal error: {s}", .{@errorName(err)});
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            var loaded = loaded_opt orelse {
                try ctx.sendErrorResponse(404, 404, "文件不存在");
                return;
            };
            defer loaded.free(self.svc.allocator);

            const current_tenant = mw.authTenantId(ctx) orelse self.default_tenant_id;
            if (!actor.admin and (loaded.row.uploader_id != actor.id or loaded.row.tenant_id != current_tenant)) {
                try ctx.sendErrorResponse(403, 403, "无权访问该文件");
                return;
            }

            try ctx.text(200, loaded.bytes);
            // 危险内容类型(HTML/SVG/JS)强制二进制输出,避免经代理缓存后被当作网页渲染。
            const safe_mime: []const u8 = if (isDangerousMime(loaded.row.mime)) "application/octet-stream" else loaded.row.mime;
            try ctx.setHeader("Content-Type", safe_mime);
            const disposition = try std.fmt.allocPrint(ctx.allocator, "attachment; filename=\"{s}\"", .{loaded.row.name});
            defer ctx.allocator.free(disposition);
            try ctx.setHeader("Content-Disposition", disposition);
        }

        fn delete(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const actor = (try authUser(ctx, self)) orelse return;

            const id = ctx.paramInt(i64, "id") catch {
                try ctx.sendErrorResponse(400, 400, "无效的文件 ID");
                return;
            };
            const row_opt = self.svc.get(id) catch |err| {
                std.log.err("internal error: {s}", .{@errorName(err)});
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            const row = row_opt orelse {
                try ctx.sendErrorResponse(404, 404, "文件不存在");
                return;
            };
            defer row.free(self.svc.allocator);
            const current_tenant = mw.authTenantId(ctx) orelse self.default_tenant_id;
            if (!actor.admin and (row.uploader_id != actor.id or row.tenant_id != current_tenant)) {
                try ctx.sendErrorResponse(403, 403, "无权删除该文件");
                return;
            }
            self.svc.delete(id) catch |err| {
                std.log.err("internal error: {s}", .{@errorName(err)});
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            var d5: [96]u8 = undefined;
            const det5 = try std.fmt.bufPrint(&d5, "删除文件 #{d}", .{id});
            self.audit.log(actor.id, ctx.getAttr("audit_actor") orelse "", "file.delete", "file", id, det5, zigmodu.http.RequestUtil.getRealIp(ctx), true, row.tenant_id);
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "ok", .data = null });
        }
    };
}

/// 取原始文件名的 basename,剔除路径分隔符、控制字符与引号(防路径穿越/header 注入)。
fn sanitizeFilename(buf: *[256]u8, raw: []const u8) []const u8 {
    var start: usize = 0;
    if (std.mem.lastIndexOfScalar(u8, raw, '/')) |i| start = i + 1;
    if (std.mem.lastIndexOfScalar(u8, raw[start..], '\\')) |j| start += j + 1;
    var len: usize = 0;
    for (raw[start..]) |c| {
        if (c < 0x20 or c == '"' or c == '\\' or c == '/') continue;
        if (len >= buf.len - 1) break;
        buf[len] = c;
        len += 1;
    }
    return buf[0..len];
}

/// 可被浏览器当活动内容渲染的 MIME 类型(附件下载场景仍需强制二进制)。
fn isDangerousMime(mime: []const u8) bool {
    return std.mem.indexOf(u8, mime, "text/html") != null or
        std.mem.indexOf(u8, mime, "image/svg") != null or
        std.mem.indexOf(u8, mime, "application/xhtml") != null or
        std.mem.indexOf(u8, mime, "text/javascript") != null or
        std.mem.indexOf(u8, mime, "application/javascript") != null;
}

pub const DefaultFileApi = FileApi(service.FileService, user_svc.UserService);
