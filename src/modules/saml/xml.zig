//! Minimal, fail-closed, namespace-aware XML parser for the SAML P0 spike.
//!
//! Scope (docs/saml.md 5.3): the SAML subset only. The tree owns all strings
//! in one arena; deinit() is a single call. Any construct that exclusive c14n
//! cannot safely handle (DOCTYPE, custom entities, PIs in content, xml:base,
//! relative namespace URIs, unbalanced tags, ...) is rejected rather than
//! silently accepted. This is a standalone spike: nothing here is wired into
//! the application yet.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Attr = struct {
    /// Resolved namespace URI ("": unqualified).
    ns: []const u8,
    /// Local name (without prefix).
    local: []const u8,
    /// Raw prefix as written ("" for unqualified).
    prefix: []const u8 = "",
    /// Decoded attribute value (entity/char refs expanded, CR normalized).
    value: []const u8,
};

pub const NsDecl = struct {
    /// "" denotes the default namespace.
    prefix: []const u8,
    /// Namespace URI (must be absolute).
    uri: []const u8,
};

pub const Child = union(enum) {
    element: *Node,
    /// Decoded text content (entity/char refs expanded, CR normalized).
    text: []const u8,
};

pub const Node = struct {
    /// Resolved namespace URI of the element ("": no namespace).
    ns: []const u8,
    /// Local name (no prefix).
    local: []const u8,
    /// Prefix as written ("" for no prefix).
    prefix: []const u8,
    /// Attributes in document order (namespace declarations excluded).
    attrs: []Attr,
    /// Namespace declarations physically on this element.
    ns_decls: []NsDecl,
    parent: ?*Node,
    children: []Child,
    /// ID/Id/id attribute value, if any.
    id: ?[]const u8 = null,
    /// Diagnostics only; NEVER used for crypto.
    raw_start: usize = 0,
    raw_end: usize = 0,
};

pub const Limits = struct {
    /// Task-15 tightens this to 64 KiB for the spike.
    max_bytes: usize = 64 * 1024,
    max_depth: usize = 64,
    max_elements: usize = 4096,
    max_attrs_per_element: usize = 64,
    max_ns_decls_per_element: usize = 128,
    max_text_bytes: usize = 64 * 1024,
};

pub const ParseError = error{
    InputTooLarge,
    InvalidUtf8,
    UnsupportedEncoding,
    ForbiddenXmlConstruct,
    DuplicateExpandedName,
    DuplicateId,
    UnboundPrefix,
    RelativeNamespaceUri,
    UnbalancedTag,
    MalformedXml,
    LimitExceeded,
    OutOfMemory,
};

pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    root: *Node,

    pub fn deinit(self: *Document) void {
        self.arena.deinit();
    }
};

/// Parse XML bytes into an arena-owned Node tree. The returned Document
/// must be deinit'ed exactly once.
pub fn parse(a: Allocator, bytes: []const u8, limits: Limits) ParseError!Document {
    if (bytes.len > limits.max_bytes) return error.InputTooLarge;

    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const aa = arena.allocator();

    // Strip a UTF-8 BOM if present. UTF-16/UTF-32 BOMs are rejected below
    // because they are not valid UTF-8.
    var input = bytes;
    if (std.mem.startsWith(u8, input, "\xef\xbb\xbf")) input = input[3..];
    if (!std.unicode.utf8ValidateSlice(input)) return error.InvalidUtf8;

    var p = Parser{
        .a = aa,
        .input = input,
        .limits = limits,
        .ids = std.StringHashMap(void).init(aa),
    };

    // Reject DTD/entity declarations before tokenizing (defense: string scan,
    // not just tokenizer state) -- XXE and entity expansion impossible.
    try p.rejectForbiddenMarkup();

    p.skipMisc();
    // Leading <?xml ...?> is the only PI allowed.
    if (std.mem.startsWith(u8, p.input[p.pos..], "<?xml") and
        (p.pos + 5 == p.input.len or isSpace(p.input[p.pos + 5])))
    {
        try p.parseXmlDeclaration();
        p.skipMisc();
    }

    const root = try p.parseElement(null, 0);
    p.skipMisc();
    if (p.pos != p.input.len) return error.MalformedXml;

    return Document{ .arena = arena, .root = root };
}

