/* Single compilation unit for stb_image (SPEC 1.3, @image decoding).
   The header is header-only; defining STB_IMAGE_IMPLEMENTATION here emits the
   code exactly once, so src/image.zig links against these symbols. */
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
