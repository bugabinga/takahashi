// Aggregate header for build-system translate-c (see CLAUDE.md: no @cImport).
// Exposes FFmpeg decode + swscale to src/video.zig. The two small helpers
// surface the AVERROR sentinels, which are function-like macros that
// translate-c cannot lower on its own.

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/imgutils.h>
#include <libswscale/swscale.h>
#include <errno.h>

static inline int taka_averror_eof(void) {
    return AVERROR_EOF;
}

static inline int taka_averror_eagain(void) {
    return AVERROR(EAGAIN);
}
