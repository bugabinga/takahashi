//! Proportional, scaled, CJK-aware text layout (SPEC 3): turn a slide's styled
//! spans into a glyph atlas plus positioned triangle vertices, sized to fill
//! the frame with padding, aspect ratio preserved.
//!
//! The vendored single-header stb_truetype rasterizes glyphs — no system text
//! libraries (no FreeType, no HarfBuzz). Fonts are discovered from the host's
//! standard locations at startup (see `candidate_paths`); codepoints the Latin
//! face lacks fall back to the CJK face via glyph-index lookup. Latin/CJK need
//! no complex shaping, so a direct codepoint-to-glyph mapping (plus kerning)
//! stands in for a shaper. The module returns plain data — an 8-bit coverage
//! atlas and a triangle list in pixel coordinates — for a caller to upload to
//! the GPU. It never touches the GPU.

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const markup = @import("markup.zig");
const c = @import("text_c");

pub const Vertex = struct { x: f32, y: f32, u: f32, v: f32 };

pub const Layout = struct {
    /// 8-bit grayscale coverage, atlas_w*atlas_h bytes.
    atlas: []const u8,
    atlas_w: u32,
    atlas_h: u32,
    /// Triangle list, 6 vertices per drawn glyph, centered in the frame.
    vertices: []const Vertex,
    /// The font pixel size chosen by the fit search.
    used_px: f32,
};

const face_regular: u8 = 0;
const face_bold: u8 = 1;
const face_oblique: u8 = 2;
const face_cjk: u8 = 3;
const face_count: usize = 4;

// Which owned font buffer backs each face. The oblique face reuses the regular
// buffer and is slanted synthetically at emit time, keeping italic advances and
// coverage identical to the upright family.
const face_data = [face_count]u8{ 0, 1, 0, 2 };
const data_count: usize = 3;
const data_regular: u8 = 0;
const data_bold: u8 = 1;
const data_cjk: u8 = 2;

const px_min: u32 = 8;
const px_max: u32 = 400;
const atlas_w_min: u32 = 1024;

// A ~11.5-degree slant applied to oblique glyphs as a horizontal shear of the
// emitted quad (0.2 matches the old FreeType FT_Matrix shear of 0.2 * 2^16).
const oblique_shear: f32 = 0.2;

const FontRole = enum { regular, bold, cjk };

/// A shaping run: contiguous bytes of a single font face (no spaces/newlines).
const Sub = struct { face_index: u8, bytes: []const u8 };
/// A whitespace-delimited word: one or more subs, possibly across faces.
const Word = struct { subs: []const Sub };
const Token = union(enum) { word: Word, newline };

const Glyph = struct {
    face_index: u8,
    glyph_index: u32,
    pen_x: f32,
};
const ShapedWord = struct { glyphs: []const Glyph, width: f32 };
const Item = union(enum) { word: usize, newline };
const WordPos = struct { word_index: usize, line: u32, x_start: f32 };
const Wrapped = struct { positions: []const WordPos, line_widths: []const f32 };
const PlacedGlyph = struct {
    face_index: u8,
    glyph_index: u32,
    pen_x: f32,
    baseline_y: f32,
};
const RasterGlyph = struct {
    w: u32,
    h: u32,
    left: i32,
    top: i32,
    pixels: []const u8,
    x: u32,
    y: u32,
};

pub const Renderer = struct {
    /// Owned font byte buffers (regular, bold, CJK); the fontinfos point into
    /// these, so they live as long as the renderer.
    data: [data_count][]u8,
    faces: [face_count]c.stbtt_fontinfo,
    /// The pixel size the fit search is currently probing (stb is stateless, so
    /// scale is derived per call from this).
    px: u32,
};

