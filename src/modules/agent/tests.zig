//! Agent module tests: capability/budget enforcement at the service entry
//! points. These tests run via the `test { _ = @import("tests.zig"); }`
//! block in root.zig, which is pulled into the main test tree because
//! src/tests.zig imports the agent module.

const std = @import("std");
const zmodu = @import("zmodu");
const db_mod = @import("../../db.zig");
const schema = @import("../../schema.zig");
const user = @import("../user/root.zig");
const persist = @import("persistence.zig");
const service = @import("service.zig");

fn openDb(allocator: std.mem.Allocator) !db_mod.StoreEnv(schema.infos, .{ user.persistence.infos, persist.infos }) {
    return db_mod.StoreEnv(schema.infos, .{ user.persistence.infos, persist.infos }).open(allocator, .sqlite, ":memory:");
}

const Fixture = struct {
    env: db_mod.StoreEnv(schema.infos, .{ user.persistence.infos, persist.infos }),
    a_store: persist.AgentStore,
    user_store: user.persistence.UserStore,
    sec: zmodu.security.AppSecurity,
    user_svc: user.service.UserService,
    svc: service.AgentService,

    fn init(allocator: std.mem.Allocator) !Fixture {
        var env = try openDb(allocator);
        errdefer env.deinit();
        var a_store = persist.AgentStore.init(allocator, env.client);
        var user_store = user.persistence.UserStore.init(allocator, env.client);
        var sec = zmodu.security.AppSecurity.init(allocator, std.testing.io, .{ .jwt_secret = "enforce-test" });
        var user_svc = user.service.UserService.init(&user_store, &sec, std.testing.io, 3600, 86400);
        _ = try user_store.createUser("Owner", "owner@x.com", "hash", false, true, 1, 100);
        const svc = service.AgentService.init(allocator, std.testing.io, &a_store, &user_svc, &sec, "http://iam.local");
        return .{
            .env = env,
            .a_store = a_store,
            .user_store = user_store,
            .sec = sec,
            .user_svc = user_svc,
            .svc = svc,
        };
    }

    fn deinit(self: *Fixture) void {
        self.env.deinit();
    }
};

test "agent enforcement: authorizeOperation rejects inactive and expired agents first" {
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit();
    const now = zmodu.time.wallClockSeconds(std.testing.io);
    const aid = try f.svc.createAgent(1, 1, "bot", "", "[\"agent.execute\"]", "[]", 0, 86400, now + 3600);

    const row = (try f.svc.getAgent(aid)).?;
    defer row.free(a);
    // Capability present → authorized.
    _ = try f.svc.authorizeOperation(row, service.CAP_EXECUTE, 1, now);

    // Expired check precedes capability: an expired agent cannot act even
    // with a matching capability.
    try std.testing.expectError(error.Expired, f.svc.authorizeOperation(row, service.CAP_EXECUTE, 1, now + 3601));
}

test "agent enforcement: MissingCapability for undeclared capability" {
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit();
    const now = zmodu.time.wallClockSeconds(std.testing.io);
    const aid = try f.svc.createAgent(1, 1, "bot", "", "[\"wallet.balance\"]", "[]", 100, 86400, 0);
    const row = (try f.svc.getAgent(aid)).?;
    defer row.free(a);

    try std.testing.expectError(error.MissingCapability, f.svc.authorizeOperation(row, "admin.delete", 1, now));
    // Explicit capability passes.
    _ = try f.svc.authorizeOperation(row, "wallet.balance", 1, now);

    // A wildcard agent accepts any capability.
    const wid = try f.svc.createAgent(1, 1, "wild", "", "[\"*\"]", "[]", 0, 86400, 0);
    const wild_row = (try f.svc.getAgent(wid)).?;
    defer wild_row.free(a);
    _ = try f.svc.authorizeOperation(wild_row, "admin.delete", 1, now);
}

