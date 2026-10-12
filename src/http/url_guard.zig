//! Outbound URL validation (OWASP API4 SSRF baseline).
//! The server actively calls URLs configured by administrators, so both the
//! write path and the pre-outbound path route through this module to reject
//! non-http(s) and literal private/loopback hosts. Wired into:
//! - AI provider endpoints (ai/api.zig create/update write check;
//!   ai/service.zig chat/checkProvider pre-outbound re-check, so rows written
//!   before this guard cannot bypass it).
//! Note: the SMTP host comes from the environment, not admin input, so it is
//! out of scope here.

const std = @import("std");

/// Whether a URL may be the target of a server-side outbound request:
/// scheme must be http/https, host non-empty, and not a literal
/// loopback/private address.
///
/// Limits (literal matching only, a baseline):
/// - no DNS resolution: a name that resolves to an internal IP (incl. DNS
///   rebinding) is not caught;
/// - equivalent IP spellings (decimal/hex integer forms, IPv6-mapped) are not
///   recognised;
/// - full protection needs a second check at the connection layer against the
///   resolved IP (egress proxy / network policy).
pub fn isAcceptableOutboundUrl(url: []const u8) bool {
    // Only http/https (case-insensitive); anything else (ftp/file/no scheme) is refused.
    const rest = if (std.ascii.startsWithIgnoreCase(url, "https://"))
        url["https://".len..]
    else if (std.ascii.startsWithIgnoreCase(url, "http://"))
        url["http://".len..]
    else
        return false;

    // authority runs to the first / ? #.
    const authority_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    var authority = rest[0..authority_end];

    // Strip userinfo (user:pass@host): take after the last '@', so
    // http://x@127.0.0.1/ cannot smuggle a literal past the check.
    if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| authority = authority[at + 1 ..];

    // host: IPv6 literal keeps its []; otherwise up to the first ':' (port).
    var host: []const u8 = undefined;
    if (authority.len > 0 and authority[0] == '[') {
        const close = std.mem.indexOfScalar(u8, authority, ']') orelse return false;
        host = authority[0 .. close + 1];
    } else {
        const colon = std.mem.indexOfScalar(u8, authority, ':') orelse authority.len;
        host = authority[0..colon];
    }
    if (host.len == 0) return false;

    return !isLiteralPrivateHost(host);
}

/// Literal loopback/private check (no resolution, no DNS):
/// localhost, ::1 and [::1], 127. / 10. / 192.168. / 169.254. prefixes, and
/// the 172.16.–172.31. range.
fn isLiteralPrivateHost(host: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(host, "localhost")) return true;
    if (std.mem.eql(u8, host, "::1") or std.mem.eql(u8, host, "[::1]")) return true;
    if (std.ascii.startsWithIgnoreCase(host, "127.")) return true;
    if (std.ascii.startsWithIgnoreCase(host, "10.")) return true;
    if (std.ascii.startsWithIgnoreCase(host, "192.168.")) return true;
    if (std.ascii.startsWithIgnoreCase(host, "169.254.")) return true;
    // 172.16.0.0 – 172.31.255.255: parse the second octet after "172.".
    if (std.ascii.startsWithIgnoreCase(host, "172.")) {
        const second_end = std.mem.indexOfScalarPos(u8, host, 4, '.') orelse return false;
        const second = std.fmt.parseInt(u16, host[4..second_end], 10) catch return false;
        if (second >= 16 and second <= 31) return true;
    }
    return false;
}

test "url_guard rejects non-http schemes" {
    try std.testing.expect(!isAcceptableOutboundUrl("ftp://example.com"));
    try std.testing.expect(!isAcceptableOutboundUrl("file:///etc/passwd"));
    try std.testing.expect(!isAcceptableOutboundUrl("example.com"));
    try std.testing.expect(!isAcceptableOutboundUrl(""));
}

test "url_guard rejects literal loopback and private hosts" {
    try std.testing.expect(!isAcceptableOutboundUrl("http://localhost/api"));
    try std.testing.expect(!isAcceptableOutboundUrl("http://127.0.0.1:8080/v1"));
    try std.testing.expect(!isAcceptableOutboundUrl("http://10.0.0.1/"));
    try std.testing.expect(!isAcceptableOutboundUrl("http://192.168.1.1/"));
    try std.testing.expect(!isAcceptableOutboundUrl("http://169.254.169.254/latest/meta-data"));
    try std.testing.expect(!isAcceptableOutboundUrl("http://172.16.0.1/"));
    try std.testing.expect(!isAcceptableOutboundUrl("http://172.31.255.255/"));
    try std.testing.expect(!isAcceptableOutboundUrl("http://[::1]/"));
    try std.testing.expect(!isAcceptableOutboundUrl("http://user:pass@127.0.0.1/"));
    // 172.32.0.1 is public, allowed.
    try std.testing.expect(isAcceptableOutboundUrl("http://172.32.0.1/"));
}

test "url_guard accepts public http(s) urls" {
    try std.testing.expect(isAcceptableOutboundUrl("https://api.openai.com/v1/chat/completions"));
    try std.testing.expect(isAcceptableOutboundUrl("http://api.example.com:8080/v1"));
    try std.testing.expect(isAcceptableOutboundUrl("HTTPS://API.EXAMPLE.COM/path"));
}