/// Standard on-disk font locations per host OS, tried in order. Every desktop
/// platform ships a Latin sans, a bold companion, and a pan-CJK face, so no
/// large font asset is committed to the repository.
fn candidate_paths(comptime role: FontRole) []const []const u8 {
    return switch (builtin.os.tag) {
        .linux => switch (role) {
            .regular => &.{
                "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
                "/usr/share/fonts/TTF/DejaVuSans.ttf",
                "/usr/share/fonts/dejavu/DejaVuSans.ttf",
                "/usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf",
                "/usr/share/fonts/liberation/LiberationSans-Regular.ttf",
            },
            .bold => &.{
                "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
                "/usr/share/fonts/TTF/DejaVuSans-Bold.ttf",
                "/usr/share/fonts/dejavu/DejaVuSans-Bold.ttf",
                "/usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf",
                "/usr/share/fonts/liberation/LiberationSans-Bold.ttf",
            },
            .cjk => &.{
                "/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc",
                "/usr/share/fonts/noto-cjk/NotoSansCJK-Regular.ttc",
                "/usr/share/fonts/opentype/noto/NotoSansCJKsc-Regular.otf",
                "/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc",
            },
        },
        .macos => switch (role) {
            .regular => &.{
                "/System/Library/Fonts/Helvetica.ttc",
                "/System/Library/Fonts/HelveticaNeue.ttc",
                "/System/Library/Fonts/Supplemental/Arial.ttf",
                "/Library/Fonts/Arial.ttf",
            },
            .bold => &.{
                "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
                "/Library/Fonts/Arial Bold.ttf",
                "/System/Library/Fonts/Helvetica.ttc",
            },
            .cjk => &.{
                "/System/Library/Fonts/PingFang.ttc",
                "/System/Library/Fonts/Hiragino Sans GB.ttc",
                "/Library/Fonts/Arial Unicode.ttf",
            },
        },
        .windows => switch (role) {
            .regular => &.{
                "C:/Windows/Fonts/arial.ttf",
                "C:/Windows/Fonts/segoeui.ttf",
                "C:/Windows/Fonts/tahoma.ttf",
            },
            .bold => &.{
                "C:/Windows/Fonts/arialbd.ttf",
                "C:/Windows/Fonts/segoeuib.ttf",
                "C:/Windows/Fonts/tahomabd.ttf",
            },
            .cjk => &.{
                "C:/Windows/Fonts/msyh.ttc",
                "C:/Windows/Fonts/msgothic.ttc",
                "C:/Windows/Fonts/malgun.ttf",
                "C:/Windows/Fonts/simsun.ttc",
            },
        },
        else => switch (role) {
            .regular, .bold, .cjk => &.{},
        },
    };
}

/// Read the first existing font for `role` into a gpa-owned buffer.
fn loadFont(gpa: Allocator, io: std.Io, comptime role: FontRole) ![]u8 {
    const paths = candidate_paths(role);
    assert(paths.len > 0);
    for (paths) |path| {
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited) catch continue;
        assert(bytes.len > 0);
        return bytes;
    }
    return error.FontNotFound;
}

/// Initialize a fontinfo over `data`, selecting the first face of a collection.
fn initFace(info: *c.stbtt_fontinfo, data: []const u8) !void {
    assert(data.len > 0);
    const offset = c.stbtt_GetFontOffsetForIndex(data.ptr, 0);
    if (offset < 0) return error.FontParse;
    if (c.stbtt_InitFont(info, data.ptr, offset) == 0) return error.FontParse;
}

/// Discover and load the regular/bold/CJK faces; the oblique face reuses the
/// regular buffer and is slanted at emit time.
pub fn init(gpa: Allocator, io: std.Io) !Renderer {
    var self: Renderer = .{ .data = undefined, .faces = undefined, .px = px_min };
    var loaded: usize = 0;
    errdefer for (0..loaded) |i| gpa.free(self.data[i]);
    self.data[data_regular] = try loadFont(gpa, io, .regular);
    loaded = 1;
    self.data[data_bold] = try loadFont(gpa, io, .bold);
    loaded = 2;
    self.data[data_cjk] = try loadFont(gpa, io, .cjk);
    loaded = 3;
    assert(loaded == data_count);
    for (0..face_count) |i| try initFace(&self.faces[i], self.data[face_data[i]]);
    return self;
}