const Parser = struct {
    a: Allocator,
    input: []const u8,
    pos: usize = 0,
    limits: Limits,
    ids: std.StringHashMap(void),
    element_count: usize = 0,

    fn rejectForbiddenMarkup(self: *Parser) ParseError!void {
        // Case-insensitive scan for the security-relevant prolog/doctype
        // constructs. We scan all bytes, including comments, fail-closed.
        const forbidden = [_][]const u8{
            "<!doctype", "<!entity", "<![if", "<![endif", "<!element", "<!attlist",
        };
        var i: usize = 0;
        while (i + 2 <= self.input.len) : (i += 1) {
            if (self.input[i] != '<') continue;
            for (forbidden) |tok| {
                if (i + tok.len > self.input.len) continue;
                var match = true;
                for (tok, 0..) |c, j| {
                    if (std.ascii.toLower(self.input[i + j]) != c) {
                        match = false;
                        break;
                    }
                }
                if (match) return error.ForbiddenXmlConstruct;
            }
        }
    }

    fn skipMisc(self: *Parser) void {
        while (self.pos < self.input.len) {
            if (isSpace(self.input[self.pos])) {
                self.pos += 1;
            } else if (std.mem.startsWith(u8, self.input[self.pos..], "<!--")) {
                // Comments are parsed and discarded; a Signature/Assertion
                // hidden in a comment is never seen as markup.
                if (std.mem.indexOfPos(u8, self.input, self.pos + 4, "-->")) |e| {
                    self.pos = e + 3;
                } else break;
            } else break;
        }
    }

    fn parseXmlDeclaration(self: *Parser) ParseError!void {
        const start = self.pos;
        const end = std.mem.indexOfPos(u8, self.input, start, "?>") orelse return error.MalformedXml;
        const decl = self.input[start .. end + 2];
        // Reject any encoding= that is not UTF-8 (case-insensitive value).
        if (findAttrValue(decl, "encoding")) |enc| {
            if (!std.ascii.eqlIgnoreCase(enc, "UTF-8")) return error.UnsupportedEncoding;
        }
        if (findAttrValue(decl, "standalone")) |sa| {
            if (!std.ascii.eqlIgnoreCase(sa, "yes") and !std.ascii.eqlIgnoreCase(sa, "no"))
                return error.MalformedXml;
        }
        self.pos = end + 2;
    }

    fn parseElement(self: *Parser, parent: ?*Node, depth: usize) ParseError!*Node {
        if (depth > self.limits.max_depth) return error.LimitExceeded;
        self.element_count += 1;
        if (self.element_count > self.limits.max_elements) return error.LimitExceeded;

        if (self.pos >= self.input.len or self.input[self.pos] != '<') return error.MalformedXml;
        const raw_start = self.pos;

        // Collect physical namespace declarations on this element first so
        // prefix/attribute resolution can consult them.
        var ns_decls = std.ArrayList(NsDecl).empty;
        errdefer ns_decls.deinit(self.a);
        var raw_attrs = std.ArrayList(RawAttr).empty;
        defer raw_attrs.deinit(self.a);

        self.pos += 1;
        const name_start = self.pos;
        const qname = try self.readName();
        _ = name_start;
        const local_start = std.mem.lastIndexOfScalar(u8, qname, ':');
        const elem_prefix = if (local_start) |c| qname[0..c] else "";
        const elem_local = if (local_start) |c| qname[c + 1 ..] else qname;
        if (elem_local.len == 0) return error.MalformedXml;

        var self_closing = false;
        while (true) {
            self.skipWs();
            if (self.pos >= self.input.len) return error.MalformedXml;
            if (self.input[self.pos] == '>') {
                self.pos += 1;
                break;
            }
            if (self.input[self.pos] == '/') {
                self.pos += 1;
                if (self.pos >= self.input.len or self.input[self.pos] != '>') return error.MalformedXml;
                self.pos += 1;
                self_closing = true;
                break;
            }
            const aname = try self.readName();
            self.skipWs();
            if (self.pos >= self.input.len or self.input[self.pos] != '=') return error.MalformedXml;
            self.pos += 1;
            self.skipWs();
            const val = try self.readQuotedValue();
            if (std.mem.eql(u8, aname, "xmlns")) {
                if (val.len == 0 and depth == 0) {
                    // xmlns="" on the root is pointless for SAML; fail closed.
                    return error.MalformedXml;
                }
                try ns_decls.append(self.a, .{ .prefix = "", .uri = val });
                if (ns_decls.items.len > self.limits.max_ns_decls_per_element) return error.LimitExceeded;
            } else if (std.mem.startsWith(u8, aname, "xmlns:")) {
                const pfx = aname[6..];
                if (pfx.len == 0 or std.mem.eql(u8, pfx, "xml") or std.mem.eql(u8, pfx, "xmlns"))
                    return error.MalformedXml;
                try ns_decls.append(self.a, .{ .prefix = pfx, .uri = val });
                if (ns_decls.items.len > self.limits.max_ns_decls_per_element) return error.LimitExceeded;
            } else {
                try raw_attrs.append(self.a, .{ .name = aname, .value = val });
                if (raw_attrs.items.len > self.limits.max_attrs_per_element) return error.LimitExceeded;
            }
        }

        // Validate namespace URIs and reject xml:base before resolving.
        for (ns_decls.items) |d| {
            if (!isAbsoluteUri(d.uri)) return error.RelativeNamespaceUri;
        }
        for (raw_attrs.items) |ra| {
            if (std.mem.eql(u8, ra.name, "xml:base")) return error.ForbiddenXmlConstruct;
        }

        // Resolve prefix -> URI: local declarations shadow inherited ones.
        // xml -> implicit URI, xmlns is reserved.
        var scope = std.StringHashMap([]const u8).init(self.a);
        try scope.put("xml", "http://www.w3.org/XML/1998/namespace");
        if (parent) |anc| {
            var cur: ?*Node = anc;
            var chain = std.ArrayList(*Node).empty;
            defer chain.deinit(self.a);
            while (cur) |n| : (cur = n.parent) try chain.append(self.a, n);
            var ci = chain.items.len;
            while (ci > 0) {
                ci -= 1;
                for (chain.items[ci].ns_decls) |d| {
                    if (d.prefix.len != 0) try scope.put(d.prefix, d.uri);
                }
            }
        }
        for (ns_decls.items) |d| {
            if (d.prefix.len != 0) try scope.put(d.prefix, d.uri);
        }
        var default_uri: []const u8 = "";
        if (parent) |anc| {
            var cur: ?*Node = anc;
            var chain = std.ArrayList(*Node).empty;
            defer chain.deinit(self.a);
            while (cur) |n| : (cur = n.parent) try chain.append(self.a, n);
            var ci = chain.items.len;
            while (ci > 0) {
                ci -= 1;
                for (chain.items[ci].ns_decls) |d| {
                    if (d.prefix.len == 0) default_uri = d.uri;
                }
            }
        }
        for (ns_decls.items) |d| {
            if (d.prefix.len == 0) default_uri = d.uri;
        }

        if (elem_prefix.len != 0 and std.mem.eql(u8, elem_prefix, "xmlns")) return error.MalformedXml;
        const elem_ns = if (elem_prefix.len == 0) default_uri else (scope.get(elem_prefix) orelse return error.UnboundPrefix);

        // Build resolved attributes, checking expanded-name uniqueness.
        var attrs = std.ArrayList(Attr).empty;
        errdefer attrs.deinit(self.a);
        for (raw_attrs.items) |ra| {
            const c = std.mem.indexOfScalar(u8, ra.name, ':');
            const aprefix = if (c) |x| ra.name[0..x] else "";
            const alocal = if (c) |x| ra.name[x + 1 ..] else ra.name;
            if (alocal.len == 0) return error.MalformedXml;
            if (std.mem.eql(u8, aprefix, "xmlns")) return error.MalformedXml;
            const ans = if (aprefix.len == 0) "" else (scope.get(aprefix) orelse return error.UnboundPrefix);
            for (attrs.items) |existing| {
                if (std.mem.eql(u8, existing.ns, ans) and std.mem.eql(u8, existing.local, alocal))
                    return error.DuplicateExpandedName;
            }
            try attrs.append(self.a, .{ .ns = ans, .local = alocal, .prefix = aprefix, .value = ra.value });
            // Collect IDs (ID/Id/id and xml:id).
            if (std.ascii.eqlIgnoreCase(alocal, "id") and (aprefix.len == 0 or std.mem.eql(u8, aprefix, "xml"))) {
                if (self.ids.contains(ra.value)) return error.DuplicateId;
                try self.ids.put(ra.value, {});
            }
        }

        const node = try self.a.create(Node);
        errdefer self.a.destroy(node);
        node.* = .{
            .ns = elem_ns,
            .local = elem_local,
            .prefix = elem_prefix,
            .attrs = &.{},
            .ns_decls = &.{},
            .parent = parent,
            .children = &.{},
            .id = null,
            .raw_start = raw_start,
            .raw_end = 0,
        };
        errdefer node.* = undefined;

        for (attrs.items) |at| {
            if (std.ascii.eqlIgnoreCase(at.local, "id") and (at.prefix.len == 0 or std.mem.eql(u8, at.prefix, "xml"))) {
                node.id = at.value;
                break;
            }
        }

        node.attrs = try attrs.toOwnedSlice(self.a);
        node.ns_decls = try ns_decls.toOwnedSlice(self.a);

        var children = std.ArrayList(Child).empty;
        errdefer children.deinit(self.a);
        var text_buf = std.ArrayList(u8).empty;
        defer text_buf.deinit(self.a);

        if (self_closing) {
            node.raw_end = self.pos;
            node.children = &.{};
            return node;
        }

        // Content loop.
        while (true) {
            if (self.pos >= self.input.len) return error.UnbalancedTag;
            if (std.mem.startsWith(u8, self.input[self.pos..], "</")) {
                self.pos += 2;
                const close_name = try self.readName();
                self.skipWs();
                if (self.pos >= self.input.len or self.input[self.pos] != '>') return error.MalformedXml;
                self.pos += 1;
                if (!std.mem.eql(u8, close_name, qname)) return error.UnbalancedTag;
                break;
            }
            if (std.mem.startsWith(u8, self.input[self.pos..], "<!--")) {
                try flushText(self.a, &text_buf, &children);
                if (std.mem.indexOfPos(u8, self.input, self.pos + 4, "-->")) |e| {
                    self.pos = e + 3;
                } else return error.MalformedXml;
                continue;
            }
            if (std.mem.startsWith(u8, self.input[self.pos..], "<![CDATA[")) {
                const cstart = self.pos + 9;
                const cend = std.mem.indexOfPos(u8, self.input, cstart, "]]>") orelse return error.MalformedXml;
                try self.appendDecoded(&text_buf, self.input[cstart..cend], true);
                if (text_buf.items.len > self.limits.max_text_bytes) return error.LimitExceeded;
                self.pos = cend + 3;
                continue;
            }
            if (std.mem.startsWith(u8, self.input[self.pos..], "<?")) {
                // PIs inside content are forbidden (c14n drops them; wrapping smell).
                return error.ForbiddenXmlConstruct;
            }
            if (self.input[self.pos] == '<') {
                // Flush accumulated text, then recursively parse the child.
                try flushText(self.a, &text_buf, &children);
                const child = try self.parseElement(node, depth + 1);
                try children.append(self.a, .{ .element = child });
                continue;
            }
            const tstart = self.pos;
            while (self.pos < self.input.len and self.input[self.pos] != '<') self.pos += 1;
            try self.appendDecoded(&text_buf, self.input[tstart..self.pos], false);
            if (text_buf.items.len > self.limits.max_text_bytes) return error.LimitExceeded;
        }

        try flushText(self.a, &text_buf, &children);
        node.children = try children.toOwnedSlice(self.a);
        node.raw_end = self.pos;
        return node;
    }

    fn skipWs(self: *Parser) void {
        while (self.pos < self.input.len and isSpace(self.input[self.pos])) self.pos += 1;
    }

    fn readName(self: *Parser) ParseError![]const u8 {
        const start = self.pos;
        while (self.pos < self.input.len) : (self.pos += 1) {
            const c = self.input[self.pos];
            if (isSpace(c) or c == '=' or c == '/' or c == '>' or c == '<' or c == '?') break;
        }
        if (self.pos == start) return error.MalformedXml;
        const name = self.input[start..self.pos];
        if (!validName(name)) return error.MalformedXml;
        return name;
    }

    fn readQuotedValue(self: *Parser) ParseError![]const u8 {
        if (self.pos >= self.input.len or (self.input[self.pos] != '"' and self.input[self.pos] != '\''))
            return error.MalformedXml;
        const q = self.input[self.pos];
        self.pos += 1;
        const start = self.pos;
        while (self.pos < self.input.len and self.input[self.pos] != q) self.pos += 1;
        if (self.pos >= self.input.len) return error.MalformedXml;
        const raw = self.input[start..self.pos];
        self.pos += 1;
        // Decode entities/refs and normalize line endings, into arena memory.
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(self.a);
        try self.appendDecoded(&out, raw, false);
        return out.toOwnedSlice(self.a);
    }

    fn appendDecoded(self: *Parser, out: *std.ArrayList(u8), raw: []const u8, in_cdata: bool) ParseError!void {
        var i: usize = 0;
        while (i < raw.len) {
            const c = raw[i];
            if (c == '\r') {
                try out.append(self.a, '\n');
                i += 1;
                if (i < raw.len and raw[i] == '\n') i += 1;
                continue;
            }
            if (!in_cdata and c == '&') {
                const semi = std.mem.indexOfScalarPos(u8, raw, i + 1, ';') orelse return error.MalformedXml;
                if (semi - i > 16) return error.MalformedXml;
                const ent = raw[i + 1 .. semi];
                if (std.mem.eql(u8, ent, "amp")) {
                    try out.append(self.a, '&');
                } else if (std.mem.eql(u8, ent, "lt")) {
                    try out.append(self.a, '<');
                } else if (std.mem.eql(u8, ent, "gt")) {
                    try out.append(self.a, '>');
                } else if (std.mem.eql(u8, ent, "quot")) {
                    try out.append(self.a, '"');
                } else if (std.mem.eql(u8, ent, "apos")) {
                    try out.append(self.a, '\'');
                } else if (ent.len > 1 and ent[0] == '#') {
                    const cp = parseCharRef(ent[1..]) orelse return error.MalformedXml;
                    var buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(cp, &buf) catch return error.MalformedXml;
                    try out.appendSlice(self.a, buf[0..n]);
                } else {
                    // Custom/undeclared entity: fail closed (no DTD exists).
                    return error.ForbiddenXmlConstruct;
                }
                i = semi + 1;
                continue;
            }
            if (!in_cdata and c == '<') return error.MalformedXml;
            try out.append(self.a, c);
            i += 1;
        }
    }
};