test "agent enforcement: BudgetExceeded before any ledger mutation" {
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit();
    const now = zmodu.time.wallClockSeconds(std.testing.io);
    const aid = try f.svc.createAgent(1, 1, "bot", "", "[\"agent.execute\"]", "[]", 10, 86400, 0);
    const row = (try f.svc.getAgent(aid)).?;
    defer row.free(a);

    // Pre-flight rejects an over-budget operation without charging.
    try std.testing.expectError(error.BudgetExceeded, f.svc.authorizeOperation(row, service.CAP_EXECUTE, 11, now));
    try std.testing.expectEqual(@as(i64, 10), try f.svc.remainingBudget(row, now));

    // Successful execution charges exactly once.
    const remain = try f.svc.executeOperation(row, service.CAP_EXECUTE, 4, now);
    try std.testing.expectEqual(@as(i64, 6), remain);
    try std.testing.expectEqual(@as(i64, 6), try f.svc.remainingBudget(row, now));

    // A rejected execution must not consume budget.
    try std.testing.expectError(error.BudgetExceeded, f.svc.executeOperation(row, service.CAP_EXECUTE, 7, now));
    try std.testing.expectEqual(@as(i64, 6), try f.svc.remainingBudget(row, now));
}

test "agent enforcement: invoke requires valid agent token and enforces authority" {
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit();
    const now = zmodu.time.wallClockSeconds(std.testing.io);
    const aid = try f.svc.createAgent(1, 1, "bot", "", "[\"agent.execute\"]", "[]", 5, 86400, 0);

    // Wrong capability → rejected, no budget charged.
    try std.testing.expectError(error.MissingCapability, f.svc.invoke(aid, "admin.delete", 1));
    const after_denied = (try f.svc.getAgent(aid)).?;
    defer after_denied.free(a);
    try std.testing.expectEqual(@as(i64, 5), try f.svc.remainingBudget(after_denied, now));

    // Declared capability → authorized and charged.
    const remain = try f.svc.invoke(aid, service.CAP_EXECUTE, 2);
    try std.testing.expectEqual(@as(i64, 3), remain);

    // Missing agent → explicit rejection.
    try std.testing.expectError(error.NotUsable, f.svc.invoke(9999, service.CAP_EXECUTE, 1));
}

test "agent enforcement: deactivateFor requires agent.deactivate delegation" {
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit();
    const aid = try f.svc.createAgent(1, 1, "bot", "", "[\"agent.execute\"]", "[]", 0, 86400, 0);

    // Without agent.deactivate capability the lifecycle write is refused.
    try std.testing.expectError(error.MissingCapability, f.svc.deactivateFor(aid));
    const still_active = (try f.svc.getAgent(aid)).?;
    defer still_active.free(a);
    try std.testing.expect(still_active.active);

    // A delegated agent may be deactivated via the capability-gated path.
    const aid2 = try f.svc.createAgent(1, 1, "bot2", "", "[\"agent.deactivate\"]", "[]", 0, 86400, 0);
    try f.svc.deactivateFor(aid2);
    const deactivated = (try f.svc.getAgent(aid2)).?;
    defer deactivated.free(a);
    try std.testing.expect(!deactivated.active);
}

test "agent enforcement: token issuance gated by agent.token.issue capability" {
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit();
    const aid = try f.svc.createAgent(1, 1, "bot", "", "[\"agent.execute\"]", "[]", 0, 86400, 0);

    // Without the capability, self-service minting is refused.
    try std.testing.expectError(
        error.MissingCapability,
        f.svc.issueAgentTokenFor(aid, 60, service.CAP_ISSUE_TOKEN),
    );

    // With the capability it succeeds.
    const aid2 = try f.svc.createAgent(1, 1, "minter", "", "[\"agent.token.issue\"]", "[]", 0, 86400, 0);
    const minted = try f.svc.issueAgentTokenFor(aid2, 60, service.CAP_ISSUE_TOKEN);
    defer a.free(minted);
    try std.testing.expect(minted.len > 0);
}