pub fn deinit(self: *Renderer, gpa: Allocator) void {
    assert(self.data.len == data_count);
    for (self.data) |buf| {
        assert(buf.len > 0);
        gpa.free(buf);
    }
    self.* = undefined;
}

/// Choose the largest integer pixel size (8..400) at which the wrapped spans
/// fit within (frame - 2*padding), then return the centered glyph layout.
pub fn layoutFit(
    self: *Renderer,
    arena: Allocator,
    spans: []const markup.Span,
    frame_w: f32,
    frame_h: f32,
    padding: f32,
) !Layout {
    assert(frame_w > 0);
    assert(frame_h > 0);
    assert(padding >= 0);
    const avail_w = frame_w - 2 * padding;
    const avail_h = frame_h - 2 * padding;
    assert(avail_w > 0);
    assert(avail_h > 0);
    const tokens = try tokenize(self, arena, spans);
    if (tokens.len == 0) return emptyLayout();
    const best = searchSize(self, tokens, avail_w, avail_h);
    setPixelSize(self, best);
    return compose(self, arena, tokens, best, frame_w, frame_h, avail_w);
}

fn emptyLayout() Layout {
    const one = &[_]u8{0};
    return .{ .atlas = one, .atlas_w = 1, .atlas_h = 1, .vertices = &.{}, .used_px = px_min };
}

/// The pixel-to-font scale of `face_index` at the current probe size.
fn scaleFor(self: *Renderer, face_index: u8) f32 {
    assert(face_index < face_count);
    assert(self.px >= px_min);
    const s = c.stbtt_ScaleForPixelHeight(&self.faces[face_index], @floatFromInt(self.px));
    assert(s > 0);
    return s;
}

fn faceForCodepoint(self: *Renderer, style: markup.Style, cp: u21) u8 {
    assert(self.faces.len == face_count);
    var base: u8 = face_regular;
    if (style.bold) base = face_bold else if (style.italic) base = face_oblique;
    assert(base < face_count);
    if (c.stbtt_FindGlyphIndex(&self.faces[base], @intCast(cp)) != 0) return base;
    if (c.stbtt_FindGlyphIndex(&self.faces[face_cjk], @intCast(cp)) != 0) return face_cjk;
    return base;
}

fn setPixelSize(self: *Renderer, px: u32) void {
    assert(px >= px_min);
    assert(px <= px_max);
    self.px = px;
}

