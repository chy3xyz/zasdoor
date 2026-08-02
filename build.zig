const std = @import("std");
const db_link = @import("db_link.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

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
    db_link.link(exe_mod, b, features);

    const exe = b.addExecutable(.{ .name = "zenaipa", .root_module = exe_mod });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    const run_step = b.step("run", "Run the zenaipa server");
    run_step.dependOn(&run_cmd.step);

    // Unit tests
    const tests_mod = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    tests_mod.addImport("zigmodu", zigmodu_dep.module("zigmodu"));
    tests_mod.addImport("zent", zent_dep.module("zent"));
    db_link.link(tests_mod, b, features);

    const tests = b.addTest(.{ .root_module = tests_mod });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
