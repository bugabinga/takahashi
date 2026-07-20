//! Decode a video file (@video, SPEC 1.3) into RGBA8 frames via FFmpeg.
//!
//! This module returns plain pixel data — it never touches the GPU. The caller
//! (the window form) uploads each `Frame` as a texture. The first video stream
//! is opened; packets are decoded and each frame is converted to
//! `AV_PIX_FMT_RGBA` with `sws_scale`.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const c = @import("video_c");

/// One decoded frame, RGBA8, tightly packed (`w * h * 4` bytes). The pixels are
/// owned by the allocator passed to `next` and must be freed by the caller.
pub const Frame = struct {
    pixels: []u8,
    w: u32,
    h: u32,
};

pub const Error = error{
    OpenFailed,
    NoStreamInfo,
    NoVideoStream,
    NoDecoder,
    CodecOpenFailed,
    ScaleFailed,
    DecodeFailed,
    OutOfMemory,
};

pub const Decoder = struct {
    format_ctx: [*c]c.AVFormatContext,
    codec_ctx: *c.AVCodecContext,
    frame: *c.AVFrame,
    packet: *c.AVPacket,
    sws: ?*c.SwsContext,
    video_index: c_int,
    draining: bool,
};

/// Open `path` and prepare its first video stream for decoding.
pub fn open(gpa: Allocator, path: [:0]const u8) Error!Decoder {
    assert(path.len > 0);
    assert(path[path.len] == 0);
    _ = gpa;

    var format_ctx: [*c]c.AVFormatContext = null;
    if (c.avformat_open_input(&format_ctx, path.ptr, null, null) != 0) {
        return error.OpenFailed;
    }
    errdefer c.avformat_close_input(&format_ctx);
    assert(format_ctx != null);
    if (c.avformat_find_stream_info(format_ctx, null) < 0) return error.NoStreamInfo;

    const video_index = findVideoStream(format_ctx);
    if (video_index < 0) return error.NoVideoStream;
    const stream = format_ctx.*.streams[@intCast(video_index)];
    const codecpar = stream.*.codecpar;

    const codec = c.avcodec_find_decoder(codecpar.*.codec_id);
    if (codec == null) return error.NoDecoder;

    const codec_ctx = c.avcodec_alloc_context3(codec) orelse return error.OutOfMemory;
    errdefer freeCodecContext(codec_ctx);
    if (c.avcodec_parameters_to_context(codec_ctx, codecpar) < 0) return error.CodecOpenFailed;
    if (c.avcodec_open2(codec_ctx, codec, null) < 0) return error.CodecOpenFailed;

    const frame = c.av_frame_alloc() orelse return error.OutOfMemory;
    errdefer freeFrame(frame);
    const packet = c.av_packet_alloc() orelse return error.OutOfMemory;
    errdefer freePacket(packet);

    assert(video_index >= 0);
    return .{
        .format_ctx = format_ctx,
        .codec_ctx = codec_ctx,
        .frame = frame,
        .packet = packet,
        .sws = null,
        .video_index = video_index,
        .draining = false,
    };
}

fn findVideoStream(format_ctx: [*c]c.AVFormatContext) c_int {
    assert(format_ctx != null);
    const count = format_ctx.*.nb_streams;
    var i: c_uint = 0;
    while (i < count) : (i += 1) {
        const par = format_ctx.*.streams[i].*.codecpar;
        if (par.*.codec_type == c.AVMEDIA_TYPE_VIDEO) return @intCast(i);
    }
    return -1;
}

/// Decode and return the next frame as RGBA, or `null` at end of stream. Pixels
/// are allocated with `gpa` and owned by the caller.
pub fn next(self: *Decoder, gpa: Allocator) Error!?Frame {
    assert(self.video_index >= 0);
    assert(self.codec_ctx.width >= 0);

    if (!try pullFrame(self)) return null;

    const width: u32 = @intCast(self.frame.width);
    const height: u32 = @intCast(self.frame.height);
    assert(width > 0);
    assert(height > 0);
    return try convert(self, gpa, width, height);
}