const RawAttr = struct { name: []const u8, value: []const u8 };

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\r' or c == '\n';
}

fn validName(s: []const u8) bool {
    if (s.len == 0) return false;
    var colon_seen = false;
    for (s, 0..) |c, i| {
        if (c == ':') {
            if (colon_seen or i == 0 or i + 1 == s.len) return false;
            colon_seen = true;
            continue;
        }
        const ok = std.ascii.isAlphabetic(c) or std.ascii.isDigit(c) or c == '_' or c == '-' or c == '.' or c >= 0x80;
        if (!ok) return false;
        if (i == 0 and (std.ascii.isDigit(c) or c == '-' or c == '.')) return false;
    }
    return true;
}

fn isAbsoluteUri(s: []const u8) bool {
    // c14n requires absolute namespace URIs. Require scheme: and reject
    // whitespace/control characters. Scheme must start with alpha.
    const colon = std.mem.indexOfScalar(u8, s, ':') orelse return false;
    if (colon == 0 or !std.ascii.isAlphabetic(s[0])) return false;
    for (s[1..colon]) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '+' or c == '-' or c == '.')) return false;
    }
    for (s) |c| {
        if (isSpace(c) or c < 0x20) return false;
    }
    return true;
}

fn parseCharRef(s: []const u8) ?u21 {
    if (s.len == 0) return null;
    var base: u8 = 10;
    var digits = s;
    if (s[0] == 'x' or s[0] == 'X') {
        base = 16;
        digits = s[1..];
    }
    if (digits.len == 0) return null;
    const v = std.fmt.parseInt(u32, digits, base) catch return null;
    if (v > 0x10ffff or (v >= 0xd800 and v <= 0xdfff)) return null;
    return @intCast(v);
}

