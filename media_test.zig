//! Media test aggregator for `zig build test-media`. These modules link system
//! libraries (FreeType, HarfBuzz) and the vendored stb/miniaudio, and read
//! fixtures under testdata/ and examples/ — so they are kept out of the default
//! `zig build test` (which stays offline and dependency-free). Run from the
//! project root so the relative fixture paths resolve.

test {
    _ = @import("src/text.zig");
    _ = @import("src/image.zig");
    _ = @import("src/audio.zig");
}