/// Drive the decoder until a frame is ready. Returns false at EOF.
fn pullFrame(self: *Decoder) Error!bool {
    const max_iterations: usize = 1 << 24;
    var iterations: usize = 0;
    while (iterations < max_iterations) : (iterations += 1) {
        const status = c.avcodec_receive_frame(self.codec_ctx, self.frame);
        if (status == 0) return true;
        if (status == c.taka_averror_eof()) return false;
        if (status != c.taka_averror_eagain()) return error.DecodeFailed;
        if (self.draining) return false;
        try feed(self);
    }
    assert(iterations == max_iterations);
    return error.DecodeFailed;
}

/// Read packets until one for our video stream is sent to the decoder, or EOF
/// is reached (then a null flush packet is sent).
fn feed(self: *Decoder) Error!void {
    assert(!self.draining);
    const max_packets: usize = 1 << 24;
    var read: usize = 0;
    while (read < max_packets) : (read += 1) {
        if (c.av_read_frame(self.format_ctx, self.packet) < 0) {
            _ = c.avcodec_send_packet(self.codec_ctx, null);
            self.draining = true;
            return;
        }
        defer c.av_packet_unref(self.packet);
        if (self.packet.stream_index != self.video_index) continue;
        if (c.avcodec_send_packet(self.codec_ctx, self.packet) < 0) return error.DecodeFailed;
        return;
    }
    assert(read == max_packets);
    return error.DecodeFailed;
}

/// Scale `self.frame` into a freshly allocated tightly packed RGBA buffer.
fn convert(self: *Decoder, gpa: Allocator, width: u32, height: u32) Error!Frame {
    assert(width > 0);
    assert(height > 0);

    self.sws = c.sws_getCachedContext(
        self.sws,
        self.frame.width,
        self.frame.height,
        self.frame.format,
        @intCast(width),
        @intCast(height),
        c.AV_PIX_FMT_RGBA,
        c.SWS_BILINEAR,
        null,
        null,
        null,
    );
    if (self.sws == null) return error.ScaleFailed;

    const pixels = try gpa.alloc(u8, width * height * 4);
    errdefer gpa.free(pixels);

    var dst_data: [4][*c]u8 = .{ null, null, null, null };
    var dst_linesize: [4]c_int = .{ 0, 0, 0, 0 };
    dst_data[0] = pixels.ptr;
    dst_linesize[0] = @intCast(width * 4);

    const rows = c.sws_scale(
        self.sws,
        &self.frame.data,
        &self.frame.linesize,
        0,
        self.frame.height,
        &dst_data,
        &dst_linesize,
    );
    if (rows != self.frame.height) return error.ScaleFailed;
    assert(pixels.len == width * height * 4);
    return .{ .pixels = pixels, .w = width, .h = height };
}

pub fn deinit(self: *Decoder, gpa: Allocator) void {
    _ = gpa;
    assert(self.video_index >= 0);
    assert(self.format_ctx != null);
    if (self.sws) |sws| c.sws_freeContext(sws);
    freePacket(self.packet);
    freeFrame(self.frame);
    freeCodecContext(self.codec_ctx);
    c.avformat_close_input(&self.format_ctx);
}

fn freeCodecContext(codec_ctx: *c.AVCodecContext) void {
    var ptr: [*c]c.AVCodecContext = codec_ctx;
    c.avcodec_free_context(&ptr);
}

fn freeFrame(frame: *c.AVFrame) void {
    var ptr: [*c]c.AVFrame = frame;
    c.av_frame_free(&ptr);
}

fn freePacket(packet: *c.AVPacket) void {
    var ptr: [*c]c.AVPacket = packet;
    c.av_packet_free(&ptr);
}

test "decode first frame of clip.mp4 as 64x48 RGBA" {
    const path = "testdata/clip.mp4";
    const gpa = std.testing.allocator;

    var decoder = try open(gpa, path);
    defer deinit(&decoder, gpa);

    const frame = (try next(&decoder, gpa)) orelse return error.NoFrame;
    defer gpa.free(frame.pixels);

    try std.testing.expectEqual(@as(u32, 64), frame.w);
    try std.testing.expectEqual(@as(u32, 48), frame.h);
    try std.testing.expectEqual(@as(usize, 64 * 48 * 4), frame.pixels.len);
}

test {
    std.testing.refAllDecls(@This());
}