fn findAttrValue(decl: []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + name.len <= decl.len) : (i += 1) {
        if (!std.ascii.eqlIgnoreCase(decl[i .. i + name.len], name)) continue;
        if (i > 0 and (std.ascii.isAlphanumeric(decl[i - 1]) or decl[i - 1] == '_')) continue;
        var j = i + name.len;
        while (j < decl.len and isSpace(decl[j])) j += 1;
        if (j >= decl.len or decl[j] != '=') continue;
        j += 1;
        while (j < decl.len and isSpace(decl[j])) j += 1;
        if (j >= decl.len or (decl[j] != '"' and decl[j] != '\'')) return null;
        const q = decl[j];
        j += 1;
        const start = j;
        while (j < decl.len and decl[j] != q) j += 1;
        if (j >= decl.len) return null;
        return decl[start..j];
    }
    return null;
}

fn flushText(a: Allocator, buf: *std.ArrayList(u8), children: *std.ArrayList(Child)) ParseError!void {
    if (buf.items.len == 0) return;
    const t = try a.dupe(u8, buf.items);
    errdefer a.free(t);
    try children.append(a, .{ .text = t });
    buf.clearRetainingCapacity();
}

/// Resolve a prefix to its namespace URI given an explicit inherited context.
/// Used by c14n for the apex of a subtree.
pub fn resolvePrefix(inherited: []const NsDecl, prefix: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, prefix, "xml")) return "http://www.w3.org/XML/1998/namespace";
    var i = inherited.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, inherited[i].prefix, prefix)) return inherited[i].uri;
    }
    return null;
}

