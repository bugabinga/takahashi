//! Parse a .taka source buffer into a `Deck` (SPEC 1).
//!
//! A paragraph (lines between blank lines) becomes a slide. A `#` comment line
//! is not rendered and belongs to no slide (SPEC 1.1); it ends the current
//! paragraph. Inline markup (SPEC 1.2), `@note`, and other @functions
//! (SPEC 1.3) are resolved later, in `document.zig`.

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

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const start = @intFromPtr(line.ptr) - @intFromPtr(source.ptr);
        const end = start + line.len;
        assert(end <= source.len);

        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) {
            // Blank line: it closes the current paragraph (SPEC 1).
            try flush(gpa, &slides, source, &paragraph);
        } else if (trimmed[0] == '#') {
            // Comment: not rendered and part of no slide (SPEC 1.1), so it
            // closes any open paragraph and is otherwise dropped.
            try flush(gpa, &slides, source, &paragraph);
        } else {
            // Content line: extend (or open) the current paragraph.
            if (paragraph) |*p| p.end = end else paragraph = .{ .start = start, .end = end };
        }
    }
    try flush(gpa, &slides, source, &paragraph);

    return .{ .slides = try slides.toOwnedSlice(gpa) };
}

/// Emit the open paragraph as a slide. A no-op when no paragraph is open.
fn flush(
    gpa: Allocator,
    slides: *std.ArrayList(Slide),
    source: []const u8,
    paragraph: *?Span,
) Allocator.Error!void {
    const p = paragraph.* orelse return;
    assert(p.end >= p.start);

    try slides.append(gpa, .{ .body = source[p.start..p.end] });
    paragraph.* = null;
}

test "paragraphs become slides and comments are dropped" {
    const gpa = std.testing.allocator;
    const source =
        \\# an authoring comment
        \\Simple Made Easy
        \\Rich Hickey
        \\
        \\Second slide
        \\
        \\# trailing comment without a slide
        \\
    ;
    var deck = try parse(gpa, source);
    defer deck.deinit(gpa);

    try std.testing.expectEqual(@as(usize, 2), deck.slides.len);
    try std.testing.expectEqualStrings(
        "Simple Made Easy\nRich Hickey",
        deck.slides[0].body,
    );
    try std.testing.expectEqualStrings("Second slide", deck.slides[1].body);
}

test "fuzz: parsing arbitrary bytes never crashes" {
    const Context = struct {
        fn one(_: @This(), smith: *std.testing.Smith) anyerror!void {
            var buffer: [512]u8 = undefined;
            const len = smith.sliceWithHash(&buffer, 0);
            var deck = parse(std.testing.allocator, buffer[0..len]) catch return;
            deck.deinit(std.testing.allocator);
        }
    };
    try std.testing.fuzz(Context{}, Context.one, .{});
}

test {
    std.testing.refAllDecls(@This());
}
