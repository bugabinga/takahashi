//! A tiny channel carrying the presenter's current slide index to a `--speaker`
//! companion (SPEC 2.1, 3.2), so the notes view in a second terminal stays in
//! step with the running presentation.
//!
//! It is a small state file keyed by the deck's absolute path: the presenter
//! overwrites it with the current index on each slide change; the companion
//! polls it. This was chosen over a socket deliberately. In the 0.16 `std.Io`
//! model sockets are vtable objects whose `accept`/read block, so serving one
//! without stalling the sokol frame loop or the raw terminal loop would need
//! poll-on-handle plumbing threaded through both. The presentation advances at
//! human speed — a slide every few seconds — so a ~120 ms poll is invisible,
//! and a file is the simplest thing that is also the most portable (just the
//! filesystem) and robust to start order (either side may launch first).

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

/// Derive the state-file path from the deck path: resolved to absolute so the
/// presenter and companion agree regardless of how each spelled the path.
pub fn statePath(gpa: Allocator, io: std.Io, deck_path: []const u8) ![]u8 {
    assert(deck_path.len > 0);
    const cwd = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd);
    const absolute = try std.fs.path.resolve(gpa, &.{ cwd, deck_path });
    defer gpa.free(absolute);
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(absolute);
    return std.fmt.allocPrint(gpa, "/tmp/taka-{x:0>16}.state", .{hasher.final()});
}

/// The presenter side: overwrites the state file with the current slide index.
pub const Publisher = struct {
    gpa: Allocator,
    io: std.Io,
    path: []u8,
    last: ?usize = null,

    pub fn init(gpa: Allocator, io: std.Io, deck_path: []const u8) !Publisher {
        return .{ .gpa = gpa, .io = io, .path = try statePath(gpa, io, deck_path) };
    }

    /// Write `index` to the state file, skipping the write when unchanged.
    pub fn publish(self: *Publisher, index: usize) void {
        if (self.last) |last| if (last == index) return;
        var buffer: [24]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "{d}\n", .{index}) catch return;
        std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = self.path, .data = text }) catch return;
        self.last = index;
    }

    pub fn deinit(self: *Publisher) void {
        std.Io.Dir.cwd().deleteFile(self.io, self.path) catch {};
        self.gpa.free(self.path);
        self.* = undefined;
    }
};

/// The companion side: reads the current slide index, polling between reads.
pub const Follower = struct {
    gpa: Allocator,
    io: std.Io,
    path: []u8,

    pub fn init(gpa: Allocator, io: std.Io, deck_path: []const u8) !Follower {
        return .{ .gpa = gpa, .io = io, .path = try statePath(gpa, io, deck_path) };
    }

    pub fn deinit(self: *Follower) void {
        self.gpa.free(self.path);
        self.* = undefined;
    }

    /// The current slide index, or null when the file is missing (no presenter)
    /// or momentarily unreadable — the caller keeps its last value on null.
    pub fn current(self: *Follower) ?usize {
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, self.path, self.gpa, .unlimited) catch return null;
        defer self.gpa.free(bytes);
        const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
        return std.fmt.parseInt(usize, trimmed, 10) catch null;
    }

    /// Sleep one poll interval. Human-paced navigation makes this imperceptible.
    pub fn wait(self: *Follower) void {
        std.Io.sleep(self.io, std.Io.Duration.fromMilliseconds(120), .awake) catch {};
    }
};

test "publisher and follower round-trip an index through the state file" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // uses /tmp
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // A unique deck path keeps this test's state file isolated.
    const deck = "testdata/__sync_roundtrip_probe__.taka";
    var pub_side = try Publisher.init(gpa, io, deck);
    defer pub_side.deinit();
    var fol = try Follower.init(gpa, io, deck);
    defer fol.deinit();

    try std.testing.expect(fol.current() == null); // nothing published yet
    pub_side.publish(7);
    try std.testing.expectEqual(@as(?usize, 7), fol.current());
    pub_side.publish(7); // unchanged: skipped, value stays
    try std.testing.expectEqual(@as(?usize, 7), fol.current());
    pub_side.publish(0);
    try std.testing.expectEqual(@as(?usize, 0), fol.current());
}

test "the follower and publisher agree on the path regardless of spelling" {
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const a = try statePath(gpa, io, "examples/demo/demo.taka");
    defer gpa.free(a);
    const b = try statePath(gpa, io, "examples/../examples/demo/demo.taka");
    defer gpa.free(b);
    try std.testing.expectEqualStrings(a, b);
}

test {
    std.testing.refAllDecls(@This());
}