const Tokenizer = struct {
    renderer: *Renderer,
    arena: Allocator,
    tokens: std.ArrayList(Token),
    word: std.ArrayList(Sub),
    span_text: []const u8,
    sub_start: usize,
    sub_len: usize,
    sub_face: u8,
    have_sub: bool,

    fn flushSub(t: *Tokenizer) !void {
        assert(t.sub_start <= t.span_text.len);
        if (!t.have_sub or t.sub_len == 0) {
            t.have_sub = false;
            return;
        }
        const end = t.sub_start + t.sub_len;
        assert(end <= t.span_text.len);
        try t.word.append(t.arena, .{
            .face_index = t.sub_face,
            .bytes = t.span_text[t.sub_start..end],
        });
        t.have_sub = false;
    }

    fn flushWord(t: *Tokenizer) !void {
        try t.flushSub();
        assert(!t.have_sub);
        if (t.word.items.len == 0) return;
        const subs = try t.word.toOwnedSlice(t.arena);
        try t.tokens.append(t.arena, .{ .word = .{ .subs = subs } });
        t.word = .empty;
    }

    fn addCodepoint(t: *Tokenizer, style: markup.Style, cp: u21, start: usize, len: usize) !void {
        assert(len >= 1);
        assert(start + len <= t.span_text.len);
        const face = faceForCodepoint(t.renderer, style, cp);
        const contiguous = t.have_sub and face == t.sub_face and start == t.sub_start + t.sub_len;
        if (contiguous) {
            t.sub_len += len;
        } else {
            try t.flushSub();
            t.sub_start = start;
            t.sub_len = len;
            t.sub_face = face;
            t.have_sub = true;
        }
    }

    fn feedSpan(t: *Tokenizer, span: markup.Span) !void {
        try t.flushSub();
        t.span_text = span.text;
        var i: usize = 0;
        while (i < span.text.len) {
            const b = span.text[i];
            if (b == '\n') {
                try t.flushWord();
                try t.tokens.append(t.arena, .newline);
                i += 1;
                continue;
            }
            if (b == ' ' or b == '\t' or b == '\r') {
                try t.flushWord();
                i += 1;
                continue;
            }
            const len = std.unicode.utf8ByteSequenceLength(b) catch 1;
            const end = @min(i + len, span.text.len);
            const cp = std.unicode.utf8Decode(span.text[i..end]) catch @as(u21, b);
            try t.addCodepoint(span.style, cp, i, end - i);
            i = end;
        }
    }
};

fn tokenize(self: *Renderer, arena: Allocator, spans: []const markup.Span) ![]const Token {
    assert(self.faces.len == face_count);
    var t: Tokenizer = .{
        .renderer = self,
        .arena = arena,
        .tokens = .empty,
        .word = .empty,
        .span_text = "",
        .sub_start = 0,
        .sub_len = 0,
        .sub_face = face_regular,
        .have_sub = false,
    };
    for (spans) |span| try t.feedSpan(span);
    try t.flushWord();
    assert(!t.have_sub);
    return t.tokens.toOwnedSlice(arena);
}

/// Map one sub's codepoints to glyphs at the current size; return its advance
/// width in pixels, appending positioned glyphs to `out` when it is non-null.
fn shapeSub(
    self: *Renderer,
    arena: Allocator,
    sub: Sub,
    base_pen: f32,
    out: ?*std.ArrayList(Glyph),
) !f32 {
    assert(sub.bytes.len > 0);
    assert(sub.face_index < face_count);
    const info = &self.faces[sub.face_index];
    const scale = scaleFor(self, sub.face_index);
    var pen: f32 = 0;
    var prev: c_int = 0;
    var have_prev = false;
    var i: usize = 0;
    while (i < sub.bytes.len) {
        const len = std.unicode.utf8ByteSequenceLength(sub.bytes[i]) catch 1;
        const end = @min(i + len, sub.bytes.len);
        const cp = std.unicode.utf8Decode(sub.bytes[i..end]) catch @as(u21, sub.bytes[i]);
        const glyph = c.stbtt_FindGlyphIndex(info, @intCast(cp));
        if (have_prev) pen += @as(f32, @floatFromInt(c.stbtt_GetGlyphKernAdvance(info, prev, glyph))) * scale;
        if (out) |o| try o.append(arena, .{
            .face_index = sub.face_index,
            .glyph_index = @intCast(glyph),
            .pen_x = base_pen + pen,
        });
        var adv: c_int = 0;
        var lsb: c_int = 0;
        c.stbtt_GetGlyphHMetrics(info, glyph, &adv, &lsb);
        pen += @as(f32, @floatFromInt(adv)) * scale;
        prev = glyph;
        have_prev = true;
        i = end;
    }
    assert(pen >= 0);
    return pen;
}

fn wordWidth(self: *Renderer, word: Word) !f32 {
    assert(word.subs.len > 0);
    var width: f32 = 0;
    for (word.subs) |sub| width += try shapeSub(self, undefined, sub, width, null);
    assert(width >= 0);
    return width;
}

