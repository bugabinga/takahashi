//! Terminal output form (SPEC 3.2): an interactive, full-screen presentation in
//! the terminal. On a TTY it takes over the alternate screen in raw mode and is
//! driven by the shared `presentation.zig` state machine (SPEC 2.1); markup maps
//! to ANSI SGR styles and images use the kitty graphics protocol where the
//! terminal supports it. When stdin/stdout is not a TTY (piped, redirected) it
//! falls back to a plain top-to-bottom dump so `--to terminal | less` still
//! works and the renderer stays testable headless.
//!
//! The interactive glue (raw mode, the read loop) is kept thin; the parts with
//! real logic — key decoding and frame rendering — are pure and unit-tested.
//! The speaker-notes frame (`renderNotesFrame`) is shared with the window form,
//! which prints it to its controlling terminal (SPEC 3.1).

const std = @import("std");
const assert = std.debug.assert;
const posix = std.posix;
const Allocator = std.mem.Allocator;

const document = @import("document.zig");
const Presentation = @import("presentation.zig").Presentation;
const sync = @import("sync.zig");
const Slide = document.Slide;
const Span = document.Span;

/// What the host terminal can display inline. The caller detects this (e.g.
/// from `$TERM` / `$KITTY_WINDOW_ID`); the renderers stay pure and testable.
pub const Graphics = enum { none, kitty };

/// A decoded navigation intent (SPEC 2.1). Pure output of `decodeKey`.
pub const Action = enum { next, prev, first, last, quit, none };

pub const Size = struct { rows: u16, cols: u16 };

const RenderError = std.Io.Writer.Error || Allocator.Error;

const enter_alt = "\x1b[?1049h";
const leave_alt = "\x1b[?1049l";
const hide_cursor = "\x1b[?25l";
const show_cursor = "\x1b[?25h";
const clear_home = "\x1b[2J\x1b[H";

pub fn present(
    gpa: Allocator,
    io: std.Io,
    deck_path: []const u8,
    slides: []const Slide,
    graphics: Graphics,
) !void {
    const stdin = std.Io.File.stdin();
    const stdout = std.Io.File.stdout();
    var out_buffer: [1 << 14]u8 = undefined;
    var file_writer = stdout.writer(io, &out_buffer);
    const w = &file_writer.interface;

    const in_tty = stdin.isTty(io) catch false;
    const out_tty = stdout.isTty(io) catch false;
    if (!in_tty or !out_tty or slides.len == 0) {
        try renderDump(w, slides, graphics);
        try w.flush();
        return;
    }
    try runInteractive(gpa, io, w, stdin.handle, stdout.handle, deck_path, slides, graphics);
}

/// The interactive loop: alt-screen + raw mode, render the current slide, read a
/// key, apply it, repeat until the speaker quits. Terminal state is always
/// restored by the defers, including on error.
fn runInteractive(
    gpa: Allocator,
    io: std.Io,
    w: *std.Io.Writer,
    in_fd: posix.fd_t,
    out_fd: posix.fd_t,
    deck_path: []const u8,
    slides: []const Slide,
    graphics: Graphics,
) !void {
    assert(slides.len > 0);
    const original = try posix.tcgetattr(in_fd);
    try setRaw(in_fd, original);
    defer posix.tcsetattr(in_fd, .NOW, original) catch {};
    try w.writeAll(enter_alt ++ hide_cursor);
    defer {
        w.writeAll(show_cursor ++ leave_alt) catch {};
        w.flush() catch {};
    }

    // Publish the current slide for a `--speaker` companion (best effort).
    var publisher: ?sync.Publisher = sync.Publisher.init(gpa, io, deck_path) catch null;
    defer if (publisher) |*p| p.deinit();

    var show = Presentation.init(slides.len);
    var frame = std.heap.ArenaAllocator.init(gpa);
    defer frame.deinit();
    var key: [8]u8 = undefined;
    while (true) { // interactive loop: bounded only by the quit key
        assert(show.current < slides.len);
        if (publisher) |*p| p.publish(show.current);
        _ = frame.reset(.retain_capacity);
        try renderSlide(w, frame.allocator(), slides, show.current, terminalSize(out_fd), graphics);
        try w.flush();
        const n = posix.read(in_fd, &key) catch 0;
        if (n == 0) continue;
        switch (decodeKey(key[0..n])) {
            .next => show.next(),
            .prev => show.prev(),
            .first => show.first(),
            .last => show.last(),
            .quit => return,
            .none => {},
        }
    }
}

