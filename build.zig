const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{ .name = "taka", .root_module = exe_mod });
    const os = target.result.os.tag;

    // Window output form (SPEC 3.1): the vendored sokol single-header C
    // libraries, compiled here. No package dependency is fetched; sokol selects
    // its backend (GL on Linux, Metal on macOS, D3D11 on Windows) from the
    // target, and we link that platform's window/graphics system libraries.
    const sokol_c = b.addTranslateC(.{
        .root_source_file = b.path("vendor/sokol/sokol.h"),
        .target = target,
        .optimize = optimize,
    });
    sokol_c.addIncludePath(b.path("vendor/sokol"));
    exe_mod.addImport("sokol", sokol_c.createModule());
    // sokol_app on macOS is Objective-C; compile the impl unit as such with
    // -ObjC. Do NOT enable ARC — sokol uses manual retain/release, which ARC
    // forbids (this mirrors how the official sokol-zig bindings build it).
    const sokol_flags: []const []const u8 = if (os == .macos)
        &.{"-ObjC"}
    else
        &.{};
    exe_mod.addCSourceFile(.{ .file = b.path("vendor/sokol/sokol.c"), .flags = sokol_flags });
    exe_mod.addIncludePath(b.path("vendor/sokol"));
    exe_mod.link_libc = true;
    linkWindowSystem(exe_mod, os);

    // Text (stb_truetype), images (stb_image) and audio (miniaudio) for the
    // window form. All vendored single-header libs; nothing is fetched. Kept off
    // the test graph so `zig build test` stays offline and headless.
    addMedia(b, exe_mod, target, optimize);

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const release_mod = b.createModule(.{
        .root_source_file = b.path("release.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    });
    const release_exe = b.addExecutable(.{
        .name = "release",
        .root_module = release_mod,
    });
    const run_release = b.addRunArtifact(release_exe);
    if (b.args) |args| {
        run_release.addArgs(args);
    }
    const release_step = b.step("release", "Create and push a signed release");
    release_step.dependOn(&run_release.step);

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

    // Media module tests (text/image/audio). These link system libraries
    // and read fixtures, so they are a separate step from the offline `test`.
    const media_test_mod = b.createModule(.{
        .root_source_file = b.path("media_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    addMedia(b, media_test_mod, target, optimize);
    const media_tests = b.addTest(.{ .root_module = media_test_mod });
    const run_media = b.addRunArtifact(media_tests);
    const media_step = b.step("test-media", "Run media module tests (needs system libs + fonts)");
    media_step.dependOn(&run_media.step);

    // Microbenchmarks — always ReleaseFast, independent of -Doptimize.
    const bench_exe = b.addExecutable(.{
        .name = "bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run parser/markup microbenchmarks (ReleaseFast)");
    bench_step.dependOn(&run_bench.step);

    // Formatting gate.
    const fmt = b.addFmt(.{
        .paths = &.{
            "src",                  "build.zig",            "build.zig.zon",
            "test.zig",             "release.zig",          "media_test.zig",
            "integration_test.zig", "correctness_test.zig", "bench.zig",
        },
        .check = true,
    });
    const check_step = b.step("check", "Verify formatting with zig fmt");
    check_step.dependOn(&fmt.step);
}

/// Link the window/graphics system libraries for `os`. sokol selects a backend
/// per target (GL / Metal / D3D11), each needing different platform libraries.
/// Only the Linux path runs in CI; the macOS and Windows paths follow sokol's
/// documented requirements and await verification on those platforms. See
/// docs/cross-platform.md.
fn linkWindowSystem(mod: *std.Build.Module, os: std.Target.Os.Tag) void {
    switch (os) {
        .linux => {
            mod.linkSystemLibrary("GL", .{});
            mod.linkSystemLibrary("X11", .{});
            mod.linkSystemLibrary("Xi", .{});
            mod.linkSystemLibrary("Xcursor", .{});
        },
        .macos => {
            mod.linkFramework("Metal", .{});
            mod.linkFramework("QuartzCore", .{});
            mod.linkFramework("AppKit", .{});
        },
        .windows => {
            // win32 windowing plus the D3D11/DXGI backend libraries. sokol_app
            // calls D3D11CreateDeviceAndSwapChain directly, so d3d11/dxgi must be
            // linked (Zig ships the import libs); matches sokol-zig.
            for ([_][]const u8{
                "kernel32", "user32", "gdi32", "ole32", "d3d11", "dxgi",
            }) |lib| {
                mod.linkSystemLibrary(lib, .{});
            }
        },
        else => {},
    }
}

/// Wire the text/image/audio C dependencies into `mod`. Text (stb_truetype) and
/// images (stb_image) are vendored single-header C, portable on every target;
/// only audio (miniaudio) needs per-platform system libraries. See
/// docs/cross-platform.md for the rationale and per-OS verification status.
fn addMedia(b: *std.Build, mod: *std.Build.Module, target: anytype, optimize: anytype) void {
    const os = target.result.os.tag;
    mod.link_libc = true;

    // text.zig: vendored stb_truetype — portable C, no system text libraries.
    const text_c = b.addTranslateC(.{
        .root_source_file = b.path("src/text_c.h"),
        .target = target,
        .optimize = optimize,
    });
    text_c.addIncludePath(b.path("vendor/stb"));
    mod.addImport("text_c", text_c.createModule());
    mod.addCSourceFile(.{ .file = b.path("vendor/stb/stb_truetype_impl.c") });
    mod.addIncludePath(b.path("vendor/stb"));

    // image.zig: vendored stb_image — portable C, no system libraries.
    const image_c = b.addTranslateC(.{
        .root_source_file = b.path("src/image_c.h"),
        .target = target,
        .optimize = optimize,
    });
    image_c.addIncludePath(b.path("vendor/stb"));
    mod.addImport("image_c", image_c.createModule());
    mod.addCSourceFile(.{ .file = b.path("vendor/stb/stb_image_impl.c") });
    mod.addIncludePath(b.path("vendor/stb"));

    // audio.zig: vendored miniaudio; its backend links different platform audio
    // libraries (ALSA via dlopen on Linux, CoreAudio on macOS, WASAPI on Win).
    const audio_c = b.addTranslateC(.{
        .root_source_file = b.path("src/audio_c.h"),
        .target = target,
        .optimize = optimize,
    });
    audio_c.addIncludePath(b.path("vendor/miniaudio"));
    mod.addImport("audio_c", audio_c.createModule());
    mod.addCSourceFile(.{ .file = b.path("vendor/miniaudio/miniaudio_impl.c") });
    mod.addIncludePath(b.path("vendor/miniaudio"));
    switch (os) {
        .linux => {
            mod.linkSystemLibrary("pthread", .{});
            mod.linkSystemLibrary("m", .{});
            mod.linkSystemLibrary("dl", .{});
        },
        .macos => {
            mod.linkFramework("CoreFoundation", .{});
            mod.linkFramework("CoreAudio", .{});
            mod.linkFramework("AudioToolbox", .{});
        },
        .windows => mod.linkSystemLibrary("ole32", .{}),
        else => {},
    }
}
