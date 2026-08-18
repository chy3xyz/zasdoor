//! EIP-4361 (Sign-In With Ethereum) message parser + validator.

const std = @import("std");

pub const ParseError = error{
    Malformed,
    MissingField,
    InvalidField,
    Expired,
    NotYetValid,
    DomainMismatch,
    AddressMismatch,
};

pub const SiweMessage = struct {
    domain: []const u8,
    address: []const u8,
    statement: ?[]const u8 = null,
    uri: []const u8 = "",
    version: u8,
    chain_id: i64,
    nonce: []const u8,
    issued_at: i64,
    expiration_time: ?i64 = null,
    not_before: ?i64 = null,
    resources: [][]const u8 = &.{},
    raw: []const u8,

    pub fn free(self: SiweMessage, a: std.mem.Allocator) void {
        a.free(self.raw);
        a.free(self.domain);
        a.free(self.address);
        if (self.statement) |s| a.free(s);
        a.free(self.uri);
        a.free(self.nonce);
        for (self.resources) |r| a.free(r);
        a.free(self.resources);
    }
};

fn trim(s: []const u8) []const u8 {
    var lo: usize = 0;
    while (lo < s.len and (s[lo] == ' ' or s[lo] == '\t' or s[lo] == '\r' or s[lo] == '\n')) : (lo += 1) {}
    var hi: usize = s.len;
    while (hi > lo and (s[hi - 1] == ' ' or s[hi - 1] == '\t' or s[hi - 1] == '\r' or s[hi - 1] == '\n')) : (hi -= 1) {}
    return s[lo..hi];
}

