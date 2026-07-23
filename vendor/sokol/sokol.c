// Single translation unit for the vendored sokol libraries (SPEC 3.1 window
// form). The backend follows the target platform — Metal on Apple, D3D11 on
// Windows, desktop GL elsewhere — matching build.zig's linked system libraries.
#define SOKOL_IMPL
#if defined(__APPLE__)
#define SOKOL_METAL
#elif defined(_WIN32)
#define SOKOL_D3D11
#else
#define SOKOL_GLCORE
#endif
#define SOKOL_NO_ENTRY
#include "sokol_log.h"
#include "sokol_app.h"
#include "sokol_gfx.h"
#include "sokol_glue.h"
#include "sokol_gl.h"
#include "sokol_debugtext.h"
