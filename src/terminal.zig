//! Terminal output form (SPEC 3.2): render slides to the terminal, mapping
//! markup to ANSI SGR styles. A scaffold: it prints slides top to bottom; the
//! interactive VT100 experience (clear, scale, navigate) comes later.

const std = @import("std");

const document = @import("document.zig");
const Slide = document.Slide;
const Span = document.Span;

pub fn present(io: std.Io, slides: []const Slide) std.Io.Writer.Error!void {
    var buffer: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(io, &buffer);
    const w = &file_writer.interface;

    for (slides, 1..) |slide, number| {
        try w.print("\x1b[2m--- slide {d}/{d} ---\x1b[0m\n", .{ number, slides.len });
        for (slide.spans) |span| try writeSpan(w, span);
        try w.writeByte('\n');
        for (slide.media) |media| {
            try w.print("[{t}: {s}]\n", .{ media.kind, media.path });
        }
        try w.writeByte('\n');
    }
    try w.flush();
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

test {
    std.testing.refAllDecls(@This());
}
