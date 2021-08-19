const std = @import("std");
const log = std.log.scoped(.takahashi);

pub fn main() anyerror!void {
    log.info("START",.{});
    defer log.info("END",.{});
    var arguments = std.process.args();
    //nani de fuck does this syntax mean ?!?!
    var allocator = std.heap.GeneralPurposeAllocator(.{}){};
    while ( arguments.next(&allocator.allocator)) | argument | {
        var arg = try argument;
        defer allocator.allocator.free(arg);
        log.info("type of arg 1 -> {any}", .{ @typeInfo(@TypeOf(arg)) });
        log.info("Arg 1: {s}", .{ arg });
    }
}
