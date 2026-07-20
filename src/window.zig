//! Window output form (SPEC 3.1): a full-screen graphical presentation driven
//! by raylib's immediate-mode render loop.
//!
//! This is a scaffold. It opens a window and draws a placeholder so the raylib
//! wiring can be exercised. Real slide parsing, text scaling to fill the frame,
//! and image layout come later.

const std = @import("std");
const rl = @import("raylib.zig").c;

const log = std.log.scoped(.takahashi);

const black = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
const white = rl.Color{ .r = 245, .g = 245, .b = 245, .a = 255 };

/// Present a deck in a full-screen window.
pub fn present(path: []const u8) void {
    log.info("presenting {s}", .{path});

    rl.InitWindow(1280, 720, "takahashi");
    defer rl.CloseWindow();
    rl.SetTargetFPS(60);
    // TODO: rl.ToggleFullscreen() once the target monitor is selected.

    while (!rl.WindowShouldClose()) {
        // Navigation the interactive forms must support (SPEC 2.1).
        if (rl.IsKeyPressed(rl.KEY_RIGHT) or rl.IsKeyPressed(rl.KEY_SPACE)) {
            // TODO: advance to the next slide.
        }
        if (rl.IsKeyPressed(rl.KEY_LEFT)) {
            // TODO: return to the previous slide.
        }
        // TODO: HOME / END jump to first / last; a position indicator; a
        // presenter view surfacing the current slide's speaker notes.

        rl.BeginDrawing();
        defer rl.EndDrawing();
        rl.ClearBackground(black);
        rl.DrawText("takahashi", 40, 40, 96, white);
        rl.DrawText("scaffold - press ESC to quit", 40, 160, 32, white);
    }
}
