//! HTML output form (SPEC 3.4): render a deck to a single self-contained HTML
//! document — inline CSS, minimal vanilla JS for navigation, no external
//! assets. Speaker notes are emitted as hidden elements for later presenter
//! support. Returns an owned buffer; the caller writes it to the destination.
//!
//! TODO: images/audio/video as data URIs (SPEC 1.3), inline markup (SPEC 1.2),
//! and text scaled to fill the frame (SPEC 3).

const std = @import("std");
const Allocator = std.mem.Allocator;

const Deck = @import("slide.zig").Deck;

const head =
    \\<!doctype html>
    \\<html lang="en"><head><meta charset="utf-8">
    \\<meta name="viewport" content="width=device-width, initial-scale=1">
    \\<title>takahashi</title>
    \\<style>
    \\  html,body{margin:0;height:100%;background:#000;color:#f5f5f5;
    \\    font-family:system-ui,sans-serif}
    \\  section{display:none;height:100%;box-sizing:border-box;padding:5vmin;
    \\    place-content:center;text-align:center;white-space:pre-wrap;
    \\    font-size:8vmin;font-weight:700}
    \\  section.active{display:grid}
    \\  .notes{display:none}
    \\</style></head><body>
    \\
;

const tail =
    \\<script>
    \\  const slides=[...document.querySelectorAll('section')];
    \\  let i=0;
    \\  const show=n=>{slides[i].classList.remove('active');
    \\    i=Math.max(0,Math.min(slides.length-1,n));
    \\    slides[i].classList.add('active')};
    \\  addEventListener('keydown',e=>{
    \\    if(e.key==='ArrowRight'||e.key===' ')show(i+1);
    \\    else if(e.key==='ArrowLeft')show(i-1);
    \\    else if(e.key==='Home')show(0);
    \\    else if(e.key==='End')show(slides.length-1)});
    \\  if(slides.length)show(0);
    \\</script></body></html>
    \\
;

pub fn render(gpa: Allocator, deck: Deck) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.appendSlice(gpa, head);
    for (deck.slides) |s| {
        try out.appendSlice(gpa, "<section>");
        try appendEscaped(gpa, &out, s.body);
        if (s.notes.len != 0) {
            try out.appendSlice(gpa, "<div class=\"notes\">");
            try appendEscaped(gpa, &out, s.notes);
            try out.appendSlice(gpa, "</div>");
        }
        try out.appendSlice(gpa, "</section>\n");
    }
    try out.appendSlice(gpa, tail);

    return out.toOwnedSlice(gpa);
}

fn appendEscaped(gpa: Allocator, out: *std.ArrayList(u8), text: []const u8) Allocator.Error!void {
    for (text) |byte| {
        switch (byte) {
            '&' => try out.appendSlice(gpa, "&amp;"),
            '<' => try out.appendSlice(gpa, "&lt;"),
            '>' => try out.appendSlice(gpa, "&gt;"),
            else => try out.append(gpa, byte),
        }
    }
}

test "produces a self-contained document with one section per slide" {
    const gpa = std.testing.allocator;
    const slide = @import("slide.zig");
    const slides = [_]slide.Slide{
        .{ .body = "One", .notes = "" },
        .{ .body = "a < b & c", .notes = "note" },
    };
    const doc = try render(gpa, .{ .slides = &slides });
    defer gpa.free(doc);

    try std.testing.expect(std.mem.startsWith(u8, doc, "<!doctype html>"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, doc, "<section>"));
    try std.testing.expect(std.mem.indexOf(u8, doc, "a &lt; b &amp; c") != null);
}

test {
    std.testing.refAllDecls(@This());
}
