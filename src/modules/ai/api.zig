//! AI HTTP API — provider admin, chat sessions, approvals, runs, metrics.

const std = @import("std");
const zigmodu = @import("zigmodu");
const http = zigmodu.http;
const mw = @import("../../middleware/auth.zig");
const service = @import("service.zig");
const user_svc = @import("../user/service.zig");

const ProviderDto = struct {
    id: i64,
    name: []const u8,
    endpoint: []const u8,
    models: []const u8,
    fallback_providers: []const u8,
    enabled: bool,
    has_keys: bool,
    created_at: i64,
    updated_at: i64,
};

fn toProviderDto(row: service.ProviderRow) ProviderDto {
    return .{
        .id = row.id,
        .name = row.name,
        .endpoint = row.endpoint,
        .models = row.models,
        .fallback_providers = row.fallback_providers,
        .enabled = row.enabled,
        .has_keys = row.api_keys_encrypted.len > 0,
        .created_at = row.created_at,
        .updated_at = row.updated_at,
    };
}

const SessionDto = struct {
    id: i64,
    title: []const u8,
    created_at: i64,
    updated_at: i64,
};

fn toSessionDto(row: service.SessionRow) SessionDto {
    return .{ .id = row.id, .title = row.title, .created_at = row.created_at, .updated_at = row.updated_at };
}

const MessageDto = struct {
    id: i64,
    role: []const u8,
    content: []const u8,
    reasoning_content: []const u8,
    created_at: i64,
};

fn toMessageDto(row: service.MessageRow) MessageDto {
    return .{ .id = row.id, .role = row.role, .content = row.content, .reasoning_content = row.reasoning_content, .created_at = row.created_at };
}

const ApprovalDto = struct {
    id: i64,
    session_id: i64,
    requested_by: i64,
    skill_name: []const u8,
    args: []const u8,
    status: []const u8,
    created_at: i64,
};

fn toApprovalDto(row: service.ApprovalRow) ApprovalDto {
    return .{
        .id = row.id,
        .session_id = row.session_id,
        .requested_by = row.requested_by,
        .skill_name = row.skill_name,
        .args = row.args,
        .status = row.status,
        .created_at = row.created_at,
    };
}

const RunDto = struct {
    id: i64,
    session_id: i64,
    user_id: i64,
    kind: []const u8,
    prompt: []const u8,
    model: []const u8,
    tokens_in: i64,
    tokens_out: i64,
    steps: i64,
    tool_calls: i64,
    tool_errors: i64,
    status: []const u8,
    err: []const u8,
    created_at: i64,
};

fn toRunDto(row: service.RunRow) RunDto {
    return .{
        .id = row.id,
        .session_id = row.session_id,
        .user_id = row.user_id,
        .kind = row.kind,
        .prompt = row.prompt,
        .model = row.model,
        .tokens_in = row.tokens_in,
        .tokens_out = row.tokens_out,
        .steps = row.steps,
        .tool_calls = row.tool_calls,
        .tool_errors = row.tool_errors,
        .status = row.status,
        .err = row.err,
        .created_at = row.created_at,
    };
}

const CreateProviderReq = struct {
    name: []const u8,
    endpoint: []const u8,
    api_keys: []const u8, // JSON array, e.g. ["sk-abc","sk-def"]
    models: []const u8 = "",
    fallback_providers: []const u8 = "",
    enabled: bool = true,
};

const UpdateProviderReq = struct {
    name: ?[]const u8 = null,
    endpoint: ?[]const u8 = null,
    api_keys: ?[]const u8 = null,
    models: ?[]const u8 = null,
    fallback_providers: ?[]const u8 = null,
    enabled: ?bool = null,
};

const ChatReq = struct {
    content: []const u8,
};

const CreateSessionReq = struct {
    title: []const u8 = "",
};

