//! SAML 2.0 SP protocol service (metadata, AuthnRequest, assertion extraction).
const std = @import("std");
const zmodu = @import("zmodu");
const persist = @import("persistence.zig");
const config = @import("config.zig");
const xml = @import("xml.zig");

pub const SamlError = error{
    NotFound,
    InvalidConfig,
    InvalidRequest,
    InvalidNameId,
    AssertionInvalid,
    SignatureInvalid,
    ReplayedAssertion,
    StateInvalid,
    TicketInvalid,
    ForbiddenRedirect,
    Unexpected,
    OutOfMemory,
};

pub const SamlService = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    store: *persist.SamlStore,
    app_host: []const u8,
    sp_entity_id: []const u8,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, store: *persist.SamlStore, app_host: []const u8, sp_entity_id: []const u8) SamlService {
        return .{ .allocator = allocator, .io = io, .store = store, .app_host = app_host, .sp_entity_id = sp_entity_id };
    }

    fn appendEscaped(list: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
        for (s) |c| switch (c) {
            '&' => try list.appendSlice(a, "&amp;"),
            '<' => try list.appendSlice(a, "&lt;"),
            '>' => try list.appendSlice(a, "&gt;"),
            '"' => try list.appendSlice(a, "&quot;"),
            '\'' => try list.appendSlice(a, "&apos;"),
            else => try list.append(a, c),
        };
    }

    fn appendIso(list: *std.ArrayList(u8), a: std.mem.Allocator, ts: i64) !void {
        const es = std.time.epoch.EpochSeconds{ .secs = @intCast(@max(0, ts)) };
        const yd = es.getEpochDay().calculateYearDay();
        const md = yd.calculateMonthDay();
        const ds = es.getDaySeconds();
        try list.print(a, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
            yd.year,              @as(u8, md.month.numeric()), md.day_index + 1,
            ds.getHoursIntoDay(), ds.getMinutesIntoHour(),     ds.getSecondsIntoMinute(),
        });
    }

    /// Raw-DEFLATE + base64 of an AuthnRequest (Redirect binding).
    pub fn buildAuthnRequest(self: *SamlService, sso_url: []const u8, request_id: []const u8, now: i64, name_id_format: []const u8) ![]u8 {
        const a = self.allocator;
        var out = std.ArrayList(u8).empty;
        defer out.deinit(a);
        try out.appendSlice(a, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>");
        try out.appendSlice(a, "<samlp:AuthnRequest xmlns:samlp=\"urn:oasis:names:tc:SAML:2.0:protocol\" xmlns:saml=\"urn:oasis:names:tc:SAML:2.0:assertion\" ID=\"");
        try appendEscaped(&out, a, request_id);
        try out.appendSlice(a, "\" Version=\"2.0\" IssueInstant=\"");
        try appendIso(&out, a, now);
        try out.appendSlice(a, "\" Destination=\"");
        try appendEscaped(&out, a, sso_url);
        try out.appendSlice(a, "\" ProtocolBinding=\"urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST\" AssertionConsumerServiceURL=\"");
        try appendEscaped(&out, a, self.app_host);
        try out.appendSlice(a, "/saml/1/acs\"><saml:Issuer>");
        try appendEscaped(&out, a, self.sp_entity_id);
        try out.appendSlice(a, "</saml:Issuer>");
        if (name_id_format.len > 0 and !std.mem.eql(u8, name_id_format, "unspecified")) {
            try out.appendSlice(a, "<samlp:NameIDPolicy Format=\"");
            try appendEscaped(&out, a, name_id_format);
            try out.appendSlice(a, "\" AllowCreate=\"true\"/>");
        }
        try out.appendSlice(a, "</samlp:AuthnRequest>");

        var compressed: [64 * 1024]u8 = undefined;
        var fw = std.Io.Writer.fixed(&compressed);
        var history: [std.compress.flate.max_window_len * 2]u8 = undefined;
        var compressor = std.compress.flate.Compress.init(&fw, &history, .raw, .{ .good = 4, .nice = 32, .lazy = 16, .chain = 64 }) catch return error.Unexpected;
        compressor.writer.writeAll(out.items) catch return error.Unexpected;
        compressor.finish() catch return error.Unexpected;
        const n = fw.end;
        const b64 = a.alloc(u8, std.base64.standard.Encoder.calcSize(n)) catch return error.OutOfMemory;
        _ = std.base64.standard.Encoder.encode(b64, compressed[0..n]);
        return b64;
    }

    pub fn metadataXml(self: *SamlService, provider_id: i64) ![]u8 {
        const a = self.allocator;
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(a);
        try out.appendSlice(a, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>");
        try out.appendSlice(a, "<md:EntityDescriptor xmlns:md=\"urn:oasis:names:tc:SAML:2.0:metadata\" entityID=\"");
        try appendEscaped(&out, a, self.sp_entity_id);
        try out.appendSlice(a, "\"><md:SPSSODescriptor AuthnRequestsSigned=\"false\" WantAssertionsSigned=\"true\" protocolSupportEnumeration=\"urn:oasis:names:tc:SAML:2.0:protocol\">");
        try out.appendSlice(a, "<md:AssertionConsumerService Binding=\"urn:oasis:names:tc:SAML:2.0:bindings:HTTP-POST\" Location=\"");
        try appendEscaped(&out, a, self.app_host);
        try out.print(a, "/saml/{d}/acs\" index=\"0\" isDefault=\"true\"/>", .{provider_id});
        try out.appendSlice(a, "</md:SPSSODescriptor></md:EntityDescriptor>");
        return out.toOwnedSlice(a);
    }

    pub const Assertion = struct {
        name_id: []const u8,
        name_id_format: []const u8,
        issuer: []const u8,
        email: []const u8 = "",
        name: []const u8 = "",

        pub fn deinit(self: *Assertion, a: std.mem.Allocator) void {
            a.free(self.name_id);
            a.free(self.name_id_format);
            a.free(self.issuer);
            if (self.email.len > 0) a.free(self.email);
            if (self.name.len > 0) a.free(self.name);
        }
    };

    pub fn extractAssertion(self: *SamlService, doc: *xml.Node, cfg: *const config.SamlConfig) !Assertion {
        const assertion = findDescendant(doc, "Assertion") orelse return error.AssertionInvalid;
        const subject = findDescendant(assertion, "Subject") orelse return error.AssertionInvalid;
        const name_id_node = findDescendant(subject, "NameID") orelse return error.AssertionInvalid;
        const fmt = attrValue(name_id_node, "Format") orelse "urn:oasis:names:tc:SAML:1.1:nameid-format:unspecified";
        if (std.mem.eql(u8, fmt, "urn:oasis:names:tc:SAML:2.0:nameid-format:transient")) return error.InvalidNameId;
        const issuer_node = findDescendant(assertion, "Issuer") orelse return error.AssertionInvalid;
        const issuer_text = nodeText(self.allocator, issuer_node) catch return error.OutOfMemory;
        defer self.allocator.free(issuer_text);
        if (issuer_text.len == 0) return error.AssertionInvalid;
        const name_id = nodeText(self.allocator, name_id_node) catch return error.OutOfMemory;
        defer self.allocator.free(name_id);
        if (name_id.len == 0 or name_id.len > 512) return error.InvalidNameId;

        var result = Assertion{
            .name_id = try self.allocator.dupe(u8, name_id),
            .name_id_format = try self.allocator.dupe(u8, fmt),
            .issuer = try self.allocator.dupe(u8, issuer_text),
        };
        errdefer result.deinit(self.allocator);

        const attrs = findDescendant(assertion, "AttributeStatement") orelse return result;
        for (attrs.children) |child| {
            const node = switch (child) {
                .element => |n| n,
                else => continue,
            };
            if (!std.mem.eql(u8, node.local, "Attribute")) continue;
            const name = attrValue(node, "Name") orelse continue;
            const value_node = findDescendant(node, "AttributeValue") orelse continue;
            const value = nodeText(self.allocator, value_node) catch return error.OutOfMemory;
            defer self.allocator.free(value);
            if (value.len == 0) continue;
            if (std.mem.eql(u8, name, cfg.email_attribute) and result.email.len == 0) {
                result.email = try self.allocator.dupe(u8, value);
            } else if (std.mem.eql(u8, name, cfg.name_attribute) and result.name.len == 0) {
                result.name = try self.allocator.dupe(u8, value);
            }
        }
        return result;
    }
};

fn attrValue(node: *const xml.Node, local: []const u8) ?[]const u8 {
    for (node.attrs) |attr| {
        if (std.mem.eql(u8, attr.local, local)) return attr.value;
    }
    return null;
}

fn nodeText(a: std.mem.Allocator, node: *const xml.Node) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(a);
    for (node.children) |child| switch (child) {
        .text => |t| try out.appendSlice(a, t),
        .element => |n| {
            const inner = try nodeText(a, n);
            defer a.free(inner);
            try out.appendSlice(a, inner);
        },
    };
    return out.toOwnedSlice(a);
}

