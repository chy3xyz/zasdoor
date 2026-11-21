//! Exclusive XML canonicalization 1.0 (exc-c14n) for the SAML P0 spike.
//!
//! Implements rules 1-10 from docs/saml.md 5.4. Standalone spike; not wired
//! into the application. Input nodes come from xml.zig.
//!
//! Core idea: a prefix binding is rendered on an element when it is *visibly
//! utilized* there (element prefix or an attribute prefix) AND differs from
//! the binding already rendered by an output ancestor. At the apex of a
//! subtree, prefixes from the inherited context used anywhere in the subset
//! are also rendered. InclusiveNamespaces@PrefixList prefixes are always
//! treated as visibly utilized within the subset.

const std = @import("std");
const xml = @import("xml.zig");
const Allocator = std.mem.Allocator;

pub const Options = struct {
    /// InclusiveNamespaces/@PrefixList from the CanonicalizationMethod.
    /// An empty string element denotes the default namespace (#default).
    inclusive_prefixes: []const []const u8 = &.{},
};

const XmlNs = "http://www.w3.org/XML/1998/namespace";

const NsBinding = struct { prefix: []const u8, uri: []const u8 };

/// Canonicalize `root` (and its subtree) using the namespace context inherited
/// from its ancestors (`inherited` maps prefix -> URI, "" for default).
pub fn canonicalize(a: Allocator, root: *const xml.Node, inherited: []const xml.NsDecl, opts: Options) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(a);

    // Scope: prefix -> URI, root-first inherited order (nearer wins).
    var scope = std.StringHashMap([]const u8).init(a);
    defer scope.deinit();
    for (inherited) |d| try scope.put(d.prefix, d.uri);

    // Bindings already rendered in the canonical output.
    var rendered = std.StringHashMap([]const u8).init(a);
    defer rendered.deinit();

    // Prefixes used anywhere in the subtree (for apex inherited decls).
    var used = std.StringHashMap(void).init(a);
    defer used.deinit();
    try collectUsedPrefixes(root, &used);

    var ctx = Context{
        .a = a,
        .opts = opts,
        .scope = &scope,
        .rendered = &rendered,
        .apex_used = &used,
        .is_apex = true,
    };
    try ctx.renderNode(root, &out);
    return out.toOwnedSlice(a);
}

