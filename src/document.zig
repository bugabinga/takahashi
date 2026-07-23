//! Turn parsed slides (parser.zig) into rendered slides ready for an output
//! form: `@run` output substituted, media collected, `@note` prose pulled out
//! as speaker notes, and the remaining text parsed into styled spans (SPEC 1).
//! Images are embedded as data URIs so the HTML form stays self-contained.

const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

const slide_mod = @import("slide.zig");
const parser = @import("parser.zig");
const function = @import("function.zig");
const markup = @import("markup.zig");
const run = @import("run.zig").run;

pub const Style = markup.Style;
pub const Span = markup.Span;

pub const MediaKind = enum { image, audio };

pub const Media = struct {
    kind: MediaKind,
    path: []const u8,
    /// A `data:` URI with the file's bytes, when it was embedded (images).
    data_uri: ?[]const u8 = null,
};

pub const Slide = struct {
    spans: []const Span,
    media: []const Media,
    notes: []const u8,
};

/// Owns everything reachable from `slides` via its arena; `notes` borrow the
/// original source, which must outlive the document.
pub const Document = struct {
    slides: []const Slide,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(document: *Document) void {
        document.arena.deinit();
    }
};

/// Read a deck's source (the file at `path`, or standard input when `path` is
/// `-`), parse it, and process it into a self-contained Document (SPEC 1). The
/// Document owns its arena, so the source is freed here.
pub fn load(gpa: Allocator, io: std.Io, base_dir: std.Io.Dir, path: []const u8) !Document {
    const source = try readSource(gpa, io, path);
    defer gpa.free(source);
    var deck = try parser.parse(gpa, source);
    defer deck.deinit(gpa);
    return process(gpa, io, base_dir, source, path, deck);
}

fn readSource(gpa: Allocator, io: std.Io, path: []const u8) ![]u8 {
    if (std.mem.eql(u8, path, "-")) {
        var buffer: [4096]u8 = undefined;
        var reader = std.Io.File.stdin().readerStreaming(io, &buffer);
        return reader.interface.allocRemaining(gpa, .unlimited);
    }
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
}

pub fn process(
    gpa: Allocator,
    io: std.Io,
    base_dir: std.Io.Dir,
    source: []const u8,
    file_path: []const u8,
    deck: slide_mod.Deck,
) !Document {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    errdefer arena_state.deinit();
    const arena = arena_state.allocator();

    const slides = try arena.alloc(Slide, deck.slides.len);
    for (deck.slides, 0..) |raw, i| {
        slides[i] = try processSlide(arena, io, base_dir, source, file_path, raw);
    }
    return .{ .slides = slides, .arena = arena_state };
}

fn processSlide(
    arena: Allocator,
    io: std.Io,
    base_dir: std.Io.Dir,
    source: []const u8,
    file_path: []const u8,
    raw: slide_mod.Slide,
) !Slide {
    const segments = try function.scan(arena, raw.body);

    var text: std.ArrayList(u8) = .empty;
    var media: std.ArrayList(Media) = .empty;
    var notes: std.ArrayList(u8) = .empty;
    for (segments) |segment| switch (segment) {
        .text => |t| try text.appendSlice(arena, t),
        .call => |call| switch (call.func) {
            .run => {
                const output = run(arena, io, source, file_path, call.tokens) catch |err| {
                    std.log.scoped(.takahashi).warn("@run failed: {t}", .{err});
                    continue;
                };
                try text.appendSlice(arena, output);
            },
            .image => try media.append(arena, try embed(arena, io, base_dir, .image, pathOf(call))),
            .audio => try media.append(arena, .{ .kind = .audio, .path = pathOf(call) }),
            .note => try appendNote(arena, &notes, call),
        },
    };

    // Pulling out `@note`/`@image` calls can leave leading or trailing blank
    // lines; slides never carry meaningful edge whitespace, so trim it.
    const visible = std.mem.trim(u8, text.items, " \t\r\n");
    return .{
        .spans = try markup.parse(arena, visible),
        .media = try media.toOwnedSlice(arena),
        .notes = try notes.toOwnedSlice(arena),
    };
}