/// Put `fd` into a cbreak/raw mode: no line buffering, no echo, no signal or
/// flow-control interception, one byte minimum per read.
fn setRaw(fd: posix.fd_t, base: posix.termios) !void {
    var raw = base;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.lflag.ISIG = false; // Ctrl-C arrives as 0x03 -> clean quit, defers run
    raw.iflag.IXON = false;
    raw.iflag.ICRNL = false;
    raw.cc[@intFromEnum(posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(posix.V.TIME)] = 0;
    try posix.tcsetattr(fd, .NOW, raw);
}

/// The terminal's size in character cells, or a sane default when the query
/// fails (e.g. no controlling terminal).
pub fn terminalSize(fd: posix.fd_t) Size {
    var ws: posix.winsize = undefined;
    const rc = posix.system.ioctl(fd, posix.T.IOCGWINSZ, @intFromPtr(&ws));
    if (posix.errno(rc) == .SUCCESS and ws.col > 0 and ws.row > 0) {
        return .{ .rows = ws.row, .cols = ws.col };
    }
    return .{ .rows = 24, .cols = 80 };
}

/// Map a read of raw key bytes to a navigation intent. Handles arrow/Home/End/
/// PageUp/Down escape sequences and a set of single-key bindings.
pub fn decodeKey(bytes: []const u8) Action {
    if (bytes.len == 0) return .none;
    const b = bytes[0];
    if (b == 0x1b) { // ESC: alone quits, else an escape sequence
        if (bytes.len == 1) return .quit;
        if (bytes.len >= 3 and bytes[1] == '[') return switch (bytes[2]) {
            'C' => .next,
            'D' => .prev,
            'H' => .first,
            'F' => .last,
            '1' => .first, // ESC [ 1 ~ (Home)
            '4' => .last, // ESC [ 4 ~ (End)
            '5' => .prev, // ESC [ 5 ~ (PageUp)
            '6' => .next, // ESC [ 6 ~ (PageDown)
            else => .none,
        };
        return .none;
    }
    return switch (b) {
        ' ', '\r', '\n', 'l', 'j', 'n' => .next,
        0x08, 0x7f, 'h', 'k', 'p' => .prev,
        'g' => .first,
        'G' => .last,
        'q', 0x03 => .quit,
        else => .none,
    };
}

const LineSeg = struct { text: []const u8, style: document.Style };

/// Render the slide at `index` cleared and centered in the frame, styled, with
/// a dim position indicator; images follow via `writeMedia`.
pub fn renderSlide(
    w: *std.Io.Writer,
    arena: Allocator,
    slides: []const Slide,
    index: usize,
    size: Size,
    graphics: Graphics,
) RenderError!void {
    assert(index < slides.len);
    assert(size.cols > 0);
    const slide = slides[index];
    try w.writeAll(clear_home);
    try w.print("\x1b[2m {d}/{d}\x1b[0m\r\n", .{ index + 1, slides.len });

    const lines = try splitLines(arena, slide.spans);
    const rows: usize = size.rows;
    const top_pad = if (rows > lines.len + 1) (rows - lines.len - 1) / 2 else 0;
    for (0..top_pad) |_| try w.writeAll("\r\n");
    for (lines) |line| {
        const width = lineWidth(line);
        const left = if (size.cols > width) (size.cols - width) / 2 else 0;
        for (0..left) |_| try w.writeByte(' ');
        for (line) |seg| try writeSpan(w, .{ .text = seg.text, .style = seg.style });
        try w.writeAll("\r\n");
    }
    for (slide.media) |media| try writeMedia(w, media, graphics);
}

/// Split styled spans into lines of styled segments, breaking on `\n`.
fn splitLines(arena: Allocator, spans: []const Span) Allocator.Error![]const []const LineSeg {
    var lines: std.ArrayList([]const LineSeg) = .empty;
    var current: std.ArrayList(LineSeg) = .empty;
    for (spans) |span| {
        var pieces = std.mem.splitScalar(u8, span.text, '\n');
        var first = true;
        while (pieces.next()) |piece| {
            if (!first) {
                try lines.append(arena, try current.toOwnedSlice(arena));
                current = .empty;
            }
            first = false;
            if (piece.len > 0) try current.append(arena, .{ .text = piece, .style = span.style });
        }
    }
    try lines.append(arena, try current.toOwnedSlice(arena));
    return lines.toOwnedSlice(arena);
}

fn lineWidth(line: []const LineSeg) usize {
    var total: usize = 0;
    for (line) |seg| total += displayWidth(seg.text);
    return total;
}

/// Column width of UTF-8 text, counting East-Asian wide codepoints as two.
fn displayWidth(text: []const u8) usize {
    var total: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const end = @min(i + len, text.len);
        const cp = std.unicode.utf8Decode(text[i..end]) catch text[i];
        total += if (isWide(cp)) 2 else 1;
        i = end;
    }
    return total;
}

