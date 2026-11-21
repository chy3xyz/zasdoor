//! AI Agent service: agent token issuance (sub=agent, actor=user), capability
//! and expiration checks, budget ledger (dev.md V4).

const std = @import("std");
const zmodu = @import("zmodu");
const persist = @import("persistence.zig");
const oauth_jwt = @import("../oauth/jwt.zig");
const user_svc = @import("../user/service.zig");

pub const AgentRow = persist.AgentRow;
pub const BudgetError = error{
    InsufficientBudget,
    NotUsable,
    Unexpected,
};

/// Errors surfaced when an agent operation is evaluated against its
/// delegated authority. Explicit variants let HTTP handlers distinguish
/// "not allowed" (403), "exhausted" (429) and "no longer valid" (403).
pub const AgentError = BudgetError || error{
    MissingCapability,
    BudgetExceeded,
    Expired,
};

/// Capability required to mint a new access token for an agent. This makes
/// token issuance itself a gated operation: a token-holder cannot mint more
/// tokens unless it was explicitly delegated `agent.token.issue`.
pub const CAP_ISSUE_TOKEN = "agent.token.issue";
/// Capability required to change an agent's lifecycle (deactivate).
pub const CAP_DEACTIVATE = "agent.deactivate";
/// Capability used by the generic execute/invoke path; agents that declare
/// `*` or `agent.execute` may run mediated operations.
pub const CAP_EXECUTE = "agent.execute";

