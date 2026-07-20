//! Command-line parsing for the taka CLI (SPEC 2).
//!
//!   taka [--to <form>] [-o <path>] [--watch] <file>
//!
//! The default form is the interactive window (SPEC 3.1). `<file>` may be `-`
//! to read from standard input.

const std = @import("std");

pub const Form = enum { window, terminal, pdf, html };

pub const Config = struct {
    path: []const u8,
    form: Form = .window,
    /// Destination for file forms (SPEC 3.3, 3.4). Null means standard output.
    out_path: ?[]const u8 = null,
    /// Watch the source and re-render on change (SPEC 2.2).
    watch: bool = false,
};

pub const Error = error{
    MissingFile,
    MissingValue,
    UnknownForm,
    UnknownFlag,
};

pub fn parse(args: []const [:0]const u8) Error!Config {
    var config: Config = .{ .path = "" };
    var have_path = false;

    var i: usize = 1; // skip the program name
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--to") or std.mem.eql(u8, arg, "-t")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            config.form = std.meta.stringToEnum(Form, args[i]) orelse return error.UnknownForm;
        } else if (std.mem.eql(u8, arg, "--output") or std.mem.eql(u8, arg, "-o")) {
            i += 1;
            if (i >= args.len) return error.MissingValue;
            config.out_path = args[i];
        } else if (std.mem.eql(u8, arg, "--watch") or std.mem.eql(u8, arg, "-w")) {
            config.watch = true;
        } else if (std.mem.eql(u8, arg, "-")) {
            config.path = arg; // standard input
            have_path = true;
        } else if (arg.len > 0 and arg[0] == '-') {
            return error.UnknownFlag;
        } else {
            config.path = arg;
            have_path = true;
        }
    }

    if (!have_path) return error.MissingFile;
    return config;
}

test "defaults to the window form and requires a file" {
    try std.testing.expectError(error.MissingFile, parse(&.{"taka"}));

    const c = try parse(&.{ "taka", "deck.taka" });
    try std.testing.expectEqual(Form.window, c.form);
    try std.testing.expectEqualStrings("deck.taka", c.path);
    try std.testing.expectEqual(false, c.watch);
}

test "parses form, output and watch flags in any order" {
    const c = try parse(&.{ "taka", "--to", "html", "-o", "out.html", "--watch", "deck.taka" });
    try std.testing.expectEqual(Form.html, c.form);
    try std.testing.expectEqualStrings("out.html", c.out_path.?);
    try std.testing.expectEqualStrings("deck.taka", c.path);
    try std.testing.expectEqual(true, c.watch);

    try std.testing.expectError(error.UnknownForm, parse(&.{ "taka", "--to", "svg", "d.taka" }));
    try std.testing.expectError(error.MissingValue, parse(&.{ "taka", "--to" }));
}

test {
    std.testing.refAllDecls(@This());
}
