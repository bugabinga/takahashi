//! Function calls in a slide (SPEC 1.3): `@name(arguments)`.
//!
//! `scan` splits text into literal and call segments. Arguments follow the
//! shared rules: whitespace separates them, `'single quotes'` group, `\`
//! escapes a special character. For `@run`, `|` separates pipeline stages and
//! a lone `%` is the current-file placeholder.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Function = enum { image, audio, video, run };

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

    const tokens = try tokenize(arena, text[inner_start..i]);
    return .{ .call = .{ .func = func, .tokens = tokens }, .end = i + 1 };
}

fn tokenize(arena: Allocator, inner: []const u8) Allocator.Error![]const Token {
    var tokens: std.ArrayList(Token) = .empty;
    var current: std.ArrayList(u8) = .empty;
    var has_token = false;
    var quoted = false;

    var i: usize = 0;
    while (i < inner.len) : (i += 1) {
        const c = inner[i];
        if (c == '\\' and i + 1 < inner.len) {
            try current.append(arena, inner[i + 1]);
            has_token = true;
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
            try endToken(arena, &tokens, &current, &has_token);
            continue;
        }
        if (c == '|') {
            try endToken(arena, &tokens, &current, &has_token);
            try tokens.append(arena, .{ .text = "|", .kind = .pipe });
            continue;
        }
        try current.append(arena, c);
        has_token = true;
    }
    try endToken(arena, &tokens, &current, &has_token);
    return tokens.toOwnedSlice(arena);
}

fn endToken(
    arena: Allocator,
    tokens: *std.ArrayList(Token),
    current: *std.ArrayList(u8),
    has_token: *bool,
) Allocator.Error!void {
    if (!has_token.*) return;
    const text = try current.toOwnedSlice(arena);
    const kind: @FieldType(Token, "kind") = if (std.mem.eql(u8, text, "%")) .percent else .arg;
    try tokens.append(arena, .{ .text = text, .kind = kind });
    has_token.* = false;
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
