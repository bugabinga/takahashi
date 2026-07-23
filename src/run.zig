//! The `@run` function (SPEC 1.3): execute a command line as a taka-built
//! pipeline and return its standard output.
//!
//! taka never invokes a shell — it resolves each program via `PATH` and spawns
//! it directly with `std.process.spawn`, so behaviour does not depend on the
//! user's shell. Stages are chained in memory (each stage's output feeds the
//! next). The file contents are fed to the first stage's stdin unless a `%`
//! placeholder is present, in which case `%` expands to the file path and stdin
//! is left empty.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const function = @import("function.zig");

// The tests spawn real POSIX utilities by absolute path; Windows has none of
// them, so they skip there. `@run` itself is cross-platform (it resolves and
// spawns whatever the deck names) — only these fixtures are POSIX-specific.
const posix_only = builtin.os.tag == .windows;

pub fn run(
    arena: Allocator,
    io: std.Io,
    source: []const u8,
    file_path: []const u8,
    tokens: []const function.Token,
) anyerror![]const u8 {
    var stages: std.ArrayList([]const []const u8) = .empty;
    var argv: std.ArrayList([]const u8) = .empty;
    var has_percent = false;

    for (tokens) |token| {
        switch (token.kind) {
            .pipe => try stages.append(arena, try argv.toOwnedSlice(arena)),
            .percent => {
                has_percent = true;
                try argv.append(arena, file_path);
            },
            .arg => try argv.append(arena, token.text),
        }
    }
    try stages.append(arena, try argv.toOwnedSlice(arena));

    var input: []const u8 = if (has_percent) "" else source;
    for (stages.items) |stage_argv| {
        if (stage_argv.len == 0) continue;
        input = try runStage(arena, io, stage_argv, input);
    }
    return input;
}

fn runStage(
    arena: Allocator,
    io: std.Io,
    argv: []const []const u8,
    input: []const u8,
) anyerror![]const u8 {
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = if (input.len > 0) .pipe else .close,
        .stdout = .pipe,
        .stderr = .inherit,
    });

    if (child.stdin) |stdin| {
        try stdin.writeStreamingAll(io, input);
        stdin.close(io);
        child.stdin = null;
    }

    var buffer: [4096]u8 = undefined;
    var reader = child.stdout.?.reader(io, &buffer);
    const output = try reader.interface.allocRemaining(arena, .unlimited);
    child.stdout.?.close(io);
    child.stdout = null;

    _ = try child.wait(io);
    return output;
}

fn testIo(threaded: *std.Io.Threaded) std.Io {
    return threaded.io();
}

test "runs a single command, feeding the source to stdin" {
    if (posix_only) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tokens = [_]function.Token{.{ .text = "/bin/cat", .kind = .arg }};
    const out = try run(arena, threaded.io(), "hello\n", "/tmp/x.taka", &tokens);
    try std.testing.expectEqualStrings("hello\n", out);
}

test "builds a pipeline without a shell" {
    if (posix_only) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // echo hi | tr a-z A-Z  ->  "HI\n"  (/bin/echo exists on Linux and macOS)
    const tokens = [_]function.Token{
        .{ .text = "/bin/echo", .kind = .arg },
        .{ .text = "hi", .kind = .arg },
        .{ .text = "|", .kind = .pipe },
        .{ .text = "/usr/bin/tr", .kind = .arg },
        .{ .text = "a-z", .kind = .arg },
        .{ .text = "A-Z", .kind = .arg },
    };
    const out = try run(arena, threaded.io(), "", "/tmp/x.taka", &tokens);
    try std.testing.expectEqualStrings("HI\n", out);
}

test {
    std.testing.refAllDecls(@This());
}