pub fn AiApi(comptime AiSvcT: type, comptime UserService: type) type {
    return struct {
        const Self = @This();
        svc: *AiSvcT,
        user_svc: *UserService,

        pub fn init(svc: *AiSvcT, users: *UserService) Self {
            return .{ .svc = svc, .user_svc = users };
        }

        pub fn registerRoutes(self: *Self, group: *http.RouteGroup) !void {
            // 认证用户可用 AI 助手。
            var g = try group.use(zigmodu.http.http_middleware.jwtAuthWithSecurity(&self.user_svc.sec.module));
            g = try g.use(mw.tokenVersionGuard(self.user_svc.sec, self.user_svc.store));
            try g.get("/ai/sessions", listSessions, @ptrCast(@alignCast(self)));
            try g.post("/ai/sessions", createSession, @ptrCast(@alignCast(self)));
            try g.get("/ai/sessions/{id}/messages", listMessages, @ptrCast(@alignCast(self)));
            try g.post("/ai/sessions/{id}/chat", chat, @ptrCast(@alignCast(self)));
            try g.delete("/ai/sessions/{id}", deleteSession, @ptrCast(@alignCast(self)));

            // 管理端点。
            var a = try group.use(zigmodu.http.http_middleware.jwtAuthWithSecurity(&self.user_svc.sec.module));
            try a.get("/ai/providers", listProviders, @ptrCast(@alignCast(self)));
            try a.post("/ai/providers", createProvider, @ptrCast(@alignCast(self)));
            try a.put("/ai/providers/{id}", updateProvider, @ptrCast(@alignCast(self)));
            try a.delete("/ai/providers/{id}", deleteProvider, @ptrCast(@alignCast(self)));
            try a.post("/ai/providers/{id}/check", checkProvider, @ptrCast(@alignCast(self)));
            try a.get("/ai/approvals", listApprovals, @ptrCast(@alignCast(self)));
            try a.post("/ai/approvals/{id}/approve", approveApproval, @ptrCast(@alignCast(self)));
            try a.post("/ai/approvals/{id}/reject", rejectApproval, @ptrCast(@alignCast(self)));
            try a.get("/ai/runs", listRuns, @ptrCast(@alignCast(self)));
            try a.post("/ai/workflow/run", runWorkflow, @ptrCast(@alignCast(self)));
            try a.get("/ai/metrics", metrics, @ptrCast(@alignCast(self)));
            try a.get("/ai/skills", skills, @ptrCast(@alignCast(self)));
        }

        /// 返回认证用户 ID(401 时已应答)。
        fn authUid(ctx: *http.Context) ?i64 {
            return mw.authUserId(ctx);
        }

        fn requireAdmin(ctx: *http.Context, self: *Self) !?i64 {
            const uid = authUid(ctx) orelse {
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
            if (!row.admin) {
                try ctx.sendErrorResponse(403, 403, "需要管理员权限");
                return null;
            }
            return uid;
        }

        // ── Provider CRUD ──

        fn listProviders(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            _ = (try requireAdmin(ctx, self)) orelse return;
            const params = zigmodu.http.PageParams.parse(ctx, .{ .max_page_size = 100 });
            var result = self.svc.store.listProviders(params.page, params.page_size) catch |err| {
                std.log.err("internal error: {s}", .{@errorName(err)});
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            defer result.free(ctx.allocator);
            const dtos = try zigmodu.http.Extract.toDtoList(ctx.allocator, result.items, ProviderDto, toProviderDto);
            try zigmodu.http.sendPaged(ctx, dtos, @intCast(result.total), params, .ruoyi);
        }

        fn createProvider(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            _ = (try requireAdmin(ctx, self)) orelse return;
            const req = ctx.bindJson(CreateProviderReq) catch {
                try ctx.sendErrorResponse(400, 400, "请求体格式错误");
                return;
            };
            defer {
                ctx.allocator.free(req.name);
                ctx.allocator.free(req.endpoint);
                ctx.allocator.free(req.api_keys);
                if (req.models.len > 0) ctx.allocator.free(req.models);
                if (req.fallback_providers.len > 0) ctx.allocator.free(req.fallback_providers);
            }
            const encrypted = self.svc.encryptKeys(ctx.allocator, req.api_keys) catch |err| switch (err) {
                error.MissingKeySecret => {
                    try ctx.sendErrorResponse(400, 400, "未配置 ZENAIPA_AI_KEY_SECRET,无法保存密钥");
                    return;
                },
                else => {
                    std.log.err("internal error: {s}", .{@errorName(err)});
                    try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                    return;
                },
            };
            defer ctx.allocator.free(encrypted);
            const now = zigmodu.time.wallClockSeconds(self.svc.io);
            const id = self.svc.store.createProvider(req.name, req.endpoint, encrypted, req.models, req.fallback_providers, req.enabled, now) catch |err| {
                std.log.err("internal error: {s}", .{@errorName(err)});
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            try ctx.jsonStruct(201, .{ .code = 0, .msg = "Provider 已创建", .data = .{ .id = id } });
        }

        fn updateProvider(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            _ = (try requireAdmin(ctx, self)) orelse return;
            const id = ctx.paramInt(i64, "id") catch {
                try ctx.sendErrorResponse(400, 400, "无效的 Provider ID");
                return;
            };
            const cur_opt = self.svc.store.getProvider(id) catch {
                try ctx.sendErrorResponse(500, 500, "服务器错误");
                return;
            };
            const cur = cur_opt orelse {
                try ctx.sendErrorResponse(404, 404, "Provider 不存在");
                return;
            };
            defer cur.free(ctx.allocator);

            const req = ctx.bindJson(UpdateProviderReq) catch {
                try ctx.sendErrorResponse(400, 400, "请求体格式错误");
                return;
            };
            defer {
                if (req.name) |v| ctx.allocator.free(v);
                if (req.endpoint) |v| ctx.allocator.free(v);
                if (req.api_keys) |v| ctx.allocator.free(v);
                if (req.models) |v| ctx.allocator.free(v);
                if (req.fallback_providers) |v| ctx.allocator.free(v);
            }

            var encrypted: []const u8 = cur.api_keys_encrypted;
            var encrypted_owned: ?[]u8 = null;
            defer if (encrypted_owned) |e| ctx.allocator.free(e);
            if (req.api_keys) |keys| {
                if (keys.len > 0) {
                    encrypted_owned = self.svc.encryptKeys(ctx.allocator, keys) catch |err| switch (err) {
                        error.MissingKeySecret => {
                            try ctx.sendErrorResponse(400, 400, "未配置 ZENAIPA_AI_KEY_SECRET,无法保存密钥");
                            return;
                        },
                        else => {
                            std.log.err("internal error: {s}", .{@errorName(err)});
                            try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                            return;
                        },
                    };
                    encrypted = encrypted_owned.?;
                }
            }

            const now = zigmodu.time.wallClockSeconds(self.svc.io);
            self.svc.store.updateProvider(
                id,
                req.name orelse cur.name,
                req.endpoint orelse cur.endpoint,
                encrypted,
                req.models orelse cur.models,
                req.fallback_providers orelse cur.fallback_providers,
                req.enabled orelse cur.enabled,
                now,
            ) catch |err| {
                std.log.err("internal error: {s}", .{@errorName(err)});
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "ok", .data = null });
        }

        fn deleteProvider(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            _ = (try requireAdmin(ctx, self)) orelse return;
            const id = ctx.paramInt(i64, "id") catch {
                try ctx.sendErrorResponse(400, 400, "无效的 Provider ID");
                return;
            };
            self.svc.store.deleteProvider(id) catch |err| {
                std.log.err("internal error: {s}", .{@errorName(err)});
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "ok", .data = null });
        }

        // ── Sessions / chat ──

        fn listSessions(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const uid = authUid(ctx) orelse {
                try ctx.sendErrorResponse(401, 401, "未登录或登录已过期");
                return;
            };
            const params = zigmodu.http.PageParams.parse(ctx, .{ .max_page_size = 100 });
            var result = self.svc.store.listSessions(uid, params.page, params.page_size) catch |err| {
                std.log.err("internal error: {s}", .{@errorName(err)});
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            defer result.free(ctx.allocator);
            const dtos = try zigmodu.http.Extract.toDtoList(ctx.allocator, result.items, SessionDto, toSessionDto);
            try zigmodu.http.sendPaged(ctx, dtos, @intCast(result.total), params, .ruoyi);
        }

        fn createSession(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const uid = authUid(ctx) orelse {
                try ctx.sendErrorResponse(401, 401, "未登录或登录已过期");
                return;
            };
            const req = ctx.bindJson(CreateSessionReq) catch {
                try ctx.sendErrorResponse(400, 400, "请求体格式错误");
                return;
            };
            defer if (req.title.len > 0) ctx.allocator.free(req.title);
            const tenant_id = mw.authTenantId(ctx) orelse 1;
            const now = zigmodu.time.wallClockSeconds(self.svc.io);
            const id = try self.svc.store.createSession(uid, tenant_id, req.title, now);
            try ctx.jsonStruct(201, .{ .code = 0, .msg = "ok", .data = .{ .id = id } });
        }

        fn listMessages(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const uid = authUid(ctx) orelse {
                try ctx.sendErrorResponse(401, 401, "未登录或登录已过期");
                return;
            };
            const sid = ctx.paramInt(i64, "id") catch {
                try ctx.sendErrorResponse(400, 400, "无效的会话 ID");
                return;
            };
            const session = (self.svc.store.getSession(sid, uid) catch null) orelse {
                try ctx.sendErrorResponse(404, 404, "会话不存在");
                return;
            };
            defer session.free(ctx.allocator);
            var result = self.svc.store.listMessages(sid) catch |err| {
                std.log.err("internal error: {s}", .{@errorName(err)});
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            defer result.free(ctx.allocator);
            const dtos = try zigmodu.http.Extract.toDtoList(ctx.allocator, result.items, MessageDto, toMessageDto);
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "", .data = .{ .list = dtos, .total = result.total } });
        }

        fn chat(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const uid = authUid(ctx) orelse {
                try ctx.sendErrorResponse(401, 401, "未登录或登录已过期");
                return;
            };
            const sid = ctx.paramInt(i64, "id") catch {
                try ctx.sendErrorResponse(400, 400, "无效的会话 ID");
                return;
            };
            const session = (self.svc.store.getSession(sid, uid) catch null) orelse {
                try ctx.sendErrorResponse(404, 404, "会话不存在");
                return;
            };
            defer session.free(ctx.allocator);

            const req = ctx.bindJson(ChatReq) catch {
                try ctx.sendErrorResponse(400, 400, "请求体格式错误");
                return;
            };
            defer ctx.allocator.free(req.content);
            const content = std.mem.trim(u8, req.content, " \t\n");
            if (content.len == 0) {
                try ctx.sendErrorResponse(400, 400, "消息不能为空");
                return;
            }

            const now = zigmodu.time.wallClockSeconds(self.svc.io);
            _ = self.svc.store.addMessage(sid, "user", content, "", now) catch {};

            // SSE 流式模式:Accept: text/event-stream → 旁路推送 reasoning/delta,结束发 done。
            const stream_req = std.mem.eql(u8, ctx.header("Accept") orelse "", "text/event-stream");
            var outcome = if (stream_req) blk: {
                var sse = try zigmodu.http.SseWriter.init(ctx);
                const StreamState = struct {
                    sse: *zigmodu.http.SseWriter,
                };
                var st = StreamState{ .sse = &sse };
                const on_delta = struct {
                    fn cb(c: ?*anyopaque, d: zigmodu.ai.AiProvider.StreamDelta) anyerror!void {
                        const s: *StreamState = @ptrCast(@alignCast(c.?));
                        if (d.reasoning_delta) |rd| try s.sse.sendEvent("reasoning", rd);
                        if (d.content_delta) |cd| try s.sse.sendEvent("delta", cd);
                    }
                }.cb;
                break :blk self.svc.chat(ctx.allocator, sid, uid, session.tenant_id, content, on_delta, &st) catch |err| {
                    try sse.sendEvent("error", @errorName(err));
                    try sse.done();
                    return;
                };
            } else self.svc.chat(ctx.allocator, sid, uid, session.tenant_id, content, null, null) catch |err| switch (err) {
                error.NoAiProvider => {
                    try ctx.sendErrorResponse(503, 503, "未配置可用的 AI Provider");
                    return;
                },
                error.QuotaExceeded => {
                    try ctx.sendErrorResponse(429, 429, "今日 AI 调用次数已达上限");
                    return;
                },
                error.AiCircuitOpen => {
                    try ctx.sendErrorResponse(503, 503, "AI 服务暂不可用(熔断保护中)");
                    return;
                },
                else => {
                    const msg = try std.fmt.allocPrint(ctx.allocator, "AI 服务调用失败: {s}", .{@errorName(err)});
                    defer ctx.allocator.free(msg);
                    try ctx.sendErrorResponse(502, 502, msg);
                    return;
                },
            };
            defer outcome.free(ctx.allocator);

            if (stream_req) {
                var sse2 = try zigmodu.http.SseWriter.init(ctx);
                const done_json = try std.json.Stringify.valueAlloc(ctx.allocator, .{
                    .answer = outcome.answer,
                    .reasoning_content = outcome.reasoning,
                    .budget_exhausted = outcome.budget_exhausted,
                }, .{});
                defer ctx.allocator.free(done_json);
                try sse2.sendEvent("done", done_json);
                try sse2.done();
            }

            _ = self.svc.store.addMessage(sid, "assistant", outcome.answer, outcome.reasoning, now) catch {};
            _ = self.svc.store.touchSession(sid, now) catch {};
            try ctx.jsonStruct(200, .{
                .code = 0,
                .msg = "",
                .data = .{
                    .answer = outcome.answer,
                    .reasoning_content = outcome.reasoning,
                    .budget_exhausted = outcome.budget_exhausted,
                },
            });
        }

        fn deleteSession(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const uid = authUid(ctx) orelse {
                try ctx.sendErrorResponse(401, 401, "未登录或登录已过期");
                return;
            };
            const sid = ctx.paramInt(i64, "id") catch {
                try ctx.sendErrorResponse(400, 400, "无效的会话 ID");
                return;
            };
            _ = self.svc.store.deleteSession(sid, uid) catch |err| {
                std.log.err("internal error: {s}", .{@errorName(err)});
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "ok", .data = null });
        }

        fn checkProvider(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            _ = (try requireAdmin(ctx, self)) orelse return;
            const id = ctx.paramInt(i64, "id") catch {
                try ctx.sendErrorResponse(400, 400, "无效的 Provider ID");
                return;
            };
            const result = self.svc.checkProvider(ctx.allocator, id) catch |err| switch (err) {
                error.ProviderNotFound => {
                    try ctx.sendErrorResponse(404, 404, "Provider 不存在");
                    return;
                },
                error.ProviderDisabled => {
                    try ctx.sendErrorResponse(400, 400, "Provider 已停用");
                    return;
                },
                error.EmptyApiKeys => {
                    try ctx.sendErrorResponse(400, 400, "Provider 未配置密钥");
                    return;
                },
                error.EmptyModel => {
                    try ctx.sendErrorResponse(400, 400, "Provider 未配置模型");
                    return;
                },
                else => {
                    const msg = try std.fmt.allocPrint(ctx.allocator, "连接失败: {s}", .{@errorName(err)});
                    defer ctx.allocator.free(msg);
                    try ctx.sendErrorResponse(502, 502, msg);
                    return;
                },
            };
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "", .data = .{ .status = result } });
        }

        // ── Approvals / runs / metrics ──

        fn listApprovals(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            _ = (try requireAdmin(ctx, self)) orelse return;
            const params = zigmodu.http.PageParams.parse(ctx, .{ .max_page_size = 100 });
            const status = ctx.queryParam("status");
            var result = self.svc.store.listApprovals(status, params.page, params.page_size) catch |err| {
                std.log.err("internal error: {s}", .{@errorName(err)});
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            defer result.free(ctx.allocator);
            const dtos = try zigmodu.http.Extract.toDtoList(ctx.allocator, result.items, ApprovalDto, toApprovalDto);
            try zigmodu.http.sendPaged(ctx, dtos, @intCast(result.total), params, .ruoyi);
        }

        fn resolveApproval(ctx: *http.Context, approve: bool) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const admin_id = (try requireAdmin(ctx, self)) orelse return;
            const id = ctx.paramInt(i64, "id") catch {
                try ctx.sendErrorResponse(400, 400, "无效的审批 ID");
                return;
            };
            const done = self.svc.approve(ctx.allocator, id, admin_id, approve) catch |err| {
                std.log.err("internal error: {s}", .{@errorName(err)});
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            if (!done) {
                try ctx.sendErrorResponse(409, 409, "审批已处理");
                return;
            }
            try ctx.jsonStruct(200, .{ .code = 0, .msg = if (approve) "已批准" else "已拒绝", .data = null });
        }

        fn approveApproval(ctx: *http.Context) !void {
            try resolveApproval(ctx, true);
        }

        fn rejectApproval(ctx: *http.Context) !void {
            try resolveApproval(ctx, false);
        }

        fn listRuns(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            _ = (try requireAdmin(ctx, self)) orelse return;
            const params = zigmodu.http.PageParams.parse(ctx, .{ .max_page_size = 100 });
            const uid = ctx.queryInt(i64, "user_id", 0);
            var result = self.svc.store.listRuns(if (uid > 0) uid else null, params.page, params.page_size) catch |err| {
                std.log.err("internal error: {s}", .{@errorName(err)});
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            defer result.free(ctx.allocator);
            const dtos = try zigmodu.http.Extract.toDtoList(ctx.allocator, result.items, RunDto, toRunDto);
            try zigmodu.http.sendPaged(ctx, dtos, @intCast(result.total), params, .ruoyi);
        }

        fn runWorkflow(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            const admin_id = (try requireAdmin(ctx, self)) orelse return;
            const tenant_id = mw.authTenantId(ctx) orelse 1;

            var result = self.svc.runHealthWorkflow(ctx.allocator, admin_id, tenant_id) catch |err| {
                std.log.err("internal error: {s}", .{@errorName(err)});
                try ctx.sendErrorResponse(500, 500, "服务器内部错误");
                return;
            };
            defer result.deinit();

            const WorkflowStepOut = struct {
                name: []const u8,
                status: []const u8,
                output: []const u8,
            };
            var outs = try ctx.allocator.alloc(WorkflowStepOut, result.steps.items.len);
            defer ctx.allocator.free(outs);
            for (result.steps.items, 0..) |rec, i| {
                outs[i] = .{
                    .name = rec.name,
                    .status = @tagName(rec.status),
                    .output = rec.output,
                };
            }
            const status_str = @tagName(result.status);
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "", .data = .{ .status = status_str, .steps = outs[0..] } });
        }

        fn metrics(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            _ = (try requireAdmin(ctx, self)) orelse return;
            // 用逐字段 atomic load 组装的快照渲染,避免与并发 chat 写回 agent_metrics 竞争。
            var snapshot = self.svc.currentAgentMetrics();
            var ai_metrics = zigmodu.ai.observability.AiMetrics{ .agent = &snapshot };
            const body = try ai_metrics.toPrometheusFormat(ctx.allocator);
            defer ctx.allocator.free(body);
            try ctx.text(200, body);
        }

        fn skills(ctx: *http.Context) !void {
            const self: *Self = @ptrCast(@alignCast(ctx.user_data orelse return error.UnexpectedError));
            _ = (try requireAdmin(ctx, self)) orelse return;
            // 技能目录(名称切片;std.json 0.17 对裸 ArrayList 无序列化分支)。
            const names = [_][]const u8{ "zenaipa.user.search", "zenaipa.task.stats", "zenaipa.audit.search", "zenaipa.tenant.list", "zenaipa.notify.send" };
            try ctx.jsonStruct(200, .{ .code = 0, .msg = "", .data = .{ .skills = names[0..] } });
        }
    };
}

pub const DefaultAiApi = AiApi(service.AiService, user_svc.UserService);
