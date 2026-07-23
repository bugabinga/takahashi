//! Window output form (SPEC 3.1): a full-screen presentation via the vendored
//! sokol libraries. Text is rendered with the vendored stb_truetype
//! (proportional, scaled to fill the frame, CJK-aware), images are laid out in
//! an equal grid behind the text, and audio plays on entry.
//!
//! Speaker notes (SPEC 2.1) are not drawn in the window — the audience must
//! never see them. Instead, when launched from a terminal, the window prints
//! the current slide's notes to that controlling terminal as the speaker
//! navigates, using the shared notes renderer from `terminal.zig`. The window
//! goes on the projector; the speaker reads notes on their own screen.

const std = @import("std");
const assert = std.debug.assert;
const sk = @import("sokol");

const document = @import("document.zig");
const Presentation = @import("presentation.zig").Presentation;
const text = @import("text.zig");
const image = @import("image.zig");
const audio = @import("audio.zig");
const terminal = @import("terminal.zig");
const sync = @import("sync.zig");
const watch = @import("watch.zig");

const log = std.log.scoped(.takahashi);
const padding_px: f32 = 48;

// sokol_app drives a C callback loop (no closures), so state lives at file scope.
const State = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    base_dir: std.Io.Dir,
    deck_dir: []const u8,
    slides: []const document.Slide,
    show: Presentation,
    renderer: text.Renderer,
    player: audio.Player,
    sampler: sk.sg_sampler = .{},
    pipeline: sk.sgl_pipeline = .{},
    // Resources for the slide currently on screen; rebuilt on slide/size change.
    arena: std.heap.ArenaAllocator,
    prepared: ?usize = null,
    prepared_w: i32 = 0,
    prepared_h: i32 = 0,
    text_tex: ?Texture = null,
    text_vertices: []const text.Vertex = &.{},
    images: []ImageDraw = &.{},
    // Speaker notes are mirrored to the controlling terminal, if there is one.
    notes_tty: bool = false,
    notes_writer: std.Io.File.Writer = undefined,
    // Current slide index published for a `--speaker` companion (SPEC 2.1).
    publisher: ?sync.Publisher = null,
    // --watch: reload the deck in place when the file changes (SPEC 2.2).
    deck_path: []const u8 = "",
    watcher: ?watch.Watcher = null,
    reloaded: ?document.Document = null,
    watch_tick: u32 = 0,
};

// Backing buffer for the notes writer; lives as long as the file-scope state.
var notes_buffer: [4096]u8 = undefined;

const Texture = struct {
    image: sk.sg_image,
    view: sk.sg_view,

    fn destroy(self: Texture) void {
        sk.sg_destroy_view(self.view);
        sk.sg_destroy_image(self.image);
    }
};

const ImageDraw = struct { tex: Texture, x0: f32, y0: f32, x1: f32, y1: f32 };

var state: State = undefined;