/// Walk ancestors from `node` up to (excluding) `stop`, collecting namespace
/// declarations root-first into `out` (later entries shadow earlier ones).
pub fn inheritedNamespaces(a: Allocator, node: *const Node, stop: ?*const Node, out: *std.ArrayList(NsDecl)) !void {
    var chain = std.ArrayList(*const Node).empty;
    defer chain.deinit(a);
    var cur: ?*const Node = node.parent;
    while (cur) |n| {
        if (stop != null and n == stop.?) break;
        try chain.append(a, n);
        cur = n.parent;
    }
    var i = chain.items.len;
    while (i > 0) {
        i -= 1;
        try out.appendSlice(a, chain.items[i].ns_decls);
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn parseForTest(input: []const u8) !Document {
    return parse(testing.allocator, input, .{});
}

test "simple element with text" {
    var doc = try parseForTest("<a>text</a>");
    defer doc.deinit();
    try testing.expectEqualStrings("a", doc.root.local);
    try testing.expectEqualStrings("", doc.root.ns);
    try testing.expectEqual(@as(usize, 1), doc.root.children.len);
    try testing.expectEqualStrings("text", doc.root.children[0].text);
}

test "empty element has no children" {
    var doc = try parseForTest("<a/>");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 0), doc.root.children.len);
}

