//! AI service — provider management (encrypted keys), platform skills,
//! agentic chat, human approvals and run/quota tracking.
//!
//! Reuses zigmodu.ai's in-memory facilities (KeyManager-style provider,
//! SkillRegistry, Agent, Budget, metrics); persistence (providers, sessions,
//! messages, approvals, runs) lives in zent tables.

const std = @import("std");
const zigmodu = @import("zigmodu");
const persist = @import("persistence.zig");

const ai = zigmodu.ai;
const user_persist = @import("../user/persistence.zig");
const task_persist = @import("../task/persistence.zig");
const audit_persist = @import("../audit/persistence.zig");
const tenant_persist = @import("../tenant/persistence.zig");
const notify_svc_mod = @import("../notify/service.zig");

pub const ProviderRow = persist.ProviderRow;
pub const SessionRow = persist.SessionRow;
pub const MessageRow = persist.MessageRow;
pub const ApprovalRow = persist.ApprovalRow;
pub const RunRow = persist.RunRow;
pub const ProviderListResult = persist.ProviderListResult;
pub const SessionListResult = persist.SessionListResult;
pub const MessageListResult = persist.MessageListResult;
pub const ApprovalListResult = persist.ApprovalListResult;
pub const RunListResult = persist.RunListResult;

/// Permission code granted to admin users (checked by skills).
pub const PERM_ADMIN = "admin";

pub const AiConfig = struct {
    /// Master key (ZENAIPA_AI_KEY_SECRET) used to encrypt stored API keys.
    key_secret: []const u8,
    /// Max agent runs per user per rolling 24h (quota).
    daily_run_limit: i64 = 100,
    default_max_steps: usize = 5,
    tool_timeout_ms: u64 = 10_000,
};

/// Business-store references injected into skill handlers via `SkillContext.userdata`.
pub const SkillsRefs = struct {
    user_store: *user_persist.UserStore,
    task_store: *task_persist.TaskStore,
    audit_store: *audit_persist.AuditStore,
    tenant_store: *tenant_persist.TenantStore,
    ai_store: *persist.AiStore,
    notify_svc: *notify_svc_mod.NotificationService,
};

pub const ChatOutcome = struct {
    answer: []u8,
    reasoning: []u8,
    budget_exhausted: bool,

    pub fn free(self: ChatOutcome, allocator: std.mem.Allocator) void {
        allocator.free(self.answer);
        allocator.free(self.reasoning);
    }
};

/// 本次 run 的 Agent 用量增量(由前后两次 `AgentMetrics.toStats()` 快照相减)。
pub const UsageDelta = struct {
    runs: usize = 0,
    steps: usize = 0,
    tool_calls: usize = 0,
    tool_errors: usize = 0,
    tool_denied: usize = 0,
    max_steps_hits: usize = 0,
    budget_exhausted: usize = 0,
    canceled: usize = 0,
};

/// 纯函数:本次 run 用量 = 运行后累计快照 − 运行前累计快照
/// (同一累加器单调递增,差值非负;避免逐字段 .load 与 {d} 传 atomic 的编译错误)。
pub fn usageDelta(before: ai.AgentMetrics.Stats, after: ai.AgentMetrics.Stats) UsageDelta {
    return .{
        .runs = after.runs - before.runs,
        .steps = after.steps - before.steps,
        .tool_calls = after.tool_calls - before.tool_calls,
        .tool_errors = after.tool_errors - before.tool_errors,
        .tool_denied = after.tool_denied - before.tool_denied,
        .max_steps_hits = after.max_steps_hits - before.max_steps_hits,
        .budget_exhausted = after.budget_exhausted - before.budget_exhausted,
        .canceled = after.canceled - before.canceled,
    };
}

