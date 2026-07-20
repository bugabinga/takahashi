//! Decode images (@image, SPEC 1.3) to RGBA8 via the vendored stb_image.
//!
//! `decode` takes encoded bytes (PNG/JPEG/GIF) and returns a tightly packed
//! `w*h*4` RGBA8 buffer owned by the passed allocator. This module never
//! touches the GPU; the caller uploads the pixels. The stb buffer is copied
//! into a Zig allocation and freed immediately, so no C-owned memory escapes.

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const c = @import("image_c");

/// A decoded image. `pixels` is RGBA8, row-major, top-left origin, length
/// exactly `w * h * 4`, allocated by the allocator passed to `decode`.
pub const Image = struct {
    pixels: []u8,
    w: u32,
    h: u32,
};

pub const Error = error{
    DecodeFailed,
    ImageTooLarge,
    OutOfMemory,
};

/// Bound on a single dimension. stb returns int; keep the product well within
/// usize so `w * h * 4` cannot overflow on any supported target.
const dimension_max: u32 = 1 << 16;

/// Decode `bytes` (PNG/JPEG/GIF) into a fresh RGBA8 `Image` owned by `gpa`.
pub fn decode(gpa: Allocator, bytes: []const u8) Error!Image {
    assert(bytes.len > 0);
    assert(bytes.len <= std.math.maxInt(c_int));

    var x: c_int = 0;
    var y: c_int = 0;
    var channels_in_file: c_int = 0;
    const decoded = c.stbi_load_from_memory(
        bytes.ptr,
        @intCast(bytes.len),
        &x,
        &y,
        &channels_in_file,
        4,
    );
    if (decoded == null) return Error.DecodeFailed;
    defer c.stbi_image_free(decoded);
    assert(x > 0);
    assert(y > 0);

    const w: u32 = @intCast(x);
    const h: u32 = @intCast(y);
    if (w > dimension_max or h > dimension_max) return Error.ImageTooLarge;

    const len: usize = @as(usize, w) * @as(usize, h) * 4;
    assert(len > 0);
    const pixels = try gpa.alloc(u8, len);
    errdefer comptime unreachable; // nothing after this can fail
    @memcpy(pixels, decoded[0..len]);

    assert(pixels.len == @as(usize, w) * @as(usize, h) * 4);
    return .{ .pixels = pixels, .w = w, .h = h };
}

/// Read `path` (relative to `dir`, or absolute) and decode it. The file bytes
/// are read into a temporary `gpa` allocation and freed before returning.
pub fn decodeFile(
    gpa: Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
) !Image {
    assert(path.len > 0);
    const bytes = try dir.readFileAlloc(io, path, gpa, .unlimited);
    defer gpa.free(bytes);
    assert(bytes.len > 0);
    return decode(gpa, bytes);
}

/// Release an `Image` previously returned by `decode` / `decodeFile`.
pub fn free(gpa: Allocator, image: Image) void {
    assert(image.pixels.len == @as(usize, image.w) * @as(usize, image.h) * 4);
    assert(image.pixels.len > 0);
    gpa.free(image.pixels);
}

test "decode rejects garbage bytes" {
    const gpa = std.testing.allocator;
    const garbage = "not an image at all";
    try std.testing.expectError(Error.DecodeFailed, decode(gpa, garbage));
}

test "decodeFile decodes examples/wat/horse.png to RGBA8" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();

    const path = "examples/wat/horse.png";
    const image = try decodeFile(gpa, threaded.io(), std.Io.Dir.cwd(), path);
    defer free(gpa, image);

    try std.testing.expect(image.w > 0);
    try std.testing.expect(image.h > 0);
    try std.testing.expectEqual(
        @as(usize, image.w) * @as(usize, image.h) * 4,
        image.pixels.len,
    );
}

test {
    std.testing.refAllDecls(@This());
}
