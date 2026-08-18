//! Mail service — console sink (dev) + real SMTP transport (prod).
//!
//! SMTP supports AUTH PLAIN and optional STARTTLS. When `ZASDOOR_SMTP_HOST`
//! is empty the mailer only logs, so the rest of the app works without a
//! mail server (SMTP becomes a drop-in for the console sink).

const std = @import("std");

pub const MailMessage = struct {
    to: []const u8,
    subject: []const u8,
    text: []const u8,
};

pub const Mailer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    host: []const u8,
    port: u16,
    username: []const u8,
    password: []const u8,
    from: []const u8,
    starttls: bool,
    console: bool,
    /// System CA bundle for STARTTLS server-certificate verification,
    /// loaded once in `init` (lazily skipped for console-only mailers).
    /// Read during the TLS handshake only — `tls.Client` does not retain it.
    ca_bundle: std.crypto.Certificate.Bundle = .empty,
    ca_lock: std.Io.RwLock = .init,
    /// True when the system CA bundle loaded successfully; otherwise the
    /// handshake falls back to `no_verification` (dev / unreachable CA).
    ca_verified: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        host: []const u8,
        port: u16,
        username: []const u8,
        password: []const u8,
        from: []const u8,
        starttls: bool,
        console: bool,
    ) Mailer {
        var self = Mailer{
            .allocator = allocator,
            .io = io,
            .host = host,
            .port = port,
            .username = username,
            .password = password,
            .from = from,
            .starttls = starttls,
            .console = console,
        };
        if (host.len > 0 and starttls) {
            const now = std.Io.Timestamp.now(io, .real);
            self.ca_bundle.rescan(allocator, io, now) catch |err| {
                // Deliberate fail-open: mail delivery is best-effort by design
                // (`send` swallows transport errors), so a missing/unsupported
                // system CA store must not block the app. A warn is emitted so
                // production operators notice the degraded trust posture; to
                // force verification, run behind a proxy or patch this site.
                std.log.warn("[mail] system CA bundle unavailable ({s}) — STARTTLS will not verify the server certificate", .{@errorName(err)});
                return self;
            };
            self.ca_verified = true;
        }
        return self;
    }

    pub fn deinit(self: *Mailer) void {
        self.ca_bundle.deinit(self.allocator);
    }

    /// Deliver a message: log (console sink) and/or SMTP. Never fails the
    /// caller on transport errors — mail is best-effort and the caller
    /// already stored the token. Errors are logged and swallowed.
    pub fn send(self: *Mailer, msg: MailMessage) void {
        if (self.console) {
            std.log.info("[mail] to={s} subject=\"{s}\"\n{s}", .{ msg.to, msg.subject, msg.text });
        }
        if (self.host.len == 0) return;
        self.sendSmtp(msg) catch |err| {
            std.log.err("[mail] SMTP delivery to {s} failed: {s}", .{ msg.to, @errorName(err) });
        };
    }

    fn sendSmtp(self: *Mailer, msg: MailMessage) !void {
        var conn = try SmtpConnection.connect(self);
        defer conn.close();

        try conn.ehlo(self.host);
        if (self.starttls and self.port != 465) {
            try conn.startTls();
            try conn.ehlo(self.host);
        }
        if (self.username.len > 0) {
            try conn.authPlain(self.username, self.password);
        }
        try conn.mailFrom(self.from);
        try conn.rcptTo(msg.to);
        try conn.data(msg.to, self.from, msg.subject, msg.text);
    }
};

