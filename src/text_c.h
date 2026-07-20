// Aggregated FreeType + HarfBuzz headers for the build's translate-c step.
// Declarations only; the implementations are linked from the system
// libfreetype and libharfbuzz. Include paths: /usr/include/freetype2 and
// /usr/include/harfbuzz. See src/text.zig and the wiring reported alongside it.
#include <ft2build.h>
#include FT_FREETYPE_H
#include <hb.h>
#include <hb-ft.h>