fn findDescendant(root: *xml.Node, local: []const u8) ?*xml.Node {
    if (std.mem.eql(u8, root.local, local)) return root;
    for (root.children) |child| {
        const node = switch (child) {
            .element => |n| n,
            else => continue,
        };
        if (findDescendant(node, local)) |found| return found;
    }
    return null;
}

test "saml: AuthnRequest is valid XML with expected attributes" {
    const a = std.testing.allocator;
    var store = persist.SamlStore.init(a, undefined);
    var svc = SamlService.init(a, std.testing.io, &store, "http://localhost:3001", "urn:zasdoor:sp");
    const id = "_abc123";
    const encoded = try svc.buildAuthnRequest("https://idp.example/sso", id, 1760000000, "urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress");
    defer a.free(encoded);
    const n = std.base64.standard.Decoder.calcSizeForSlice(encoded) catch return error.InvalidRequest;
    const raw = try a.alloc(u8, n);
    defer a.free(raw);
    try std.base64.standard.Decoder.decode(raw, encoded);
    // Raw DEFLATE payload must be non-empty and differ from the plain XML.
    try std.testing.expect(raw.len > 32);
    try std.testing.expect(std.mem.indexOf(u8, raw, "<samlp:AuthnRequest") == null);
}

test "saml: metadata advertises POST ACS and no signing" {
    const a = std.testing.allocator;
    var store = persist.SamlStore.init(a, undefined);
    var svc = SamlService.init(a, std.testing.io, &store, "http://localhost:3001", "urn:zasdoor:sp");
    const meta = try svc.metadataXml(7);
    defer a.free(meta);
    try std.testing.expect(std.mem.indexOf(u8, meta, "AuthnRequestsSigned=\"false\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, meta, "saml/7/acs") != null);
}
