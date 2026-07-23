const std = @import("std");
const log = std.log.scoped(.takahashi);

const cli = @import("cli.zig");
const parser = @import("parser.zig");
const document = @import("document.zig");
const window = @import("window.zig");
const terminal = @import("terminal.zig");
const html = @import("html.zig");
const pdf = @import("pdf.zig");

/// As of Zig 0.16 the runtime hands `main` a `std.process.Init`, which carries
/// the command line arguments, an I/O implementation and allocators.
pub fn main(init: std.process.Init) !void {
    log.info("START", .{});
    defer log.info("END", .{});

    const gpa = init.gpa;
    const io = init.io;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const config = cli.parse(args) catch |err| {
        log.err(
            "usage: takahashi [--to window|terminal|pdf|html] [-o <path>] [--watch] <file.taka>",
            .{},
        );
        return err;
    };

    // TODO: config.path == "-" should read the deck from standard input.
    const source = try std.Io.Dir.cwd().readFileAlloc(io, config.path, gpa, .unlimited);
    defer gpa.free(source);

    var deck = try parser.parse(gpa, source);
    defer deck.deinit(gpa);

    // Functions resolve relative to the deck's directory (SPEC 1.3).
    const deck_dir = std.fs.path.dirname(config.path) orelse ".";
    const base_dir = try std.Io.Dir.cwd().openDir(io, deck_dir, .{});
    var doc = try document.process(gpa, io, base_dir, source, config.path, deck);
    defer doc.deinit();

    switch (config.form) {
        .window => window.present(gpa, io, base_dir, deck_dir, doc.slides),
        .terminal => try terminal.present(gpa, io, doc.slides, detectGraphics(init.environ_map)),
        .html => {
            const out = try html.render(gpa, doc.slides);
            defer gpa.free(out);
            try writeOutput(io, config.out_path, out);
        },
        .pdf => {
            const out = try pdf.render(gpa, doc.slides);
            defer gpa.free(out);
            try writeOutput(io, config.out_path, out);
        },
    }

    // TODO: watch mode (SPEC 2.2) — when config.watch, re-render on file change.
}

/// Detect the terminal's inline-graphics support for the terminal form
/// (SPEC 3.2). kitty sets `KITTY_WINDOW_ID`; kitty and compatible emulators
/// (ghostty, …) put "kitty" in `$TERM`. Anything else gets the text fallback.
fn detectGraphics(env: *std.process.Environ.Map) terminal.Graphics {
    if (env.contains("KITTY_WINDOW_ID")) return .kitty;
    if (env.get("TERM")) |term| {
        if (std.mem.indexOf(u8, term, "kitty") != null) return .kitty;
    }
    return .none;
}

/// Write a file form's bytes to `out_path`, or to standard output when null.
fn writeOutput(io: std.Io, out_path: ?[]const u8, bytes: []const u8) !void {
    if (out_path) |path| {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
    } else {
        try std.Io.File.stdout().writeStreamingAll(io, bytes);
    }
}
