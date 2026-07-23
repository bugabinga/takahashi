//! PDF output form (SPEC 3.3): emit a paginated PDF directly, one slide per
//! page, with no external PDF library. Text uses the standard "base-14" fonts,
//! so markup maps to real weights: Helvetica / -Bold / -Oblique / -BoldOblique
//! and Courier for monospace. Speaker notes become page Text annotations
//! (encoded UTF-16, so CJK notes survive) — the "note" a PDF reader shows.
//!
//! Kept pure Zig: it links nothing, so `zig build test` renders it offline.
//! Two things stay out of reach without pulling a dependency into this form and
//! are omitted by design: CJK *body* text (needs an embedded font — the base-14
//! set is Latin-only) and images (needs an image decoder). Notes carry CJK.
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

// The base-14 fonts taka uses, mapped to PDF resource names F1..F5.
const font_names = [_][]const u8{
    "Helvetica",             "Helvetica-Bold", "Helvetica-Oblique",
    "Helvetica-BoldOblique", "Courier",
};
const catalog_obj = 1;
const pages_obj = 2;
const first_font_obj = 3;
const first_page_obj = first_font_obj + font_names.len; // 8

pub fn render(gpa: Allocator, slides: []const Slide) Allocator.Error![]u8 {
    // Object numbering: 1 catalog, 2 pages, 3..7 fonts, then per slide a page,
    // a content stream, and — when it has notes — a Text annotation.
    var total: usize = first_page_obj - 1; // the 7 fixed objects
    for (slides) |slide| {
        total += 2;
        if (slide.notes.len != 0) total += 1;
    }
    const offsets = try gpa.alloc(usize, total + 1); // 1-based; index 0 unused
    defer gpa.free(offsets);
    @memset(offsets, 0);

    // Assign each slide's object numbers up front so pages can reference them.
    const nums = try gpa.alloc(SlideObjs, slides.len);
    defer gpa.free(nums);
    var next = first_page_obj;
    for (slides, 0..) |slide, i| {
        nums[i] = .{ .page = next, .content = next + 1, .annot = 0 };
        next += 2;
        if (slide.notes.len != 0) {
            nums[i].annot = next;
            next += 1;
        }
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "%PDF-1.7\n");

    try emitCatalog(gpa, &out, offsets);
    try emitPages(gpa, &out, offsets, nums);
    try emitFonts(gpa, &out, offsets);
    for (slides, 0..) |slide, i| try emitSlide(gpa, &out, offsets, slide, nums[i]);
    try emitTrailer(gpa, &out, offsets, total);

    return out.toOwnedSlice(gpa);
}

const SlideObjs = struct { page: usize, content: usize, annot: usize };

fn emitCatalog(gpa: Allocator, out: *std.ArrayList(u8), offsets: []usize) Allocator.Error!void {
    try beginObj(gpa, out, offsets, catalog_obj);
    try out.print(gpa, "<</Type/Catalog/Pages {d} 0 R>>", .{pages_obj});
    try endObj(gpa, out);
}

fn emitPages(gpa: Allocator, out: *std.ArrayList(u8), offsets: []usize, nums: []const SlideObjs) Allocator.Error!void {
    try beginObj(gpa, out, offsets, pages_obj);
    try out.appendSlice(gpa, "<</Type/Pages/Kids[");
    for (nums) |n| try out.print(gpa, "{d} 0 R ", .{n.page});
    try out.print(gpa, "]/Count {d}>>", .{nums.len});
    try endObj(gpa, out);
}

fn emitFonts(gpa: Allocator, out: *std.ArrayList(u8), offsets: []usize) Allocator.Error!void {
    for (font_names, 0..) |name, i| {
        try beginObj(gpa, out, offsets, first_font_obj + i);
        try out.print(gpa, "<</Type/Font/Subtype/Type1/BaseFont/{s}>>", .{name});
        try endObj(gpa, out);
    }
}

fn emitSlide(gpa: Allocator, out: *std.ArrayList(u8), offsets: []usize, slide: Slide, n: SlideObjs) Allocator.Error!void {
    try beginObj(gpa, out, offsets, n.page);
    try out.print(gpa, "<</Type/Page/Parent {d} 0 R/MediaBox[0 0 {d} {d}]" ++
        "/Resources<</Font<</F1 3 0 R/F2 4 0 R/F3 5 0 R/F4 6 0 R/F5 7 0 R>>>>" ++
        "/Contents {d} 0 R", .{ pages_obj, page_w, page_h, n.content });
    if (n.annot != 0) try out.print(gpa, "/Annots[{d} 0 R]", .{n.annot});
    try out.appendSlice(gpa, ">>");
    try endObj(gpa, out);

    const content = try contentStream(gpa, slide);
    defer gpa.free(content);
    try beginObj(gpa, out, offsets, n.content);
    try out.print(gpa, "<</Length {d}>>\nstream\n{s}\nendstream", .{ content.len, content });
    try endObj(gpa, out);

    if (n.annot != 0) {
        try beginObj(gpa, out, offsets, n.annot);
        try out.print(gpa, "<</Type/Annot/Subtype/Text/Rect[20 {d} 40 {d}]" ++
            "/Open false/Contents ", .{ page_h - 40, page_h - 20 });
        try appendUtf16Hex(gpa, out, slide.notes);
        try out.appendSlice(gpa, ">>");
        try endObj(gpa, out);
    }
}

