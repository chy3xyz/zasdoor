const std = @import("std");
const db_link = @import("db_link.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Build-time version baked into /system/info and the shutdown log. Bump in
    // step with the CHANGELOG; releases can override with -Drelease=x.y.z.
    const version = b.option([]const u8, "release", "Version string embedded in /system/info") orelse "0.4.0";
    const build_info = b.addOptions();
    build_info.addOption([]const u8, "version", version);

    // Link SQLite + Postgres + MySQL drivers (drivers discovered by db_link/dependency build).
    const features = db_link.Features.all;

    const zigmodu_dep = b.dependency("zigmodu", .{
        .target = target,
        .optimize = optimize,
    });
    const zent_dep = b.dependency("zent", .{
        .target = target,
        .optimize = optimize,
    });

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("zigmodu", zigmodu_dep.module("zigmodu"));
    exe_mod.addImport("zent", zent_dep.module("zent"));
    exe_mod.addOptions("build_info", build_info);
    db_link.link(exe_mod, b, features);

    const exe = b.addExecutable(.{ .name = "zasdoor", .root_module = exe_mod });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the zasdoor server");
    run_step.dependOn(&run_cmd.step);

    // Admin CLI (create/list administrator accounts)
    const admin_mod = b.createModule(.{
        .root_source_file = b.path("src/admin_cli.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    admin_mod.addImport("zigmodu", zigmodu_dep.module("zigmodu"));
    admin_mod.addImport("zent", zent_dep.module("zent"));
    admin_mod.addOptions("build_info", build_info);
    db_link.link(admin_mod, b, features);

    const admin_exe = b.addExecutable(.{ .name = "zasdoor-admin", .root_module = admin_mod });
    b.installArtifact(admin_exe);

    const admin_cmd = b.addRunArtifact(admin_exe);
    admin_cmd.step.dependOn(b.getInstallStep());
    const admin_step = b.step("admin", "Admin CLI help; run zig-out/bin/zasdoor-admin create-admin --email you@example.com");
    admin_step.dependOn(&admin_cmd.step);

    // Unit tests
    const tests_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    tests_mod.addImport("zigmodu", zigmodu_dep.module("zigmodu"));
    tests_mod.addImport("zent", zent_dep.module("zent"));
    tests_mod.addOptions("build_info", build_info);
    db_link.link(tests_mod, b, features);

    const tests = b.addTest(.{ .root_module = tests_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    // Size gate: fail if any src/**/*.zig exceeds the line budget.
    const size_check = b.addSystemCommand(&.{ "/bin/sh", "scripts/check_file_size.sh" });
    const lint_size = b.step("lint-size", "Fail if any src/**/*.zig exceeds the line budget (1800)");
    lint_size.dependOn(&size_check.step);

    // Format gate: fail if any src/**/*.zig is not zig-fmt clean.
    const fmt_check = b.addSystemCommand(&.{ b.graph.zig_exe, "fmt", "--check", "src" });
    const lint_fmt = b.step("lint-fmt", "Fail if any src/**/*.zig is not zig-fmt clean");
    lint_fmt.dependOn(&fmt_check.step);
}
