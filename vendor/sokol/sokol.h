// Aggregated sokol headers for the build's translate-c step (see build.zig).
// Declarations only; the implementation is compiled from sokol.c. The backend
// follows the target platform, matching sokol.c.
#if defined(__APPLE__)
#define SOKOL_METAL
#elif defined(_WIN32)
#define SOKOL_D3D11
#else
#define SOKOL_GLCORE
#endif
#include "sokol_log.h"
#include "sokol_app.h"
#include "sokol_gfx.h"
#include "sokol_glue.h"
#include "sokol_gl.h"
#include "sokol_debugtext.h"
