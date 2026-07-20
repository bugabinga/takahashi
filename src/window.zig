//! Window output form (SPEC 3.1): a full-screen presentation driven by the
//! vendored sokol libraries (window + immediate-mode rendering).
//!
//! This is a scaffold: it opens a window, clears each frame, and drives slide
//! navigation. Drawing slide text scaled to fill the frame (via FreeType +
//! HarfBuzz), images, audio and video come next.

const std = @import("std");
const sk = @import("sokol");

const Deck = @import("slide.zig").Deck;
const Presentation = @import("presentation.zig").Presentation;

const log = std.log.scoped(.takahashi);

// sokol_app drives a C callback loop (function pointers, no closures), so the
// deck and navigation state live in file-scope globals for the frame.
var deck: Deck = .{ .slides = &.{} };
var show: Presentation = .{ .count = 0 };

pub fn present(presented: Deck) void {
    deck = presented;
    show = Presentation.init(presented.slides.len);
    log.info("presenting {d} slide(s)", .{presented.slides.len});

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

fn init() callconv(.c) void {
    sk.sg_setup(&.{
        .environment = sk.sglue_environment(),
        .logger = .{ .func = &sk.slog_func },
    });
}

fn frame() callconv(.c) void {
    // TODO: draw deck.slides[show.current].body scaled to fill the frame
    // (FreeType + HarfBuzz, SPEC 1.2 / 3), plus images, audio and video.
    var pass: sk.sg_pass = .{ .swapchain = sk.sglue_swapchain() };
    sk.sg_begin_pass(&pass);
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
    sk.sg_shutdown();
}
