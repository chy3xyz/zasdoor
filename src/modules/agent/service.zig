//! AI Agent service: agent token issuance (sub=agent, actor=user), capability
//! and expiration checks, budget ledger (dev.md V4).

const std = @import("std");
const zigmodu = @import("zigmodu");
const persist = @import("persistence.zig");
const oauth_jwt = @import("../oauth/jwt.zig");
const user_svc = @import("../user/service.zig");

pub const AgentRow = persist.AgentRow;
pub const BudgetError = error{
    InsufficientBudget,
    NotUsable,
    Unexpected,
};

pub const AgentService = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *persist.AgentStore,
    users: *user_svc.UserService,
    sec: *zigmodu.security.AppSecurity,
    issuer: []const u8,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        store: *persist.AgentStore,
        users: *user_svc.UserService,
        sec: *zigmodu.security.AppSecurity,
        issuer: []const u8,
    ) AgentService {
        return .{ .allocator = allocator, .io = io, .store = store, .users = users, .sec = sec, .issuer = issuer };
    }

    fn now(self: *AgentService) i64 {
        return zigmodu.time.wallClockSeconds(self.io);
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

    /// Issue a JWT access token for an agent: sub=agent_<id>, actor=<owner>.
    /// Claims include budget_remaining when the agent has a budget (> 0).
    /// Returns null when the agent is not usable.
    pub fn issueAgentToken(self: *AgentService, agent_id: i64, ttl: i64) !?[]const u8 {
        const row_opt = try self.store.getById(agent_id);
        const agent = row_opt orelse return null;
        defer agent.free(self.allocator);
        const now_s = self.now();
        if (!self.isUsable(agent, now_s)) return null;

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

        const tok = oauth_jwt.sign(self.allocator, self.sec.module.jwt_secret, obj.items) catch return null;
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