/// Append a `@note` body to the slide's notes (SPEC 1.3), blank line between
/// multiple notes. Empty `@note()` calls contribute nothing.
fn appendNote(arena: Allocator, notes: *std.ArrayList(u8), call: function.Call) Allocator.Error!void {
    if (call.tokens.len == 0) return;
    const note = call.tokens[0].text;
    if (note.len == 0) return;
    if (notes.items.len != 0) try notes.appendSlice(arena, "\n\n");
    try notes.appendSlice(arena, note);
}

/// The first line of a slide's visible text, for a "next slide" preview in the
/// presenter views (SPEC 2.1). Borrows the slide's span text.
pub fn previewOf(slide: Slide) []const u8 {
    if (slide.spans.len == 0) return "";
    const first = slide.spans[0].text;
    const end = std.mem.indexOfScalar(u8, first, '\n') orelse first.len;
    return first[0..end];
}

fn pathOf(call: function.Call) []const u8 {
    for (call.tokens) |token| {
        if (token.kind == .arg) return token.text;
    }
    return "";
}

/// Read an image and build a `data:` URI so the HTML form is self-contained.
/// On any error the media is kept with a null URI (forms fall back to the path).
fn embed(arena: Allocator, io: std.Io, base_dir: std.Io.Dir, kind: MediaKind, path: []const u8) !Media {
    const bytes = base_dir.readFileAlloc(io, path, arena, .unlimited) catch {
        return .{ .kind = kind, .path = path };
    };
    const mime = mimeOf(path);
    const encoder = std.base64.standard.Encoder;
    const uri = try arena.alloc(u8, "data:".len + mime.len + ";base64,".len + encoder.calcSize(bytes.len));
    var w: std.Io.Writer = .fixed(uri);
    w.writeAll("data:") catch unreachable;
    w.writeAll(mime) catch unreachable;
    w.writeAll(";base64,") catch unreachable;
    _ = encoder.encodeWriter(&w, bytes) catch unreachable;
    return .{ .kind = kind, .path = path, .data_uri = uri };
}

fn mimeOf(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".png")) return "image/png";
    if (std.mem.endsWith(u8, path, ".jpg") or std.mem.endsWith(u8, path, ".jpeg")) return "image/jpeg";
    if (std.mem.endsWith(u8, path, ".gif")) return "image/gif";
    return "application/octet-stream";
}

test "substitutes @run output and collects media, then parses markup" {
    // The test spawns /bin/echo (present on Linux and macOS, absent on Windows).
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();

    const src =
        "Title with @run(/bin/echo hi) and *bold*\n@image(missing.png)@note(speak up)";
    const slides = [_]slide_mod.Slide{.{ .body = src }};
    var doc = try process(gpa, threaded.io(), std.Io.Dir.cwd(), src, "/tmp/x.taka", .{ .slides = &slides });
    defer doc.deinit();

    try std.testing.expectEqual(@as(usize, 1), doc.slides.len);
    const slide = doc.slides[0];
    // The @run output "hi\n" is spliced into the visible text.
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(gpa);
    for (slide.spans) |s| try joined.appendSlice(gpa, s.text);
    try std.testing.expect(std.mem.indexOf(u8, joined.items, "hi") != null);
    try std.testing.expect(std.mem.indexOf(u8, joined.items, "bold") != null);
    // @note is pulled out as speaker notes, not left in the visible text.
    try std.testing.expectEqualStrings("speak up", slide.notes);
    try std.testing.expect(std.mem.indexOf(u8, joined.items, "speak up") == null);
    // one image collected (missing file -> path kept, no data uri)
    try std.testing.expectEqual(@as(usize, 1), slide.media.len);
    try std.testing.expectEqual(MediaKind.image, slide.media[0].kind);
}

test {
    std.testing.refAllDecls(@This());
}
