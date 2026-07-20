//! Integration tests over the real example decks (examples/), exercising the
//! parse -> process -> render path end to end. Rooted at the project directory
//! so the example files can be embedded. See examples/README.md.

const std = @import("std");

const parser = @import("src/parser.zig");
const document = @import("src/document.zig");
const html = @import("src/html.zig");

const simple_made_easy = @embedFile("examples/simple_made_easy/simple_made_easy.taka");

test "parses the Simple Made Easy deck into many slides" {
    const gpa = std.testing.allocator;
    var deck = try parser.parse(gpa, simple_made_easy);
    defer deck.deinit(gpa);
    try std.testing.expect(deck.slides.len >= 20);
}

test "processes and renders the example deck to self-contained HTML" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();

    var deck = try parser.parse(gpa, simple_made_easy);
    defer deck.deinit(gpa);

    var doc = try document.process(
        gpa,
        threaded.io(),
        std.Io.Dir.cwd(),
        simple_made_easy,
        "examples/simple_made_easy/simple_made_easy.taka",
        deck,
    );
    defer doc.deinit();

    const out = try html.render(gpa, doc.slides);
    defer gpa.free(out);

    try std.testing.expect(std.mem.startsWith(u8, out, "<!doctype html>"));
    try std.testing.expectEqual(
        deck.slides.len,
        std.mem.count(u8, out, "<section>"),
    );
}
