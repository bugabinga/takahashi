//! Inline text markup (SPEC 1.2): parse a run of text into styled spans.
//!
//! Each marker toggles a style and is paired with its next unescaped match;
//! an unpaired marker is a literal character, so stray `/` or `-` in ordinary
//! text (URLs, dates) are left alone. A marker is escaped with a leading `\`.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

pub const Style = packed struct {
    mono: bool = false,
    bold: bool = false,
    italic: bool = false,
    underline: bool = false,
    strike: bool = false,
    reverse: bool = false,
};

pub const Span = struct {
    text: []const u8,
    style: Style,
};

const markers = "`*/_-|";

fn isSpace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\n' or byte == '\r';
}

fn markerStyle(byte: u8, style: *Style) void {
    switch (byte) {
        '`' => style.mono = !style.mono,
        '*' => style.bold = !style.bold,
        '/' => style.italic = !style.italic,
        '_' => style.underline = !style.underline,
        '-' => style.strike = !style.strike,
        '|' => style.reverse = !style.reverse,
        else => unreachable,
    }
}

// Bytes that can begin markup work: the six markers plus the escape.
const special = markers ++ "\\";

/// SIMD scan: does `text` contain any marker or backslash? The overwhelmingly
/// common slide body has none, so this fast-paths to a single borrowed span.
fn containsSpecial(text: []const u8) bool {
    const lanes = comptime std.simd.suggestVectorLength(u8) orelse 16;
    const Block = @Vector(lanes, u8);
    var i: usize = 0;
    while (i + lanes <= text.len) : (i += lanes) {
        const block: Block = text[i..][0..lanes].*;
        var hit: @Vector(lanes, bool) = @splat(false);
        inline for (special) |d| hit = hit | (block == @as(Block, @splat(d)));
        if (@reduce(.Or, hit)) return true;
    }
    while (i < text.len) : (i += 1) {
        inline for (special) |d| if (text[i] == d) return true;
    }
    return false;
}

/// Parse `text` into styled spans. Span text borrows `text` where no escape
/// intervenes; escaped spans are copied into `arena`.
pub fn parse(arena: Allocator, text: []const u8) Allocator.Error![]const Span {
    if (text.len == 0) return &.{};
    // Fast path: no markers and no escapes — the whole text is one span, no
    // per-byte work and no allocation beyond the one-element array.
    if (!containsSpecial(text)) {
        const spans = try arena.alloc(Span, 1);
        spans[0] = .{ .text = text, .style = .{} };
        return spans;
    }

    // A backslash escapes the following byte (and is consumed), so it cannot
    // escape a byte that is itself escaped: `\\*` frees the `*`.
    var escaped: std.DynamicBitSetUnmanaged = try .initEmpty(arena, text.len);
    var pos: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, pos, '\\')) |bs| {
        if (bs + 1 < text.len) escaped.set(bs + 1);
        pos = bs + 2;
    }

    // Pair each marker with markdown-style boundaries (SIMD jumps between
    // occurrences); record the paired positions as the active markers.
    var active: std.DynamicBitSetUnmanaged = try .initEmpty(arena, text.len);
    inline for (markers) |m| {
        var open: ?usize = null;
        var at: usize = 0;
        while (std.mem.indexOfScalarPos(u8, text, at, m)) |i| {
            at = i + 1;
            if (escaped.isSet(i)) continue;
            const before_space = i == 0 or isSpace(text[i - 1]);
            const after_space = i + 1 >= text.len or isSpace(text[i + 1]);
            if (open) |o| {
                if (!before_space) { // can close
                    active.set(o);
                    active.set(i);
                    open = null;
                } else if (!after_space) {
                    open = i;
                }
            } else if (before_space and !after_space) {
                open = i;
            }
        }
    }

    var spans: std.ArrayList(Span) = .empty;
    var style: Style = .{};
    var span_start: usize = 0;
    var it = active.iterator(.{});
    while (it.next()) |i| {
        try emitSpan(arena, &spans, text[span_start..i], style);
        markerStyle(text[i], &style);
        span_start = i + 1;
    }
    try emitSpan(arena, &spans, text[span_start..], style);
    return spans.toOwnedSlice(arena);
}

/// Emit one span. Borrows `region` when it has no escape; otherwise copies it
/// into `arena` with escaping backslashes removed. Empty regions are dropped.
fn emitSpan(
    arena: Allocator,
    spans: *std.ArrayList(Span),
    region: []const u8,
    style: Style,
) Allocator.Error!void {
    if (region.len == 0) return;
    if (std.mem.indexOfScalar(u8, region, '\\') == null) {
        try spans.append(arena, .{ .text = region, .style = style });
        return;
    }
    const buffer = try arena.alloc(u8, region.len);
    var n: usize = 0;
    var j: usize = 0;
    while (j < region.len) : (j += 1) {
        if (region[j] == '\\' and j + 1 < region.len) j += 1;
        buffer[n] = region[j];
        n += 1;
    }
    try spans.append(arena, .{ .text = buffer[0..n], .style = style });
}

test "plain text is one unstyled span" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const spans = try parse(arena, "hello world");
    try std.testing.expectEqual(@as(usize, 1), spans.len);
    try std.testing.expectEqualStrings("hello world", spans[0].text);
    try std.testing.expectEqual(Style{}, spans[0].style);
}

test "paired markers style the text between them" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const spans = try parse(arena, "a *bold* b");
    try std.testing.expectEqual(@as(usize, 3), spans.len);
    try std.testing.expectEqualStrings("a ", spans[0].text);
    try std.testing.expectEqualStrings("bold", spans[1].text);
    try std.testing.expect(spans[1].style.bold);
    try std.testing.expectEqualStrings(" b", spans[2].text);
}

test "unpaired marker and escapes are literal" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Two slashes in a URL pair up (harmless); a lone trailing marker is literal.
    const one = try parse(arena, "use * literally");
    try std.testing.expectEqual(@as(usize, 1), one.len);
    try std.testing.expectEqualStrings("use * literally", one[0].text);

    const esc = try parse(arena, "\\*not bold\\*");
    try std.testing.expectEqual(@as(usize, 1), esc.len);
    try std.testing.expectEqualStrings("*not bold*", esc[0].text);
}

test "ordinary punctuation in prose is left literal" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // URL slashes and hyphenated words must survive unchanged.
    const url = try parse(arena, "see http://a.com/x/y and Made-Easy");
    try std.testing.expectEqual(@as(usize, 1), url.len);
    try std.testing.expectEqualStrings("see http://a.com/x/y and Made-Easy", url[0].text);
}

test {
    std.testing.refAllDecls(@This());
}
