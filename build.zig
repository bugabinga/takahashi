const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // The raylib window backend (SPEC 3.1) is opt-in: it pulls a GitHub
    // dependency that needs a network connection to fetch. Everything else —
    // building the CLI, the file forms, and the whole test suite — needs
    // neither raylib nor the network. To build the window form:
    //   zig fetch --save git+https://github.com/raysan5/raylib
    //   zig build -Dwindow=true
    const build_window = b.option(
        bool,
        "window",
        "Build the raylib window output form (needs the raylib dependency).",
    ) orelse false;

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{ .name = "takahashi", .root_module = exe_mod });

    // window.zig imports "raylib"; swap what that name resolves to. The real
    // build translates raylib's header and links the library; the default
    // build uses a no-op stub, so it compiles and links offline without a
    // display. main.zig never references raylib either way.
    if (build_window) {
        const raylib_dep = b.dependency("raylib", .{ .target = target, .optimize = optimize });
        const raylib_translate = b.addTranslateC(.{
            .root_source_file = b.path("src/raylib.h"),
            .target = target,
            .optimize = optimize,
        });
        raylib_translate.addIncludePath(raylib_dep.path("src"));
        exe_mod.addImport("raylib", raylib_translate.createModule());
        exe_mod.linkLibrary(raylib_dep.artifact("raylib"));
    } else {
        const raylib_stub = b.createModule(.{
            .root_source_file = b.path("src/raylib_stub.zig"),
            .target = target,
            .optimize = optimize,
        });
        exe_mod.addImport("raylib", raylib_stub);
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // Tests and fuzzing are rooted at src/test.zig, which imports every
    // raylib-free module. No window backend, no network, no display.
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