test "namespace resolution: prefix and default" {
    var doc = try parseForTest("<r xmlns:p=\"urn:p\" xmlns=\"urn:d\"><p:c p:a=\"1\"/></r>");
    defer doc.deinit();
    const r = doc.root;
    try testing.expectEqualStrings("urn:d", r.ns);
    const c = r.children[0].element;
    try testing.expectEqualStrings("urn:p", c.ns);
    try testing.expectEqualStrings("c", c.local);
    try testing.expectEqualStrings("p", c.prefix);
    try testing.expectEqualStrings("urn:p", c.attrs[0].ns);
}

test "entities and numeric refs decoded, CR normalized" {
    var doc = try parseForTest("<a x=\"&amp;&lt;&gt;&quot;&apos;&#x41;&#65;\">x&amp;y\r\n&#10;</a>");
    defer doc.deinit();
    try testing.expectEqualStrings("&<>\"'AA", doc.root.attrs[0].value);
    try testing.expectEqualStrings("x&y\n\n", doc.root.children[0].text);
}

test "CDATA converted to text" {
    var doc = try parseForTest("<a><![CDATA[<x&y>]]></a>");
    defer doc.deinit();
    try testing.expectEqualStrings("<x&y>", doc.root.children[0].text);
}

test "comments discarded" {
    var doc = try parseForTest("<a>one<!-- hidden <b/> -->two</a>");
    defer doc.deinit();
    try testing.expectEqual(@as(usize, 2), doc.root.children.len);
    try testing.expectEqualStrings("one", doc.root.children[0].text);
    try testing.expectEqualStrings("two", doc.root.children[1].text);
}

