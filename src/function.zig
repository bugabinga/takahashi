//! Function calls in a slide (SPEC 1.3): `@name(arguments)`.
//!
//! `scan` splits text into literal and call segments. Arguments follow the
//! shared rules: whitespace separates them, `'single quotes'` group, `\`
//! escapes a special character. For `@run`, `|` separates pipeline stages and
//! a lone `%` is the current-file placeholder. `@note` is the exception: its
//! content is captured verbatim as prose, not split into an argument vector.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

pub const Function = enum { image, audio, note, run };

pub const Token = struct {
    text: []const u8,
    kind: enum { arg, pipe, percent },
};

pub const Call = struct {
    func: Function,
    tokens: []const Token,
};

pub const Segment = union(enum) {
    text: []const u8,
    call: Call,
};

pub fn scan(arena: Allocator, text: []const u8) Allocator.Error![]const Segment {
    var segments: std.ArrayList(Segment) = .empty;
    var literal_start: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '@') {
            if (try parseCall(arena, text, i)) |parsed| {
                if (i > literal_start) {
                    try segments.append(arena, .{ .text = text[literal_start..i] });
                }
                try segments.append(arena, .{ .call = parsed.call });
                i = parsed.end;
                literal_start = i;
                continue;
            }
        }
        i += 1;
    }
    if (text.len > literal_start) {
        try segments.append(arena, .{ .text = text[literal_start..] });
    }
    return segments.toOwnedSlice(arena);
}

const Parsed = struct { call: Call, end: usize };

fn parseCall(arena: Allocator, text: []const u8, at: usize) Allocator.Error!?Parsed {
    var i = at + 1; // past '@'
    const name_start = i;
    while (i < text.len and text[i] >= 'a' and text[i] <= 'z') : (i += 1) {}
    const func = std.meta.stringToEnum(Function, text[name_start..i]) orelse return null;
    if (i >= text.len or text[i] != '(') return null;
    i += 1; // past '('

    // Find the matching ')', respecting quotes and escapes.
    const inner_start = i;
    var quoted = false;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c == '\\') {
            i += 1;
            continue;
        }
        if (c == '\'') quoted = !quoted;
        if (c == ')' and !quoted) break;
    }
    if (i >= text.len) return null; // no closing ')'

    const inner = text[inner_start..i];
    // `@note` is prose for the speaker, not an argument vector: capture it
    // whole rather than tokenizing it (SPEC 1.3).
    const tokens = if (func == .note)
        try noteTokens(arena, inner)
    else
        try tokenize(arena, inner);
    return .{ .call = .{ .func = func, .tokens = tokens }, .end = i + 1 };
}

/// Capture a `@note` body verbatim as a single token: whitespace and newlines
/// are preserved, and `\` escapes the following byte so a literal `)` can be
/// written `\)` without closing the call.
fn noteTokens(arena: Allocator, inner: []const u8) Allocator.Error![]const Token {
    var buffer: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        if (inner[i] == '\\' and i + 1 < inner.len) i += 1;
        try buffer.append(arena, inner[i]);
    }
    const tokens = try arena.alloc(Token, 1);
    tokens[0] = .{ .text = try buffer.toOwnedSlice(arena), .kind = .arg };
    assert(tokens.len == 1);
    assert(tokens[0].kind == .arg);
    return tokens;
}

fn tokenize(arena: Allocator, inner: []const u8) Allocator.Error![]const Token {
    var tokens: std.ArrayList(Token) = .empty;
    var current: std.ArrayList(u8) = .empty;
    var has_token = false;
    // Whether the current token was formed with a backslash escape. An escaped
    // `\%` must stay a literal argument, not the `%` placeholder (SPEC 1.3).
    var has_escape = false;
    var quoted = false;

    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        const c = inner[i];
        if (c == '\\' and i + 1 < inner.len) {
            try current.append(arena, inner[i + 1]);
            has_token = true;
            has_escape = true;
            i += 1;
            continue;
        }
        if (c == '\'') {
            quoted = !quoted;
            has_token = true;
            continue;
        }
        if (quoted) {
            try current.append(arena, c);
            continue;
        }
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            try endToken(arena, &tokens, &current, &has_token, &has_escape);
            continue;
        }
        if (c == '|') {
            try endToken(arena, &tokens, &current, &has_token, &has_escape);
            try tokens.append(arena, .{ .text = "|", .kind = .pipe });
            continue;
        }
        try current.append(arena, c);
        has_token = true;
    }
    try endToken(arena, &tokens, &current, &has_token, &has_escape);
    return tokens.toOwnedSlice(arena);
}

fn endToken(
    arena: Allocator,
    tokens: *std.ArrayList(Token),
    current: *std.ArrayList(u8),
    has_token: *bool,
    has_escape: *bool,
) Allocator.Error!void {
    if (!has_token.*) return;
    const text = try current.toOwnedSlice(arena);
    // A lone, unescaped `%` is the file-path placeholder; `\%` is literal.
    const is_percent = !has_escape.* and std.mem.eql(u8, text, "%");
    try tokens.append(arena, .{ .text = text, .kind = if (is_percent) .percent else .arg });
    has_token.* = false;
    has_escape.* = false;
}

test "splits literal text from a call" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const segs = try scan(arena, "before @image(pic.png) after");
    try std.testing.expectEqual(@as(usize, 3), segs.len);
    try std.testing.expectEqualStrings("before ", segs[0].text);
    try std.testing.expectEqual(Function.image, segs[1].call.func);
    try std.testing.expectEqualStrings("pic.png", segs[1].call.tokens[0].text);
    try std.testing.expectEqualStrings(" after", segs[2].text);
}

test "tokenizes quotes, pipes and the percent placeholder" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const segs = try scan(arena, "@run(echo 'a b' | sort %)");
    try std.testing.expectEqual(@as(usize, 1), segs.len);
    const t = segs[0].call.tokens;
    try std.testing.expectEqual(Function.run, segs[0].call.func);
    try std.testing.expectEqualStrings("echo", t[0].text);
    try std.testing.expectEqualStrings("a b", t[1].text); // grouped
    try std.testing.expectEqual(@as(@TypeOf(t[2].kind), .pipe), t[2].kind);
    try std.testing.expectEqualStrings("sort", t[3].text);
    try std.testing.expectEqual(@as(@TypeOf(t[4].kind), .percent), t[4].kind);
}

test "note captures its content verbatim, not as split arguments" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const segs = try scan(arena, "@note(breathe, then \\) smile)");
    try std.testing.expectEqual(@as(usize, 1), segs.len);
    try std.testing.expectEqual(Function.note, segs[0].call.func);
    const t = segs[0].call.tokens;
    // One token, whitespace preserved, `\)` unescaped to a literal `)`.
    try std.testing.expectEqual(@as(usize, 1), t.len);
    try std.testing.expectEqualStrings("breathe, then ) smile", t[0].text);
}

test "an unknown or unterminated call stays literal" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const unknown = try scan(arena, "email me @ home @nope(x)");
    for (unknown) |s| try std.testing.expect(s == .text);
}

test {
    std.testing.refAllDecls(@This());
}