fn shapeWord(self: *Renderer, arena: Allocator, word: Word) !ShapedWord {
    assert(word.subs.len > 0);
    var glyphs: std.ArrayList(Glyph) = .empty;
    var width: f32 = 0;
    for (word.subs) |sub| width += try shapeSub(self, arena, sub, width, &glyphs);
    assert(width >= 0);
    return .{ .glyphs = try glyphs.toOwnedSlice(arena), .width = width };
}

fn spaceWidth(self: *Renderer) f32 {
    const sub: Sub = .{ .face_index = face_regular, .bytes = " " };
    const w = shapeSub(self, undefined, sub, 0, null) catch unreachable;
    assert(w >= 0);
    assert(self.faces.len == face_count);
    return w;
}

fn lineHeightPx(self: *Renderer) f32 {
    var ascent: c_int = 0;
    var descent: c_int = 0;
    var line_gap: c_int = 0;
    c.stbtt_GetFontVMetrics(&self.faces[face_regular], &ascent, &descent, &line_gap);
    const units: f32 = @floatFromInt(ascent - descent + line_gap);
    const h = units * scaleFor(self, face_regular);
    assert(h > 0);
    return h;
}

fn ascentPx(self: *Renderer) f32 {
    var ascent: c_int = 0;
    var descent: c_int = 0;
    var line_gap: c_int = 0;
    c.stbtt_GetFontVMetrics(&self.faces[face_regular], &ascent, &descent, &line_gap);
    const a = @as(f32, @floatFromInt(ascent)) * scaleFor(self, face_regular);
    assert(a > 0);
    return a;
}

/// Greedy word wrap at the current size; true when the block fits the frame.
fn fits(
    self: *Renderer,
    tokens: []const Token,
    avail_w: f32,
    avail_h: f32,
) !bool {
    assert(avail_w > 0);
    assert(avail_h > 0);
    const space_w = spaceWidth(self);
    const line_h = lineHeightPx(self);
    var lines: u32 = 1;
    var cur: f32 = 0;
    for (tokens) |tok| switch (tok) {
        .newline => {
            lines += 1;
            cur = 0;
        },
        .word => |w| {
            const ww = try wordWidth(self, w);
            if (ww > avail_w) return false;
            if (cur == 0) {
                cur = ww;
            } else if (cur + space_w + ww > avail_w) {
                lines += 1;
                cur = ww;
            } else cur += space_w + ww;
        },
    };
    return @as(f32, @floatFromInt(lines)) * line_h <= avail_h;
}

fn searchSize(
    self: *Renderer,
    tokens: []const Token,
    avail_w: f32,
    avail_h: f32,
) u32 {
    assert(tokens.len > 0);
    assert(avail_w > 0);
    var lo: u32 = px_min;
    var hi: u32 = px_max;
    var best: u32 = px_min;
    while (lo <= hi) {
        const mid = lo + (hi - lo) / 2;
        setPixelSize(self, mid);
        const ok = fits(self, tokens, avail_w, avail_h) catch false;
        if (ok) {
            best = mid;
            lo = mid + 1;
        } else {
            if (mid == px_min) break;
            hi = mid - 1;
        }
    }
    assert(best >= px_min);
    assert(best <= px_max);
    return best;
}

fn compose(
    self: *Renderer,
    arena: Allocator,
    tokens: []const Token,
    best: u32,
    frame_w: f32,
    frame_h: f32,
    avail_w: f32,
) !Layout {
    assert(tokens.len > 0);
    assert(best >= px_min);
    const space_w = spaceWidth(self);
    var words: std.ArrayList(ShapedWord) = .empty;
    var items: std.ArrayList(Item) = .empty;
    for (tokens) |tok| switch (tok) {
        .newline => try items.append(arena, .newline),
        .word => |w| {
            try words.append(arena, try shapeWord(self, arena, w));
            try items.append(arena, .{ .word = words.items.len - 1 });
        },
    };
    const wrapped = try wrap(arena, items.items, words.items, space_w, avail_w);
    const placed = try placeGlyphs(
        arena,
        wrapped,
        words.items,
        lineHeightPx(self),
        ascentPx(self),
        frame_w,
        frame_h,
    );
    return buildLayout(self, arena, placed, best);
}

