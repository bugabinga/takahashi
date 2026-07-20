//! Thin access to the raylib C API.
//!
//! raylib is an *immediate-mode* library: there is no retained scene graph.
//! Each frame is drawn from scratch inside the render loop (see window.zig).
//! Note that raylib's colour macros (e.g. `BLACK`) are compound-literal
//! `#define`s that C-to-Zig translation drops, so construct `c.Color` values
//! directly instead of reaching for them.

pub const c = @cImport({
    @cInclude("raylib.h");
});