const Context = struct {
    a: Allocator,
    opts: Options,
    scope: *std.StringHashMap([]const u8),
    rendered: *std.StringHashMap([]const u8),
    apex_used: *std.StringHashMap(void),
    is_apex: bool,

    fn renderNode(self: *Context, node: *const xml.Node, out: *std.ArrayList(u8)) !void {
        // Snapshot scope and rendered maps for sibling restoration.
        var outer_scope = std.StringHashMap([]const u8).init(self.a);
        errdefer outer_scope.deinit();
        var sit = self.scope.iterator();
        while (sit.next()) |e| try outer_scope.put(e.key_ptr.*, e.value_ptr.*);

        var outer_rendered = std.StringHashMap([]const u8).init(self.a);
        errdefer outer_rendered.deinit();
        var rit = self.rendered.iterator();
        while (rit.next()) |e| try outer_rendered.put(e.key_ptr.*, e.value_ptr.*);

        // Apply this element's own declarations to the scope.
        for (node.ns_decls) |d| try self.scope.put(d.prefix, d.uri);

        // Decide which declarations to emit.
        var decls = std.ArrayList(NsBinding).empty;
        defer decls.deinit(self.a);
        try self.collectDecls(node, &decls);
        std.mem.sort(NsBinding, decls.items, {}, nsLessThan);
        for (decls.items) |b| try self.rendered.put(b.prefix, b.uri);

        // Start tag.
        try out.append(self.a, '<');
        try appendQName(out, self.a, node.prefix, node.local);

        // Namespace declarations (default first, then by prefix).
        for (decls.items) |b| {
            try out.append(self.a, ' ');
            if (b.prefix.len == 0) {
                try out.appendSlice(self.a, "xmlns=\"");
            } else {
                try out.appendSlice(self.a, "xmlns:");
                try out.appendSlice(self.a, b.prefix);
                try out.appendSlice(self.a, "=\"");
            }
            try escapeAttr(self.a, out, b.uri);
            try out.append(self.a, '"');
        }

        // Attributes sorted by (namespace URI, local name).
        const sorted = try self.a.dupe(xml.Attr, node.attrs);
        defer self.a.free(sorted);
        std.mem.sort(xml.Attr, sorted, {}, attrLessThan);
        for (sorted) |at| {
            const pfx = if (std.mem.eql(u8, at.ns, XmlNs)) "xml" else at.prefix;
            try out.append(self.a, ' ');
            try appendQName(out, self.a, pfx, at.local);
            try out.appendSlice(self.a, "=\"");
            try escapeAttr(self.a, out, at.value);
            try out.append(self.a, '"');
        }
        try out.append(self.a, '>');

        // Children.
        for (node.children) |child| {
            switch (child) {
                .text => |t| try escapeText(self.a, out, t),
                .element => |c| {
                    const saved = self.is_apex;
                    self.is_apex = false;
                    try self.renderNode(c, out);
                    self.is_apex = saved;
                },
            }
        }

        // End tag (empty elements always expanded).
        try out.appendSlice(self.a, "</");
        try appendQName(out, self.a, node.prefix, node.local);
        try out.append(self.a, '>');

        // Restore maps for siblings (free the child's map storage first).
        self.scope.deinit();
        self.scope.* = outer_scope;
        self.rendered.deinit();
        self.rendered.* = outer_rendered;
    }

    fn collectDecls(self: *Context, node: *const xml.Node, out: *std.ArrayList(NsBinding)) !void {
        // Default namespace: utilized when an unprefixed element is in a ns.
        if (node.prefix.len == 0 and node.ns.len != 0) {
            try self.addDecl(out, "", node.ns);
        }

        // Prefixes used by this element's QName and attribute QNames.
        if (node.prefix.len != 0) try self.addDecl(out, node.prefix, null);
        for (node.attrs) |at| {
            if (std.mem.eql(u8, at.ns, XmlNs)) continue; // implicit xml prefix
            if (at.prefix.len != 0) try self.addDecl(out, at.prefix, null);
        }

        // InclusiveNamespaces: treat listed prefixes as visibly utilized.
        for (self.opts.inclusive_prefixes) |p| {
            if (p.len == 0) continue; // #default handled by element ns above
            if (std.mem.eql(u8, p, "xml")) continue;
            try self.addDecl(out, p, null);
        }

        // At the apex, inherited prefixes used anywhere in the subset must be
        // rendered here (the declaration may move to the apex).
        if (self.is_apex) {
            var it = self.apex_used.iterator();
            while (it.next()) |e| {
                const p = e.key_ptr.*;
                if (p.len == 0 or std.mem.eql(u8, p, "xml")) continue;
                var local = false;
                for (node.ns_decls) |d| {
                    if (std.mem.eql(u8, d.prefix, p)) local = true;
                }
                if (local) continue;
                try self.addDecl(out, p, null);
            }
        }
    }

    /// Append a namespace declaration for `prefix` if its binding differs from
    /// what an output ancestor rendered. `uri_override` is used for the default
    /// namespace where the element's resolved ns is authoritative.
    fn addDecl(self: *Context, out: *std.ArrayList(NsBinding), prefix: []const u8, uri_override: ?[]const u8) !void {
        const uri = uri_override orelse (self.scope.get(prefix) orelse return);
        if (uri.len == 0) return; // no namespace to declare
        if (self.rendered.get(prefix)) |r| {
            if (std.mem.eql(u8, r, uri)) return;
        }
        for (out.items) |b| if (std.mem.eql(u8, b.prefix, prefix)) return;
        try out.append(self.a, .{ .prefix = prefix, .uri = uri });
    }
};

fn collectUsedPrefixes(node: *const xml.Node, set: *std.StringHashMap(void)) !void {
    if (node.prefix.len != 0) try set.put(node.prefix, {});
    for (node.attrs) |at| {
        if (at.prefix.len != 0 and !std.mem.eql(u8, at.prefix, "xml")) try set.put(at.prefix, {});
    }
    for (node.children) |child| {
        switch (child) {
            .element => |c| try collectUsedPrefixes(c, set),
            .text => {},
        }
    }
}

fn attrLessThan(_: void, x: xml.Attr, y: xml.Attr) bool {
    const c = std.mem.order(u8, x.ns, y.ns);
    if (c == .lt) return true;
    if (c == .gt) return false;
    return std.mem.lessThan(u8, x.local, y.local);
}

fn nsLessThan(_: void, x: NsBinding, y: NsBinding) bool {
    if (x.prefix.len == 0 and y.prefix.len != 0) return true;
    if (x.prefix.len != 0 and y.prefix.len == 0) return false;
    return std.mem.lessThan(u8, x.prefix, y.prefix);
}

fn appendQName(out: *std.ArrayList(u8), a: Allocator, prefix: []const u8, local: []const u8) !void {
    if (prefix.len != 0) {
        try out.appendSlice(a, prefix);
        try out.append(a, ':');
    }
    try out.appendSlice(a, local);
}

