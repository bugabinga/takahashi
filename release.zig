const std = @import("std");

const assert = std.debug.assert;
const manifest_path = "build.zig.zon";

const VersionField = struct {
    version: std.SemanticVersion,
    value_start: usize,
    value_end: usize,
};

const Preflight = struct {
    branch: []const u8,
    status: []const u8,
    upstream: []const u8,
    head: []const u8,
    upstream_head: []const u8,
    signing_format: []const u8,
    signing_key: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    assert(args.len >= 1);
    assert(args[0].len > 0);

    if (args.len != 2 or args[1].len == 0) {
        std.log.err("usage: zig build release -- patch|minor|major|<semver>", .{});
        std.process.exit(2);
    }
    release(init.arena.allocator(), init.io, args[1]) catch std.process.exit(1);
}

fn release(arena: std.mem.Allocator, io: std.Io, request: []const u8) !void {
    assert(request.len > 0);
    assert(manifest_path.len > 0);

    const dir = std.Io.Dir.cwd();
    const source = try dir.readFileAlloc(io, manifest_path, arena, .limited(1024 * 1024));
    const field = try parseVersionField(source);
    const target = selectVersion(field.version, request) catch |err| {
        switch (err) {
            error.InvalidVersion => std.log.err(
                "release request '{s}' is neither patch, minor, major, nor valid SemVer",
                .{request},
            ),
            error.VersionNotIncreasing => {
                const requested = std.SemanticVersion.parse(request) catch unreachable;
                std.log.err(
                    "requested release {f} is not newer than current {f}",
                    .{ requested, field.version },
                );
                if (requested.major == field.version.major and
                    requested.minor == field.version.minor and
                    requested.patch == field.version.patch and
                    requested.pre != null and field.version.pre == null)
                {
                    std.log.err(
                        "SemVer prereleases precede their matching stable version; bump first",
                        .{},
                    );
                }
            },
            error.Overflow, error.VersionOverflow => std.log.err(
                "release request '{s}' exceeds the supported version range",
                .{request},
            ),
        }
        return err;
    };
    const target_text = try std.fmt.allocPrint(arena, "{f}", .{target});
    const tag = try std.fmt.allocPrint(arena, "v{s}", .{target_text});

    preflight(arena, io, tag) catch |err| {
        std.log.err("preflight failed: {s}", .{@errorName(err)});
        return err;
    };

    const updated = try replaceVersion(arena, source, &field, target_text);
    try writeManifest(io, updated);
    runChecks(io) catch |err| {
        writeManifest(io, source) catch |restore_err| {
            std.log.err(
                "checks failed and manifest restore failed: {s}",
                .{@errorName(restore_err)},
            );
            return restore_err;
        };
        std.log.err("checks failed; {s} restored", .{manifest_path});
        return err;
    };

    try createRelease(arena, io, tag);
}

fn parseVersionField(source: []const u8) !VersionField {
    const marker = ".version = \"";
    const marker_start = std.mem.indexOf(u8, source, marker) orelse return error.MissingVersion;
    const value_start = marker_start + marker.len;
    const tail = source[value_start..];
    const value_length = std.mem.indexOfScalar(u8, tail, '"') orelse return error.MissingVersion;
    const value_end = value_start + value_length;
    if (std.mem.indexOf(u8, source[value_end..], marker) != null) return error.DuplicateVersion;

    const version = try std.SemanticVersion.parse(source[value_start..value_end]);
    assert(value_start < value_end);
    assert(value_end <= source.len);
    return .{ .version = version, .value_start = value_start, .value_end = value_end };
}

fn selectVersion(current: std.SemanticVersion, request: []const u8) !std.SemanticVersion {
    assert(request.len > 0);
    assert(current.pre == null or current.pre.?.len > 0);
    assert(current.build == null or current.build.?.len > 0);

    const target = if (std.mem.eql(u8, request, "patch"))
        try bump(current, .patch)
    else if (std.mem.eql(u8, request, "minor"))
        try bump(current, .minor)
    else if (std.mem.eql(u8, request, "major"))
        try bump(current, .major)
    else
        try std.SemanticVersion.parse(request);

    if (current.order(target) != .lt) return error.VersionNotIncreasing;
    assert(target.pre == null or target.pre.?.len > 0);
    assert(target.build == null or target.build.?.len > 0);
    return target;
}

const Bump = enum { patch, minor, major };

fn bump(current: std.SemanticVersion, component: Bump) !std.SemanticVersion {
    const target: std.SemanticVersion = switch (component) {
        .patch => .{
            .major = current.major,
            .minor = current.minor,
            .patch = std.math.add(usize, current.patch, 1) catch return error.VersionOverflow,
        },
        .minor => .{
            .major = current.major,
            .minor = std.math.add(usize, current.minor, 1) catch return error.VersionOverflow,
            .patch = 0,
        },
        .major => .{
            .major = std.math.add(usize, current.major, 1) catch return error.VersionOverflow,
            .minor = 0,
            .patch = 0,
        },
    };
    assert(target.pre == null);
    assert(target.build == null);
    return target;
}