fn isWide(cp: u21) bool {
    return (cp >= 0x1100 and cp <= 0x115F) or (cp >= 0x2E80 and cp <= 0xA4CF) or
        (cp >= 0xAC00 and cp <= 0xD7A3) or (cp >= 0xF900 and cp <= 0xFAFF) or
        (cp >= 0xFF00 and cp <= 0xFF60) or (cp >= 0x20000 and cp <= 0x3FFFD);
}

/// The speaker-notes frame (SPEC 2.1): a cleared screen with a position banner,
/// the current slide's notes word-wrapped to `cols`, and a preview of the next
/// slide. Shared by the terminal form and the window form's controlling
/// terminal. Pure — writes only to `w`.
pub fn renderNotesFrame(
    w: *std.Io.Writer,
    notes: []const u8,
    index: usize,
    total: usize,
    next_preview: []const u8,
    cols: u16,
) std.Io.Writer.Error!void {
    assert(cols > 0);
    try w.writeAll(clear_home);
    try w.print("\x1b[7m speaker notes  {d}/{d} \x1b[0m\r\n\r\n", .{ index + 1, total });
    const body = if (notes.len == 0) "(no notes for this slide)" else notes;
    try writeWrapped(w, body, cols);
    try w.writeAll("\r\n\x1b[2m\xe2\x94\x80 next \xe2\x94\x80\x1b[0m\r\n");
    try writeWrapped(w, if (next_preview.len == 0) "\xe2\x80\x94 end \xe2\x80\x94" else next_preview, cols);
    try w.flush();
}

/// Word-wrap `text` to `cols`, honoring explicit newlines, emitting CRLFs.
fn writeWrapped(w: *std.Io.Writer, text: []const u8, cols: u16) std.Io.Writer.Error!void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var column: usize = 0;
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        while (words.next()) |word| {
            const wide = displayWidth(word);
            if (column > 0 and column + 1 + wide > cols) {
                try w.writeAll("\r\n");
                column = 0;
            }
            if (column > 0) {
                try w.writeByte(' ');
                column += 1;
            }
            try w.writeAll(word);
            column += wide;
        }
        try w.writeAll("\r\n");
    }
}

/// Non-interactive fallback (piped/redirected): dump every slide top to bottom.
pub fn renderDump(w: *std.Io.Writer, slides: []const Slide, graphics: Graphics) std.Io.Writer.Error!void {
    for (slides, 1..) |slide, number| {
        try w.print("\x1b[2m--- slide {d}/{d} ---\x1b[0m\n", .{ number, slides.len });
        for (slide.spans) |span| try writeSpan(w, span);
        try w.writeByte('\n');
        for (slide.media) |media| try writeMedia(w, media, graphics);
        try w.writeByte('\n');
    }
}

fn writeSpan(w: *std.Io.Writer, span: Span) std.Io.Writer.Error!void {
    const s = span.style;
    if (!hasStyle(s)) {
        try w.writeAll(span.text);
        return;
    }
    try w.writeAll("\x1b[");
    var first = true;
    if (s.bold) first = try code(w, first, "1");
    if (s.italic) first = try code(w, first, "3");
    if (s.underline) first = try code(w, first, "4");
    if (s.reverse) first = try code(w, first, "7");
    if (s.strike) first = try code(w, first, "9");
    if (s.mono) first = try code(w, first, "2"); // dim, as a stand-in
    try w.writeAll("m");
    try w.writeAll(span.text);
    try w.writeAll("\x1b[0m");
}

fn code(w: *std.Io.Writer, first: bool, sgr: []const u8) std.Io.Writer.Error!bool {
    if (!first) try w.writeByte(';');
    try w.writeAll(sgr);
    return false;
}

fn hasStyle(s: document.Style) bool {
    return s.mono or s.bold or s.italic or s.underline or s.strike or s.reverse;
}

/// An image is drawn inline with the kitty graphics protocol when the terminal
/// supports it and we have its PNG bytes; everything else is noted textually.
fn writeMedia(w: *std.Io.Writer, media: document.Media, graphics: Graphics) std.Io.Writer.Error!void {
    if (media.kind == .image and graphics == .kitty) {
        if (pngBase64(media.data_uri)) |b64| {
            try writeKittyImage(w, b64);
            return;
        }
    }
    try w.print("[{t}: {s}]\n", .{ media.kind, media.path });
}

