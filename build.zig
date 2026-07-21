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

    // Text (FreeType+HarfBuzz), images (stb_image), audio (miniaudio) and video
    // (FFmpeg) for the window form. All vendored single-header or system libs;
    // nothing is fetched. Kept off the test graph so `zig build test` stays
    // offline and headless.
    addMedia(b, exe_mod, target, optimize);

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

    // Media module tests (text/image/audio/video). These link system libraries
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
            "src",                  "build.zig",      "build.zig.zon",
            "test.zig",             "media_test.zig", "integration_test.zig",
            "correctness_test.zig", "bench.zig",
        },
        .check = true,
    });
    const check_step = b.step("check", "Verify formatting with zig fmt");
    check_step.dependOn(&fmt.step);
}

/// Wire the text/image/audio/video C dependencies into `mod`. See the module
/// files and docs/window-backend.md for the rationale (vendored + system libs).
fn addMedia(b: *std.Build, mod: *std.Build.Module, target: anytype, optimize: anytype) void {
    // text.zig: FreeType + HarfBuzz (system libraries).
    const text_c = b.addTranslateC(.{
        .root_source_file = b.path("src/text_c.h"),
        .target = target,
        .optimize = optimize,
    });
    text_c.addIncludePath(.{ .cwd_relative = "/usr/include/freetype2" });
    text_c.addIncludePath(.{ .cwd_relative = "/usr/include/harfbuzz" });
    mod.addImport("text_c", text_c.createModule());
    mod.linkSystemLibrary("freetype", .{});
    mod.linkSystemLibrary("harfbuzz", .{});

    // image.zig: vendored stb_image.
    const image_c = b.addTranslateC(.{
        .root_source_file = b.path("src/image_c.h"),
        .target = target,
        .optimize = optimize,
    });
    image_c.addIncludePath(b.path("vendor/stb"));
    mod.addImport("image_c", image_c.createModule());
    mod.addCSourceFile(.{ .file = b.path("vendor/stb/stb_image_impl.c") });
    mod.addIncludePath(b.path("vendor/stb"));

    // audio.zig: vendored miniaudio (dlopens ALSA at runtime).
    const audio_c = b.addTranslateC(.{
        .root_source_file = b.path("src/audio_c.h"),
        .target = target,
        .optimize = optimize,
    });
    audio_c.addIncludePath(b.path("vendor/miniaudio"));
    mod.addImport("audio_c", audio_c.createModule());
    mod.addCSourceFile(.{ .file = b.path("vendor/miniaudio/miniaudio_impl.c") });
    mod.addIncludePath(b.path("vendor/miniaudio"));
    mod.linkSystemLibrary("pthread", .{});
    mod.linkSystemLibrary("m", .{});
    mod.linkSystemLibrary("dl", .{});

    // video.zig: FFmpeg (system libraries).
    const video_c = b.addTranslateC(.{
        .root_source_file = b.path("src/video_c.h"),
        .target = target,
        .optimize = optimize,
    });
    video_c.addIncludePath(.{ .cwd_relative = "/usr/include/x86_64-linux-gnu" });
    video_c.addIncludePath(.{ .cwd_relative = "/usr/include" });
    mod.addImport("video_c", video_c.createModule());
    mod.addIncludePath(.{ .cwd_relative = "/usr/include/x86_64-linux-gnu" });
    mod.linkSystemLibrary("avformat", .{});
    mod.linkSystemLibrary("avcodec", .{});
    mod.linkSystemLibrary("avutil", .{});
    mod.linkSystemLibrary("swscale", .{});
}