pub fn present(
    gpa: std.mem.Allocator,
    io: std.Io,
    base_dir: std.Io.Dir,
    deck_dir: []const u8,
    deck_path: []const u8,
    slides: []const document.Slide,
    watch_enabled: bool,
) void {
    const renderer = text.init(gpa, io) catch |err| {
        log.err("font init failed: {t}", .{err});
        return;
    };
    state = .{
        .gpa = gpa,
        .io = io,
        .base_dir = base_dir,
        .deck_dir = deck_dir,
        .slides = slides,
        .show = Presentation.init(slides.len),
        .renderer = renderer,
        .player = audio.Player.init() catch .{},
        .arena = std.heap.ArenaAllocator.init(gpa),
    };
    // Mirror speaker notes to the launching terminal, if stdout is one.
    state.notes_tty = std.Io.File.stdout().isTty(io) catch false;
    if (state.notes_tty) {
        state.notes_writer = std.Io.File.stdout().writer(io, &notes_buffer);
    }
    // Publish the current slide for a `--speaker` companion (best effort).
    state.publisher = sync.Publisher.init(gpa, io, deck_path) catch null;
    state.deck_path = deck_path;
    if (watch_enabled) state.watcher = watch.Watcher.init(io, deck_path);
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

fn init() callconv(.c) void {
    sk.sg_setup(&.{
        .environment = sk.sglue_environment(),
        .logger = .{ .func = &sk.slog_func },
    });
    sk.sgl_setup(&.{ .logger = .{ .func = &sk.slog_func } });

    var sampler_desc: sk.sg_sampler_desc = .{};
    sampler_desc.min_filter = @intCast(sk.SG_FILTER_LINEAR);
    sampler_desc.mag_filter = @intCast(sk.SG_FILTER_LINEAR);
    state.sampler = sk.sg_make_sampler(&sampler_desc);

    var pip_desc: sk.sg_pipeline_desc = .{};
    pip_desc.colors[0].blend.enabled = true;
    pip_desc.colors[0].blend.src_factor_rgb = @intCast(sk.SG_BLENDFACTOR_SRC_ALPHA);
    pip_desc.colors[0].blend.dst_factor_rgb = @intCast(sk.SG_BLENDFACTOR_ONE_MINUS_SRC_ALPHA);
    pip_desc.colors[0].blend.src_factor_alpha = @intCast(sk.SG_BLENDFACTOR_SRC_ALPHA);
    pip_desc.colors[0].blend.dst_factor_alpha = @intCast(sk.SG_BLENDFACTOR_ONE_MINUS_SRC_ALPHA);
    state.pipeline = sk.sgl_make_pipeline(&pip_desc);
}

fn frame() callconv(.c) void {
    const w = sk.sapp_width();
    const h = sk.sapp_height();
    maybeReload();
    if (state.prepared != state.show.current or state.prepared_w != w or state.prepared_h != h) {
        prepareSlide(w, h);
    }

    sk.sgl_defaults();
    sk.sgl_load_pipeline(state.pipeline);
    sk.sgl_matrix_mode_projection();
    sk.sgl_load_identity();
    sk.sgl_ortho(0, @floatFromInt(w), @floatFromInt(h), 0, -1, 1);
    sk.sgl_enable_texture();

    // Background layer: images (SPEC 1.3), text on top (SPEC 3).
    for (state.images) |img| {
        drawRect(img.tex.view, img.x0, img.y0, img.x1, img.y1);
    }
    if (state.text_tex) |tex| drawGlyphs(tex.view, state.text_vertices);

    var pass: sk.sg_pass = .{ .swapchain = sk.sglue_swapchain() };
    pass.action.colors[0].load_action = @intCast(sk.SG_LOADACTION_CLEAR);
    pass.action.colors[0].clear_value = .{ .r = 0, .g = 0, .b = 0, .a = 1 };
    sk.sg_begin_pass(&pass);
    sk.sgl_draw();
    sk.sg_end_pass();
    sk.sg_commit();
}

fn event(ev: [*c]const sk.sapp_event) callconv(.c) void {
    if (ev.*.type != sk.SAPP_EVENTTYPE_KEY_DOWN) return;
    switch (ev.*.key_code) {
        sk.SAPP_KEYCODE_RIGHT, sk.SAPP_KEYCODE_SPACE => state.show.next(),
        sk.SAPP_KEYCODE_LEFT => state.show.prev(),
        sk.SAPP_KEYCODE_HOME => state.show.first(),
        sk.SAPP_KEYCODE_END => state.show.last(),
        sk.SAPP_KEYCODE_ESCAPE => sk.sapp_request_quit(),
        else => {},
    }
}

fn cleanup() callconv(.c) void {
    releaseSlide();
    if (state.reloaded) |*d| d.deinit();
    if (state.publisher) |*p| p.deinit();
    state.player.deinit();
    text.deinit(&state.renderer, state.gpa);
    state.arena.deinit();
    sk.sgl_shutdown();
    sk.sg_shutdown();
}

/// Free the GPU resources held for the previous slide.
fn releaseSlide() void {
    if (state.text_tex) |tex| tex.destroy();
    state.text_tex = null;
    for (state.images) |img| img.tex.destroy();
    state.images = &.{};
}

/// Under --watch, poll the deck (throttled) and reload it in place when it
/// changes, keeping the current position (SPEC 2.2). A load failure or an empty
/// deck mid-edit is ignored, so a bad save never tears down the presentation.
fn maybeReload() void {
    if (state.watcher == null) return;
    state.watch_tick +%= 1;
    if (state.watch_tick % 12 != 0) return; // ~5 checks/sec at 60 fps
    if (!state.watcher.?.changed()) return;

    var next = document.load(state.gpa, state.io, state.base_dir, state.deck_path) catch return;
    if (next.slides.len == 0) {
        next.deinit();
        return;
    }
    if (state.reloaded) |*old| old.deinit();
    state.reloaded = next;
    state.slides = next.slides;
    state.show.count = next.slides.len;
    if (state.show.current >= state.show.count) state.show.current = state.show.count - 1;
    state.prepared = null; // force prepareSlide to rebuild this slide's resources
    assert(state.show.current < state.slides.len);
}

fn prepareSlide(w: i32, h: i32) void {
    const slide_changed = if (state.prepared) |p| p != state.show.current else true;
    releaseSlide();
    _ = state.arena.reset(.retain_capacity);
    const arena = state.arena.allocator();
    const slide = state.slides[state.show.current];

    layoutText(arena, slide, w, h);
    layoutImages(slide, w, h);
    startMedia(arena, slide);

    state.prepared = state.show.current;
    state.prepared_w = w;
    state.prepared_h = h;
    // On slide changes only (not window resizes): refresh the terminal notes
    // and publish the index for any `--speaker` companion.
    if (slide_changed) {
        emitNotes();
        if (state.publisher) |*p| p.publish(state.show.current);
    }
}

/// Print the current slide's speaker notes to the controlling terminal, synced
/// to navigation (SPEC 2.1). No-op when there is no controlling terminal.
fn emitNotes() void {
    if (!state.notes_tty) return;
    const total = state.slides.len;
    const current = state.show.current;
    const preview = if (current + 1 < total) document.previewOf(state.slides[current + 1]) else "";
    const size = terminal.terminalSize(std.Io.File.stdout().handle);
    terminal.renderNotesFrame(
        &state.notes_writer.interface,
        state.slides[current].notes,
        current,
        total,
        preview,
        size.cols,
    ) catch {};
}

fn layoutText(arena: std.mem.Allocator, slide: document.Slide, w: i32, h: i32) void {
    const layout = text.layoutFit(
        &state.renderer,
        arena,
        slide.spans,
        @floatFromInt(w),
        @floatFromInt(h),
        padding_px,
    ) catch |err| {
        log.warn("text layout failed: {t}", .{err});
        return;
    };
    if (layout.vertices.len == 0) return;
    const rgba = expandCoverage(arena, layout.atlas) catch return;
    state.text_tex = uploadTexture(rgba, layout.atlas_w, layout.atlas_h);
    state.text_vertices = layout.vertices;
}

/// Decode each image and place it in an equal-weighted grid (SPEC 1.3).
fn layoutImages(slide: document.Slide, w: i32, h: i32) void {
    var count: usize = 0;
    for (slide.media) |m| {
        if (m.kind == .image) count += 1;
    }
    if (count == 0) return;

    var draws = state.gpa.alloc(ImageDraw, count) catch return;
    var n: usize = 0;
    const cols = columnsFor(count);
    const rows = (count + cols - 1) / cols;
    const cell_w = @as(f32, @floatFromInt(w)) / @as(f32, @floatFromInt(cols));
    const cell_h = @as(f32, @floatFromInt(h)) / @as(f32, @floatFromInt(rows));

    for (slide.media) |m| {
        if (m.kind != .image) continue;
        const img = image.decodeFile(state.gpa, state.io, state.base_dir, m.path) catch |err| {
            log.warn("image {s} failed: {t}", .{ m.path, err });
            continue;
        };
        defer image.free(state.gpa, img);
        const tex = uploadTexture(img.pixels, img.w, img.h);
        const col = n % cols;
        const row = n / cols;
        const rect = fitRect(
            @floatFromInt(col),
            @floatFromInt(row),
            cell_w,
            cell_h,
            @floatFromInt(img.w),
            @floatFromInt(img.h),
        );
        draws[n] = .{ .tex = tex, .x0 = rect[0], .y0 = rect[1], .x1 = rect[2], .y1 = rect[3] };
        n += 1;
    }
    state.images = draws[0..n];
}

fn startMedia(arena: std.mem.Allocator, slide: document.Slide) void {
    for (slide.media) |m| {
        const full = std.fs.path.joinZ(arena, &.{ state.deck_dir, m.path }) catch continue;
        switch (m.kind) {
            .audio => state.player.play(full),
            .image => {},
        }
    }
}

fn drawRect(view: sk.sg_view, x0: f32, y0: f32, x1: f32, y1: f32) void {
    sk.sgl_texture(view, state.sampler);
    sk.sgl_c4b(255, 255, 255, 255);
    sk.sgl_begin_triangles();
    sk.sgl_v2f_t2f(x0, y0, 0, 0);
    sk.sgl_v2f_t2f(x1, y0, 1, 0);
    sk.sgl_v2f_t2f(x1, y1, 1, 1);
    sk.sgl_v2f_t2f(x0, y0, 0, 0);
    sk.sgl_v2f_t2f(x1, y1, 1, 1);
    sk.sgl_v2f_t2f(x0, y1, 0, 1);
    sk.sgl_end();
}

fn drawGlyphs(view: sk.sg_view, vertices: []const text.Vertex) void {
    sk.sgl_texture(view, state.sampler);
    sk.sgl_c4b(245, 245, 245, 255);
    sk.sgl_begin_triangles();
    for (vertices) |v| sk.sgl_v2f_t2f(v.x, v.y, v.u, v.v);
    sk.sgl_end();
}

fn uploadTexture(pixels: []const u8, w: u32, h: u32) Texture {
    var img_desc: sk.sg_image_desc = .{ .width = @intCast(w), .height = @intCast(h) };
    img_desc.pixel_format = @intCast(sk.SG_PIXELFORMAT_RGBA8);
    img_desc.data.mip_levels[0] = .{ .ptr = pixels.ptr, .size = pixels.len };
    const img = sk.sg_make_image(&img_desc);
    var view_desc: sk.sg_view_desc = .{};
    view_desc.texture.image = img;
    return .{ .image = img, .view = sk.sg_make_view(&view_desc) };
}

/// Expand an 8-bit coverage atlas to white RGBA with coverage as alpha.
fn expandCoverage(arena: std.mem.Allocator, coverage: []const u8) ![]u8 {
    const rgba = try arena.alloc(u8, coverage.len * 4);
    for (coverage, 0..) |c, i| {
        rgba[i * 4 + 0] = 255;
        rgba[i * 4 + 1] = 255;
        rgba[i * 4 + 2] = 255;
        rgba[i * 4 + 3] = c;
    }
    return rgba;
}

fn columnsFor(count: usize) usize {
    var cols: usize = 1;
    while (cols * cols < count) cols += 1;
    return cols;
}

/// Fit a w_px x h_px image into a grid cell, preserving aspect ratio, centered.
fn fitRect(col: f32, row: f32, cell_w: f32, cell_h: f32, w_px: f32, h_px: f32) [4]f32 {
    const scale = @min(cell_w / w_px, cell_h / h_px);
    const dw = w_px * scale;
    const dh = h_px * scale;
    const x0 = col * cell_w + (cell_w - dw) / 2;
    const y0 = row * cell_h + (cell_h - dh) / 2;
    return .{ x0, y0, x0 + dw, y0 + dh };
}
