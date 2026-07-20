const std = @import("std");
const window = @import("window.zig");
const log = std.log.scoped(.takahashi);

/// As of Zig 0.16 the runtime hands `main` a `std.process.Init`, which carries
/// the command line arguments, an I/O implementation and a default general
/// purpose allocator (with leak checking in Debug builds).
pub fn main(init: std.process.Init) !void {
    log.info("START", .{});
    defer log.info("END", .{});

    // The argument iterator may allocate on some targets (Windows, WASI), so
    // it owns backing memory that must be released with `deinit`.
    var arguments = try init.minimal.args.iterateAllocator(init.gpa);
    defer arguments.deinit();

    _ = arguments.next(); // program name

    const path = arguments.next() orelse {
        log.err("usage: takahashi <file.taka>", .{});
        return error.MissingArgument;
    };

    // TODO: parse the .taka file into slides (SPEC 1). For now the raylib
    // window form shows a placeholder so the render path can be exercised
    // end to end.
    window.present(path);
}