fn emitTrailer(gpa: Allocator, out: *std.ArrayList(u8), offsets: []usize, total: usize) Allocator.Error!void {
    const xref_offset = out.items.len;
    try out.print(gpa, "xref\n0 {d}\n", .{total + 1});
    try out.appendSlice(gpa, "0000000000 65535 f \n");
    for (offsets[1..]) |off| try out.print(gpa, "{d:0>10} 00000 n \n", .{off});
    try out.print(gpa, "trailer\n<</Size {d}/Root {d} 0 R>>\nstartxref\n{d}\n%%EOF\n", .{
        total + 1, catalog_obj, xref_offset,
    });
}

fn beginObj(gpa: Allocator, out: *std.ArrayList(u8), offsets: []usize, number: usize) Allocator.Error!void {
    std.debug.assert(number < offsets.len);
    std.debug.assert(offsets[number] == 0);
    offsets[number] = out.items.len;
    try out.print(gpa, "{d} 0 obj\n", .{number});
}

fn endObj(gpa: Allocator, out: *std.ArrayList(u8)) Allocator.Error!void {
    try out.appendSlice(gpa, "\nendobj\n");
}

/// The base-14 resource name for a span's style. Underline/strike/reverse have
/// no base-font equivalent and fall back to the closest weight.
fn fontFor(style: document.Style) []const u8 {
    if (style.mono) return "F5";
    if (style.bold and style.italic) return "F4";
    if (style.bold) return "F2";
    if (style.italic) return "F3";
    return "F1";
}

/// Build a slide's content stream: styled spans drawn line by line. Consecutive
/// `Tj`s on a line flow left-to-right (PDF advances the text point), so per-span
/// font switches need no width math; a newline drops one line down.
fn contentStream(gpa: Allocator, slide: Slide) Allocator.Error![]u8 {
    var c: std.ArrayList(u8) = .empty;
    errdefer c.deinit(gpa);
    try c.print(gpa, "BT\n{d} {d} Td\n", .{ margin, page_h - margin - font_size });
    for (slide.spans) |span| {
        var pieces = std.mem.splitScalar(u8, span.text, '\n');
        var first = true;
        while (pieces.next()) |piece| {
            if (!first) try c.print(gpa, "0 -{d} Td\n", .{line_height});
            first = false;
            if (piece.len == 0) continue;
            try c.print(gpa, "/{s} {d} Tf (", .{ fontFor(span.style), font_size });
            try appendPdfString(gpa, &c, piece);
            try c.appendSlice(gpa, ") Tj\n");
        }
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
        // Drop bytes the Latin base-14 fonts cannot show (e.g. UTF-8 CJK);
        // CJK is carried in the notes annotation instead.
        0...31, 128...255 => {},
        else => try out.append(gpa, byte),
    };
}

/// Write `text` as a PDF UTF-16BE hex string (`<FEFF…>`), the portable way to
/// put Unicode — CJK included — in an annotation's `/Contents`.
fn appendUtf16Hex(gpa: Allocator, out: *std.ArrayList(u8), text: []const u8) Allocator.Error!void {
    try out.appendSlice(gpa, "<FEFF");
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
        const end = @min(i + len, text.len);
        const cp = std.unicode.utf8Decode(text[i..end]) catch text[i];
        i = end;
        if (cp <= 0xFFFF) {
            try out.print(gpa, "{X:0>4}", .{@as(u16, @intCast(cp))});
        } else {
            const c = cp - 0x10000;
            try out.print(gpa, "{X:0>4}{X:0>4}", .{
                @as(u16, @intCast(0xD800 + (c >> 10))),
                @as(u16, @intCast(0xDC00 + (c & 0x3FF))),
            });
        }
    }
    try out.appendSlice(gpa, ">");
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

test "styled spans select the matching base-14 font" {
    const gpa = std.testing.allocator;
    const spans = [_]document.Span{
        .{ .text = "plain ", .style = .{} },
        .{ .text = "bold ", .style = .{ .bold = true } },
        .{ .text = "code", .style = .{ .mono = true } },
    };
    const slides = [_]Slide{.{ .spans = &spans, .media = &.{}, .notes = "" }};
    const doc = try render(gpa, &slides);
    defer gpa.free(doc);
    try std.testing.expect(std.mem.indexOf(u8, doc, "/F1 32 Tf (plain ) Tj") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "/F2 32 Tf (bold ) Tj") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "/F5 32 Tf (code) Tj") != null);
    // Helvetica-Bold must be one of the emitted font objects.
    try std.testing.expect(std.mem.indexOf(u8, doc, "/BaseFont/Helvetica-Bold>>") != null);
}

test "speaker notes become a UTF-16 text annotation" {
    const gpa = std.testing.allocator;
    const spans = [_]document.Span{.{ .text = "Title", .style = .{} }};
    const slides = [_]Slide{.{ .spans = &spans, .media = &.{}, .notes = "hi" }};
    const doc = try render(gpa, &slides);
    defer gpa.free(doc);
    try std.testing.expect(std.mem.indexOf(u8, doc, "/Subtype/Text") != null);
    try std.testing.expect(std.mem.indexOf(u8, doc, "/Annots[") != null);
    // "hi" as UTF-16BE hex with a BOM.
    try std.testing.expect(std.mem.indexOf(u8, doc, "<FEFF00680069>") != null);
}

test {
    std.testing.refAllDecls(@This());
}