fn parseIso8601(s: []const u8) ParseError!i64 {
    if (s.len < 19) return error.InvalidField;
    var p: usize = 0;
    var year: i64 = 0;
    while (p < 4) : (p += 1) {
        const c = s[p];
        if (c < '0' or c > '9') return error.InvalidField;
        year = year * 10 + (c - '0');
    }
    if (s[p] != '-') return error.InvalidField;
    p += 1;
    var month: i64 = 0;
    var i: usize = 0;
    while (i < 2) : (i += 1) {
        const c = s[p];
        if (c < '0' or c > '9') return error.InvalidField;
        month = month * 10 + (c - '0');
        p += 1;
    }
    if (s[p] != '-') return error.InvalidField;
    p += 1;
    var day: i64 = 0;
    i = 0;
    while (i < 2) : (i += 1) {
        const c = s[p];
        if (c < '0' or c > '9') return error.InvalidField;
        day = day * 10 + (c - '0');
        p += 1;
    }
    if (s[p] != 'T') return error.InvalidField;
    p += 1;
    var hh: i64 = 0;
    i = 0;
    while (i < 2) : (i += 1) {
        const c = s[p];
        if (c < '0' or c > '9') return error.InvalidField;
        hh = hh * 10 + (c - '0');
        p += 1;
    }
    if (s[p] != ':') return error.InvalidField;
    p += 1;
    var mm: i64 = 0;
    i = 0;
    while (i < 2) : (i += 1) {
        const c = s[p];
        if (c < '0' or c > '9') return error.InvalidField;
        mm = mm * 10 + (c - '0');
        p += 1;
    }
    if (s[p] != ':') return error.InvalidField;
    p += 1;
    var ss: i64 = 0;
    i = 0;
    while (i < 2) : (i += 1) {
        const c = s[p];
        if (c < '0' or c > '9') return error.InvalidField;
        ss = ss * 10 + (c - '0');
        p += 1;
    }
    if (p < s.len and s[p] == '.') {
        p += 1;
        while (p < s.len and s[p] >= '0' and s[p] <= '9') : (p += 1) {}
    }
    if (p < s.len and (s[p] == 'Z' or s[p] == 'z')) p += 1;
    if (p != s.len) return error.InvalidField;
    if (month < 1 or month > 12) return error.InvalidField;
    const dim = [12]i64{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    var days: i64 = 0;
    var y: i64 = 1970;
    while (y < year) : (y += 1) {
        days += if (isLeap(y)) 366 else 365;
    }
    var m: i64 = 1;
    while (m < month) : (m += 1) {
        days += dim[@intCast(m - 1)];
        if (m == 2 and isLeap(year)) days += 1;
    }
    var max_day = dim[@intCast(month - 1)];
    if (month == 2 and isLeap(year)) max_day += 1;
    if (day < 1 or day > max_day) return error.InvalidField;
    days += day - 1;
    return days * 86400 + hh * 3600 + mm * 60 + ss;
}

fn isLeap(y: i64) bool {
    return (@mod(y, 4) == 0 and @mod(y, 100) != 0) or @mod(y, 400) == 0;
}

pub fn parse(allocator: std.mem.Allocator, message: []const u8) anyerror!SiweMessage {
    const raw = try allocator.dupe(u8, message);
    var it = std.mem.splitScalar(u8, message, '\n');
    const header = it.next() orelse return error.Malformed;
    const header_trim = trim(header);
    const wants = " wants you to sign in with your Ethereum account:";
    if (!std.mem.endsWith(u8, header_trim, wants)) return error.Malformed;
    const domain = try allocator.dupe(u8, header_trim[0 .. header_trim.len - wants.len]);
    const addr_line = it.next() orelse return error.Malformed;
    const address = try allocator.dupe(u8, trim(addr_line));
    if (address.len == 0) return error.Malformed;
    _ = it.next() orelse return error.Malformed;

    var statement: ?[]const u8 = null;
    var uri_line: []const u8 = "";
    var version: u8 = 0;
    var chain_id: i64 = -1;
    var nonce: []const u8 = "";
    var issued_at: i64 = 0;
    var expiration_time: ?i64 = null;
    var not_before: ?i64 = null;
    var resources_buf: [8][]const u8 = undefined;
    var resources_count: usize = 0;
    var in_resources = false;
    var structured = false;
    while (it.next()) |raw_line| {
        const line = trim(raw_line);
        if (line.len == 0) continue;
        if (in_resources) {
            if (std.mem.startsWith(u8, line, "- ")) {
                if (resources_count >= resources_buf.len) return error.Malformed;
                resources_buf[resources_count] = try allocator.dupe(u8, line[2..]);
                resources_count += 1;
            } else {
                return error.Malformed;
            }
        } else if (std.mem.startsWith(u8, line, "Version:")) {
            structured = true;
            version = std.fmt.parseInt(u8, line[9..], 10) catch return error.InvalidField;
        } else if (std.mem.startsWith(u8, line, "Chain ID:")) {
            structured = true;
            chain_id = std.fmt.parseInt(i64, line[10..], 10) catch return error.InvalidField;
        } else if (std.mem.startsWith(u8, line, "Nonce:")) {
            structured = true;
            nonce = try allocator.dupe(u8, line[7..]);
        } else if (std.mem.startsWith(u8, line, "Issued At:")) {
            structured = true;
            issued_at = try parseIso8601(line[11..]);
        } else if (std.mem.startsWith(u8, line, "Expiration Time:")) {
            structured = true;
            expiration_time = try parseIso8601(line[17..]);
        } else if (std.mem.startsWith(u8, line, "Not Before:")) {
            structured = true;
            not_before = try parseIso8601(line[12..]);
        } else if (std.mem.eql(u8, line, "Resources:")) {
            structured = true;
            in_resources = true;
        } else if (std.mem.startsWith(u8, line, "URI: ")) {
            if (!structured) uri_line = try allocator.dupe(u8, line[5..]);
        } else if (!structured) {
            if (statement == null) {
                statement = try allocator.dupe(u8, line);
            } else {
                const old = statement.?;
                var merged = try allocator.alloc(u8, old.len + 1 + line.len);
                @memcpy(merged[0..old.len], old);
                merged[old.len] = '\n';
                @memcpy(merged[old.len + 1 ..], line);
                allocator.free(old);
                statement = merged;
            }
        } else {
            return error.Malformed;
        }
    }

    if (version != 1) return error.InvalidField;
    if (chain_id < 0) return error.MissingField;
    if (nonce.len == 0) return error.MissingField;
    return .{
        .domain = domain,
        .address = address,
        .statement = statement,
        .uri = uri_line,
        .version = version,
        .chain_id = chain_id,
        .nonce = nonce,
        .issued_at = issued_at,
        .expiration_time = expiration_time,
        .not_before = not_before,
        .resources = try allocator.dupe([]const u8, resources_buf[0..resources_count]),
        .raw = raw,
    };
}