fn replaceVersion(
    allocator: std.mem.Allocator,
    source: []const u8,
    field: *const VersionField,
    target: []const u8,
) ![]const u8 {
    assert(field.value_start < field.value_end);
    assert(field.value_end <= source.len);
    assert(target.len > 0);

    const result = try std.mem.concat(allocator, u8, &.{
        source[0..field.value_start],
        target,
        source[field.value_end..],
    });
    assert(result.len == source.len - (field.value_end - field.value_start) + target.len);
    return result;
}

fn preflight(arena: std.mem.Allocator, io: std.Io, tag: []const u8) !void {
    assert(tag.len > 1);
    assert(tag[0] == 'v');

    var snapshot: Preflight = .{
        .branch = try capture(arena, io, &.{ "git", "branch", "--show-current" }),
        .status = try capture(arena, io, &.{ "git", "status", "--porcelain" }),
        .upstream = capture(
            arena,
            io,
            &.{ "git", "rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{upstream}" },
        ) catch return error.MissingUpstream,
        .head = "",
        .upstream_head = "",
        .signing_format = capture(
            arena,
            io,
            &.{ "git", "config", "--get", "gpg.format" },
        ) catch return error.MissingSigningFormat,
        .signing_key = capture(
            arena,
            io,
            &.{ "git", "config", "--get", "user.signingKey" },
        ) catch return error.MissingSigningKey,
    };
    try validateLocalPreflight(&snapshot);

    try runCommand(io, &.{ "git", "fetch", "--prune", "--tags", "origin" });
    snapshot.head = try capture(arena, io, &.{ "git", "rev-parse", "HEAD" });
    snapshot.upstream_head = try capture(arena, io, &.{ "git", "rev-parse", "origin/trunk" });
    try validateSynchronization(&snapshot);

    const tag_ref = try std.fmt.allocPrint(arena, "refs/tags/{s}", .{tag});
    switch (try commandExitCode(io, &.{ "git", "show-ref", "--verify", "--quiet", tag_ref })) {
        0 => return error.TagExists,
        1 => {},
        else => return error.CommandFailed,
    }
}

fn validateLocalPreflight(snapshot: *const Preflight) !void {
    if (!std.mem.eql(u8, snapshot.branch, "trunk")) return error.NotTrunk;
    if (snapshot.status.len != 0) return error.DirtyWorktree;
    if (!std.mem.eql(u8, snapshot.upstream, "origin/trunk")) return error.WrongUpstream;
    if (!std.mem.eql(u8, snapshot.signing_format, "ssh")) return error.WrongSigningFormat;
    if (snapshot.signing_key.len == 0) return error.MissingSigningKey;

    assert(std.mem.eql(u8, snapshot.branch, "trunk"));
    assert(snapshot.status.len == 0);
    assert(std.mem.eql(u8, snapshot.upstream, "origin/trunk"));
    assert(std.mem.eql(u8, snapshot.signing_format, "ssh"));
}

fn validateSynchronization(snapshot: *const Preflight) !void {
    if (snapshot.head.len == 0) return error.MissingHead;
    if (snapshot.upstream_head.len == 0) return error.MissingUpstreamHead;
    if (!std.mem.eql(u8, snapshot.head, snapshot.upstream_head)) return error.UnsynchronizedTrunk;

    assert(snapshot.head.len > 0);
    assert(snapshot.upstream_head.len > 0);
    assert(std.mem.eql(u8, snapshot.head, snapshot.upstream_head));
}

fn runChecks(io: std.Io) !void {
    try runCommand(io, &.{ "zig", "build", "check" });
    try runCommand(io, &.{ "zig", "build", "test" });
}

fn createRelease(arena: std.mem.Allocator, io: std.Io, tag: []const u8) !void {
    assert(tag.len > 1);
    assert(tag[0] == 'v');

    try runCommand(io, &.{ "git", "add", "--", manifest_path });
    const message = try std.fmt.allocPrint(arena, "release: {s}", .{tag});
    runCommand(io, &.{ "git", "commit", "-S", "-m", message }) catch |err| {
        std.log.err("commit failed; retry: git commit -S -m \"release: {s}\"", .{tag});
        return err;
    };
    runCommand(io, &.{ "git", "tag", "-s", tag, "-m", tag }) catch |err| {
        std.log.err("tag failed; retry: git tag -s {s} -m {s}", .{ tag, tag });
        return err;
    };
    runCommand(io, &.{ "git", "push", "--atomic", "origin", "trunk", tag }) catch |err| {
        std.log.err("push failed; retry: git push --atomic origin trunk {s}", .{tag});
        return err;
    };
}

