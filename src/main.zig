const std = @import("std");
const log = std.log.scoped(.takahashi);

const cli = @import("cli.zig");
const document = @import("document.zig");
const window = @import("window.zig");
const terminal = @import("terminal.zig");
const html = @import("html.zig");
const pdf = @import("pdf.zig");
const sync = @import("sync.zig");
const watch = @import("watch.zig");

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
            "usage: takahashi [--to window|terminal|pdf|html] [-o <path>] " ++
                "[--watch] [--speaker] <file.taka|->",
            .{},
        );
        return err;
    };

    // Functions resolve relative to the deck's directory (SPEC 1.3); a deck read
    // from standard input (`-`) resolves against the current directory.
    const stdin_deck = std.mem.eql(u8, config.path, "-");
    const deck_dir = if (stdin_deck) "." else (std.fs.path.dirname(config.path) orelse ".");
    const base_dir = try std.Io.Dir.cwd().openDir(io, deck_dir, .{});
    var doc = try document.load(gpa, io, base_dir, config.path);
    defer doc.deinit();

    // The speaker companion follows a running presentation of this deck rather
    // than presenting itself (SPEC 2.1).
    if (config.speaker) {
        try runSpeaker(gpa, io, config.path, doc.slides);
        return;
    }

    switch (config.form) {
        .window => window.present(gpa, io, base_dir, deck_dir, config.path, doc.slides, config.watch),
        .terminal => try terminal.present(
            gpa,
            io,
            base_dir,
            config.path,
            doc.slides,
            detectGraphics(init.environ_map),
            config.watch,
        ),
        .html, .pdf => try renderFileForm(gpa, io, base_dir, config, doc.slides),
    }
}

/// Render a file form (HTML/PDF) once, then — under `--watch` — regenerate it
/// whenever the deck changes on disk (SPEC 2.2). Stdin decks cannot be watched.
fn renderFileForm(
    gpa: std.mem.Allocator,
    io: std.Io,
    base_dir: std.Io.Dir,
    config: cli.Config,
    slides: []const document.Slide,
) !void {
    try emitFileForm(gpa, io, config, slides);
    if (!config.watch or std.mem.eql(u8, config.path, "-")) return;

    var watcher = watch.Watcher.init(io, config.path);
    while (true) { // watch loop: bounded only by the user interrupting
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(200), .awake) catch {};
        if (!watcher.changed()) continue;
        var reloaded = document.load(gpa, io, base_dir, config.path) catch |err| {
            log.warn("reload failed: {t}", .{err});
            continue;
        };
        defer reloaded.deinit();
        emitFileForm(gpa, io, config, reloaded.slides) catch |err| {
            log.warn("re-render failed: {t}", .{err});
        };
    }
}

fn emitFileForm(
    gpa: std.mem.Allocator,
    io: std.Io,
    config: cli.Config,
    slides: []const document.Slide,
) !void {
    const out = switch (config.form) {
        .html => try html.render(gpa, slides),
        .pdf => try pdf.render(gpa, slides),
        else => unreachable,
    };
    defer gpa.free(out);
    try writeOutput(io, config.out_path, out);
}

/// The `--speaker` companion (SPEC 2.1): follow a running presentation of this
/// deck via the shared state file and render the current slide's notes in this
/// terminal, updating as the presenter navigates. Exits when the presenter does.
fn runSpeaker(gpa: std.mem.Allocator, io: std.Io, deck_path: []const u8, slides: []const document.Slide) !void {
    if (slides.len == 0) return;
    var follower = try sync.Follower.init(gpa, io, deck_path);
    defer follower.deinit();

    var out_buffer: [8192]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(io, &out_buffer);
    const w = &file_writer.interface;

    // Wait briefly for a presentation to appear before giving up.
    var tries: usize = 0;
    while (follower.current() == null and tries < 25) : (tries += 1) follower.wait();
    if (follower.current() == null) {
        log.err("no running taka presentation for this deck — start one first", .{});
        return;
    }

    var last: ?usize = null;
    var misses: usize = 0;
    while (misses <= 8) { // exit once the presenter's state file is gone (~1s)
        if (follower.current()) |index| {
            misses = 0;
            const shown = @min(index, slides.len - 1);
            if (last == null or last.? != shown) {
                renderSpeakerFrame(w, slides, shown);
                last = shown;
            }
        } else misses += 1;
        follower.wait();
    }
}

/// Render one notes frame for the companion's current slide.
fn renderSpeakerFrame(w: *std.Io.Writer, slides: []const document.Slide, index: usize) void {
    const total = slides.len;
    const preview = if (index + 1 < total) document.previewOf(slides[index + 1]) else "";
    const size = terminal.terminalSize(std.Io.File.stdout().handle);
    terminal.renderNotesFrame(w, slides[index].notes, index, total, preview, size.cols) catch {};
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
