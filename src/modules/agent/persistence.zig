//! Persistence over the zent Client for AI Agent identity + budget ledger.

const std = @import("std");
const zent = @import("zent");
const crud = zent.crud_helpers;
const model = @import("model.zig");
const schema = @import("../../schema.zig");

const graph = zent.codegen.graph.buildGraph(&.{ model.Agent, model.AgentUsage });
pub const infos = graph.types;
pub const Client = schema.Client;
pub const AgentInfo = infos[0];
pub const AgentUsageInfo = infos[1];

pub const AgentRow = struct {
    id: i64,
    tenant_id: i64,
    owner_user_id: i64,
    name: []const u8,
    description: []const u8,
    capabilities: []const u8,
    scopes: []const u8,
    budget: i64,
    budget_period_seconds: i64,
    expires_at: i64,
    active: bool,
    created_at: i64,
    updated_at: i64,

    pub fn free(self: AgentRow, a: std.mem.Allocator) void {
        a.free(self.name);
        a.free(self.description);
        a.free(self.capabilities);
        a.free(self.scopes);
    }
};

pub const AgentUsageRow = struct {
    id: i64,
    agent_id: i64,
    period_start: i64,
    used: i64,

    pub fn free(_: AgentUsageRow, _: std.mem.Allocator) void {}
};

pub const AgentStore = struct {
    allocator: std.mem.Allocator,
    client: Client,

    pub fn init(allocator: std.mem.Allocator, client: Client) AgentStore {
        return .{ .allocator = allocator, .client = client };
    }

    fn ts(e: anytype) i64 {
        return @as(?i64, e) orelse 0;
    }

    fn dup(self: *AgentStore, e: anytype) !AgentRow {
        return .{
            .id = e.id,
            .tenant_id = e.tenant_id,
            .owner_user_id = e.owner_user_id,
            .name = try self.allocator.dupe(u8, e.name),
            .description = try self.allocator.dupe(u8, e.description),
            .capabilities = try self.allocator.dupe(u8, e.capabilities),
            .scopes = try self.allocator.dupe(u8, e.scopes),
            .budget = e.budget,
            .budget_period_seconds = e.budget_period_seconds,
            .expires_at = e.expires_at,
            .active = e.active,
            .created_at = ts(e.created_at),
            .updated_at = ts(e.updated_at),
        };
    }

    fn dupUsage(_: *AgentStore, e: anytype) AgentUsageRow {
        return .{
            .id = e.id,
            .agent_id = e.agent_id,
            .period_start = e.period_start,
            .used = e.used,
        };
    }

    pub fn create(
        self: *AgentStore,
        tenant_id: i64,
        owner_user_id: i64,
        name: []const u8,
        description: []const u8,
        capabilities: []const u8,
        scopes: []const u8,
        budget: i64,
        budget_period_seconds: i64,
        expires_at: i64,
    ) !i64 {
        var b = try self.client.agent.Create();
        defer b.deinit();
        _ = try b.setFieldValue("tenant_id", tenant_id);
        _ = try b.setFieldValue("owner_user_id", owner_user_id);
        _ = try b.setFieldValue("name", name);
        _ = try b.setFieldValue("description", description);
        _ = try b.setFieldValue("capabilities", capabilities);
        _ = try b.setFieldValue("scopes", scopes);
        _ = try b.setFieldValue("budget", budget);
        _ = try b.setFieldValue("budget_period_seconds", budget_period_seconds);
        _ = try b.setFieldValue("expires_at", expires_at);
        _ = try b.setFieldValue("active", true);
        var row = try b.Save();
        defer zent.codegen.deinitEntity(infos, AgentInfo, &row, self.allocator);
        return row.id;
    }

    pub fn getById(self: *AgentStore, id: i64) !?AgentRow {
        var e = (try crud.get(self.client.agent, id)) orelse return null;
        defer zent.codegen.deinitEntity(infos, AgentInfo, &e, self.allocator);
        return try self.dup(e);
    }

    pub fn setActive(self: *AgentStore, id: i64, active: bool, now: i64) !void {
        const preds = self.client.agent.predicates;
        var u = self.client.agent.Update();
        defer u.deinit();
        _ = try u.setFieldValue("active", active);
        _ = try u.setFieldValue("updated_at", now);
        _ = try u.Where(.{preds.idEQ(.{ .int = id })});
        _ = try u.Save();
    }

    /// Look up the current period's usage row for an agent. Returns a new
    /// (zeroed) row if none exists (caller can insert via upsertUsage).
    pub fn currentUsage(self: *AgentStore, agent_id: i64) !AgentUsageRow {
        const preds = self.client.agent_usage.predicates;
        var e = (try crud.first(self.client.agent_usage, .{preds.agent_idEQ(.{ .int = agent_id })})) orelse return .{ .id = 0, .agent_id = agent_id, .period_start = 0, .used = 0 };
        defer zent.codegen.deinitEntity(infos, AgentUsageInfo, &e, self.allocator);
        return self.dupUsage(e);
    }

    /// Insert (or reset) the usage row for an agent and a period start.
    pub fn upsertUsage(self: *AgentStore, agent_id: i64, period_start: i64, used: i64) !void {
        const preds = self.client.agent_usage.predicates;
        var existing = try crud.first(self.client.agent_usage, .{preds.agent_idEQ(.{ .int = agent_id })});
        if (existing) |*e| {
            defer zent.codegen.deinitEntity(infos, AgentUsageInfo, e, self.allocator);
            const id = e.id;
            var u = self.client.agent_usage.Update();
            defer u.deinit();
            _ = try u.setFieldValue("period_start", period_start);
            _ = try u.setFieldValue("used", used);
            _ = try u.Where(.{preds.idEQ(.{ .int = id })});
            _ = try u.Save();
            return;
        }
        var b = try self.client.agent_usage.Create();
        defer b.deinit();
        _ = try b.setFieldValue("agent_id", agent_id);
        _ = try b.setFieldValue("period_start", period_start);
        _ = try b.setFieldValue("used", used);
        var row = try b.Save();
        defer zent.codegen.deinitEntity(infos, AgentUsageInfo, &row, self.allocator);
    }

    /// Increment `used` by `amount`. Returns the new used count, or null if
    /// the period has elapsed and was reset to amount.
    pub fn incrementUsage(self: *AgentStore, agent_id: i64, amount: i64, period_start: i64) !void {
        const row = try self.currentUsage(agent_id);
        _ = row;
        try self.upsertUsage(agent_id, period_start, amount);
    }
};
