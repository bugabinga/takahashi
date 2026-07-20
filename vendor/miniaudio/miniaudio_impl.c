/* Single translation unit that compiles the vendored miniaudio library.
   Everything else (src/audio.zig via src/audio_c.h) sees declarations only;
   the implementation lives here. miniaudio dlopens the OS audio backend
   (ALSA on Linux) at runtime, so no audio system library is linked. */
#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"