fn wrap(
    arena: Allocator,
    items: []const Item,
    words: []const ShapedWord,
    space_w: f32,
    avail_w: f32,
) !Wrapped {
    assert(avail_w > 0);
    assert(space_w >= 0);
    var positions: std.ArrayList(WordPos) = .empty;
    var widths: std.ArrayList(f32) = .empty;
    try widths.append(arena, 0);
    var line: u32 = 0;
    var cur: f32 = 0;
    for (items) |it| switch (it) {
        .newline => {
            line += 1;
            cur = 0;
            try widths.append(arena, 0);
        },
        .word => |wi| {
            const ww = words[wi].width;
            var x_start: f32 = 0;
            if (cur == 0) {
                cur = ww;
            } else if (cur + space_w + ww > avail_w) {
                line += 1;
                cur = ww;
                try widths.append(arena, 0);
            } else {
                x_start = cur + space_w;
                cur += space_w + ww;
            }
            try positions.append(arena, .{ .word_index = wi, .line = line, .x_start = x_start });
            widths.items[line] = cur;
        },
    };
    return .{
        .positions = try positions.toOwnedSlice(arena),
        .line_widths = try widths.toOwnedSlice(arena),
    };
}

fn placeGlyphs(
    arena: Allocator,
    wrapped: Wrapped,
    words: []const ShapedWord,
    line_h: f32,
    ascent: f32,
    frame_w: f32,
    frame_h: f32,
) ![]const PlacedGlyph {
    assert(line_h > 0);
    assert(wrapped.line_widths.len > 0);
    var block_w: f32 = 0;
    for (wrapped.line_widths) |lw| block_w = @max(block_w, lw);
    const block_h = @as(f32, @floatFromInt(wrapped.line_widths.len)) * line_h;
    const origin_x = (frame_w - block_w) / 2;
    const origin_y = (frame_h - block_h) / 2;
    var placed: std.ArrayList(PlacedGlyph) = .empty;
    for (wrapped.positions) |p| {
        const line_x = origin_x + (block_w - wrapped.line_widths[p.line]) / 2;
        const baseline = origin_y + ascent + @as(f32, @floatFromInt(p.line)) * line_h;
        for (words[p.word_index].glyphs) |g| try placed.append(arena, .{
            .face_index = g.face_index,
            .glyph_index = g.glyph_index,
            .pen_x = line_x + p.x_start + g.pen_x,
            .baseline_y = baseline,
        });
    }
    return placed.toOwnedSlice(arena);
}

fn rasterize(self: *Renderer, arena: Allocator, face_index: u8, glyph_index: u32) !RasterGlyph {
    assert(face_index < face_count);
    const scale = scaleFor(self, face_index);
    var w: c_int = 0;
    var h: c_int = 0;
    var xoff: c_int = 0;
    var yoff: c_int = 0;
    const bmp = c.stbtt_GetGlyphBitmap(
        &self.faces[face_index],
        scale,
        scale,
        @intCast(glyph_index),
        &w,
        &h,
        &xoff,
        &yoff,
    );
    defer if (bmp != null) c.stbtt_FreeBitmap(bmp, null);
    assert(w >= 0);
    assert(h >= 0);
    const uw: u32 = @intCast(w);
    const uh: u32 = @intCast(h);
    var pixels: []const u8 = &.{};
    if (uw > 0 and uh > 0) {
        assert(bmp != null);
        const buffer = try arena.alloc(u8, uw * uh);
        @memcpy(buffer, bmp[0 .. uw * uh]);
        pixels = buffer;
    }
    // stb yoff is the downward offset from the baseline to the bitmap top; the
    // atlas/vertex code wants top as an upward distance, so negate.
    return .{ .w = uw, .h = uh, .left = xoff, .top = -yoff, .pixels = pixels, .x = 0, .y = 0 };
}