pub const AiService = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *persist.AiStore,
    cfg: AiConfig,
    http: zigmodu.http.HttpClient,
    registry: ai.SkillRegistry,
    agent_metrics: ai.AgentMetrics,
    bulkhead: zigmodu.Bulkhead,
    /// AI provider 熔断:连续失败达到阈值后快速失败,避免拖垮上游。
    breaker: zigmodu.CircuitBreaker,
    refs: SkillsRefs,

    /// 读取当前累计值组装 AgentMetrics 快照(逐字段 atomic load,无锁;供
    /// run 起点与 /metrics 渲染使用,避免整 struct 拷贝与并发写回竞争)。
    pub fn currentAgentMetrics(self: *AiService) ai.AgentMetrics {
        const s = self.agent_metrics.toStats();
        return .{
            .runs = .init(s.runs),
            .steps = .init(s.steps),
            .tool_calls = .init(s.tool_calls),
            .tool_errors = .init(s.tool_errors),
            .tool_denied = .init(s.tool_denied),
            .max_steps_hits = .init(s.max_steps_hits),
            .budget_exhausted = .init(s.budget_exhausted),
            .canceled = .init(s.canceled),
        };
    }

    /// 原子累加本次 run 的用量增量。AgentMetrics 字段均为 atomic.Value,
    /// 逐字段 fetchAdd 无锁且并发安全(整 struct 覆盖写回会丢增量/回退,
    /// 故不采用)。
    pub fn addAgentMetrics(self: *AiService, d: UsageDelta) void {
        _ = self.agent_metrics.runs.fetchAdd(d.runs, .monotonic);
        _ = self.agent_metrics.steps.fetchAdd(d.steps, .monotonic);
        _ = self.agent_metrics.tool_calls.fetchAdd(d.tool_calls, .monotonic);
        _ = self.agent_metrics.tool_errors.fetchAdd(d.tool_errors, .monotonic);
        _ = self.agent_metrics.tool_denied.fetchAdd(d.tool_denied, .monotonic);
        _ = self.agent_metrics.max_steps_hits.fetchAdd(d.max_steps_hits, .monotonic);
        _ = self.agent_metrics.budget_exhausted.fetchAdd(d.budget_exhausted, .monotonic);
        _ = self.agent_metrics.canceled.fetchAdd(d.canceled, .monotonic);
    }

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        store: *persist.AiStore,
        cfg: AiConfig,
        refs: SkillsRefs,
    ) !AiService {
        var self = AiService{
            .allocator = allocator,
            .io = io,
            .store = store,
            .cfg = cfg,
            .http = zigmodu.http.HttpClient.init(allocator, io, 4, 30_000),
            .registry = ai.SkillRegistry.init(allocator, io),
            .agent_metrics = .{},
            .bulkhead = try zigmodu.Bulkhead.init(allocator, "ai-chat", 4, 16),
            .breaker = try zigmodu.CircuitBreaker.init(allocator, "ai-provider", .{
                .failure_threshold = 5,
                .success_threshold = 2,
                .timeout_seconds = 60,
                .half_open_max_calls = 2,
            }),
            .refs = refs,
        };
        errdefer self.registry.deinit();
        try self.registerSkills();
        return self;
    }

    pub fn deinit(self: *AiService) void {
        self.registry.deinit();
        self.http.deinit();
        self.bulkhead.deinit();
        self.breaker.deinit();
    }

    // ── Key encryption ─────────────────────────────────────────────────────

    const KeyLen = 32;
    const NonceLen = 12;
    const TagLen = 16;

    /// AES-256-GCM over the key secret's SHA-256 digest. Output layout:
    /// `nonce || tag || ciphertext` (base64). Returns error.MissingKeySecret
    /// when no master key is configured.
    pub fn encryptKeys(self: *AiService, allocator: std.mem.Allocator, plain: []const u8) ![]u8 {
        if (self.cfg.key_secret.len == 0) return error.MissingKeySecret;
        var key: [KeyLen]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(self.cfg.key_secret, &key, .{});

        var nonce: [NonceLen]u8 = undefined;
        fillRandom(self.io, &nonce);
        const tag_len = TagLen;
        const raw_len = NonceLen + tag_len + plain.len;
        const raw = try allocator.alloc(u8, raw_len);
        errdefer allocator.free(raw);
        std.crypto.aead.aes_gcm.Aes256Gcm.encrypt(raw[NonceLen + tag_len ..], raw[NonceLen..][0..tag_len], plain, "", nonce, key);
        @memcpy(raw[0..NonceLen], &nonce);

        const b64 = std.base64.standard.Encoder.calcSize(raw.len);
        const out = try allocator.alloc(u8, b64);
        defer allocator.free(raw);
        _ = std.base64.standard.Encoder.encode(out, raw);
        return out;
    }

    /// Reverse of `encryptKeys`. Returns error.AuthenticationFailed on
    /// tampering/wrong secret, error.MissingKeySecret when no master key set.
    pub fn decryptKeys(self: *AiService, allocator: std.mem.Allocator, cipher_b64: []const u8) ![]u8 {
        if (self.cfg.key_secret.len == 0) return error.MissingKeySecret;
        var key: [KeyLen]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(self.cfg.key_secret, &key, .{});

        const raw_len = std.base64.standard.Decoder.calcSizeForSlice(cipher_b64) catch return error.InvalidCipher;
        const raw = try allocator.alloc(u8, raw_len);
        defer allocator.free(raw);
        _ = std.base64.standard.Decoder.decode(raw, cipher_b64) catch return error.InvalidCipher;
        if (raw.len < NonceLen + TagLen) return error.InvalidCipher;

        const nonce: [NonceLen]u8 = raw[0..NonceLen].*;
        const tag: [TagLen]u8 = raw[NonceLen..][0..TagLen].*;
        const out = try allocator.alloc(u8, raw.len - NonceLen - TagLen);
        errdefer allocator.free(out);
        std.crypto.aead.aes_gcm.Aes256Gcm.decrypt(out, raw[NonceLen + TagLen ..], tag, "", nonce, key) catch return error.AuthenticationFailed;
        return out;
    }

    // ── Provider resolution ────────────────────────────────────────────────

    /// Resolve the first enabled provider + decrypt its first key. Caller
    /// owns `keys_json` (the decrypted JSON array) and must free it after the
    /// provider is used; `endpoint`/`model` borrow from `row` (caller-owned).
    pub fn resolveProvider(self: *AiService, allocator: std.mem.Allocator) !?struct {
        row: ProviderRow,
        keys_json: []u8,
        key: []const u8,
        model: []const u8,
    } {
        var list = try self.store.listProviders(1, 100);
        defer list.free(allocator);
        var chosen: ?ProviderRow = null;
        for (list.items) |r| {
            if (r.enabled) {
                chosen = r;
                break;
            }
        }
        const row = chosen orelse return null;
        errdefer row.free(allocator);

        const keys_json = try self.decryptKeys(allocator, row.api_keys_encrypted);
        errdefer allocator.free(keys_json);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, keys_json, .{});
        defer parsed.deinit();
        const keys_arr = parsed.value.array.items;
        if (keys_arr.len == 0) return error.EmptyApiKeys;

        var model: []const u8 = "";
        var it = std.mem.splitScalar(u8, row.models, ',');
        while (it.next()) |m| {
            if (m.len > 0) {
                model = m;
                break;
            }
        }
        // `.key` 必须复制:parseFromSlice 的字符串在含转义字符时由 arena
        // 持有,`parsed.deinit()` 后即悬垂;始终 dupe 一份由调用方管理。
        const key = try allocator.dupe(u8, keys_arr[0].string);
        errdefer allocator.free(key);
        return .{
            .row = row,
            .keys_json = keys_json,
            .key = key,
            .model = model,
        };
    }

    // ── Skills ─────────────────────────────────────────────────────────────

    fn registerSkills(self: *AiService) !void {
        const tools = [_]ai.Tool{
            .{
                .name = "zenaipa.user.search",
                .description = "按关键词搜索平台用户,返回 ID/姓名/邮箱/角色/租户",
                .parameters = &.{
                    .{ .name = "keyword", .type = .string, .description = "姓名或邮箱关键词", .required = true },
                },
                .required_permission = PERM_ADMIN,
                .handler = skillUserSearch,
            },
            .{
                .name = "zenaipa.task.stats",
                .description = "获取后台任务队列统计(pending/claimed/done/failed/canceled)",
                .parameters = &.{},
                .required_permission = PERM_ADMIN,
                .handler = skillTaskStats,
            },
            .{
                .name = "zenaipa.audit.search",
                .description = "按操作类型/关键词检索审计日志(最近 limit 条)",
                .parameters = &.{
                    .{ .name = "action", .type = .string, .description = "操作类型前缀,如 user.", .required = false },
                    .{ .name = "keyword", .type = .string, .description = "详情关键词", .required = false },
                    .{ .name = "limit", .type = .number, .description = "返回条数(1-50,默认10)", .required = false },
                },
                .required_permission = PERM_ADMIN,
                .handler = skillAuditSearch,
            },
            .{
                .name = "zenaipa.tenant.list",
                .description = "列出全部租户(ID/名称/状态)",
                .parameters = &.{},
                .required_permission = PERM_ADMIN,
                .handler = skillTenantList,
            },
            .{
                .name = "zenaipa.notify.send",
                .description = "向指定用户发送站内通知(需管理员审批)",
                .parameters = &.{
                    .{ .name = "user_id", .type = .number, .description = "目标用户 ID", .required = true },
                    .{ .name = "title", .type = .string, .description = "标题", .required = true },
                    .{ .name = "body", .type = .string, .description = "正文", .required = true },
                    .{ .name = "kind", .type = .string, .description = "info/success/warning/error", .required = false },
                },
                .required_permission = PERM_ADMIN,
                .handler = skillNotifySend,
            },
        };
        for (tools) |t| try self.registry.register(t);
    }

    fn refsOf(ctx: *ai.SkillContext) !*SkillsRefs {
        return @ptrCast(@alignCast(ctx.userdata orelse return error.MissingSkillContext));
    }

    /// 安全读取对象字段:存在但类型不符返回 error.InvalidArgs
    /// (LLM 经 prompt 注入可能传任意 JSON 类型,禁止直接访问 tag)。
    fn objString(args: std.json.Value, key: []const u8) ?[]const u8 {
        const v = args.object.get(key) orelse return null;
        return if (v == .string) v.string else null;
    }

    fn objInt(args: std.json.Value, key: []const u8) ?i64 {
        const v = args.object.get(key) orelse return null;
        return if (v == .integer) v.integer else null;
    }

    fn jsonOk(allocator: std.mem.Allocator, obj: std.json.ObjectMap) anyerror!std.json.Value {
        try obj.put(allocator, try allocator.dupe(u8, "ok"), .{ .boolean = true });
        return .{ .object = obj };
    }

    fn skillUserSearch(ctx: *ai.SkillContext, args: std.json.Value) anyerror!std.json.Value {
        try ctx.checkDeadline();
        const refs = try refsOf(ctx);
        const kw = objString(args, "keyword") orelse return error.InvalidArgs;
        var result = try refs.user_store.listUsers(1, 20, kw, null, null, false);
        defer result.free(ctx.allocator);

        var arr = std.json.Array.init(ctx.allocator);
        for (result.items) |u| {
            var o = std.json.ObjectMap{};
            try o.put(ctx.allocator, try ctx.allocator.dupe(u8, "id"), .{ .integer = u.id });
            try o.put(ctx.allocator, try ctx.allocator.dupe(u8, "name"), .{ .string = try ctx.allocator.dupe(u8, u.name) });
            try o.put(ctx.allocator, try ctx.allocator.dupe(u8, "email"), .{ .string = try ctx.allocator.dupe(u8, u.email) });
            try o.put(ctx.allocator, try ctx.allocator.dupe(u8, "admin"), .{ .bool = u.admin });
            try o.put(ctx.allocator, try ctx.allocator.dupe(u8, "tenant_id"), .{ .integer = u.tenant_id });
            try arr.append(.{ .object = o });
        }
        var obj = std.json.ObjectMap{};
        try obj.put(ctx.allocator, try ctx.allocator.dupe(u8, "total"), .{ .integer = result.total });
        try obj.put(ctx.allocator, try ctx.allocator.dupe(u8, "users"), .{ .array = arr });
        return .{ .object = obj };
    }

    fn skillTaskStats(ctx: *ai.SkillContext, _: std.json.Value) anyerror!std.json.Value {
        try ctx.checkDeadline();
        const refs = try refsOf(ctx);
        const c = try refs.task_store.countByStatus();
        var obj = std.json.ObjectMap{};
        try obj.put(ctx.allocator, try ctx.allocator.dupe(u8, "pending"), .{ .integer = c.pending });
        try obj.put(ctx.allocator, try ctx.allocator.dupe(u8, "claimed"), .{ .integer = c.claimed });
        try obj.put(ctx.allocator, try ctx.allocator.dupe(u8, "done"), .{ .integer = c.done });
        try obj.put(ctx.allocator, try ctx.allocator.dupe(u8, "failed"), .{ .integer = c.failed });
        try obj.put(ctx.allocator, try ctx.allocator.dupe(u8, "canceled"), .{ .integer = c.canceled });
        return .{ .object = obj };
    }

    fn skillAuditSearch(ctx: *ai.SkillContext, args: std.json.Value) anyerror!std.json.Value {
        try ctx.checkDeadline();
        const refs = try refsOf(ctx);
        const action = objString(args, "action");
        const keyword = objString(args, "keyword");
        var limit: usize = 10;
        if (objInt(args, "limit")) |n| {
            if (n > 0) limit = @intCast(@min(n, 50));
        }
        var result = try refs.audit_store.list(1, limit, .{ .action = action, .keyword = keyword });
        defer result.free(ctx.allocator);

        var arr = std.json.Array.init(ctx.allocator);
        for (result.items) |r| {
            var o = std.json.ObjectMap{};
            try o.put(ctx.allocator, try ctx.allocator.dupe(u8, "id"), .{ .integer = r.id });
            try o.put(ctx.allocator, try ctx.allocator.dupe(u8, "action"), .{ .string = try ctx.allocator.dupe(u8, r.action) });
            try o.put(ctx.allocator, try ctx.allocator.dupe(u8, "actor"), .{ .string = try ctx.allocator.dupe(u8, r.actor_name) });
            try o.put(ctx.allocator, try ctx.allocator.dupe(u8, "detail"), .{ .string = try ctx.allocator.dupe(u8, r.detail) });
            try arr.append(.{ .object = o });
        }
        var obj = std.json.ObjectMap{};
        try obj.put(ctx.allocator, try ctx.allocator.dupe(u8, "total"), .{ .integer = result.total });
        try obj.put(ctx.allocator, try ctx.allocator.dupe(u8, "entries"), .{ .array = arr });
        return .{ .object = obj };
    }

    fn skillTenantList(ctx: *ai.SkillContext, _: std.json.Value) anyerror!std.json.Value {
        try ctx.checkDeadline();
        const refs = try refsOf(ctx);
        var result = try refs.tenant_store.list(1, 100);
        defer result.free(ctx.allocator);

        var arr = std.json.Array.init(ctx.allocator);
        for (result.items) |t| {
            var o = std.json.ObjectMap{};
            try o.put(ctx.allocator, try ctx.allocator.dupe(u8, "id"), .{ .integer = t.id });
            try o.put(ctx.allocator, try ctx.allocator.dupe(u8, "name"), .{ .string = try ctx.allocator.dupe(u8, t.name) });
            try o.put(ctx.allocator, try ctx.allocator.dupe(u8, "status"), .{ .string = try ctx.allocator.dupe(u8, t.status) });
            try arr.append(.{ .object = o });
        }
        var obj = std.json.ObjectMap{};
        try obj.put(ctx.allocator, try ctx.allocator.dupe(u8, "tenants"), .{ .array = arr });
        return .{ .object = obj };
    }

    /// Write skill: enqueue a human approval instead of executing directly.
    /// The admin approve endpoint performs the actual send.
    fn skillNotifySend(ctx: *ai.SkillContext, args: std.json.Value) anyerror!std.json.Value {
        try ctx.checkDeadline();
        const refs = try refsOf(ctx);
        if (objInt(args, "user_id") == null) return error.InvalidArgs;
        if (objString(args, "title") == null) return error.InvalidArgs;
        if (objString(args, "body") == null) return error.InvalidArgs;
        _ = objString(args, "kind"); // 可选,类型错也拒绝
        const kind = objString(args, "kind");
        if (kind) |k| {
            if (!std.mem.eql(u8, k, "info") and !std.mem.eql(u8, k, "success") and !std.mem.eql(u8, k, "warning") and !std.mem.eql(u8, k, "error")) return error.InvalidArgs;
        }

        // Serialize the args back to JSON for the approval record.
        const args_json = try std.json.Stringify.valueAlloc(ctx.allocator, args, .{});
        errdefer ctx.allocator.free(args_json);
        const session_id = ctx.run_id orelse "0";
        const sid = std.fmt.parseInt(i64, session_id, 10) catch 0;
        const now_sec = @divTrunc(zigmodu.time.monotonicNowMilliseconds(), 1000);
        const approval_id = try refs.ai_store.createApproval(sid, ctx.user_id orelse 0, "zenaipa.notify.send", args_json, now_sec);

        var obj = std.json.ObjectMap{};
        try obj.put(ctx.allocator, try ctx.allocator.dupe(u8, "status"), .{ .string = try ctx.allocator.dupe(u8, "pending_approval") });
        try obj.put(ctx.allocator, try ctx.allocator.dupe(u8, "approval_id"), .{ .integer = approval_id });
        try obj.put(ctx.allocator, try ctx.allocator.dupe(u8, "message"), .{ .string = try ctx.allocator.dupe(u8, "操作已提交审批,等待管理员批准") });
        return .{ .object = obj };
    }

    // ── Chat ───────────────────────────────────────────────────────────────

    /// Run one agent turn: quota check → provider resolve → Agent run →
    /// persist run audit. Returns the assistant answer (caller-owned).
    /// `on_delta`/`delta_ctx`(可选):挂到 Agent hooks.on_delta 旁路推送流式增量
    /// (SSE 模式);为 null 时与原先完全一致(一次性返回)。
    pub fn chat(
        self: *AiService,
        allocator: std.mem.Allocator,
        session_id: i64,
        user_id: i64,
        tenant_id: i64,
        prompt: []const u8,
        on_delta: ?*const fn (?*anyopaque, ai.AiProvider.StreamDelta) anyerror!void,
        delta_ctx: ?*anyopaque,
    ) !ChatOutcome {
        const now = zigmodu.time.wallClockSeconds(self.io);
        const used = try self.store.runCountForUser(user_id, now - 24 * 3600);
        if (used >= self.cfg.daily_run_limit) return error.QuotaExceeded;

        if (!self.bulkhead.tryAcquire()) return error.AiBusy;
        defer self.bulkhead.release();

        var permissions: []const []const u8 = &.{};
        if (try self.refs.user_store.getUserById(user_id)) |row| {
            defer row.free(allocator);
            if (row.admin) permissions = &.{PERM_ADMIN};
        }

        const resolved = (try self.resolveProvider(allocator)) orelse return error.NoAiProvider;
        defer {
            resolved.row.free(allocator);
            allocator.free(resolved.keys_json);
            allocator.free(resolved.key);
        }

        var provider = ai.AiProvider{
            .allocator = allocator,
            .http = &self.http,
            .endpoint = resolved.row.endpoint,
            .api_key = resolved.key,
            .model = resolved.model,
        };

        var budget = ai.Budget.init(4000);
        var skill_ctx = ai.SkillContext{
            .allocator = allocator,
            .tenant_id = tenant_id,
            .user_id = user_id,
            .run_id = try std.fmt.allocPrint(allocator, "{d}", .{session_id}),
            .userdata = &self.refs,
            .permissions = permissions,
        };
        defer allocator.free(skill_ctx.run_id.?);

        // zigmodu v0.15.17:AgentMetrics.toStats() 运行前累计快照——与运行后快照
        // 相减得到本次 run 的用量增量(避免逐字段 .load(.monotonic) 与 {d} 传 atomic 的编译错误)。
        // run 起点与 before 用同一次快照,消除并发写回下的不一致窗口。
        const start_metrics = self.currentAgentMetrics();
        const agent_stats_before = start_metrics.toStats();

        var agent = ai.Agent{
            .provider = &provider,
            .registry = &self.registry,
            .allowlist = &.{ "zenaipa.user.search", "zenaipa.task.stats", "zenaipa.audit.search", "zenaipa.tenant.list", "zenaipa.notify.send" },
            .tool_timeout_ms = self.cfg.tool_timeout_ms,
            .budget = &budget,
            .metrics = start_metrics,
            .hooks = .{ .ctx = delta_ctx, .on_delta = on_delta },
        };

        // 熔断保护:连续失败后快速失败(callWithContext 经 ctx 传状态,无闭包捕获)。
        const RunCtx = struct {
            agent: *ai.Agent,
            allocator: std.mem.Allocator,
            prompt: []const u8,
            skill_ctx: *ai.SkillContext,
            max_steps: usize,
            result: ?ai.AgentResult = null,
        };
        var run_ctx = RunCtx{
            .agent = &agent,
            .allocator = allocator,
            .prompt = prompt,
            .skill_ctx = &skill_ctx,
            .max_steps = self.cfg.default_max_steps,
        };
        const br = self.breaker.callWithContext(&run_ctx, struct {
            fn op(c: ?*anyopaque) anyerror!void {
                const r: *RunCtx = @ptrCast(@alignCast(c.?));
                r.result = r.agent.run(r.allocator, r.prompt, r.skill_ctx, r.max_steps) catch return;
            }
        }.op);
        var result: ai.AgentResult = undefined;
        switch (br) {
            .circuit_open => return error.AiCircuitOpen,
            .failure => |e| {
                // 失败也记录部分用量(agent.metrics 为累计快照起步,差值即本次增量),
                // 并同样原子累加进累计器,与成功路径语义一致。
                const f_stats = agent.metrics.toStats();
                const f_prov = provider.metrics.toStats();
                const fd = usageDelta(agent_stats_before, f_stats);
                self.addAgentMetrics(fd);
                _ = self.store.createRun(session_id, user_id, tenant_id, "chat", prompt, "", @intCast(f_prov.total_prompt_tokens), @intCast(f_prov.total_completion_tokens), @intCast(fd.steps), @intCast(fd.tool_calls), @intCast(fd.tool_errors), "error", @errorName(e), now) catch {};
                return e;
            },
            .success => result = run_ctx.result orelse return error.AiRunFailed,
        }
        defer result.deinit(allocator);
        // 本次 run 用量:Agent 快照差值(本地拷贝,无锁)+ provider(本次新建)tokens;
        // 逐字段 fetchAdd 原子累加,并发 chat 不丢增量(不用整 struct 覆盖写回)。
        const d = usageDelta(agent_stats_before, agent.metrics.toStats());
        self.addAgentMetrics(d);
        const provider_stats = provider.metrics.toStats();
        const status: []const u8 = if (result.budget_exhausted) "budget" else "ok";
        _ = try self.store.createRun(session_id, user_id, tenant_id, "chat", prompt, result.model, @intCast(provider_stats.total_prompt_tokens), @intCast(provider_stats.total_completion_tokens), @intCast(d.steps), @intCast(d.tool_calls), @intCast(d.tool_errors), status, "", now);
        const answer = try allocator.dupe(u8, result.answer);
        const reasoning = try allocator.dupe(u8, result.reasoning);
        return .{ .answer = answer, .reasoning = reasoning, .budget_exhausted = result.budget_exhausted };
    }

    // ── Workflow ───────────────────────────────────────────────────────────

    /// 平台健康工作流:任务统计 + 租户列表两个只读技能编排(无 LLM 步骤)。
    pub fn runHealthWorkflow(self: *AiService, allocator: std.mem.Allocator, user_id: i64, tenant_id: i64) !ai.workflow.WorkflowResult {
        var workflow = ai.workflow.Workflow.init(&self.registry, &.{
            .{ .name = "task_stats", .kind = .{ .skill = .{ .name = "zenaipa.task.stats", .args = .{ .object = .{} } } } },
            .{ .name = "tenant_list", .kind = .{ .skill = .{ .name = "zenaipa.tenant.list", .args = .{ .object = .{} } } } },
        });
        var skill_ctx = ai.SkillContext{
            .allocator = allocator,
            .tenant_id = tenant_id,
            .user_id = user_id,
            .userdata = &self.refs,
            .permissions = &.{PERM_ADMIN},
        };
        return workflow.run(allocator, &skill_ctx);
    }

    // ── Provider health check ──────────────────────────────────────────────

    /// 向 Provider 发送一次最小 chat 请求(max_tokens=1)验证连通性。
    /// 返回 "ok" 或 error(调用方转成 502 + 错误信息)。
    pub fn checkProvider(self: *AiService, allocator: std.mem.Allocator, id: i64) ![]const u8 {
        const row_opt = try self.store.getProvider(id);
        const row = row_opt orelse return error.ProviderNotFound;
        defer row.free(allocator);
        if (!row.enabled) return error.ProviderDisabled;
        if (row.api_keys_encrypted.len == 0) return error.EmptyApiKeys;

        const keys_json = try self.decryptKeys(allocator, row.api_keys_encrypted);
        defer allocator.free(keys_json);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, keys_json, .{});
        defer parsed.deinit();
        if (parsed.value.array.items.len == 0) return error.EmptyApiKeys;

        var model: []const u8 = "";
        var it = std.mem.splitScalar(u8, row.models, ',');
        while (it.next()) |m| {
            if (m.len > 0) {
                model = m;
                break;
            }
        }
        if (model.len == 0) return error.EmptyModel;

        var provider = ai.AiProvider{
            .allocator = allocator,
            .http = &self.http,
            .endpoint = row.endpoint,
            .api_key = parsed.value.array.items[0].string,
            .model = model,
        };
        var resp = provider.chat(&.{.{ .role = "user", .content = "ping" }}) catch |err| return err;
        defer provider.freeResponse(&resp);
        return "ok";
    }

    // ── Quota / approvals ──────────────────────────────────────────────────

    pub fn runCountToday(self: *AiService, user_id: i64) !i64 {
        const now = zigmodu.time.wallClockSeconds(self.io);
        return self.store.runCountForUser(user_id, now - 24 * 3600);
    }

    /// Approve a pending approval. For `zenaipa.notify.send` this performs
    /// the actual notification. Returns false when already resolved.
    pub fn approve(self: *AiService, allocator: std.mem.Allocator, id: i64, approved_by: i64, do_approve: bool) !bool {
        const row_opt = try self.store.getApproval(id);
        const row = row_opt orelse return false;
        defer row.free(allocator);
        if (!std.mem.eql(u8, row.status, "pending")) return false;

        const now = zigmodu.time.wallClockSeconds(self.io);
        const new_status: []const u8 = if (do_approve) "approved" else "rejected";
        const affected = try self.store.resolveApproval(id, new_status, approved_by, now);
        if (affected == 0) return false; // 并发下已被他人处理

        // 审批处置写入平台审计日志(合规)。
        const now_s = zigmodu.time.wallClockSeconds(self.io);
        var detail_buf: [160]u8 = undefined;
        const detail = try std.fmt.bufPrint(&detail_buf, "AI 审批 {s}: {s} #{d}", .{ if (do_approve) "批准" else "拒绝", row.skill_name, id });
        _ = self.refs.audit_store.create(approved_by, "", "ai.approval", "ai_approval", id, detail, "", true, 0, now_s) catch {};

        if (do_approve and std.mem.eql(u8, row.skill_name, "zenaipa.notify.send")) {
            const parsed = try std.json.parseFromSlice(std.json.Value, allocator, row.args, .{});
            defer parsed.deinit();
            const o = parsed.value.object;
            const uid = objInt(parsed.value, "user_id") orelse return error.InvalidArgs;
            const title = objString(parsed.value, "title") orelse return error.InvalidArgs;
            const body = objString(parsed.value, "body") orelse return error.InvalidArgs;
            const kind = objString(parsed.value, "kind") orelse "info";
            _ = o;
            // 目标用户必须存在,避免 uid=0 幽灵通知。
            const target = (try self.refs.user_store.getUserById(uid)) orelse return error.UserNotFound;
            defer target.free(allocator);
            _ = try self.refs.notify_svc.notify(uid, title, body, kind);
        }
        return true;
    }
};