/// The base64 payload of a `data:image/png;base64,…` URI, or null for any
/// other media (kitty's `f=100` transmits PNG only; we never decode here).
fn pngBase64(data_uri: ?[]const u8) ?[]const u8 {
    const uri = data_uri orelse return null;
    const prefix = "data:image/png;base64,";
    if (!std.mem.startsWith(u8, uri, prefix)) return null;
    return uri[prefix.len..];
}

/// Emit a PNG via the kitty graphics protocol: transmit-and-display (`a=T`) a
/// PNG (`f=100`), capped to 20 rows tall, the base64 payload chunked to 4096
/// bytes with `m=1` on every chunk but the last (kitty requires the split).
fn writeKittyImage(w: *std.Io.Writer, b64: []const u8) std.Io.Writer.Error!void {
    assert(b64.len > 0);
    const chunk_max = 4096;
    var start: usize = 0;
    var first = true;
    while (start < b64.len) {
        const end = @min(start + chunk_max, b64.len);
        const last = end == b64.len;
        assert(end > start);
        try w.writeAll("\x1b_G");
        if (first) try w.writeAll("f=100,a=T,r=20,");
        try w.print("m={d};", .{@intFromBool(!last)});
        try w.writeAll(b64[start..end]);
        try w.writeAll("\x1b\\");
        first = false;
        start = end;
    }
    assert(start == b64.len);
    try w.writeByte('\n');
}

test "decodeKey maps arrows, keys and quit" {
    try std.testing.expectEqual(Action.next, decodeKey(&.{ 0x1b, '[', 'C' }));
    try std.testing.expectEqual(Action.prev, decodeKey(&.{ 0x1b, '[', 'D' }));
    try std.testing.expectEqual(Action.first, decodeKey(&.{ 0x1b, '[', 'H' }));
    try std.testing.expectEqual(Action.last, decodeKey(&.{ 0x1b, '[', 'F' }));
    try std.testing.expectEqual(Action.next, decodeKey(" "));
    try std.testing.expectEqual(Action.prev, decodeKey("h"));
    try std.testing.expectEqual(Action.quit, decodeKey("q"));
    try std.testing.expectEqual(Action.quit, decodeKey(&.{0x1b})); // lone ESC
    try std.testing.expectEqual(Action.quit, decodeKey(&.{0x03})); // Ctrl-C
    try std.testing.expectEqual(Action.none, decodeKey("z"));
    try std.testing.expectEqual(Action.none, decodeKey(""));
}

test "renderSlide centers styled text and clears the screen" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const spans = [_]Span{
        .{ .text = "a ", .style = .{} },
        .{ .text = "bold", .style = .{ .bold = true } },
    };
    const slides = [_]Slide{.{ .spans = &spans, .media = &.{}, .notes = "" }};
    var buffer: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    try renderSlide(&w, arena_state.allocator(), &slides, 0, .{ .rows = 24, .cols = 80 }, .none);
    const out = w.buffered();
    try std.testing.expect(std.mem.startsWith(u8, out, clear_home));
    try std.testing.expect(std.mem.indexOf(u8, out, " 1/1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[1mbold\x1b[0m") != null);
}

test "renderNotesFrame shows notes and the next preview" {
    var buffer: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    try renderNotesFrame(&w, "breathe and speak", 0, 3, "next words", 40);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "1/3") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "breathe and speak") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "next words") != null);
}

test "renderNotesFrame notes-less slide shows a placeholder" {
    var buffer: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    try renderNotesFrame(&w, "", 1, 2, "", 40);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "(no notes for this slide)") != null);
}

test "image renders as kitty graphics when the terminal supports it" {
    const media = [_]document.Media{
        .{ .kind = .image, .path = "p.png", .data_uri = "data:image/png;base64,QUJD" },
    };
    const slides = [_]Slide{.{ .spans = &.{}, .media = &media, .notes = "" }};
    var buffer: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    try renderDump(&w, &slides, .kitty);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b_Gf=100,a=T,r=20,m=0;QUJD\x1b\\") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[image:") == null);
}

test "image falls back to text without graphics support or PNG bytes" {
    const media = [_]document.Media{
        .{ .kind = .image, .path = "p.jpg", .data_uri = "data:image/jpeg;base64,QUJD" },
    };
    const slides = [_]Slide{.{ .spans = &.{}, .media = &media, .notes = "" }};
    var buffer: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    try renderDump(&w, &slides, .kitty);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "[image: p.jpg]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b_G") == null);
}

test {
    std.testing.refAllDecls(@This());
}