fn packAtlas(rasters: []RasterGlyph, atlas_w: u32) u32 {
    assert(atlas_w > 0);
    var pen_x: u32 = 0;
    var pen_y: u32 = 0;
    var row_h: u32 = 0;
    for (rasters) |*rg| {
        if (rg.w == 0 or rg.h == 0) continue;
        assert(rg.w < atlas_w);
        if (pen_x + rg.w + 1 > atlas_w) {
            pen_x = 0;
            pen_y += row_h + 1;
            row_h = 0;
        }
        rg.x = pen_x;
        rg.y = pen_y;
        pen_x += rg.w + 1;
        row_h = @max(row_h, rg.h);
    }
    return pen_y + row_h;
}

fn blitAtlas(atlas: []u8, atlas_w: u32, rasters: []const RasterGlyph) void {
    assert(atlas_w > 0);
    assert(atlas.len % atlas_w == 0);
    for (rasters) |rg| {
        if (rg.w == 0 or rg.h == 0) continue;
        var r: u32 = 0;
        while (r < rg.h) : (r += 1) {
            const dst = (rg.y + r) * atlas_w + rg.x;
            @memcpy(atlas[dst .. dst + rg.w], rg.pixels[r * rg.w .. r * rg.w + rg.w]);
        }
    }
}

fn buildLayout(self: *Renderer, arena: Allocator, placed: []const PlacedGlyph, best: u32) !Layout {
    assert(best >= px_min);
    if (placed.len == 0) return emptyLayout();
    var map = std.AutoHashMap(u64, usize).init(arena);
    var rasters: std.ArrayList(RasterGlyph) = .empty;
    for (placed) |pg| {
        const key = keyOf(pg.face_index, pg.glyph_index);
        if (map.contains(key)) continue;
        try rasters.append(arena, try rasterize(self, arena, pg.face_index, pg.glyph_index));
        try map.put(key, rasters.items.len - 1);
    }
    var max_w: u32 = 0;
    for (rasters.items) |rg| max_w = @max(max_w, rg.w);
    const atlas_w = @max(atlas_w_min, max_w + 1);
    assert(atlas_w >= atlas_w_min);
    const atlas_h = packAtlas(rasters.items, atlas_w);
    if (atlas_h == 0) return emptyLayout();
    const atlas = try arena.alloc(u8, atlas_w * atlas_h);
    @memset(atlas, 0);
    blitAtlas(atlas, atlas_w, rasters.items);
    const vertices = try emitVertices(arena, placed, rasters.items, &map, atlas_w, atlas_h);
    return .{
        .atlas = atlas,
        .atlas_w = atlas_w,
        .atlas_h = atlas_h,
        .vertices = vertices,
        .used_px = @floatFromInt(best),
    };
}

fn keyOf(face_index: u8, glyph_index: u32) u64 {
    assert(face_index < face_count);
    const key = (@as(u64, face_index) << 32) | @as(u64, glyph_index);
    assert(key != 0 or glyph_index == 0);
    return key;
}

/// Horizontal shear for a vertex of a glyph on `face_index`: oblique glyphs
/// slant so points above the baseline move right, points below move left.
fn shearX(face_index: u8, x: f32, y: f32, baseline_y: f32) f32 {
    assert(face_index < face_count);
    if (face_index != face_oblique) return x;
    return x + oblique_shear * (baseline_y - y);
}

