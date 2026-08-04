//! zenaipa-admin — CLI for creating and listing administrator accounts.
//!
//! Commands:
//!   create-admin --email you@example.com [--password secret123] [--name Admin]
//!     Creates the first administrator (or promotes an existing user).
//!     A password is generated and printed when not provided.
//!   list-admins
//!     Lists all admin accounts.
//!
//! DB selection uses the same env vars as the server (ZENAIPA_DB_DRIVER,
//! ZENAIPA_SQLITE_PATH, ZENAIPA_PG_CONNINFO).

const std = @import("std");
const zigmodu = @import("zigmodu");
const config_mod = @import("config.zig");
const db_mod = @import("db.zig");
const schema = @import("schema.zig");
const user = @import("modules/user/root.zig");
const task = @import("modules/task/root.zig");
const file = @import("modules/file/root.zig");
const notify = @import("modules/notify/root.zig");
const tenant = @import("modules/tenant/root.zig");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer arg_it.deinit();
    _ = arg_it.skip(); // argv0

    var args = std.ArrayList([]const u8).empty;
    defer args.deinit(allocator);
    while (arg_it.next()) |a| try args.append(allocator, a);

    if (args.items.len == 0 or std.mem.eql(u8, args.items[0], "help")) {
        try printHelp(io);
        return;
    }

    const cfg = config_mod.Config.fromEnv(init.environ_map);
    const kind: db_mod.DriverKind = if (std.mem.eql(u8, cfg.db_driver, "postgres")) .postgres else .sqlite;
    const dsn = if (kind == .postgres) cfg.pg_conninfo else cfg.sqlite_path;
    var store_env = try db_mod.StoreEnv(schema.infos, .{
        tenant.persistence.infos,
        user.persistence.infos,
        task.persistence.infos,
        file.persistence.infos,
        notify.persistence.infos,
    }).open(allocator, kind, dsn);
    defer store_env.deinit();

    var store = user.persistence.UserStore.init(allocator, store_env.client);
    var sec = zigmodu.security.AppSecurity.init(allocator, io, .{
        .jwt_secret = cfg.jwt_secret,
        .token_expiry_seconds = cfg.token_expiry_seconds,
    });
    var svc = user.service.UserService.init(&store, &sec, io, cfg.password_token_expiration_seconds, cfg.verification_token_expiration_seconds);

    var tenant_store = tenant.persistence.TenantStore.init(allocator, store_env.client);
    var tenant_svc = tenant.service.TenantService.init(allocator, io, &tenant_store);
    const default_tenant_id = try tenant_svc.ensureDefault();

    const cmd = args.items[0];
    if (std.mem.eql(u8, cmd, "create-admin")) {
        try cmdCreateAdmin(io, allocator, &svc, default_tenant_id, args.items[1..]);
    } else if (std.mem.eql(u8, cmd, "list-admins")) {
        try cmdListAdmins(io, allocator, &store);
    } else {
        std.log.err("unknown command: {s}", .{cmd});
        try printHelp(io);
    }
}

fn printHelp(io: std.Io) !void {
    try std.Io.File.stdout().writeStreamingAll(io,
        \\zenaipa-admin — bootstrap administrators for zenaipa
        \\
        \\  create-admin --email you@example.com [--password secret123] [--name Admin]
        \\  list-admins
        \\
    );
}

fn cmdCreateAdmin(io: std.Io, allocator: std.mem.Allocator, svc: *user.service.UserService, default_tenant_id: i64, args: []const []const u8) !void {
    var email: ?[]const u8 = null;
    var password: ?[]const u8 = null;
    var name: []const u8 = "Administrator";

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--email") and i + 1 < args.len) {
            email = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--password") and i + 1 < args.len) {
            password = args[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, a, "--name") and i + 1 < args.len) {
            name = args[i + 1];
            i += 1;
        } else {
            try printLine(io, "unknown flag: ");
            try printLine(io, a);
            try printLine(io, "\n");
            try printHelp(io);
            return;
        }
    }
    if (email == null) {
        try printLine(io, "--email is required\n");
        try printHelp(io);
        return;
    }

    const final_password = password orelse try randomPassword(allocator, io);
    defer if (password == null) allocator.free(final_password);

    // Promote when the user already exists.
    if (try svc.getUserByEmail(allocator, email.?)) |existing| {
        defer existing.free(allocator);
        try svc.setAdmin(existing.id, true);
        try svc.setVerified(existing.id, true);
        if (password != null) {
            try svc.setPassword(existing.id, final_password);
        }
        const line = try std.fmt.allocPrint(allocator, "admin promoted: {s} (id={d})\n", .{ existing.email, existing.id });
        defer allocator.free(line);
        try printLine(io, line);
        return;
    }

    var session = try svc.register(allocator, name, email.?, final_password, true, default_tenant_id);
    defer session.deinit(allocator);
    try svc.setVerified(session.row.id, true);
    const line = try std.fmt.allocPrint(allocator, "admin created: {s} (id={d})\n", .{ session.row.email, session.row.id });
    defer allocator.free(line);
    try printLine(io, line);
    if (password == null) {
        const pw_line = try std.fmt.allocPrint(allocator, "generated password: {s}\n", .{final_password});
        defer allocator.free(pw_line);
        try printLine(io, pw_line);
    }
}

fn cmdListAdmins(io: std.Io, allocator: std.mem.Allocator, store: *user.persistence.UserStore) !void {
    var result = try store.listUsers(1, 1000, null, null, null, false);
    defer result.free(allocator);
    for (result.items) |u| {
        if (u.admin) {
            const line = try std.fmt.allocPrint(allocator, "{s} (id={d})\n", .{ u.email, u.id });
            defer allocator.free(line);
            try printLine(io, line);
        }
    }
}

fn randomPassword(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
    const chars = "abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789";
    var out = try allocator.alloc(u8, 16);
    var rng_file = try std.Io.Dir.cwd().openFile(io, "/dev/urandom", .{});
    defer rng_file.close(io);
    var buf: [16]u8 = undefined;
    const read = try rng_file.readPositionalAll(io, &buf, 0);
    if (read != buf.len) return error.Unexpected;
    for (buf, 0..) |b, i| {
        out[i] = chars[b % chars.len];
    }
    return out;
}

fn printLine(io: std.Io, msg: []const u8) !void {
    try std.Io.File.stdout().writeStreamingAll(io, msg);
}
