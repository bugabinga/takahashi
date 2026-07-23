# Third-party notices

taka (MIT) is built with the following third-party components. Vendored code
lives under `vendor/`; system libraries are linked at build time and provided
by the platform (see `docs/cross-platform.md`).

## Vendored (under `vendor/`)

- **sokol** — window and immediate-mode rendering (`vendor/sokol/`).
  © Andre Weissflog. zlib/libpng license.
- **stb_image** — image decoding (`vendor/stb/`).
  © Sean Barrett. Dual-licensed: MIT / public domain.
- **miniaudio** — audio playback (`vendor/miniaudio/`).
  © David Reid. Dual-licensed: MIT-0 / public domain.

## System libraries (linked, not distributed)

- **FreeType** — font rasterization. FreeType License (BSD-style with a credit
  clause) or GPLv2, at your option.
- **HarfBuzz** — text shaping. "Old MIT" license.
- Platform window/graphics/audio libraries (OpenGL/X11, Metal, Direct3D 11,
  ALSA, CoreAudio, WASAPI) provided by the operating system.

## Runtime tools (not distributed)

- **`@run`** invokes whatever programs the deck names, resolved from `PATH`.
  Those programs keep their own licenses; taka neither bundles nor modifies
  them.

Full license texts for the vendored components are included in their
respective source files under `vendor/`.
