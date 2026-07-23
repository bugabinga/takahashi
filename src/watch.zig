//! File-change detection for watch mode (SPEC 2.2): a tiny mtime/size poller.
//!
//! Change detection is a single `stat`, so the caller decides when to poll —
//! the file forms sleep between checks, the interactive forms fold it into their
//! event loop. A transient `stat` failure (a mid-write file) reports no change,
//! so a save-in-progress never tears down the presentation.

const std = @import("std");
const builtin = @import("builtin");

pub const Signature = struct { mtime_ns: i96, size: u64 };

pub const Watcher = struct {
    io: std.Io,
    path: []const u8,
    last: ?Signature,

    pub fn init(io: std.Io, path: []const u8) Watcher {
        return .{ .io = io, .path = path, .last = current(io, path) };
    }

    /// True (once) when the file's mtime or size differs from the last observed
    /// value; updates the baseline so the next call reflects the new state.
    pub fn changed(self: *Watcher) bool {
        const now = current(self.io, self.path) orelse return false;
        if (self.last) |prev| {
            if (now.mtime_ns == prev.mtime_ns and now.size == prev.size) return false;
        }
        self.last = now;
        return true;
    }
};

fn current(io: std.Io, path: []const u8) ?Signature {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    return .{ .mtime_ns = stat.mtime.nanoseconds, .size = stat.size };
}

test "watcher reports a change after the file grows" {
    if (builtin.os.tag == .windows) return error.SkipZigTest; // uses /tmp
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const path = "/tmp/taka-watch-probe.taka";
    const dir = std.Io.Dir.cwd();
    try dir.writeFile(io, .{ .sub_path = path, .data = "one" });
    defer dir.deleteFile(io, path) catch {};

    var watcher = Watcher.init(io, path);
    try std.testing.expect(!watcher.changed()); // unchanged since init
    try dir.writeFile(io, .{ .sub_path = path, .data = "one two three" });
    try std.testing.expect(watcher.changed()); // size grew
    try std.testing.expect(!watcher.changed()); // stable again
}

test {
    std.testing.refAllDecls(@This());
}
