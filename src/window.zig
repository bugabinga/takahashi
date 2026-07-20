//! Window output form (SPEC 3.1): a full-screen graphical presentation driven
//! by raylib's immediate-mode render loop.
//!
//! This is a scaffold. It opens a window and draws a placeholder so the raylib
//! wiring can be exercised. Real slide parsing, text scaling to fill the frame,
//! and image layout come later.

const std = @import("std");

// The "raylib" module is produced by the build's translate-c step (build.zig).
const rl = @import("raylib");

const Deck = @import("slide.zig").Deck;

const log = std.log.scoped(.takahashi);

// raylib's colour macros (e.g. BLACK) are compound-literal `#define`s that
// translate-c drops, so construct `rl.Color` values directly.
const black = rl.Color{ .r = 0, .g = 0, .b = 0, .a = 255 };
const white = rl.Color{ .r = 245, .g = 245, .b = 245, .a = 255 };

/// Present a deck in a full-screen window.
pub fn present(deck: Deck) void {
    log.info("presenting {d} slide(s)", .{deck.slides.len});

    rl.InitWindow(1280, 720, "takahashi");
    defer rl.CloseWindow();
    rl.SetTargetFPS(60);
    // TODO: rl.ToggleFullscreen() once the target monitor is selected.

    var current: usize = 0;
    while (!rl.WindowShouldClose()) {
        // Navigation the interactive forms must support (SPEC 2.1).
        if (rl.IsKeyPressed(rl.KEY_RIGHT) or rl.IsKeyPressed(rl.KEY_SPACE)) {
            if (current + 1 < deck.slides.len) current += 1;
        }
        if (rl.IsKeyPressed(rl.KEY_LEFT)) {
            if (current > 0) current -= 1;
        }
        // TODO: HOME / END jump to first / last; a position indicator; a
        // presenter view surfacing the current slide's speaker notes.

        rl.BeginDrawing();
        defer rl.EndDrawing();
        rl.ClearBackground(black);
        // TODO: draw deck.slides[current].body scaled to fill the frame.
        rl.DrawText("takahashi", 40, 40, 96, white);
        rl.DrawText("scaffold - press ESC to quit", 40, 160, 32, white);
    }
}