fn emitVertices(
    arena: Allocator,
    placed: []const PlacedGlyph,
    rasters: []const RasterGlyph,
    map: *std.AutoHashMap(u64, usize),
    atlas_w: u32,
    atlas_h: u32,
) ![]const Vertex {
    assert(atlas_w > 0);
    assert(atlas_h > 0);
    const fw = @as(f32, @floatFromInt(atlas_w));
    const fh = @as(f32, @floatFromInt(atlas_h));
    var verts: std.ArrayList(Vertex) = .empty;
    for (placed) |pg| {
        const rg = rasters[map.get(keyOf(pg.face_index, pg.glyph_index)).?];
        if (rg.w == 0 or rg.h == 0) continue;
        const x0 = pg.pen_x + @as(f32, @floatFromInt(rg.left));
        const y0 = pg.baseline_y - @as(f32, @floatFromInt(rg.top));
        const x1 = x0 + @as(f32, @floatFromInt(rg.w));
        const y1 = y0 + @as(f32, @floatFromInt(rg.h));
        const sx0y0 = shearX(pg.face_index, x0, y0, pg.baseline_y);
        const sx1y0 = shearX(pg.face_index, x1, y0, pg.baseline_y);
        const sx0y1 = shearX(pg.face_index, x0, y1, pg.baseline_y);
        const sx1y1 = shearX(pg.face_index, x1, y1, pg.baseline_y);
        const au0 = @as(f32, @floatFromInt(rg.x)) / fw;
        const av0 = @as(f32, @floatFromInt(rg.y)) / fh;
        const au1 = @as(f32, @floatFromInt(rg.x + rg.w)) / fw;
        const av1 = @as(f32, @floatFromInt(rg.y + rg.h)) / fh;
        try verts.append(arena, .{ .x = sx0y0, .y = y0, .u = au0, .v = av0 });
        try verts.append(arena, .{ .x = sx1y0, .y = y0, .u = au1, .v = av0 });
        try verts.append(arena, .{ .x = sx0y1, .y = y1, .u = au0, .v = av1 });
        try verts.append(arena, .{ .x = sx1y0, .y = y0, .u = au1, .v = av0 });
        try verts.append(arena, .{ .x = sx1y1, .y = y1, .u = au1, .v = av1 });
        try verts.append(arena, .{ .x = sx0y1, .y = y1, .u = au0, .v = av1 });
    }
    return verts.toOwnedSlice(arena);
}

fn testRenderer() !Renderer {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    return init(std.testing.allocator, threaded.io());
}

fn testSpans(comptime one: []const u8, comptime two: []const u8) [2]markup.Span {
    return .{
        .{ .text = one, .style = .{} },
        .{ .text = two, .style = .{ .bold = true } },
    };
}

test "layoutFit produces an atlas and centered vertices for latin text" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var renderer = try testRenderer();
    defer deinit(&renderer, std.testing.allocator);

    const spans = testSpans("Hello ", "bold");
    const layout = try layoutFit(&renderer, arena, &spans, 1280, 720, 40);
    try std.testing.expect(layout.atlas.len > 0);
    try std.testing.expectEqual(layout.atlas.len, layout.atlas_w * layout.atlas_h);
    try std.testing.expect(layout.vertices.len > 0);
    try std.testing.expect(layout.vertices.len % 6 == 0);
    // Advances must be non-zero: the fit search lands well below the ceiling.
    try std.testing.expect(layout.used_px > @as(f32, px_min));
    try std.testing.expect(layout.used_px < @as(f32, px_max));
}

test "layoutFit shapes CJK text via the Noto fallback face" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var renderer = try testRenderer();
    defer deinit(&renderer, std.testing.allocator);

    const spans = [_]markup.Span{.{ .text = "こんにちは", .style = .{} }};
    const layout = try layoutFit(&renderer, arena, &spans, 1280, 720, 40);
    try std.testing.expect(layout.atlas.len > 0);
    try std.testing.expect(layout.vertices.len > 0);
    try std.testing.expectEqual(@as(usize, 5 * 6), layout.vertices.len);
    try std.testing.expect(layout.used_px > @as(f32, px_min));
}

test {
    std.testing.refAllDecls(@This());
}