fn writeManifest(io: std.Io, data: []const u8) !void {
    assert(data.len > 0);
    assert(manifest_path.len > 0);

    const dir = std.Io.Dir.cwd();
    const stat = try dir.statFile(io, manifest_path, .{});
    var atomic_file = try dir.createFileAtomic(io, manifest_path, .{
        .permissions = stat.permissions,
        .replace = true,
    });
    defer atomic_file.deinit(io);

    var buffer: [4096]u8 = undefined;
    var writer = atomic_file.file.writer(io, &buffer);
    try writer.interface.writeAll(data);
    try writer.flush();
    try atomic_file.replace(io);
}

fn runCommand(io: std.Io, argv: []const []const u8) !void {
    assert(argv.len > 0);
    assert(argv[0].len > 0);

    var child = try std.process.spawn(io, .{ .argv = argv });
    const term = try child.wait(io);
    if (!termSucceeded(term)) {
        std.log.err("command failed: {s}", .{argv[0]});
        return error.CommandFailed;
    }
}

fn capture(
    arena: std.mem.Allocator,
    io: std.Io,
    argv: []const []const u8,
) ![]const u8 {
    assert(argv.len > 0);
    assert(argv[0].len > 0);

    const result = try std.process.run(arena, io, .{
        .argv = argv,
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    });
    if (!termSucceeded(result.term)) {
        if (result.stderr.len > 0) std.log.err("{s}", .{result.stderr});
        return error.CommandFailed;
    }
    return std.mem.trim(u8, result.stdout, " \r\n\t");
}

fn commandExitCode(io: std.Io, argv: []const []const u8) !u8 {
    assert(argv.len > 0);
    assert(argv[0].len > 0);

    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    return switch (try child.wait(io)) {
        .exited => |code| code,
        .signal, .stopped, .unknown => error.CommandFailed,
    };
}

fn termSucceeded(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        .signal, .stopped, .unknown => false,
    };
}

test "selects named bumps and clears suffixes" {
    const current = try std.SemanticVersion.parse("1.4.2-rc.1+build.7");
    try std.testing.expectFmt("1.4.3", "{f}", .{try selectVersion(current, "patch")});
    try std.testing.expectFmt("1.5.0", "{f}", .{try selectVersion(current, "minor")});
    try std.testing.expectFmt("2.0.0", "{f}", .{try selectVersion(current, "major")});
}

test "accepts only increasing explicit versions" {
    const current = try std.SemanticVersion.parse("0.1.0-alpha.1");
    try std.testing.expectFmt(
        "0.1.0-beta.1+build.4",
        "{f}",
        .{try selectVersion(current, "0.1.0-beta.1+build.4")},
    );
    try std.testing.expectError(
        error.VersionNotIncreasing,
        selectVersion(current, "0.1.0-alpha.1"),
    );
    try std.testing.expectError(error.VersionNotIncreasing, selectVersion(current, "0.0.9"));
    try std.testing.expectError(error.InvalidVersion, selectVersion(current, "beta"));
}

test "build metadata does not create precedence" {
    const current = try std.SemanticVersion.parse("1.0.0+build.1");
    try std.testing.expectError(
        error.VersionNotIncreasing,
        selectVersion(current, "1.0.0+build.2"),
    );
}

test "reads and replaces only the manifest version" {
    const source = ".{\n    .version = \"1.2.3-alpha.1\",\n    .other = \"1.2.3-alpha.1\",\n}\n";
    const field = try parseVersionField(source);
    try std.testing.expectFmt("1.2.3-alpha.1", "{f}", .{field.version});
    const result = try replaceVersion(std.testing.allocator, source, &field, "1.2.3");
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualStrings(
        ".{\n    .version = \"1.2.3\",\n    .other = \"1.2.3-alpha.1\",\n}\n",
        result,
    );
}

test "rejects malformed manifest versions" {
    try std.testing.expectError(error.MissingVersion, parseVersionField(".{}"));
    try std.testing.expectError(error.InvalidVersion, parseVersionField(".version = \"1.2\""));
    try std.testing.expectError(
        error.DuplicateVersion,
        parseVersionField(".version = \"1.2.3\"\n.version = \"2.0.0\""),
    );
}

test "validates preflight command results" {
    const valid: Preflight = .{
        .branch = "trunk",
        .status = "",
        .upstream = "origin/trunk",
        .head = "abc",
        .upstream_head = "abc",
        .signing_format = "ssh",
        .signing_key = "~/.ssh/key",
    };
    try validateLocalPreflight(&valid);
    try validateSynchronization(&valid);

    var invalid = valid;
    invalid.status = " M build.zig.zon";
    try std.testing.expectError(error.DirtyWorktree, validateLocalPreflight(&invalid));
    invalid = valid;
    invalid.upstream_head = "def";
    try std.testing.expectError(error.UnsynchronizedTrunk, validateSynchronization(&invalid));
    invalid = valid;
    invalid.signing_format = "openpgp";
    try std.testing.expectError(error.WrongSigningFormat, validateLocalPreflight(&invalid));
}
