// Single translation unit for the vendored sokol libraries (SPEC 3.1 window
// form). Desktop GL backend; see build.zig for the linked system libraries.
#define SOKOL_IMPL
#define SOKOL_GLCORE 1
#define SOKOL_NO_ENTRY
#include "sokol_log.h"
#include "sokol_app.h"
#include "sokol_gfx.h"
#include "sokol_glue.h"
#include "sokol_gl.h"
#include "sokol_debugtext.h"
