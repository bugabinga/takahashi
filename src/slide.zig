//! The in-memory model that parsing a .taka file produces (SPEC 1).
//!
//! `body` and `notes` borrow the source buffer they were parsed from, so the
//! source must outlive the deck. Only the slide array itself is owned.

const std = @import("std");

pub const Slide = struct {
    /// The visible slide text, markup preserved as authored (SPEC 1.2).
    /// Parsing markup spans and resolving @functions (SPEC 1.3) come later.
    body: []const u8,
    /// Speaker notes: the raw `#` comment lines that precede the slide
    /// (SPEC 1.1). Empty when the slide has no comments. Stripping the leading
    /// `#` is a later step.
    notes: []const u8,
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