/// One SMTP session over a TCP stream (optionally upgraded to TLS).
const SmtpConnection = struct {
    io: std.Io,
    stream: ?std.Io.net.Stream = null,
    tls: ?std.crypto.tls.Client = null,
    /// Borrowed from the Mailer for the duration of this session (STARTTLS
    /// handshake only — `tls.Client` releases the bundle before init returns).
    mailer: *Mailer = undefined,
    read_buf: [4096]u8 = undefined,
    write_buf: [4096]u8 = undefined,

    fn connect(self: *Mailer) !SmtpConnection {
        const addr = try std.Io.net.IpAddress.resolve(self.io, self.host, self.port);
        const stream = try addr.connect(self.io, .{ .mode = .stream });
        errdefer stream.close(self.io);

        var conn = SmtpConnection{ .io = self.io, .stream = stream, .mailer = self };
        try conn.expectCode('2', "connect greeting");
        return conn;
    }

    fn close(self: *SmtpConnection) void {
        if (self.stream) |s| s.close(self.io);
        self.stream = null;
        self.tls = null;
    }

    /// Plain-text writer (pre-TLS).
    fn plainWriter(self: *SmtpConnection) std.Io.net.Stream.Writer {
        const stream = self.stream orelse unreachable;
        return stream.writer(self.io, &self.write_buf);
    }

    fn sendLine(self: *SmtpConnection, line: []const u8) !void {
        if (self.tls) |*t| {
            try t.writer.writeAll(line);
            try t.writer.writeAll("\r\n");
            try t.writer.flush();
        } else {
            var w = self.plainWriter();
            try w.interface.writeAll(line);
            try w.interface.writeAll("\r\n");
            try w.interface.flush();
        }
    }

    /// Read one SMTP reply line (up to `read_buf`). Expects the leading
    /// digit class (`2`=ok, `3`=continue, `4/5`=error).
    fn expectCode(self: *SmtpConnection, comptime class: u8, what: []const u8) !void {
        const line = try self.readLine();
        if (line.len < 3) return error.SmtpProtocolError;
        if (line[0] != class) {
            std.log.err("[mail] SMTP {s} rejected: {s}", .{ what, std.mem.trim(u8, line, " \r\n") });
            return error.SmtpRejected;
        }
        // Multiline replies ("250-...") — drain continuation lines.
        if (line.len >= 4 and line[3] == '-') {
            while (true) {
                const cont = try self.readLine();
                if (cont.len >= 4 and cont[3] == ' ') break;
            }
        }
    }

    fn readLine(self: *SmtpConnection) ![]const u8 {
        var i: usize = 0;
        while (i < self.read_buf.len) {
            var one: [1]u8 = undefined;
            const n = if (self.tls) |*t|
                try t.reader.readSliceShort(&one)
            else blk: {
                const stream = self.stream orelse unreachable;
                var iovec: [1][]u8 = .{&one};
                break :blk try stream.read(self.io, &iovec);
            };
            if (n == 0) return error.ConnectionClosed;
            self.read_buf[i] = one[0];
            i += 1;
            if (one[0] == '\n') break;
        }
        return self.read_buf[0..i];
    }

    fn ehlo(self: *SmtpConnection, hostname: []const u8) !void {
        try self.sendLine("EHLO zasdoor");
        try self.expectCode('2', "EHLO");
        _ = hostname;
    }

    fn startTls(self: *SmtpConnection) !void {
        const mailer = self.mailer;
        const host = mailer.host;
        try self.sendLine("STARTTLS");
        try self.expectCode('2', "STARTTLS");

        const stream = self.stream orelse unreachable;
        var entropy: [240]u8 = undefined; // std.crypto.tls.Client.entropy_len
        try fillEntropy(self.io, &entropy);
        var plain_reader = stream.reader(self.io, &self.read_buf);
        var plain_writer = stream.writer(self.io, &self.write_buf);

        const tls_client = try std.crypto.tls.Client.init(
            &plain_reader.interface,
            &plain_writer.interface,
            .{
                .host = .{ .explicit = host },
                .ca = if (mailer.ca_verified)
                    .{ .bundle = .{ .gpa = mailer.allocator, .io = mailer.io, .lock = &mailer.ca_lock, .bundle = &mailer.ca_bundle } }
                else
                    .no_verification,
                .write_buffer = &self.write_buf,
                .read_buffer = &self.read_buf,
                .entropy = &entropy,
                .realtime_now = std.Io.Timestamp.now(self.io, .real),
            },
        );
        self.tls = tls_client;
    }

    fn authPlain(self: *SmtpConnection, username: []const u8, password: []const u8) !void {
        const creds = try std.fmt.allocPrint(std.heap.page_allocator, "\x00{s}\x00{s}", .{ username, password });
        defer std.heap.page_allocator.free(creds);
        const b64 = std.base64.standard.Encoder.calcSize(creds.len);
        var out: [512]u8 = undefined;
        if (b64 > out.len) return error.SmtpAuthTooLong;
        const encoded = std.base64.standard.Encoder.encode(&out, creds);
        var line_buf: [600]u8 = undefined;
        const line = try std.fmt.bufPrint(&line_buf, "AUTH PLAIN {s}", .{encoded});
        try self.sendLine(line);
        try self.expectCode('2', "AUTH");
    }

    fn mailFrom(self: *SmtpConnection, from: []const u8) !void {
        var line_buf: [512]u8 = undefined;
        const line = try std.fmt.bufPrint(&line_buf, "MAIL FROM:<{s}>", .{from});
        try self.sendLine(line);
        try self.expectCode('2', "MAIL FROM");
    }

    fn rcptTo(self: *SmtpConnection, to: []const u8) !void {
        var line_buf: [512]u8 = undefined;
        const line = try std.fmt.bufPrint(&line_buf, "RCPT TO:<{s}>", .{to});
        try self.sendLine(line);
        try self.expectCode('2', "RCPT TO");
    }

    fn data(self: *SmtpConnection, to: []const u8, from: []const u8, subject: []const u8, text: []const u8) !void {
        try self.sendLine("DATA");
        try self.expectCode('3', "DATA");

        // Build the full message once, then write it in a single block.
        var msg: std.ArrayList(u8) = .empty;
        defer msg.deinit(std.heap.page_allocator);
        try msg.appendSlice(std.heap.page_allocator, "From: ");
        try msg.appendSlice(std.heap.page_allocator, from);
        try msg.appendSlice(std.heap.page_allocator, "\r\nTo: ");
        try msg.appendSlice(std.heap.page_allocator, to);
        try msg.appendSlice(std.heap.page_allocator, "\r\nSubject: ");
        try msg.appendSlice(std.heap.page_allocator, subject);
        try msg.appendSlice(std.heap.page_allocator, "\r\nMIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n");

        // Dot-stuff body lines.
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |part| {
            const trimmed = std.mem.trim(u8, part, "\r");
            if (std.mem.startsWith(u8, trimmed, ".")) try msg.appendSlice(std.heap.page_allocator, ".");
            try msg.appendSlice(std.heap.page_allocator, trimmed);
            try msg.appendSlice(std.heap.page_allocator, "\r\n");
        }
        try msg.appendSlice(std.heap.page_allocator, ".\r\n");

        if (self.tls) |*t| {
            try t.writer.writeAll(msg.items);
            try t.writer.flush();
        } else {
            var w = self.plainWriter();
            try w.interface.writeAll(msg.items);
            try w.interface.flush();
        }
        try self.expectCode('2', "message body");
        try self.sendLine("QUIT");
    }
};

fn fillEntropy(io: std.Io, buf: []u8) !void {
    var file = try std.Io.Dir.cwd().openFile(io, "/dev/urandom", .{});
    defer file.close(io);
    const read = try file.readPositionalAll(io, buf, 0);
    if (read != buf.len) return error.Unexpected;
}
