//! Terminal output form (SPEC 3.2): a text presentation in the terminal.
//!
//! Scaffold: prints each slide's body to standard output so the parse -> render
//! path works end to end. The interactive VT100/ANSI experience — clearing the
//! screen, scaling text, navigation (SPEC 2.1) — comes later.

const std = @import("std");

const Deck = @import("slide.zig").Deck;

pub fn present(io: std.Io, deck: Deck) std.Io.Writer.Error!void {
    var buffer: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(io, &buffer);
    const w = &file_writer.interface;

    for (deck.slides, 1..) |slide, number| {
        try w.print("--- slide {d}/{d} ---\n", .{ number, deck.slides.len });
        try w.writeAll(slide.body);
        try w.writeAll("\n\n");
    }
    try w.flush();
}

test {
    std.testing.refAllDecls(@This());
}