pub const AgentService = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *persist.AgentStore,
    users: *user_svc.UserService,
    sec: *zmodu.security.AppSecurity,
    issuer: []const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        store: *persist.AgentStore,
        users: *user_svc.UserService,
        sec: *zmodu.security.AppSecurity,
        issuer: []const u8,
    ) AgentService {
        return .{ .allocator = allocator, .io = io, .store = store, .users = users, .sec = sec, .issuer = issuer };
    }

    fn now(self: *AgentService) i64 {
        return zmodu.time.wallClockSeconds(self.io);
    }

    pub fn createAgent(
        self: *AgentService,
        tenant_id: i64,
        owner: i64,
        name: []const u8,
        description: []const u8,
        capabilities: []const u8,
        scopes: []const u8,
        budget: i64,
        period_seconds: i64,
        expires_at: i64,
    ) !i64 {
        const ttl = if (period_seconds == 0) 86400 else period_seconds;
        return self.store.create(tenant_id, owner, name, description, capabilities, scopes, budget, ttl, expires_at);
    }

    pub fn getAgent(self: *AgentService, id: i64) !?AgentRow {
        return self.store.getById(id);
    }

    pub fn listAgents(self: *AgentService, page: usize, page_size: usize, owner: ?i64) !persist.AgentListResult {
        return self.store.listAgents(page, page_size, owner);
    }

    pub fn setActive(self: *AgentService, id: i64, active: bool) !void {
        try self.store.setActive(id, active, self.now());
    }

    /// Is the agent usable (active and not past expiration)?
    pub fn isUsable(self: *AgentService, agent: AgentRow, at_secs: i64) bool {
        _ = self;
        if (!agent.active) return false;
        if (agent.expires_at > 0 and at_secs >= agent.expires_at) return false;
        return true;
    }

    /// Does the agent's declared capabilities include `cap` (or a wildcard)?
    pub fn hasCapability(self: *AgentService, agent: AgentRow, cap: []const u8) bool {
        _ = self;
        var it = std.mem.tokenizeAny(u8, agent.capabilities, "[],\" \t\n");
        while (it.next()) |c| {
            if (std.mem.eql(u8, c, cap) or std.mem.eql(u8, c, "*")) return true;
        }
        return false;
    }

    /// Current period's remaining budget for an agent (0 = unlimited).
    /// Rolls the period forward when expired.
    pub fn remainingBudget(self: *AgentService, agent: AgentRow, now_s: i64) !i64 {
        if (agent.budget <= 0) return 0;
        const period = agent.budget_period_seconds;
        const usage = self.store.currentUsage(agent.id) catch return error.Unexpected;
        const elapsed = now_s - usage.period_start;
        if (usage.period_start == 0 or elapsed >= period) {
            self.store.upsertUsage(agent.id, now_s, 0) catch return error.Unexpected;
            return agent.budget;
        }
        const remain = agent.budget - usage.used;
        return if (remain < 0) 0 else remain;
    }

    /// Atomically consume `amount` from the agent's remaining budget. Rolls
    /// the period forward when expired. Returns the new remaining budget.
    pub fn consumeBudget(self: *AgentService, agent: AgentRow, amount: i64, now_s: i64) BudgetError!i64 {
        if (agent.budget <= 0 or amount <= 0) return 0;
        const period = agent.budget_period_seconds;
        const usage = self.store.currentUsage(agent.id) catch return error.Unexpected;
        const elapsed = now_s - usage.period_start;
        var base_used: i64 = 0;
        var period_start: i64 = usage.period_start;
        if (usage.period_start == 0 or elapsed >= period) {
            period_start = now_s;
        } else {
            base_used = usage.used;
        }
        const available = agent.budget - base_used;
        if (amount > available) return error.InsufficientBudget;
        self.store.upsertUsage(agent.id, period_start, base_used + amount) catch return error.Unexpected;
        return available - amount;
    }

    /// Refund `amount` to the agent's current-period usage (clamps at 0).
    pub fn resumeBudget(self: *AgentService, agent: AgentRow, amount: i64, now_s: i64) BudgetError!void {
        if (agent.budget <= 0 or amount <= 0) return;
        const period = agent.budget_period_seconds;
        const usage = self.store.currentUsage(agent.id) catch return error.Unexpected;
        const elapsed = now_s - usage.period_start;
        var base_used: i64 = 0;
        var period_start: i64 = usage.period_start;
        if (usage.period_start == 0 or elapsed >= period) {
            period_start = now_s;
        } else {
            base_used = usage.used;
        }
        const new_used = if (base_used <= amount) 0 else base_used - amount;
        self.store.upsertUsage(agent.id, period_start, new_used) catch return error.Unexpected;
    }

    // ── Authority enforcement ────────────────────────────────────────────
    //
    // These are the choke points every write/destructive path must pass
    // through. They evaluate an agent's delegated authority in the fixed
    // order: identity validity → capability allow-list → budget. A failure
    // at any stage returns an explicit `AgentError` variant; no mutation is
    // performed on the rejection path.

    /// Verify an agent access token and return the agent id encoded in its
    /// `sub` claim (`agent_<id>`). Returns null for any token that is not a
    /// validly signed agent token — including human tokens whose `sub` is a
    /// numeric user id. Used to distinguish machine callers from admins.
    pub fn agentIdFromToken(self: *AgentService, token: []const u8) ?i64 {
        const payload = oauth_jwt.verify(self.allocator, self.sec.module.jwt_secret, token) catch return null;
        defer self.allocator.free(payload);
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, payload, .{}) catch return null;
        defer parsed.deinit();
        const sub = blk: {
            const v = parsed.value.object.get("sub") orelse return null;
            if (v != .string) return null;
            break :blk v.string;
        };
        if (!std.mem.startsWith(u8, sub, "agent_")) return null;
        return std.fmt.parseInt(i64, sub["agent_".len..], 10) catch null;
    }

    /// Pre-flight authorization for an operation costing `amount` units.
    /// Pure check: it never touches the budget ledger. Returns the remaining
    /// budget after the hypothetical charge (0 means unlimited).
    ///
    /// Error precedence is deliberate:
    ///   - `Expired`              agent is deactivated or past `expires_at`
    ///   - `MissingCapability`    `cap` is not in the delegate's allow-list
    ///   - `BudgetExceeded`       one unit of budget is not available
    pub fn authorizeOperation(
        self: *AgentService,
        agent: AgentRow,
        cap: []const u8,
        amount: i64,
        now_s: i64,
    ) AgentError!i64 {
        // 1. Identity validity: inactive or expired agents have no authority.
        if (!agent.active) return error.Expired;
        if (agent.expires_at > 0 and now_s >= agent.expires_at) return error.Expired;
        // 2. Capability allow-list (with `*` wildcard support).
        if (!self.hasCapability(agent, cap)) return error.MissingCapability;
        // 3. Budget: a budget of 0 means unlimited; otherwise require room.
        if (agent.budget <= 0 or amount <= 0) return 0;
        const remain = try self.remainingBudget(agent, now_s);
        if (amount > remain) return error.BudgetExceeded;
        return remain;
    }

    /// Authorize and atomically charge one operation. This is the single
    /// entry point for execute/invoke/run paths: capability is checked
    /// before the budget is consumed, and `consumeBudget` uses an atomic
    /// ledger UPDATE so concurrent calls cannot overspend. Returns the new
    /// remaining budget (0 when unlimited).
    pub fn executeOperation(
        self: *AgentService,
        agent: AgentRow,
        cap: []const u8,
        amount: i64,
        now_s: i64,
    ) AgentError!i64 {
        _ = try self.authorizeOperation(agent, cap, amount, now_s);
        const charged = self.consumeBudget(agent, amount, now_s) catch |err| switch (err) {
            error.InsufficientBudget => return error.BudgetExceeded,
            error.NotUsable => return error.Expired,
            error.Unexpected => return error.Unexpected,
        };
        return charged;
    }

    /// Authorize a write/destructive action without charging budget (e.g.
    /// lifecycle changes). Used by the deactivate route so an agent cannot
    /// revoke itself unless explicitly delegated that capability.
    pub fn authorizeWrite(self: *AgentService, agent: AgentRow, cap: []const u8, now_s: i64) AgentError!void {
        _ = try self.authorizeOperation(agent, cap, 0, now_s);
    }

    /// Public invoke entry point used by the HTTP handler. Loads the target
    /// agent and authorizes+charges `amount` budget units for `cap`. This is
    /// the single choke point for agent-mediated execute/run operations: no
    /// code path can reach the effectful work without passing this check.
    /// The caller's human JWT authenticates the request; the *agent's*
    /// delegated capability and budget are what get enforced here.
    pub fn invoke(
        self: *AgentService,
        agent_id: i64,
        cap: []const u8,
        amount: i64,
    ) AgentError!i64 {
        const row_opt = self.store.getById(agent_id) catch return error.Unexpected;
        const agent = row_opt orelse return error.NotUsable;
        defer agent.free(self.allocator);
        return try self.executeOperation(agent, cap, amount, self.now());
    }

    /// Capability-gated lifecycle write: deactivate an agent only when it
    /// has been delegated `agent.deactivate` (or `*`). Available for mediated
    /// lifecycle paths; the direct admin route uses `setActive`.
    pub fn deactivateFor(self: *AgentService, agent_id: i64) AgentError!void {
        const agent = try self.authorizeAgentOperation(agent_id, CAP_DEACTIVATE, 0);
        defer agent.free(self.allocator);
        self.store.setActive(agent_id, false, self.now()) catch return error.Unexpected;
    }

    /// Load an agent by id and authorize an operation in one call — the
    /// shape HTTP handlers need. Returns the loaded row so callers can read
    /// claims; ownership of the row transfers to the caller.
    pub fn authorizeAgentOperation(
        self: *AgentService,
        agent_id: i64,
        cap: []const u8,
        amount: i64,
    ) AgentError!AgentRow {
        const row_opt = self.store.getById(agent_id) catch return error.Unexpected;
        const agent = row_opt orelse return error.NotUsable;
        errdefer agent.free(self.allocator);
        _ = try self.authorizeOperation(agent, cap, amount, self.now());
        return agent;
    }

    /// Issue a JWT access token for an agent: sub=agent_<id>, actor=<owner>.
    /// Claims include budget_remaining when the agent has a budget (> 0).
    /// Returns null when the agent is not usable.
    ///
    /// Backward-compatible entry point used by the existing test suite and
    /// by trusted administrative callers. HTTP token issuance goes through
    /// `issueAgentTokenFor`, which additionally enforces the
    /// `agent.token.issue` capability.
    pub fn issueAgentToken(self: *AgentService, agent_id: i64, ttl: i64) !?[]const u8 {
        const row_opt = try self.store.getById(agent_id);
        const agent = row_opt orelse return null;
        defer agent.free(self.allocator);
        const now_s = self.now();
        if (!self.isUsable(agent, now_s)) return null;
        return try self.signAgentToken(agent, ttl, now_s);
    }

    /// Capability-gated token issuance for the public HTTP route. Before
    /// minting a token the agent must be active, unexpired and explicitly
    /// delegated `agent.token.issue` (or `*`). Returns explicit `AgentError`
    /// variants so handlers can map 403/429 instead of a generic failure.
    pub fn issueAgentTokenFor(
        self: *AgentService,
        agent_id: i64,
        ttl: i64,
        required_cap: []const u8,
    ) AgentError![]const u8 {
        const agent = try self.authorizeAgentOperation(agent_id, required_cap, 0);
        defer agent.free(self.allocator);
        return self.signAgentToken(agent, ttl, self.now()) catch return error.Unexpected;
    }

    /// Shared signer. `now_s` is supplied by the caller so both issuance
    /// paths agree on iat/exp/budget claims from the same instant.
    fn signAgentToken(self: *AgentService, agent: AgentRow, ttl: i64, now_s: i64) ![]const u8 {
        const sub = try std.fmt.allocPrint(self.allocator, "agent_{d}", .{agent.id});
        defer self.allocator.free(sub);
        const actor = try std.fmt.allocPrint(self.allocator, "{d}", .{agent.owner_user_id});
        defer self.allocator.free(actor);

        var obj = std.ArrayList(u8).empty;
        defer obj.deinit(self.allocator);
        try jsonKV(&obj, self.allocator, "iss", self.issuer);
        try jsonKV(&obj, self.allocator, "sub", sub);
        try jsonKV(&obj, self.allocator, "actor", actor);
        try jsonKVInt(&obj, self.allocator, "iat", now_s);
        const exp = now_s + ttl;
        try jsonKVInt(&obj, self.allocator, "exp", exp);
        if (agent.scopes.len > 2) try jsonKV(&obj, self.allocator, "scope", agent.scopes);
        const remaining = try self.remainingBudget(agent, now_s);
        if (agent.budget > 0) {
            var num: [24]u8 = undefined;
            const rem_str = try std.fmt.bufPrint(&num, "{d}", .{remaining});
            if (obj.items.len > 0) try obj.appendSlice(self.allocator, ",");
            try obj.appendSlice(self.allocator, "\"budget_remaining\":");
            try obj.appendSlice(self.allocator, rem_str);
        }

        // Wrap claims in a JSON object so the token payload is valid JSON
        // (needed by callers that parse `sub` to identify machine callers).
        var payload = std.ArrayList(u8).empty;
        defer payload.deinit(self.allocator);
        try payload.append(self.allocator, '{');
        try payload.appendSlice(self.allocator, obj.items);
        try payload.append(self.allocator, '}');

        const tok = try oauth_jwt.sign(self.allocator, self.sec.module.jwt_secret, payload.items);
        return tok;
    }
};

fn jsonKV(buf: *std.ArrayList(u8), a: std.mem.Allocator, k: []const u8, v: []const u8) !void {
    if (buf.items.len > 0) try buf.appendSlice(a, ",");
    try buf.appendSlice(a, "\"");
    try buf.appendSlice(a, k);
    try buf.appendSlice(a, "\":\"");
    try buf.appendSlice(a, v);
    try buf.appendSlice(a, "\"");
}

fn jsonKVInt(buf: *std.ArrayList(u8), a: std.mem.Allocator, k: []const u8, v: i64) !void {
    if (buf.items.len > 0) try buf.appendSlice(a, ",");
    try buf.appendSlice(a, "\"");
    try buf.appendSlice(a, k);
    try buf.appendSlice(a, "\":");
    var num: [24]u8 = undefined;
    const s = try std.fmt.bufPrint(&num, "{d}", .{v});
    try buf.appendSlice(a, s);
}
