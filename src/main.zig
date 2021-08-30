const std = @import("std");
const log = std.log.scoped(.takahashi);

pub fn main() anyerror!void {
    log.info("START",.{});
    defer log.info("END",.{});

    //nani de fuck does this syntax mean ?!?!
    const general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    var arguments = std.process.args();
    var allocator = general_purpose_allocator.allocator;
    while ( arguments.next(&allocator)) | argument | {
        var arg = try argument;
        defer allocator.free(arg);
        log.info("type of arg 1 -> {any}", .{ @typeInfo(@TypeOf(arg)) });
        log.info("Arg 1: {s}", .{ arg });
    }
}