fn escapeText(a: Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '&' => try out.appendSlice(a, "&amp;"),
            '<' => try out.appendSlice(a, "&lt;"),
            '>' => try out.appendSlice(a, "&gt;"),
            '\r' => try out.appendSlice(a, "&#xD;"),
            else => try out.append(a, c),
        }
    }
}

fn escapeAttr(a: Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '&' => try out.appendSlice(a, "&amp;"),
            '<' => try out.appendSlice(a, "&lt;"),
            '"' => try out.appendSlice(a, "&quot;"),
            '\t' => try out.appendSlice(a, "&#x9;"),
            '\n' => try out.appendSlice(a, "&#xA;"),
            '\r' => try out.appendSlice(a, "&#xD;"),
            else => try out.append(a, c),
        }
    }
}

// ---------------------------------------------------------------------------
// Golden vectors (docs/saml.md 5.4, rules 1-10).
// Expected bytes are hand-computed from the W3C exc-c14n 1.0 rules and
// cross-checked against lxml-style canonical output. Byte-for-byte comparison
// is the acceptance criterion.
// ---------------------------------------------------------------------------

const testing = std.testing;

fn canon(a: std.mem.Allocator, input: []const u8, inherited: []const xml.NsDecl, opts: Options) ![]u8 {
    var doc = try xml.parse(a, input, .{});
    defer doc.deinit();
    return canonicalize(a, doc.root, inherited, opts);
}

fn expectCanon(input: []const u8, inherited: []const xml.NsDecl, opts: Options, expected: []const u8) !void {
    const out = try canon(testing.allocator, input, inherited, opts);
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(expected, out);
}

// Vector (a): W3C exc-c14n rule 1/2 -- simple text, no declaration, no newline.
test "vector a: simple <a>text</a>" {
    try expectCanon("<a>text</a>", &.{}, .{}, "<a>text</a>");
}

// Vector (b): W3C exc-c14n rule 2 -- empty element expanded.
test "vector b: empty element <a/> -> <a></a>" {
    try expectCanon("<a/>", &.{}, .{}, "<a></a>");
}

