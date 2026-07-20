//! Play audio files (@audio, SPEC 1.3) via the vendored miniaudio.
//!
//! `Player` wraps a miniaudio engine for fire-and-forget playback in the forms
//! that can play sound. On a headless box with no audio device the engine fails
//! to start; the player degrades to a no-op rather than crashing, so a deck with
//! `@audio` still presents. `decodeFrames` is device-free: it counts a file's
//! PCM frames through `ma_decoder`, which needs no engine and works headless.
//!
//! This module never touches the GPU; it only plays sound and reports frame
//! counts. The engine allocation is owned via libc (miniaudio itself uses libc).

const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const c = @import("audio_c");

const log = std.log.scoped(.takahashi);

pub const Error = error{
    DecodeFailed,
    OutOfMemory,
};

/// A fire-and-forget audio engine. `engine` is null when no device could be
/// opened (headless / no sound card); playback then does nothing.
pub const Player = struct {
    engine: ?*c.ma_engine = null,

    /// Start a miniaudio engine on the default playback device. When no device
    /// is available the returned player has a null engine and `play` is a
    /// no-op — the only hard failure is running out of memory for the engine.
    pub fn init() Error!Player {
        const engine = std.heap.c_allocator.create(c.ma_engine) catch {
            return Error.OutOfMemory;
        };
        const result = c.ma_engine_init(null, engine);
        if (result != c.MA_SUCCESS) {
            std.heap.c_allocator.destroy(engine);
            log.warn("audio engine unavailable (ma_result {d}); muting", .{result});
            return .{ .engine = null };
        }
        assert(result == c.MA_SUCCESS);
        return .{ .engine = engine };
    }

    /// Stop the engine and release it. Safe to call on a muted player.
    pub fn deinit(self: *Player) void {
        if (self.engine) |engine| {
            assert(@intFromPtr(engine) != 0);
            c.ma_engine_uninit(engine);
            std.heap.c_allocator.destroy(engine);
            self.engine = null;
        }
        assert(self.engine == null);
    }

    /// Best-effort playback of the file at `path`. Never crashes: a muted player
    /// or a failed decode is logged and ignored.
    pub fn play(self: *Player, path: [:0]const u8) void {
        assert(path.len > 0);
        const engine = self.engine orelse {
            log.debug("audio muted; skipping {s}", .{path});
            return;
        };
        assert(@intFromPtr(engine) != 0);
        const result = c.ma_engine_play_sound(engine, path.ptr, null);
        if (result != c.MA_SUCCESS) {
            log.warn("audio play failed for {s} (ma_result {d})", .{ path, result });
        }
    }
};

/// Frames read per `ma_decoder_read_pcm_frames` call in `decodeFrames`.
const frames_per_read: usize = 4096;

/// Upper bound on read iterations — a fixed loop bound (TIGER_STYLE). At
/// `frames_per_read` frames each this covers >10^13 frames, far past any deck.
const reads_max: usize = 1 << 32;

/// Count the total PCM frames in the audio file at `path`, device-free. Decodes
/// to mono f32 at the file's native rate (frame count is preserved) and sums the
/// frames returned by `ma_decoder_read_pcm_frames`. Returns `DecodeFailed` when
/// the file cannot be opened or decoded.
pub fn decodeFrames(gpa: Allocator, path: [:0]const u8) Error!usize {
    assert(path.len > 0);

    var config = c.ma_decoder_config_init(c.ma_format_f32, 1, 0);
    var decoder: c.ma_decoder = undefined;
    if (c.ma_decoder_init_file(path.ptr, &config, &decoder) != c.MA_SUCCESS) {
        return Error.DecodeFailed;
    }
    defer _ = c.ma_decoder_uninit(&decoder);

    const buffer = try gpa.alloc(f32, frames_per_read);
    defer gpa.free(buffer);
    assert(buffer.len == frames_per_read);

    var total: usize = 0;
    var reads: usize = 0;
    while (reads < reads_max) : (reads += 1) {
        var frames_read: c.ma_uint64 = 0;
        const result = c.ma_decoder_read_pcm_frames(
            &decoder,
            buffer.ptr,
            frames_per_read,
            &frames_read,
        );
        total += @intCast(frames_read);
        if (result != c.MA_SUCCESS or frames_read == 0) break;
    }
    assert(reads < reads_max); // the loop terminated on EOF, not the bound
    return total;
}

test "decodeFrames counts frames in a WAV file" {
    const gpa = std.testing.allocator;
    const path = "testdata/tone.wav";
    const frames = try decodeFrames(gpa, path);
    try std.testing.expect(frames > 0);
}

test "decodeFrames rejects a missing file" {
    const gpa = std.testing.allocator;
    try std.testing.expectError(
        Error.DecodeFailed,
        decodeFrames(gpa, "/nonexistent/definitely-not-here.wav"),
    );
}

test "player init/play/deinit never crash on a headless box" {
    var player = try Player.init();
    defer player.deinit();
    // Whether or not a device exists, this must be a safe no-op / best-effort.
    player.play("/tmp/does-not-matter.wav");
}

test {
    std.testing.refAllDecls(@This());
}
