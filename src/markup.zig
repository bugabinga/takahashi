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

/// Parse `text` into styled spans. Span text is copied into `arena`.
pub fn parse(arena: Allocator, text: []const u8) Allocator.Error![]const Span {
    // Pass 1: classify each byte position as an active (paired) marker or not.
    // A byte is an active marker only if it is an unescaped marker whose count
    // of unescaped occurrences seen so far pairs it with a later one.
    var active = try arena.alloc(bool, text.len);
    @memset(active, false);
    inline for (markers) |m| {
        var open: ?usize = null;
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            if (text[i] == '\\') {
                i += 1; // skip the escaped byte
                continue;
            }
            if (text[i] != m) continue;
            // Markdown-style boundaries: an opener follows start/whitespace and
            // precedes non-whitespace; a closer follows non-whitespace. This
            // keeps stray markers in ordinary text literal — `http://x`,
            // `Made-Easy` — while still styling `*bold*` and `/italic/`.
            const before_space = i == 0 or isSpace(text[i - 1]);
            const after_space = i + 1 >= text.len or isSpace(text[i + 1]);
            const can_open = before_space and !after_space;
            const can_close = !before_space;
            if (open) |o| {
                if (can_close) {
                    active[o] = true;
                    active[i] = true;
                    open = null;
                } else if (can_open) {
                    open = i;
                }
            } else if (can_open) {
                open = i;
            }
        }
    }

    var spans: std.ArrayList(Span) = .empty;
    var buffer: std.ArrayList(u8) = .empty;
    var style: Style = .{};

    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\\' and i + 1 < text.len) {
            try buffer.append(arena, text[i + 1]);
            i += 1;
            continue;
        }
        if (active[i]) {
            try flush(arena, &spans, &buffer, style);
            markerStyle(text[i], &style);
            continue;
        }
        try buffer.append(arena, text[i]);
    }
    try flush(arena, &spans, &buffer, style);

    return spans.toOwnedSlice(arena);
}

fn flush(
    arena: Allocator,
    spans: *std.ArrayList(Span),
    buffer: *std.ArrayList(u8),
    style: Style,
) Allocator.Error!void {
    if (buffer.items.len == 0) return;
    const owned = try buffer.toOwnedSlice(arena);
    try spans.append(arena, .{ .text = owned, .style = style });
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
