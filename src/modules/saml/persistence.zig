//! SAML 2.0 SP persistence: assertion replay cache and login tickets.

const std = @import("std");
const zent = @import("zent");
const crud = zent.crud_helpers;
const model = @import("model.zig");
const schema = @import("../../schema.zig");

const graph = zent.codegen.graph.buildGraph(&.{ model.SamlAssertionReplay, model.SamlLoginTicket });
pub const infos = graph.types;
pub const Client = schema.Client;
pub const ReplayInfo = infos[0];
pub const TicketInfo = infos[1];

pub const SamlLoginTicketRow = struct {
    id: i64,
    tenant_id: i64,
    provider_id: i64,
    ticket: []const u8,
    user_id: i64,
    redirect_to: []const u8,
    expires_at: i64,
    used: bool,

    pub fn free(self: SamlLoginTicketRow, a: std.mem.Allocator) void {
        a.free(self.ticket);
        a.free(self.redirect_to);
    }
};

pub const SamlStore = struct {
    allocator: std.mem.Allocator,
    client: Client,

    pub fn init(allocator: std.mem.Allocator, client: Client) SamlStore {
        return .{ .allocator = allocator, .client = client };
    }

    fn dupTicket(self: *SamlStore, e: anytype) !SamlLoginTicketRow {
        return .{
            .id = e.id,
            .tenant_id = e.tenant_id,
            .provider_id = e.provider_id,
            .ticket = try self.allocator.dupe(u8, e.ticket),
            .user_id = e.user_id,
            .redirect_to = try self.allocator.dupe(u8, e.redirect_to),
            .expires_at = e.expires_at,
            .used = e.used,
        };
    }

    pub fn createTicket(self: *SamlStore, tenant_id: i64, provider_id: i64, ticket: []const u8, user_id: i64, redirect_to: []const u8, expires_at: i64, now: i64) !void {
        var b = try self.client.saml_login_ticket.Create();
        defer b.deinit();
        _ = try b.setFieldValue("tenant_id", tenant_id);
        _ = try b.setFieldValue("provider_id", provider_id);
        _ = try b.setFieldValue("ticket", ticket);
        _ = try b.setFieldValue("user_id", user_id);
        _ = try b.setFieldValue("redirect_to", redirect_to);
        _ = try b.setFieldValue("expires_at", expires_at);
        _ = try b.setFieldValue("used", false);
        _ = try b.setFieldValue("created_at", now);
        _ = try b.setFieldValue("updated_at", now);
        var row = try b.Save();
        defer zent.codegen.deinitEntity(infos, TicketInfo, &row, self.allocator);
    }

    /// CAS-consume a ticket: only an unused, unexpired row is accepted.
    pub fn consumeTicket(self: *SamlStore, ticket: []const u8, now: i64) !?SamlLoginTicketRow {
        const preds = self.client.saml_login_ticket.predicates;
        var e = (try crud.first(self.client.saml_login_ticket, .{preds.ticketEQ(.{ .string = ticket })})) orelse return null;
        defer zent.codegen.deinitEntity(infos, TicketInfo, &e, self.allocator);
        if (e.used or e.expires_at < now) return null;
        var u = self.client.saml_login_ticket.Update();
        defer u.deinit();
        _ = try u.setFieldValue("used", true);
        _ = try u.setFieldValue("updated_at", now);
        _ = try u.Where(.{preds.idEQ(.{ .int = e.id })});
        _ = try u.Save();
        return try self.dupTicket(e);
    }

    /// Insert an assertion id; false means it was already claimed (replay).
    pub fn claimAssertion(self: *SamlStore, tenant_id: i64, provider_id: i64, assertion_id: []const u8, expires_at: i64, now: i64) !bool {
        const preds = self.client.saml_assertion_replay.predicates;
        if (try crud.first(self.client.saml_assertion_replay, .{preds.assertion_idEQ(.{ .string = assertion_id })})) |existing| {
            var e = existing;
            defer zent.codegen.deinitEntity(infos, ReplayInfo, &e, self.allocator);
            return false;
        }
        var b = try self.client.saml_assertion_replay.Create();
        defer b.deinit();
        _ = try b.setFieldValue("tenant_id", tenant_id);
        _ = try b.setFieldValue("provider_id", provider_id);
        _ = try b.setFieldValue("assertion_id", assertion_id);
        _ = try b.setFieldValue("expires_at", expires_at);
        _ = try b.setFieldValue("created_at", now);
        _ = try b.setFieldValue("updated_at", now);
        var row = try b.Save();
        defer zent.codegen.deinitEntity(infos, ReplayInfo, &row, self.allocator);
        return true;
    }

    pub fn purgeExpired(self: *SamlStore, now: i64) !void {
        const rp = self.client.saml_assertion_replay.predicates;
        var d1 = self.client.saml_assertion_replay.Delete();
        defer d1.deinit();
        _ = try d1.Where(.{rp.expires_atLT(.{ .int = now })});
        _ = try d1.Exec();
        const tp = self.client.saml_login_ticket.predicates;
        var d2 = self.client.saml_login_ticket.Delete();
        defer d2.deinit();
        _ = try d2.Where(.{tp.expires_atLT(.{ .int = now - 3600 })});
        _ = try d2.Exec();
    }
};
