const std = @import("std");

pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native.
    const target = b.standardTargetOptions(.{});

    // Standard optimization options allow the person running `zig build` to
    // select between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const optimize = b.standardOptimizeOption(.{});

    // raylib supplies the immediate-mode window and renderer for the window
    // output form (SPEC 3.1). Pin the exact version once with:
    //   zig fetch --save git+https://github.com/raysan5/raylib
    const raylib_dep = b.dependency("raylib", .{
        .target = target,
        .optimize = optimize,
    });
    const raylib_lib = raylib_dep.artifact("raylib");

    // Modern Zig binds C through the build system, not `@cImport` (removed in
    // 0.16). Translate raylib's header into a Zig module imported as "raylib".
    const raylib_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/raylib.h"),
        .target = target,
        .optimize = optimize,
    });
    raylib_translate.addIncludePath(raylib_dep.path("src"));
    const raylib_mod = raylib_translate.createModule();

    const exe = b.addExecutable(.{
        .name = "takahashi",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "raylib", .module = raylib_mod },
            },
        }),
    });
    exe.linkLibrary(raylib_lib);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    // `zig build test` runs the unit tests.
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "raylib", .module = raylib_mod },
            },
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
