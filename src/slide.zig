//! The in-memory model that parsing a .taka file produces (SPEC 1).
//!
//! `body` borrows the source buffer it was parsed from, so the source must
//! outlive the deck. Only the slide array itself is owned.

const std = @import("std");

pub const Slide = struct {
    /// The visible slide text, markup and `@note` preserved as authored
    /// (SPEC 1.2, 1.3). Comment lines (`#`) are already stripped. Parsing
    /// markup spans and resolving @functions happens in `document.zig`.
    body: []const u8,
};

pub const Deck = struct {
    slides: []const Slide,

    pub fn deinit(deck: *Deck, gpa: std.mem.Allocator) void {
        gpa.free(deck.slides);
        deck.* = undefined;
    }
};

test {
    std.testing.refAllDecls(@This());
}