/// ChaCha20-based CSPRNG bytes (std.crypto.random is gone in Zig 0.17;
/// seeded from timestamps + addresses like zigmodu's SecurityModule).
fn fillRandom(io: std.Io, buf: []u8) void {
    var seed: [32]u8 = undefined;
    @memset(&seed, 0);
    // 系统熵(尽力而为;失败时仅用下方时间戳/指针种子)。
    if (std.Io.Dir.openFileAbsolute(io, "/dev/urandom", .{})) |f| {
        defer f.close(io);
        var ent: [24]u8 = undefined;
        if (f.readStreaming(io, &.{ent[0..]})) |n| {
            for (ent[0..n], 0..) |b, i| seed[i % 32] ^= b;
        } else |_| {}
    } else |_| {}

    const t = zigmodu.time.monotonicNowMilliseconds();
    std.mem.writeInt(u64, seed[0..8], @as(u64, @intCast(t)), .little);
    std.mem.writeInt(u64, seed[8..16], @intFromPtr(buf.ptr), .little);
    std.mem.writeInt(u64, seed[16..24], @intCast(t *% 31 +% 17), .little);
    std.mem.writeInt(u64, seed[24..32], @as(u64, @intCast(t)) *% 0x9e3779b97f4a7c15, .little);
    var csprng = std.Random.DefaultCsprng.init(seed);
    csprng.random().bytes(buf);
}
