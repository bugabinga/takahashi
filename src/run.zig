//! The `@run` function (SPEC 1.3): execute a command line as a taka-built
//! pipeline, substituting its standard output.
//!
//! taka never invokes a shell — it resolves each program via `PATH` and builds
//! the pipeline itself with `std.process.Child`, so behaviour does not depend
//! on the user's shell. Not implemented yet.
//!
//! TODO: spawn `stages` as a pipeline, feed `source` to the first stage's
//! stdin unless a stage contains the `%` file-path token, and return the final
//! stage's output.

const std = @import("std");

/// One program in a pipeline: `argv[0]` is the program, the rest its arguments
/// (already tokenised, whitespace-split, quotes resolved — SPEC 1.3).
pub const Stage = struct {
    argv: []const []const u8,
};

pub const Error = error{NotImplemented} || std.mem.Allocator.Error;

pub fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    stages: []const Stage,
) Error![]u8 {
    _ = gpa;
    _ = io;
    _ = source;
    _ = stages;
    return error.NotImplemented;
}

test {
    std.testing.refAllDecls(@This());
}
