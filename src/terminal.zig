//! Terminal output form (SPEC 3.2): render slides to the terminal, mapping
//! markup to ANSI SGR styles. Images are shown inline via the kitty graphics
//! protocol where the terminal supports it (SPEC 3), and noted textually
//! otherwise. A scaffold: it prints slides top to bottom; the interactive
//! VT100 experience (clear, scale, navigate) comes later.

const std = @import("std");
const assert = std.debug.assert;

const document = @import("document.zig");
const Slide = document.Slide;
const Span = document.Span;

/// What the host terminal can display inline. The caller detects this (e.g.
/// from `$TERM` / `$KITTY_WINDOW_ID`); the renderer stays pure and testable.
pub const Graphics = enum { none, kitty };

pub fn present(io: std.Io, slides: []const Slide, graphics: Graphics) std.Io.Writer.Error!void {
    var buffer: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(io, &buffer);
    try render(&file_writer.interface, slides, graphics);
    try file_writer.interface.flush();
}

/// Render every slide to `w`. Split out from `present` so tests can render to a
/// fixed buffer without a real stdout.
pub fn render(w: *std.Io.Writer, slides: []const Slide, graphics: Graphics) std.Io.Writer.Error!void {
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

test "styled spans map to SGR codes and reset" {
    const spans = [_]Span{
        .{ .text = "plain ", .style = .{} },
        .{ .text = "bold", .style = .{ .bold = true } },
    };
    const slides = [_]Slide{.{ .spans = &spans, .media = &.{}, .notes = "" }};
    var buffer: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    try render(&w, &slides, .none);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "plain ") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b[1mbold\x1b[0m") != null);
}

test "image renders as kitty graphics when the terminal supports it" {
    const media = [_]document.Media{
        .{ .kind = .image, .path = "p.png", .data_uri = "data:image/png;base64,QUJD" },
    };
    const slides = [_]Slide{.{ .spans = &.{}, .media = &media, .notes = "" }};
    var buffer: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    try render(&w, &slides, .kitty);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b_Gf=100,a=T,r=20,m=0;QUJD\x1b\\") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "[image:") == null);
}

test "image falls back to text without graphics support or PNG bytes" {
    const media = [_]document.Media{
        // kitty supported, but a JPEG data URI is not PNG -> text fallback.
        .{ .kind = .image, .path = "p.jpg", .data_uri = "data:image/jpeg;base64,QUJD" },
    };
    const slides = [_]Slide{.{ .spans = &.{}, .media = &media, .notes = "" }};
    var buffer: [256]u8 = undefined;
    var w = std.Io.Writer.fixed(&buffer);
    try render(&w, &slides, .kitty);
    const out = w.buffered();
    try std.testing.expect(std.mem.indexOf(u8, out, "[image: p.jpg]") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\x1b_G") == null);
}

test {
    std.testing.refAllDecls(@This());
}