// Vector (c): docs/saml.md 5.4 danger zone -- ds prefix declared on an
// ancestor (Response) and used by a child SignedInfo canonicalized as a
// subtree. Source: W3C exc-c14n 1.0 section 2 + signxml/SAML interop.
test "vector c: inherited ds prefix on subtree apex" {
    const input =
        "<Response xmlns:ds=\"http://www.w3.org/2000/09/xmldsig#\">" ++
        "<ds:SignedInfo><ds:CanonicalizationMethod/></ds:SignedInfo></Response>";
    var doc = try xml.parse(testing.allocator, input, .{});
    defer doc.deinit();
    const signed_info = doc.root.children[0].element;
    var inherited = std.ArrayList(xml.NsDecl).empty;
    defer inherited.deinit(testing.allocator);
    try xml.inheritedNamespaces(testing.allocator, signed_info, null, &inherited);
    const out = try canonicalize(testing.allocator, signed_info, inherited.items, .{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings(
        "<ds:SignedInfo xmlns:ds=\"http://www.w3.org/2000/09/xmldsig#\">" ++
            "<ds:CanonicalizationMethod></ds:CanonicalizationMethod></ds:SignedInfo>",
        out,
    );
}

// Vector (d): rule 4 -- namespace declarations first, then attributes sorted
// by (uri, local); unqualified sorts before namespaced with same local name.
// Source: W3C C14N 1.0 section 2.3 / exc-c14n section 3.
test "vector d: attribute sorting and ns-first" {
    const input =
        "<e xmlns:z=\"urn:z\" xmlns:a=\"urn:a\"" ++
        " z:b=\"zb\" a:b=\"ab\" id=\"x\" b=\"plain\"/>";
    try expectCanon(input, &.{}, .{}, "<e xmlns:a=\"urn:a\" xmlns:z=\"urn:z\"" ++
        " b=\"plain\" id=\"x\" a:b=\"ab\" z:b=\"zb\"></e>");
}

// Vector (e): rules 5/6 -- text and attribute escaping. The parser normalizes
// literal CR/LF to LF; &#xD; and &#x9;/&#xA; in character references remain and
// must be re-escaped by c14n. Source: W3C exc-c14n 1.0 section 2.
test "vector e: text and attribute escaping" {
    const input = "<a x=\"&amp;&lt;&quot;&#x9;&#xA;&#xD;\">&amp;&lt;&gt;&#xD;\r\n</a>";
    try expectCanon(input, &.{}, .{}, "<a x=\"&amp;&lt;&quot;&#x9;&#xA;&#xD;\">&amp;&lt;&gt;&#xD;\n</a>");
}

// Vector (f): default namespace inheritance + unused ancestor ns dropped.
// Source: W3C exc-c14n 1.0 section 3 (visibly utilized) + lxml-style output.
test "vector f: default namespace inherited, unused ancestor ns dropped" {
    const input =
        "<r xmlns=\"urn:default\" xmlns:unused=\"urn:unused\">" ++
        "<child/></r>";
    // Whole document: default ns rendered on root, unused dropped.
    try expectCanon(input, &.{}, .{}, "<r xmlns=\"urn:default\"><child></child></r>");

    // Subtree <child>: default ns must be rendered on the apex.
    var doc = try xml.parse(testing.allocator, input, .{});
    defer doc.deinit();
    const child = doc.root.children[0].element;
    var inherited = std.ArrayList(xml.NsDecl).empty;
    defer inherited.deinit(testing.allocator);
    try xml.inheritedNamespaces(testing.allocator, child, null, &inherited);
    const out = try canonicalize(testing.allocator, child, inherited.items, .{});
    defer testing.allocator.free(out);
    try testing.expectEqualStrings("<child xmlns=\"urn:default\"></child>", out);
}

// Vector (g): docs/saml.md 5.4 danger zone -- InclusiveNamespaces PrefixList
// forces an unused namespace to be rendered. Source: W3C exc-c14n 1.0 section 3
// (InclusiveNamespaces) + lxml-style expected output.
test "vector g: InclusiveNamespaces forces unused prefix" {
    const input = "<e xmlns:n0=\"urn:n0\" xmlns:n1=\"urn:n1\"><n0:c/></e>";
    // Without PrefixList: n0 is declared where first used (on <n0:c>), n1
    // dropped. Verified against libxml2: xmllint --exc-c14n.
    try expectCanon(input, &.{}, .{}, "<e><n0:c xmlns:n0=\"urn:n0\"></n0:c></e>");
    // With PrefixList="n1": n1 forced onto the apex (InclusiveNamespaces
    // rule); n0 is still emitted at its first use site on <n0:c>.
    // Source: W3C exc-c14n 1.0 section 3, InclusiveNamespaces PrefixList.
    try expectCanon(input, &.{}, .{ .inclusive_prefixes = &.{"n1"} }, "<e xmlns:n1=\"urn:n1\"><n0:c xmlns:n0=\"urn:n0\"></n0:c></e>");
}

// Rule 7: xml:* attributes use implicit prefix, xml ns never declared.
test "rule 7: xml:lang implicit prefix, xml ns not declared" {
    try expectCanon("<a xml:lang=\"en\"/>", &.{}, .{}, "<a xml:lang=\"en\"></a>");
}

// Rule 8: comments and CDATA markers never appear in canonical output.
test "rule 8: comments and CDATA converted, no markers" {
    try expectCanon("<a>one<!-- c -->two<![CDATA[<x&>]]></a>", &.{}, .{}, "<a>onetwo&lt;x&amp;&gt;</a>");
}

// Rule 10: prefixes not rewritten; declaration moves to element that uses it.
test "rule 10: inherited prefix redeclared on descendant" {
    const input = "<r xmlns:p=\"urn:old\"><p:a xmlns:p=\"urn:new\"/></r>";
    try expectCanon(input, &.{}, .{}, "<r><p:a xmlns:p=\"urn:new\"></p:a></r>");
}

// OOM-path coverage (leak-prevention checklist #11): the parse step uses
// randomized StringHashMap seeds, so full parse+c14n allocation counts are
// nondeterministic and cannot be checked with checkAllAllocationFailures.
// We cover the deterministic part: canonicalize() of an arena-owned tree under
// every allocation-failure point. (parse() itself is covered by the arena's
// single-deinit design and by the normal leak-detecting tests above.)
test "OOM paths: canonicalize leak-free under allocation failures" {
    const src = "<e xmlns:n0=\"urn:n0\"><n0:c x=\"v\">text</n0:c></e>";
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var doc = try xml.parse(arena.allocator(), src, .{});
    defer doc.deinit();
    const S = struct {
        fn once(a: std.mem.Allocator, root: *const xml.Node) !void {
            const out = try canonicalize(a, root, &.{}, .{});
            defer a.free(out);
        }
    };
    try std.testing.checkAllAllocationFailures(testing.allocator, S.once, .{doc.root});
}
