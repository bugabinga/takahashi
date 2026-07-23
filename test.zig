//! Test aggregator: the root module for `zig build test` and `zig build fuzz`.
//!
//! It is rooted at the project directory (not src/) so integration tests can
//! `@embedFile` the decks under examples/. It pulls in every window-free module
//! so their tests run without the sokol backend, a display, or the network. The
//! sokol window path is verified by building the executable (`zig build`), not
//! here.

test {
    _ = @import("src/slide.zig");
    _ = @import("src/parser.zig");
    _ = @import("src/cli.zig");
    _ = @import("src/presentation.zig");
    _ = @import("src/markup.zig");
    _ = @import("src/function.zig");
    _ = @import("src/run.zig");
    _ = @import("src/sync.zig");
    _ = @import("src/watch.zig");
    _ = @import("src/document.zig");
    _ = @import("src/html.zig");
    _ = @import("src/terminal.zig");
    _ = @import("src/pdf.zig");
    _ = @import("integration_test.zig");
    _ = @import("correctness_test.zig");
}
