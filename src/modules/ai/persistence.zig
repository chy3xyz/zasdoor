//! Persistence over the zent Client — AI platform tables.

const std = @import("std");
const zent = @import("zent");
const crud = zent.crud_helpers;
const model = @import("model.zig");
const schema = @import("../../schema.zig");

const graph = zent.codegen.graph.buildGraph(&.{
    model.AiProvider,
    model.AiSession,
    model.AiMessage,
    model.AiApproval,
    model.AiRun,
});
pub const infos = graph.types;
pub const Client = schema.Client;

pub const ProviderInfo = infos[0];
pub const SessionInfo = infos[1];
pub const MessageInfo = infos[2];
pub const ApprovalInfo = infos[3];
pub const RunInfo = infos[4];

// 单表图,用于逐表迁移(zent migrate 的 comptime 有每调用分支配额)。
pub const provider_infos = zent.codegen.graph.buildGraph(&.{model.AiProvider}).types;
pub const session_infos = zent.codegen.graph.buildGraph(&.{model.AiSession}).types;
pub const message_infos = zent.codegen.graph.buildGraph(&.{model.AiMessage}).types;
pub const approval_infos = zent.codegen.graph.buildGraph(&.{model.AiApproval}).types;
pub const run_infos = zent.codegen.graph.buildGraph(&.{model.AiRun}).types;

// ── Rows ───────────────────────────────────────────────────────────────────

pub const ProviderRow = struct {
    id: i64,
    name: []const u8,
    endpoint: []const u8,
    api_keys_encrypted: []const u8,
    models: []const u8,
    fallback_providers: []const u8,
    enabled: bool,
    created_at: i64,
    updated_at: i64,

    pub fn free(self: ProviderRow, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.endpoint);
        allocator.free(self.api_keys_encrypted);
        allocator.free(self.models);
        allocator.free(self.fallback_providers);
    }
};

pub const SessionRow = struct {
    id: i64,
    user_id: i64,
    tenant_id: i64,
    title: []const u8,
    created_at: i64,
    updated_at: i64,

    pub fn free(self: SessionRow, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
    }
};

pub const MessageRow = struct {
    id: i64,
    session_id: i64,
    role: []const u8,
    content: []const u8,
    reasoning_content: []const u8,
    created_at: i64,

    pub fn free(self: MessageRow, allocator: std.mem.Allocator) void {
        allocator.free(self.role);
        allocator.free(self.content);
        allocator.free(self.reasoning_content);
    }
};

pub const ApprovalRow = struct {
    id: i64,
    session_id: i64,
    requested_by: i64,
    skill_name: []const u8,
    args: []const u8,
    status: []const u8,
    approved_by: i64,
    approved_at: i64,
    created_at: i64,

    pub fn free(self: ApprovalRow, allocator: std.mem.Allocator) void {
        allocator.free(self.skill_name);
        allocator.free(self.args);
        allocator.free(self.status);
    }
};

pub const RunRow = struct {
    id: i64,
    session_id: i64,
    user_id: i64,
    tenant_id: i64,
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

    pub fn free(self: RunRow, allocator: std.mem.Allocator) void {
        allocator.free(self.kind);
        allocator.free(self.prompt);
        allocator.free(self.model);
        allocator.free(self.status);
        allocator.free(self.err);
    }
};

// ── List results ───────────────────────────────────────────────────────────

pub const ProviderListResult = struct {
    items: []ProviderRow,
    total: i64,
    pub fn free(self: *ProviderListResult, allocator: std.mem.Allocator) void {
        for (self.items) |r| r.free(allocator);
        allocator.free(self.items);
    }
};

pub const SessionListResult = struct {
    items: []SessionRow,
    total: i64,
    pub fn free(self: *SessionListResult, allocator: std.mem.Allocator) void {
        for (self.items) |r| r.free(allocator);
        allocator.free(self.items);
    }
};

pub const MessageListResult = struct {
    items: []MessageRow,
    total: i64,
    pub fn free(self: *MessageListResult, allocator: std.mem.Allocator) void {
        for (self.items) |r| r.free(allocator);
        allocator.free(self.items);
    }
};

