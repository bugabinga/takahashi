//! Parse a .taka source buffer into a `Deck` (SPEC 1).
//!
//! Implemented: a paragraph (lines between blank lines) becomes a slide, and
//! the `#` comment lines preceding a slide become its notes (SPEC 1.1).
//! TODO: inline markup spans (SPEC 1.2) and @function resolution (SPEC 1.3).

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const slide = @import("slide.zig");
const Slide = slide.Slide;
const Deck = slide.Deck;

const Span = struct { start: usize, end: usize };

pub fn parse(gpa: Allocator, source: []const u8) Allocator.Error!Deck {
    var slides: std.ArrayList(Slide) = .empty;
    errdefer slides.deinit(gpa);

    var paragraph: ?Span = null;
    var notes: ?Span = null;

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const start = @intFromPtr(line.ptr) - @intFromPtr(source.ptr);
        const end = start + line.len;
        assert(end <= source.len);

        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) {
            // Blank line: it closes the current paragraph (SPEC 1).
            try flush(gpa, &slides, source, &paragraph, &notes);
        } else if (trimmed[0] == '#') {
            // Comment: it maps to the *following* slide (SPEC 1.1), so close
            // any open paragraph first, then accumulate the comment block.
            try flush(gpa, &slides, source, &paragraph, &notes);
            if (notes) |*n| n.end = end else notes = .{ .start = start, .end = end };
        } else {
            // Content line: extend (or open) the current paragraph.
            if (paragraph) |*p| p.end = end else paragraph = .{ .start = start, .end = end };
        }
    }
    try flush(gpa, &slides, source, &paragraph, &notes);

    return .{ .slides = try slides.toOwnedSlice(gpa) };
}

/// Emit the open paragraph as a slide, attaching any pending notes. A no-op
/// when no paragraph is open.
fn flush(
    gpa: Allocator,
    slides: *std.ArrayList(Slide),
    source: []const u8,
    paragraph: *?Span,
    notes: *?Span,
) Allocator.Error!void {
    const p = paragraph.* orelse return;
    assert(p.end >= p.start);

    const body = source[p.start..p.end];
    const note_text = if (notes.*) |n| source[n.start..n.end] else "";
    try slides.append(gpa, .{ .body = body, .notes = note_text });

    paragraph.* = null;
    notes.* = null;
}

test "paragraphs become slides and comments become notes" {
    const gpa = std.testing.allocator;
    const source =
        \\# a note
        \\Simple Made Easy
        \\Rich Hickey
        \\
        \\Second slide
        \\
        \\# trailing note without a slide
        \\
    ;
    var deck = try parse(gpa, source);
    defer deck.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), deck.slides.len);
    try std.testing.expectEqualStrings(
        "Simple Made Easy\nRich Hickey",
        deck.slides[0].body,
    );
    try std.testing.expectEqualStrings("# a note", deck.slides[0].notes);
    try std.testing.expectEqualStrings("Second slide", deck.slides[1].body);
    try std.testing.expectEqualStrings("", deck.slides[1].notes);
}

test {
    std.testing.refAllDecls(@This());
}
