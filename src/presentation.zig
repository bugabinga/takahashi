//! Slide navigation for the interactive forms (SPEC 2.1).
//!
//! Pure state with no backend, so the pacing logic is unit-testable without a
//! window or terminal. The window/terminal forms translate their input events
//! into these calls and read `current` back out.

const std = @import("std");
const assert = std.debug.assert;

pub const Presentation = struct {
    /// Total number of slides. May be zero (an empty deck).
    count: usize,
    /// Index of the slide on screen. Always `< count`, unless `count == 0`.
    current: usize = 0,

    pub fn init(count: usize) Presentation {
        return .{ .count = count, .current = 0 };
    }

    pub fn next(p: *Presentation) void {
        if (p.current + 1 < p.count) p.current += 1;
        assert(p.count == 0 or p.current < p.count);
    }

    pub fn prev(p: *Presentation) void {
        if (p.current > 0) p.current -= 1;
        assert(p.count == 0 or p.current < p.count);
    }

    pub fn first(p: *Presentation) void {
        p.current = 0;
    }

    pub fn last(p: *Presentation) void {
        if (p.count > 0) p.current = p.count - 1;
        assert(p.count == 0 or p.current < p.count);
    }
};

test "navigation is clamped to the deck bounds" {
    var p = Presentation.init(3);
    try std.testing.expectEqual(@as(usize, 0), p.current);

    p.prev(); // already at the first slide
    try std.testing.expectEqual(@as(usize, 0), p.current);

    p.next();
    p.next();
    try std.testing.expectEqual(@as(usize, 2), p.current);

    p.next(); // already at the last slide
    try std.testing.expectEqual(@as(usize, 2), p.current);

    p.first();
    try std.testing.expectEqual(@as(usize, 0), p.current);

    p.last();
    try std.testing.expectEqual(@as(usize, 2), p.current);
}

test "an empty deck stays put" {
    var p = Presentation.init(0);
    p.next();
    p.last();
    try std.testing.expectEqual(@as(usize, 0), p.current);
}

test {
    std.testing.refAllDecls(@This());
}