pub const ApprovalListResult = struct {
    items: []ApprovalRow,
    total: i64,
    pub fn free(self: *ApprovalListResult, allocator: std.mem.Allocator) void {
        for (self.items) |r| r.free(allocator);
        allocator.free(self.items);
    }
};

pub const RunListResult = struct {
    items: []RunRow,
    total: i64,
    pub fn free(self: *RunListResult, allocator: std.mem.Allocator) void {
        for (self.items) |r| r.free(allocator);
        allocator.free(self.items);
    }
};

/// Daily token usage for quota checks (sum by user).
pub const QuotaAgg = struct {
    tokens_in: i64 = 0,
    tokens_out: i64 = 0,
};

// ── Store ──────────────────────────────────────────────────────────────────

pub const AiStore = struct {
    allocator: std.mem.Allocator,
    client: Client,

    pub fn init(allocator: std.mem.Allocator, client: Client) AiStore {
        return .{ .allocator = allocator, .client = client };
    }

    fn dupProvider(self: *AiStore, e: anytype) !ProviderRow {
        const name = try self.allocator.dupe(u8, e.name);
        errdefer self.allocator.free(name);
        const endpoint = try self.allocator.dupe(u8, e.endpoint);
        errdefer self.allocator.free(endpoint);
        const keys = try self.allocator.dupe(u8, e.api_keys_encrypted);
        errdefer self.allocator.free(keys);
        const models = try self.allocator.dupe(u8, e.models);
        errdefer self.allocator.free(models);
        const fb = try self.allocator.dupe(u8, e.fallback_providers);
        errdefer self.allocator.free(fb);
        return .{
            .id = e.id,
            .name = name,
            .endpoint = endpoint,
            .api_keys_encrypted = keys,
            .models = models,
            .fallback_providers = fb,
            .enabled = e.enabled,
            .created_at = e.created_at orelse 0,
            .updated_at = e.updated_at orelse 0,
        };
    }

    fn dupSession(self: *AiStore, e: anytype) !SessionRow {
        const title = try self.allocator.dupe(u8, e.title);
        errdefer self.allocator.free(title);
        return .{
            .id = e.id,
            .user_id = e.user_id,
            .tenant_id = e.tenant_id,
            .title = title,
            .created_at = e.created_at orelse 0,
            .updated_at = e.updated_at orelse 0,
        };
    }

    fn dupMessage(self: *AiStore, e: anytype) !MessageRow {
        const role = try self.allocator.dupe(u8, e.role);
        errdefer self.allocator.free(role);
        const content = try self.allocator.dupe(u8, e.content);
        errdefer self.allocator.free(content);
        const reasoning = try self.allocator.dupe(u8, e.reasoning_content);
        errdefer self.allocator.free(reasoning);
        return .{
            .id = e.id,
            .session_id = e.session_id,
            .role = role,
            .content = content,
            .reasoning_content = reasoning,
            .created_at = e.created_at orelse 0,
        };
    }

    fn dupApproval(self: *AiStore, e: anytype) !ApprovalRow {
        const skill_name = try self.allocator.dupe(u8, e.skill_name);
        errdefer self.allocator.free(skill_name);
        const args = try self.allocator.dupe(u8, e.args);
        errdefer self.allocator.free(args);
        const status = try self.allocator.dupe(u8, e.status);
        errdefer self.allocator.free(status);
        return .{
            .id = e.id,
            .session_id = e.session_id,
            .requested_by = e.requested_by,
            .skill_name = skill_name,
            .args = args,
            .status = status,
            .approved_by = e.approved_by,
            .approved_at = e.approved_at,
            .created_at = e.created_at orelse 0,
        };
    }

    fn dupRun(self: *AiStore, e: anytype) !RunRow {
        const kind = try self.allocator.dupe(u8, e.kind);
        errdefer self.allocator.free(kind);
        const prompt = try self.allocator.dupe(u8, e.prompt);
        errdefer self.allocator.free(prompt);
        const model_name = try self.allocator.dupe(u8, e.model);
        errdefer self.allocator.free(model_name);
        const status = try self.allocator.dupe(u8, e.status);
        errdefer self.allocator.free(status);
        const err = try self.allocator.dupe(u8, e.err_msg);
        errdefer self.allocator.free(err);
        return .{
            .id = e.id,
            .session_id = e.session_id,
            .user_id = e.user_id,
            .tenant_id = e.tenant_id,
            .kind = kind,
            .prompt = prompt,
            .model = model_name,
            .tokens_in = e.tokens_in,
            .tokens_out = e.tokens_out,
            .steps = e.steps,
            .tool_calls = e.tool_calls,
            .tool_errors = e.tool_errors,
            .status = status,
            .err = err,
            .created_at = e.created_at orelse 0,
        };
    }

    // ── Providers ──

    pub fn createProvider(self: *AiStore, name: []const u8, endpoint: []const u8, api_keys_encrypted: []const u8, models: []const u8, fallback_providers: []const u8, enabled: bool, now: i64) !i64 {
        var b = try self.client.ai_provider.Create();
        defer b.deinit();
        _ = try b.setFieldValue("name", name);
        _ = try b.setFieldValue("endpoint", endpoint);
        _ = try b.setFieldValue("api_keys_encrypted", api_keys_encrypted);
        _ = try b.setFieldValue("models", models);
        _ = try b.setFieldValue("fallback_providers", fallback_providers);
        _ = try b.setFieldValue("enabled", enabled);
        _ = try b.setFieldValue("created_at", now);
        _ = try b.setFieldValue("updated_at", now);
        var row = try b.Save();
        defer zent.codegen.deinitEntity(infos, ProviderInfo, &row, self.allocator);
        return row.id;
    }

    pub fn updateProvider(self: *AiStore, id: i64, name: []const u8, endpoint: []const u8, api_keys_encrypted: []const u8, models: []const u8, fallback_providers: []const u8, enabled: bool, now: i64) !void {
        const preds = self.client.ai_provider.predicates;
        var upd = self.client.ai_provider.Update();
        defer upd.deinit();
        _ = try upd.setFieldValue("name", name);
        _ = try upd.setFieldValue("endpoint", endpoint);
        _ = try upd.setFieldValue("api_keys_encrypted", api_keys_encrypted);
        _ = try upd.setFieldValue("models", models);
        _ = try upd.setFieldValue("fallback_providers", fallback_providers);
        _ = try upd.setFieldValue("enabled", enabled);
        _ = try upd.setFieldValue("updated_at", now);
        _ = try upd.Where(.{preds.idEQ(.{ .int = id })});
        _ = try upd.Save();
    }

    pub fn listProviders(self: *AiStore, page: usize, page_size: usize) !ProviderListResult {
        var q = self.client.ai_provider.Query();
        defer q.deinit();
        _ = try q.OrderBy(&[_]zent.sql.Order{.{ .column = .{ .name = "name", .desc = false } }});
        var paged = try q.paged(page, page_size);
        defer paged.deinit();
        var out = try self.allocator.alloc(ProviderRow, paged.items.items.len);
        var n: usize = 0;
        errdefer {
            for (out[0..n]) |r| r.free(self.allocator);
            self.allocator.free(out);
        }
        for (paged.items.items) |e| {
            out[n] = try self.dupProvider(e);
            n += 1;
        }
        return .{ .items = out, .total = paged.total };
    }

    /// zent.crud_helpers.get — 按主键查单行。
    pub fn getProvider(self: *AiStore, id: i64) !?ProviderRow {
        var entity = (try crud.get(self.client.ai_provider, id)) orelse return null;
        defer zent.codegen.deinitEntity(infos, ProviderInfo, &entity, self.allocator);
        return try self.dupProvider(entity);
    }

    pub fn getProviderByName(self: *AiStore, name: []const u8) !?ProviderRow {
        const preds = self.client.ai_provider.predicates;
        var entity = (try crud.first(self.client.ai_provider, .{preds.nameEQ(.{ .string = name })})) orelse return null;
        defer zent.codegen.deinitEntity(infos, ProviderInfo, &entity, self.allocator);
        return try self.dupProvider(entity);
    }

    pub fn deleteProvider(self: *AiStore, id: i64) !void {
        const preds = self.client.ai_provider.predicates;
        var d = self.client.ai_provider.Delete();
        defer d.deinit();
        _ = try d.Where(.{preds.idEQ(.{ .int = id })});
        _ = try d.Exec();
    }

    // ── Sessions ──

    pub fn createSession(self: *AiStore, user_id: i64, tenant_id: i64, title: []const u8, now: i64) !i64 {
        var b = try self.client.ai_session.Create();
        defer b.deinit();
        _ = try b.setFieldValue("user_id", user_id);
        _ = try b.setFieldValue("tenant_id", tenant_id);
        _ = try b.setFieldValue("title", title);
        _ = try b.setFieldValue("created_at", now);
        _ = try b.setFieldValue("updated_at", now);
        var row = try b.Save();
        defer zent.codegen.deinitEntity(infos, SessionInfo, &row, self.allocator);
        return row.id;
    }

    pub fn listSessions(self: *AiStore, user_id: i64, page: usize, page_size: usize) !SessionListResult {
        const preds = self.client.ai_session.predicates;
        var q = self.client.ai_session.Query();
        defer q.deinit();
        _ = try q.Where(.{preds.user_idEQ(.{ .int = user_id })});
        _ = try q.OrderBy(&[_]zent.sql.Order{.{ .column = .{ .name = "updated_at", .desc = true } }});
        var paged = try q.paged(page, page_size);
        defer paged.deinit();
        var out = try self.allocator.alloc(SessionRow, paged.items.items.len);
        var n: usize = 0;
        errdefer {
            for (out[0..n]) |r| r.free(self.allocator);
            self.allocator.free(out);
        }
        for (paged.items.items) |e| {
            out[n] = try self.dupSession(e);
            n += 1;
        }
        return .{ .items = out, .total = paged.total };
    }

    pub fn getSession(self: *AiStore, id: i64, user_id: i64) !?SessionRow {
        const preds = self.client.ai_session.predicates;
        var q = self.client.ai_session.Query();
        defer q.deinit();
        _ = try q.Where(.{preds.idEQ(.{ .int = id })});
        _ = try q.Where(.{preds.user_idEQ(.{ .int = user_id })});
        _ = q.Limit(1);
        var rows = try q.All();
        defer {
            for (rows.items) |*e| zent.codegen.deinitEntity(infos, SessionInfo, e, self.allocator);
            rows.deinit();
        }
        if (rows.items.len == 0) return null;
        return try self.dupSession(rows.items[0]);
    }

    pub fn touchSession(self: *AiStore, id: i64, now: i64) !void {
        const preds = self.client.ai_session.predicates;
        var upd = self.client.ai_session.Update();
        defer upd.deinit();
        _ = try upd.setFieldValue("updated_at", now);
        _ = try upd.Where(.{preds.idEQ(.{ .int = id })});
        _ = try upd.Save();
    }

    pub fn deleteSession(self: *AiStore, id: i64, user_id: i64) !bool {
        // 级联删除该会话的全部消息,避免孤儿数据。
        const mpreds = self.client.ai_message.predicates;
        var dm = self.client.ai_message.Delete();
        defer dm.deinit();
        _ = try dm.Where(.{mpreds.session_idEQ(.{ .int = id })});
        _ = try dm.Exec();

        const preds = self.client.ai_session.predicates;
        var d = self.client.ai_session.Delete();
        defer d.deinit();
        _ = try d.Where(.{preds.idEQ(.{ .int = id })});
        _ = try d.Where(.{preds.user_idEQ(.{ .int = user_id })});
        _ = try d.Exec();
        return true;
    }

    // ── Messages ──

    pub fn addMessage(self: *AiStore, session_id: i64, role: []const u8, content: []const u8, reasoning: []const u8, now: i64) !i64 {
        var b = try self.client.ai_message.Create();
        defer b.deinit();
        _ = try b.setFieldValue("session_id", session_id);
        _ = try b.setFieldValue("role", role);
        _ = try b.setFieldValue("content", content);
        _ = try b.setFieldValue("reasoning_content", reasoning);
        _ = try b.setFieldValue("created_at", now);
        var row = try b.Save();
        defer zent.codegen.deinitEntity(infos, MessageInfo, &row, self.allocator);
        return row.id;
    }

    pub fn listMessages(self: *AiStore, session_id: i64) !MessageListResult {
        const preds = self.client.ai_message.predicates;
        var q = self.client.ai_message.Query();
        defer q.deinit();
        _ = try q.Where(.{preds.session_idEQ(.{ .int = session_id })});
        _ = try q.OrderBy(&[_]zent.sql.Order{.{ .column = .{ .name = "created_at", .desc = false } }});
        var paged = try q.paged(1, 500);
        defer paged.deinit();
        var out = try self.allocator.alloc(MessageRow, paged.items.items.len);
        var n: usize = 0;
        errdefer {
            for (out[0..n]) |r| r.free(self.allocator);
            self.allocator.free(out);
        }
        for (paged.items.items) |e| {
            out[n] = try self.dupMessage(e);
            n += 1;
        }
        return .{ .items = out, .total = paged.total };
    }

    // ── Approvals ──

    pub fn createApproval(self: *AiStore, session_id: i64, requested_by: i64, skill_name: []const u8, args: []const u8, now: i64) !i64 {
        var b = try self.client.ai_approval.Create();
        defer b.deinit();
        _ = try b.setFieldValue("session_id", session_id);
        _ = try b.setFieldValue("requested_by", requested_by);
        _ = try b.setFieldValue("skill_name", skill_name);
        _ = try b.setFieldValue("args", args);
        _ = try b.setFieldValue("status", "pending");
        _ = try b.setFieldValue("approved_by", 0);
        _ = try b.setFieldValue("approved_at", 0);
        _ = try b.setFieldValue("created_at", now);
        var row = try b.Save();
        defer zent.codegen.deinitEntity(infos, ApprovalInfo, &row, self.allocator);
        return row.id;
    }

    pub fn listApprovals(self: *AiStore, status: ?[]const u8, page: usize, page_size: usize) !ApprovalListResult {
        var q = self.client.ai_approval.Query();
        defer q.deinit();
        if (status) |s| {
            if (s.len > 0) {
                const preds = self.client.ai_approval.predicates;
                _ = try q.Where(.{preds.statusEQ(.{ .string = s })});
            }
        }
        _ = try q.OrderBy(&[_]zent.sql.Order{.{ .column = .{ .name = "created_at", .desc = true } }});
        var paged = try q.paged(page, page_size);
        defer paged.deinit();
        var out = try self.allocator.alloc(ApprovalRow, paged.items.items.len);
        var n: usize = 0;
        errdefer {
            for (out[0..n]) |r| r.free(self.allocator);
            self.allocator.free(out);
        }
        for (paged.items.items) |e| {
            out[n] = try self.dupApproval(e);
            n += 1;
        }
        return .{ .items = out, .total = paged.total };
    }

    pub fn getApproval(self: *AiStore, id: i64) !?ApprovalRow {
        const preds = self.client.ai_approval.predicates;
        var q = self.client.ai_approval.Query();
        defer q.deinit();
        _ = try q.Where(.{preds.idEQ(.{ .int = id })});
        _ = q.Limit(1);
        var rows = try q.All();
        defer {
            for (rows.items) |*e| zent.codegen.deinitEntity(infos, ApprovalInfo, e, self.allocator);
            rows.deinit();
        }
        if (rows.items.len == 0) return null;
        return try self.dupApproval(rows.items[0]);
    }

    /// 乐观锁:仅当仍为 pending 时更新,返回受影响行数(0 = 已被并发处理)。
    pub fn resolveApproval(self: *AiStore, id: i64, status: []const u8, approved_by: i64, now: i64) !usize {
        const preds = self.client.ai_approval.predicates;
        var upd = self.client.ai_approval.Update();
        defer upd.deinit();
        _ = try upd.setFieldValue("status", status);
        _ = try upd.setFieldValue("approved_by", approved_by);
        _ = try upd.setFieldValue("approved_at", now);
        _ = try upd.Where(.{preds.idEQ(.{ .int = id })});
        _ = try upd.Where(.{preds.statusEQ(.{ .string = "pending" })});
        return try upd.Save();
    }

    // ── Runs (audit / metrics / quota) ──

    pub fn createRun(self: *AiStore, session_id: i64, user_id: i64, tenant_id: i64, kind: []const u8, prompt: []const u8, model_name: []const u8, tokens_in: i64, tokens_out: i64, steps: i64, tool_calls: i64, tool_errors: i64, status: []const u8, err: []const u8, now: i64) !i64 {
        var b = try self.client.ai_run.Create();
        defer b.deinit();
        _ = try b.setFieldValue("session_id", session_id);
        _ = try b.setFieldValue("user_id", user_id);
        _ = try b.setFieldValue("tenant_id", tenant_id);
        _ = try b.setFieldValue("kind", kind);
        _ = try b.setFieldValue("prompt", prompt);
        _ = try b.setFieldValue("model", model_name);
        _ = try b.setFieldValue("tokens_in", tokens_in);
        _ = try b.setFieldValue("tokens_out", tokens_out);
        _ = try b.setFieldValue("steps", steps);
        _ = try b.setFieldValue("tool_calls", tool_calls);
        _ = try b.setFieldValue("tool_errors", tool_errors);
        _ = try b.setFieldValue("status", status);
        _ = try b.setFieldValue("err_msg", err);
        _ = try b.setFieldValue("created_at", now);
        var row = try b.Save();
        defer zent.codegen.deinitEntity(infos, RunInfo, &row, self.allocator);
        return row.id;
    }

    pub fn listRuns(self: *AiStore, user_id: ?i64, page: usize, page_size: usize) !RunListResult {
        var q = self.client.ai_run.Query();
        defer q.deinit();
        if (user_id) |uid| {
            const preds = self.client.ai_run.predicates;
            _ = try q.Where(.{preds.user_idEQ(.{ .int = uid })});
        }
        _ = try q.OrderBy(&[_]zent.sql.Order{.{ .column = .{ .name = "created_at", .desc = true } }});
        var paged = try q.paged(page, page_size);
        defer paged.deinit();
        var out = try self.allocator.alloc(RunRow, paged.items.items.len);
        var n: usize = 0;
        errdefer {
            for (out[0..n]) |r| r.free(self.allocator);
            self.allocator.free(out);
        }
        for (paged.items.items) |e| {
            out[n] = try self.dupRun(e);
            n += 1;
        }
        return .{ .items = out, .total = paged.total };
    }

    /// Number of runs by `user_id` since `since` (rolling daily quota).
    pub fn runCountForUser(self: *AiStore, user_id: i64, since: i64) !i64 {
        const preds = self.client.ai_run.predicates;
        return try crud.count(self.client.ai_run, .{
            preds.user_idEQ(.{ .int = user_id }),
            preds.created_atGTE(.{ .int = since }),
        });
    }

    /// Sum of tokens consumed by `user_id` since `since` (daily quota).
    /// zent v0.29.4: `Sum` now returns f64 (numeric SUM parses via text
    /// representation) — convert explicitly instead of @intCast.
    pub fn quotaForUser(self: *AiStore, user_id: i64, since: i64) !QuotaAgg {
        const preds = self.client.ai_run.predicates;
        var q = self.client.ai_run.Query();
        defer q.deinit();
        _ = try q.Where(.{preds.user_idEQ(.{ .int = user_id })});
        _ = try q.Where(.{preds.created_atGTE(.{ .int = since })});
        return .{
            .tokens_in = @intFromFloat(try q.Sum("tokens_in")),
            .tokens_out = @intFromFloat(try q.Sum("tokens_out")),
        };
    }
};
