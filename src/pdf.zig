//! PDF output form (SPEC 3.3): emit a paginated PDF directly, one slide per
//! page, with no external PDF library. Text is drawn with the standard
//! Helvetica font (WinAnsi); styled/CJK text and images are future work.
//! Returns an owned buffer; the caller writes it out.

const std = @import("std");
const Allocator = std.mem.Allocator;

const document = @import("document.zig");
const Slide = document.Slide;

const page_w = 792; // US Letter, landscape (points)
const page_h = 612;
const font_size = 32;
const line_height = 40;
const margin = 50;

pub fn render(gpa: Allocator, slides: []const Slide) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    // Object offsets, indexed by object number (1-based; index 0 unused).
    var offsets: std.ArrayList(usize) = .empty;
    defer offsets.deinit(gpa);
    try offsets.append(gpa, 0);

    try out.appendSlice(gpa, "%PDF-1.7\n");

    // 1: catalog, 2: pages, 3: font. Pages/contents start at object 4.
    try obj(gpa, &out, &offsets, "<</Type/Catalog/Pages 2 0 R>>");

    // Pages object references each page; build the Kids list first.
    var kids: std.ArrayList(u8) = .empty;
    defer kids.deinit(gpa);
    for (slides, 0..) |_, i| {
        try kids.print(gpa, "{d} 0 R ", .{4 + 2 * i});
    }
    try objFmt(gpa, &out, &offsets, "<</Type/Pages/Kids[{s}]/Count {d}>>", .{ kids.items, slides.len });

    try obj(gpa, &out, &offsets, "<</Type/Font/Subtype/Type1/BaseFont/Helvetica>>");

    for (slides) |slide| {
        const content = try contentStream(gpa, slide);
        defer gpa.free(content);
        try objFmt(gpa, &out, &offsets, "<</Type/Page/Parent 2 0 R" ++
            "/MediaBox[0 0 {d} {d}]/Resources<</Font<</F1 3 0 R>>>>" ++
            "/Contents {d} 0 R>>", .{ page_w, page_h, offsets.items.len + 1 });
        try objFmt(gpa, &out, &offsets, "<</Length {d}>>\nstream\n{s}\nendstream", .{ content.len, content });
    }

    // Cross-reference table.
    const xref_offset = out.items.len;
    try out.print(gpa, "xref\n0 {d}\n", .{offsets.items.len});
    try out.appendSlice(gpa, "0000000000 65535 f \n");
    for (offsets.items[1..]) |off| {
        try out.print(gpa, "{d:0>10} 00000 n \n", .{off});
    }
    try out.print(gpa, "trailer\n<</Size {d}/Root 1 0 R>>\nstartxref\n{d}\n%%EOF\n", .{ offsets.items.len, xref_offset });

    return out.toOwnedSlice(gpa);
}

fn obj(gpa: Allocator, out: *std.ArrayList(u8), offsets: *std.ArrayList(usize), body: []const u8) Allocator.Error!void {
    return objFmt(gpa, out, offsets, "{s}", .{body});
}

fn objFmt(
    gpa: Allocator,
    out: *std.ArrayList(u8),
    offsets: *std.ArrayList(usize),
    comptime fmt: []const u8,
    args: anytype,
) Allocator.Error!void {
    const number = offsets.items.len;
    try offsets.append(gpa, out.items.len);
    try out.print(gpa, "{d} 0 obj\n", .{number});
    try out.print(gpa, fmt, args);
    try out.appendSlice(gpa, "\nendobj\n");
}

fn contentStream(gpa: Allocator, slide: Slide) Allocator.Error![]u8 {
    var c: std.ArrayList(u8) = .empty;
    errdefer c.deinit(gpa);
    try c.print(gpa, "BT\n/F1 {d} Tf\n{d} {d} Td\n", .{ font_size, margin, page_h - margin - font_size });

    // Flatten spans to text, then draw line by line.
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    for (slide.spans) |span| try text.appendSlice(gpa, span.text);

    var first = true;
    var lines = std.mem.splitScalar(u8, text.items, '\n');
    while (lines.next()) |line| {
        if (!first) try c.print(gpa, "0 -{d} Td\n", .{line_height});
        first = false;
        try c.appendSlice(gpa, "(");
        try appendPdfString(gpa, &c, line);
        try c.appendSlice(gpa, ") Tj\n");
    }
    try c.appendSlice(gpa, "ET");
    return c.toOwnedSlice(gpa);
}

fn appendPdfString(gpa: Allocator, out: *std.ArrayList(u8), text: []const u8) Allocator.Error!void {
    for (text) |byte| switch (byte) {
        '(', ')', '\\' => {
            try out.append(gpa, '\\');
            try out.append(gpa, byte);
        },
        // Drop bytes that WinAnsi/Helvetica cannot show (e.g. UTF-8 CJK); a
        // proper embedded font is future work.
        0...31, 128...255 => {},
        else => try out.append(gpa, byte),
    };
}

test "emits a valid-looking PDF with one page per slide" {
    const gpa = std.testing.allocator;
    const spans_a = [_]document.Span{.{ .text = "Slide one\nsecond line", .style = .{} }};
    const spans_b = [_]document.Span{.{ .text = "Slide two", .style = .{} }};
    const slides = [_]Slide{
        .{ .spans = &spans_a, .media = &.{}, .notes = "" },
        .{ .spans = &spans_b, .media = &.{}, .notes = "" },
    };
    const doc = try render(gpa, &slides);
    defer gpa.free(doc);

    try std.testing.expect(std.mem.startsWith(u8, doc, "%PDF-1.7"));
    try std.testing.expect(std.mem.endsWith(u8, doc, "%%EOF\n"));
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, doc, "/Type/Page/"));
    try std.testing.expect(std.mem.indexOf(u8, doc, "(Slide one) Tj") != null);
}

test {
    std.testing.refAllDecls(@This());
}
