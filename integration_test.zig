//! Integration tests over the real example decks (examples/), exercising the
//! parse -> render path end to end. Rooted at the project directory so the
//! example files can be embedded. See examples/README.md.

const std = @import("std");

const parser = @import("src/parser.zig");
const html = @import("src/html.zig");

const simple_made_easy = @embedFile("examples/simple_made_easy/simple_made_easy.taka");

test "parses the Simple Made Easy deck into many slides" {
    const gpa = std.testing.allocator;
    var deck = try parser.parse(gpa, simple_made_easy);
    defer deck.deinit(gpa);

    // The deck is dozens of slides; assert it is clearly multi-slide.
    try std.testing.expect(deck.slides.len >= 20);
}

test "renders the example deck to self-contained HTML, one section per slide" {
    const gpa = std.testing.allocator;
    var deck = try parser.parse(gpa, simple_made_easy);
    defer deck.deinit(gpa);

    const document = try html.render(gpa, deck);
    defer gpa.free(document);

    try std.testing.expect(std.mem.startsWith(u8, document, "<!doctype html>"));
    try std.testing.expectEqual(
        deck.slides.len,
        std.mem.count(u8, document, "<section>"),
    );
}
