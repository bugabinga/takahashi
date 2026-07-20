//! Stand-in for the raylib C module, used when taka is built without the window
//! output form (a plain `zig build`, i.e. `-Dwindow=false`). It exposes just the
//! subset of the raylib API that window.zig calls, as no-ops, so the default
//! build compiles and links without the raylib dependency or a display.
//!
//! The build swaps this for the translate-c of raylib.h under the "raylib"
//! import name when `-Dwindow=true` (see build.zig). Opening the window form on
//! a stub build logs a hint instead of drawing.

const std = @import("std");

pub const Color = extern struct { r: u8, g: u8, b: u8, a: u8 };

pub const KEY_SPACE: c_int = 32;
pub const KEY_RIGHT: c_int = 262;
pub const KEY_LEFT: c_int = 263;
pub const KEY_HOME: c_int = 268;
pub const KEY_END: c_int = 269;

pub fn InitWindow(width: c_int, height: c_int, title: [*c]const u8) void {
    _ = width;
    _ = height;
    _ = title;
    std.log.scoped(.takahashi).err(
        "the window output form was not built; rebuild with `zig build -Dwindow=true`",
        .{},
    );
}

pub fn CloseWindow() void {}
pub fn SetTargetFPS(fps: c_int) void {
    _ = fps;
}
pub fn WindowShouldClose() bool {
    return true; // exit the render loop immediately on a stub build
}
pub fn IsKeyPressed(key: c_int) bool {
    _ = key;
    return false;
}
pub fn BeginDrawing() void {}
pub fn EndDrawing() void {}
pub fn ClearBackground(color: Color) void {
    _ = color;
}
pub fn DrawText(text: [*c]const u8, x: c_int, y: c_int, size: c_int, color: Color) void {
    _ = text;
    _ = x;
    _ = y;
    _ = size;
    _ = color;
}
