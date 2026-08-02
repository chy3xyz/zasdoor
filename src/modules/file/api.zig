//! File HTTP API — upload/download/list/delete. Uploads require any
//! authenticated user; admins see all files, users see their own.

const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;
const mw = @import("../../middleware/auth.zig");
const user_svc = @import("../user/service.zig");
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
        default_tenant_id: i64,

        pub fn init(svc: *Service, users: *UserService, default_tenant_id: i64) Self {
            return .{ .svc = svc, .user_svc = users, .default_tenant_id = default_tenant_id };
        }

        pub fn registerRoutes(self: *Self, group: *http.RouteGroup) !void {
            var g = try group.use(mw.jwtAuth(self.user_svc.sec));
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
            defer row.free(ctx.allocator);
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
                    try ctx.sendErrorResponse(500, 500, @errorName(err));
                    return;
                },
            };
            defer row.free(ctx.allocator);
            try ctx.jsonStruct(201, .{ .code = 0, .msg = "上传成功", .data = toDto(row) });
        }

        fn list(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const actor = (try authUser(ctx, self)) orelse return;

            const page = ctx.queryInt(usize, "page", 1);
            const page_size = ctx.queryInt(usize, "page_size", 20);
            const current_tenant = mw.authTenantId(ctx) orelse self.default_tenant_id;
            const owner: ?i64 = if (actor.admin) null else actor.id;
            const tenant_filter: ?i64 = if (actor.admin)
                blk: {
                    const tid = ctx.queryInt(i64, "tenant_id", 0);
                    break :blk if (tid > 0) tid else null;
                }
            else
                current_tenant;

            var result = self.svc.list(page, page_size, owner, tenant_filter) catch |err| {
                try ctx.sendErrorResponse(500, 500, @errorName(err));
                return;
            };
            defer result.free(ctx.allocator);

            var items = std.ArrayList(FileDto).empty;
            defer items.deinit(ctx.allocator);
            for (result.items) |r| try items.append(ctx.allocator, toDto(r));

            try ctx.jsonStruct(200, .{
                .code = 0,
                .msg = "",
                .data = .{
                    .list = items.items,
                    .total = result.total,
                    .page = page,
                    .pageSize = page_size,
                },
            });
        }

        fn download(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const actor = (try authUser(ctx, self)) orelse return;

            const id = ctx.paramInt(i64, "id") catch {
                try ctx.sendErrorResponse(400, 400, "无效的文件 ID");
                return;
            };
            const loaded_opt = self.svc.load(id) catch |err| {
                try ctx.sendErrorResponse(500, 500, @errorName(err));
                return;
            };
            var loaded = loaded_opt orelse {
                try ctx.sendErrorResponse(404, 404, "文件不存在");
                return;
            };
            defer loaded.free(ctx.allocator);

            const current_tenant = mw.authTenantId(ctx) orelse self.default_tenant_id;
            if (!actor.admin and (loaded.row.uploader_id != actor.id or loaded.row.tenant_id != current_tenant)) {
                try ctx.sendErrorResponse(403, 403, "无权访问该文件");
                return;
            }

            try ctx.text(200, loaded.bytes);
            try ctx.setHeader("Content-Type", loaded.row.mime);
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
                try ctx.sendErrorResponse(500, 500, @errorName(err));
                return;
            };
            const row = row_opt orelse {
                try ctx.sendErrorResponse(404, 404, "文件不存在");
                return;
            };
            defer row.free(ctx.allocator);
            const current_tenant = mw.authTenantId(ctx) orelse self.default_tenant_id;
            if (!actor.admin and (row.uploader_id != actor.id or row.tenant_id != current_tenant)) {
                try ctx.sendErrorResponse(403, 403, "无权删除该文件");
                return;
            }
            self.svc.delete(id) catch |err| {
                try ctx.sendErrorResponse(500, 500, @errorName(err));
                return;
            };
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "ok", .data = null });
        }
    };
}

pub const DefaultFileApi = FileApi(service.FileService, user_svc.UserService);
