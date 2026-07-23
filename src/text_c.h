// Declarations for the vendored stb_truetype rasterizer, pulled into Zig by the
// build's translate-c step (see build.zig). The implementation is compiled
// separately from vendor/stb/stb_truetype_impl.c. No system text libraries are
// used — stb_truetype is a single header, so taka needs no FreeType/HarfBuzz.
#include "stb_truetype.h"
