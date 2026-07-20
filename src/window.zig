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
const Presentation = @import("presentation.zig").Presentation;

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

    // Slide navigation (SPEC 2.1) lives in the backend-free Presentation state
    // machine, which is unit-tested in presentation.zig.
    var show = Presentation.init(deck.slides.len);
    while (!rl.WindowShouldClose()) {
        if (rl.IsKeyPressed(rl.KEY_RIGHT) or rl.IsKeyPressed(rl.KEY_SPACE)) show.next();
        if (rl.IsKeyPressed(rl.KEY_LEFT)) show.prev();
        if (rl.IsKeyPressed(rl.KEY_HOME)) show.first();
        if (rl.IsKeyPressed(rl.KEY_END)) show.last();
        // TODO: a position indicator; a presenter view surfacing the current
        // slide's speaker notes.

        rl.BeginDrawing();
        defer rl.EndDrawing();
        rl.ClearBackground(black);
        // TODO: draw deck.slides[show.current].body scaled to fill the frame.
        rl.DrawText("takahashi", 40, 40, 96, white);
        rl.DrawText("scaffold - press ESC to quit", 40, 160, 32, white);
    }
}
