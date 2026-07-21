//! Microbenchmarks for taka's hot pure-CPU paths: slide parsing (parser.zig)
//! and inline-markup scanning (markup.zig). Build in ReleaseFast:
//!   zig build-exe -OReleaseFast bench.zig -femit-bin=/tmp/taka-bench && /tmp/taka-bench
//! Reports the minimum wall time over N iterations (min filters scheduler
//! noise) and the peak arena bytes for one parse+markup pass.

const std = @import("std");

const parser = @import("src/parser.zig");
const markup = @import("src/markup.zig");
const function = @import("src/function.zig");

const iterations = 200;
const target_bytes = 4 << 20; // ~4 MiB of synthetic deck

// A realistic mix: plain words, markup, URLs/hyphens (must stay literal),
// CJK, multi-line slides, and a couple of @functions.
const corpus = [_][]const u8{
    "Simple",
    "Made Easy",
    "One fold/braid   vs *complex* vs -hard-",
    "Source: http://www.infoq.com/presentations/Simple-Made-Easy",
    "高橋メソッド について",
    "State is Never Simple\nComplects value and time\nIt is _easy_, in the familiar sense",
    "Your ability to `reason` about your program is /critical/ to changing it",
    "人に やさしく",
    "number of words: @run(/usr/bin/wc -w %)",
    "見やすい",
};

fn buildInput(gpa: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, target_bytes + 4096);
    var i: usize = 0;
    while (out.items.len < target_bytes) : (i += 1) {
        try out.appendSlice(gpa, corpus[i % corpus.len]);
        try out.appendSlice(gpa, "\n\n");
    }
    return out.toOwnedSlice(gpa);
}

fn readNs(io: std.Io) u64 {
    return @intCast(std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds);
}

fn minTime(
    comptime bench: anytype,
    io: std.Io,
    arena: *std.heap.ArenaAllocator,
    source: []const u8,
) !u64 {
    var best: u64 = std.math.maxInt(u64);
    var n: usize = 0;
    while (n < iterations) : (n += 1) {
        _ = arena.reset(.retain_capacity);
        const start = readNs(io);
        try bench(arena.allocator(), source);
        const elapsed = readNs(io) - start;
        if (elapsed < best) best = elapsed;
    }
    return best;
}

fn minTimeSlides(io: std.Io, arena: *std.heap.ArenaAllocator, bodies: []const []const u8) !u64 {
    var best: u64 = std.math.maxInt(u64);
    var n: usize = 0;
    while (n < iterations) : (n += 1) {
        _ = arena.reset(.retain_capacity);
        const start = readNs(io);
        for (bodies) |body| {
            const spans = try markup.parse(arena.allocator(), body);
            std.mem.doNotOptimizeAway(spans.len);
        }
        const elapsed = readNs(io) - start;
        if (elapsed < best) best = elapsed;
    }
    return best;
}

fn runParse(a: std.mem.Allocator, source: []const u8) !void {
    const deck = try parser.parse(a, source);
    std.mem.doNotOptimizeAway(deck.slides.len);
}

fn runMarkup(a: std.mem.Allocator, source: []const u8) !void {
    const spans = try markup.parse(a, source);
    std.mem.doNotOptimizeAway(spans.len);
}

fn runScan(a: std.mem.Allocator, source: []const u8) !void {
    const segments = try function.scan(a, source);
    std.mem.doNotOptimizeAway(segments.len);
}

fn report(name: []const u8, ns: u64, bytes: usize) void {
    const mb: f64 = @as(f64, @floatFromInt(bytes)) / (1 << 20);
    const secs: f64 = @as(f64, @floatFromInt(ns)) / 1e9;
    const throughput = mb / secs;
    std.debug.print(
        "{s:<8} {d:>10.3} ms   {d:>8.1} MiB/s\n",
        .{ name, secs * 1e3, throughput },
    );
}

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.page_allocator;
    const io = init.io;

    const source = try buildInput(gpa);
    defer gpa.free(source);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    std.debug.print("input: {d:.2} MiB\n", .{@as(f64, @floatFromInt(source.len)) / (1 << 20)});
    std.debug.print("{s:<8} {s:>13}   {s:>13}\n", .{ "stage", "min time", "throughput" });

    const t_parse = try minTime(runParse, io, &arena, source);
    report("parse", t_parse, source.len);

    const t_markup = try minTime(runMarkup, io, &arena, source);
    report("markup*", t_markup, source.len); // whole marker-heavy buffer (stress)

    const t_scan = try minTime(runScan, io, &arena, source);
    report("scan", t_scan, source.len);

    // Realistic markup: per-slide, most bodies marker-free (as taka runs it).
    var body_arena = std.heap.ArenaAllocator.init(gpa);
    defer body_arena.deinit();
    const deck = try parser.parse(body_arena.allocator(), source);
    const bodies = try gpa.alloc([]const u8, deck.slides.len);
    defer gpa.free(bodies);
    var body_bytes: usize = 0;
    for (deck.slides, 0..) |slide, i| {
        bodies[i] = slide.body;
        body_bytes += slide.body.len;
    }
    const t_slides = try minTimeSlides(io, &arena, bodies);
    report("markup", t_slides, body_bytes); // per-slide (realistic)

    // Peak arena bytes for one full parse+markup pass (memory proxy).
    _ = arena.reset(.free_all);
    const mem_deck = try parser.parse(arena.allocator(), source);
    for (mem_deck.slides) |slide| {
        _ = try markup.parse(arena.allocator(), slide.body);
    }
    std.debug.print(
        "\nmem (parse+markup, one pass): {d:.2} MiB arena, {d} slides\n",
        .{ @as(f64, @floatFromInt(arena.queryCapacity())) / (1 << 20), mem_deck.slides.len },
    );
}
