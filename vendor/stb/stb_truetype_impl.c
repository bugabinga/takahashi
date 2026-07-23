// Single translation unit that compiles the vendored stb_truetype rasterizer
// (SPEC 3 text). Declarations are pulled in separately by the build's
// translate-c step (src/text_c.h); this file provides the implementation.
#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"
