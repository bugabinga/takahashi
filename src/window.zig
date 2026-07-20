//! Window output form (SPEC 3.1): a full-screen presentation via the vendored
//! sokol libraries. Text is drawn large with sokol_debugtext and navigated
//! through the tested Presentation state machine.
//!
//! Scaffold: sokol_debugtext is an ASCII bitmap font, so this renders the deck
//! blocky and Latin-only. Proportional, scaled, CJK-aware text via FreeType +
//! HarfBuzz (SPEC 1.2 / 3), plus images, audio and video, come next.

const std = @import("std");
const sk = @import("sokol");

const document = @import("document.zig");
const Presentation = @import("presentation.zig").Presentation;

const log = std.log.scoped(.takahashi);

// sokol_app drives a C callback loop (no closures), so slide text and the
// navigation state live in file-scope globals for the frame.
var texts: []const []const u8 = &.{};
var show: Presentation = .{ .count = 0 };

pub fn present(gpa: std.mem.Allocator, slides: []const document.Slide) void {
    texts = flatten(gpa, slides) catch &.{};
    show = Presentation.init(slides.len);
    log.info("presenting {d} slide(s)", .{slides.len});

    var desc: sk.sapp_desc = .{
        .init_cb = &init,
        .frame_cb = &frame,
        .event_cb = &event,
        .cleanup_cb = &cleanup,
        .width = 1280,
        .height = 720,
        .window_title = "takahashi",
        .logger = .{ .func = &sk.slog_func },
    };
    sk.sapp_run(&desc);
}

// The small canvas fits roughly this many bitmap columns across the frame.
const wrap_columns = 19;

/// Flatten each slide's styled spans to plain text and wrap it to the frame
/// width for the bitmap renderer.
fn flatten(gpa: std.mem.Allocator, slides: []const document.Slide) ![]const []const u8 {
    const out = try gpa.alloc([]const u8, slides.len);
    for (slides, 0..) |slide, i| {
        var plain: std.ArrayList(u8) = .empty;
        defer plain.deinit(gpa);
        for (slide.spans) |span| try plain.appendSlice(gpa, span.text);
        out[i] = try wrap(gpa, plain.items, wrap_columns);
    }
    return out;
}

/// Greedy word wrap that keeps existing line breaks.
fn wrap(gpa: std.mem.Allocator, text: []const u8, columns: usize) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var column: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var first_line = true;
    while (lines.next()) |line| {
        if (!first_line) {
            try out.append(gpa, '\n');
            column = 0;
        }
        first_line = false;
        var words = std.mem.tokenizeScalar(u8, line, ' ');
        var first_word = true;
        while (words.next()) |word| {
            if (!first_word and column + 1 + word.len > columns) {
                try out.append(gpa, '\n');
                column = 0;
                first_word = true;
            }
            if (!first_word) {
                try out.append(gpa, ' ');
                column += 1;
            }
            try out.appendSlice(gpa, word);
            column += word.len;
            first_word = false;
        }
    }
    return out.toOwnedSlice(gpa);
}

fn init() callconv(.c) void {
    sk.sg_setup(&.{
        .environment = sk.sglue_environment(),
        .logger = .{ .func = &sk.slog_func },
    });
    var text_desc: sk.sdtx_desc_t = .{ .logger = .{ .func = &sk.slog_func } };
    text_desc.fonts[0] = sk.sdtx_font_c64();
    sk.sdtx_setup(&text_desc);
}

fn frame() callconv(.c) void {
    // A small canvas magnifies the 8x8 font, so text fills the frame (SPEC 3).
    sk.sdtx_canvas(sk.sapp_widthf() / 8.0, sk.sapp_heightf() / 8.0);
    sk.sdtx_origin(1, 1);
    sk.sdtx_font(0);
    sk.sdtx_color3b(245, 245, 245);
    if (show.current < texts.len) {
        const text = texts[show.current];
        sk.sdtx_putr(text.ptr, @intCast(text.len));
    }

    var pass: sk.sg_pass = .{ .swapchain = sk.sglue_swapchain() };
    pass.action.colors[0].load_action = @intCast(sk.SG_LOADACTION_CLEAR);
    pass.action.colors[0].clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 1 };
    sk.sg_begin_pass(&pass);
    sk.sdtx_draw();
    sk.sg_end_pass();
    sk.sg_commit();
}

fn event(ev: [*c]const sk.sapp_event) callconv(.c) void {
    if (ev.*.type != sk.SAPP_EVENTTYPE_KEY_DOWN) return;
    // Navigation (SPEC 2.1) delegates to the tested Presentation state machine.
    switch (ev.*.key_code) {
        sk.SAPP_KEYCODE_RIGHT, sk.SAPP_KEYCODE_SPACE => show.next(),
        sk.SAPP_KEYCODE_LEFT => show.prev(),
        sk.SAPP_KEYCODE_HOME => show.first(),
        sk.SAPP_KEYCODE_END => show.last(),
        sk.SAPP_KEYCODE_ESCAPE => sk.sapp_request_quit(),
        else => {},
    }
}

fn cleanup() callconv(.c) void {
    sk.sdtx_shutdown();
    sk.sg_shutdown();
}