test "reject forbidden constructs" {
    const bad = [_][]const u8{
        "<!DOCTYPE a><a/>",
        "<a>&custom;</a>",
        "<a><?pi x?></a>",
        "<a xml:base=\"http://x/\"/>",
        "<a xmlns:p=\"relative/path\"/>",
        "<a></b>",
    };
    for (bad) |input| {
        var doc = parseForTest(input) catch |err| {
            try testing.expect(err != error.OutOfMemory);
            continue;
        };
        defer doc.deinit();
        std.debug.print("unexpectedly accepted: {s}\n", .{input});
        return error.TestUnexpectedResult;
    }
}

test "duplicate expanded name rejected" {
    var doc = parseForTest("<a xmlns:p=\"urn:p\" xmlns:q=\"urn:p\" p:x=\"1\" q:x=\"2\"/>") catch |err| {
        try testing.expectEqual(error.DuplicateExpandedName, err);
        return;
    };
    defer doc.deinit();
    return error.TestUnexpectedResult;
}

test "duplicate id rejected" {
    var doc = parseForTest("<a><b Id=\"x\"/><c id=\"x\"/></a>") catch |err| {
        try testing.expectEqual(error.DuplicateId, err);
        return;
    };
    defer doc.deinit();
    return error.TestUnexpectedResult;
}

test "input size limit" {
    var big = std.ArrayList(u8).empty;
    defer big.deinit(testing.allocator);
    try big.appendSlice(testing.allocator, "<a>");
    try big.appendNTimes(testing.allocator, 'x', 64 * 1024);
    try big.appendSlice(testing.allocator, "</a>");
    _ = parse(testing.allocator, big.items, .{}) catch |err| {
        try testing.expectEqual(error.InputTooLarge, err);
        return;
    };
    return error.TestUnexpectedResult;
}

test "inherited namespace helpers" {
    var doc = try parseForTest("<r xmlns:a=\"urn:a\"><b xmlns:b=\"urn:b\"><c/></b></r>");
    defer doc.deinit();
    const c = doc.root.children[0].element.children[0].element;
    var list = std.ArrayList(NsDecl).empty;
    defer list.deinit(testing.allocator);
    try inheritedNamespaces(testing.allocator, c, null, &list);
    // Root-first chain: a declared on grandparent, b on parent.
    try testing.expectEqual(@as(usize, 2), list.items.len);
    try testing.expectEqualStrings("a", list.items[0].prefix);
    try testing.expectEqualStrings("urn:a", list.items[0].uri);
    try testing.expectEqualStrings("b", list.items[1].prefix);
    try testing.expectEqualStrings("urn:b", list.items[1].uri);
}
