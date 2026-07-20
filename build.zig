const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{ .name = "takahashi", .root_module = exe_mod });

    // Window output form (SPEC 3.1): the vendored sokol single-header C
    // libraries, compiled here. No package dependency is fetched — only system
    // OpenGL/X11 libraries are linked (installed by the SessionStart hook).
    const sokol_c = b.addTranslateC(.{
        .root_source_file = b.path("vendor/sokol/sokol.h"),
        .target = target,
        .optimize = optimize,
    });
    sokol_c.addIncludePath(b.path("vendor/sokol"));
    exe_mod.addImport("sokol", sokol_c.createModule());
    exe_mod.addCSourceFile(.{ .file = b.path("vendor/sokol/sokol.c") });
    exe_mod.addIncludePath(b.path("vendor/sokol"));
    exe_mod.link_libc = true;
    exe_mod.linkSystemLibrary("GL", .{});
    exe_mod.linkSystemLibrary("X11", .{});
    exe_mod.linkSystemLibrary("Xi", .{});
    exe_mod.linkSystemLibrary("Xcursor", .{});

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Tests and fuzzing are rooted at test.zig, which imports every module that
    // does not touch the window backend. No sokol, no display, no network.
    const test_mod = b.createModule(.{
        .root_source_file = b.path("test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const unit_tests = b.addTest(.{ .root_module = test_mod });
    const run_tests = b.addRunArtifact(unit_tests);
    // Each `std.testing.fuzz` test runs once here; `zig build test --fuzz`
    // fuzzes continuously (it serves a coverage UI, so it needs a network
    // socket available).
    const test_step = b.step("test", "Run unit and integration tests");
    test_step.dependOn(&run_tests.step);

    // Formatting gate.
    const fmt = b.addFmt(.{
        .paths = &.{ "src", "build.zig", "build.zig.zon", "test.zig", "integration_test.zig" },
        .check = true,
    });
    const check_step = b.step("check", "Verify formatting with zig fmt");
    check_step.dependOn(&fmt.step);
}
