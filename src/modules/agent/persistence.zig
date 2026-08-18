//! Persistence over the zent Client for AI Agent identity.

const std = @import("std");
const zent = @import("zent");
const crud = zent.crud_helpers;
const model = @import("model.zig");
const schema = @import("../../schema.zig");

const graph = zent.codegen.graph.buildGraph(&.{model.Agent});
pub const infos = graph.types;
pub const Client = schema.Client;
pub const AgentInfo = infos[0];

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
};
