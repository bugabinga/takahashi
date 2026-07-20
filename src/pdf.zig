//! PDF output form (SPEC 3.3): a paginated PDF, one slide per page.
//!
//! Planned: emit PDF bytes directly, with no external PDF library (a native
//! writer, per CLAUDE.md). Speaker notes become page notes where possible.
//! Not implemented yet.

const std = @import("std");

const Deck = @import("slide.zig").Deck;

pub const Error = error{NotImplemented};

pub fn render(gpa: std.mem.Allocator, io: std.Io, deck: Deck, out_path: ?[]const u8) Error!void {
    _ = gpa;
    _ = io;
    _ = deck;
    _ = out_path;
    return error.NotImplemented;
}

test {
    std.testing.refAllDecls(@This());
}
