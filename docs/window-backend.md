# Window backend & media stack

Why the window output form (SPEC 3.1) is built on **vendored sokol + system
libraries**, and not a Zig package dependency.

## The constraint that drove this

Zig's package fetcher (`zig fetch`) cannot reach GitHub through the managed
egress proxy — its built-in git client does not use the proxy, so `git+https`
package URLs fail with `ReadFailed`. Plain `git` *does* work. On top of that,
some popular packages pull heavy **non-lazy** transitive dependencies (raylib's
manifest drags the entire Emscripten SDK, needed only for WebAssembly builds).

The lesson: **minimize Zig package dependencies**, and prefer sources that do
not go through the package manager at all.

## Alternatives considered

| Option | Immediate mode | Dependencies | CJK / markup text | Audio |
| --- | --- | --- | --- | --- |
| raylib | yes | package; **non-lazy emsdk** | weak (no shaping) | audio |
| dvui | yes (pure Zig) | all lazy, clean | **no CJK / complex text** | none |
| Mach | yes | heavy (WebGPU/Dawn); pins a custom Zig | freetype + harfbuzz | sysaudio |
| **sokol** | yes (`sokol_gl`) | **single-header C, vendorable** | (bring your own) | (bring your own) |

taka is a CJK-heavy typographic tool (the Japanese deck is a core example) that
needs markup and audio — so text quality is first-class, which points to a
dedicated rasterizer rather than any toolkit's built-in text. The takahashi
style is huge, single-word slides in Latin/CJK, which need no complex shaping,
so the vendored single-header **stb_truetype** covers it without a shaping
library — and stays fetch-free like the rest of the stack.

## Decision

A **fetch-free** stack:

- **Window + immediate-mode 2D:** vendored **sokol** (`sokol_app`, `sokol_gfx`,
  `sokol_gl`, `sokol_glue`, `sokol_debugtext`) under `vendor/sokol/`, compiled
  as one C unit. Cross-platform (X11/Wayland, macOS, Windows, web).
- **Text (CJK + bold/italic/mono/…):** vendored **stb_truetype**
  (`vendor/stb/`); fonts are read from the host's standard font directories at
  runtime, so no font asset is committed and no text library is linked.
- **Images (`@image`):** vendored **stb_image** (`vendor/stb/`).
- **Audio (`@audio`):** vendored **miniaudio** (`vendor/miniaudio/`); it
  `dlopen`s ALSA/PulseAudio at runtime, so nothing extra is linked.

There are **no Zig package dependencies** (`build.zig.zon` has none), so the
build fetches nothing. Text and images are vendored single-header C; the window
backend links only the platform window/graphics libraries (OpenGL/X11 on Linux,
frameworks on macOS, D3D11 on Windows). The SessionStart hook installs the Linux
`-dev` packages and the DejaVu + Noto CJK fonts via `apt`.

## Why this holds up

- **Nothing to fetch** — vendored single-header C plus system libraries. The
  whole `zig fetch`/GitHub-policy problem disappears.
- **Right text engine** for the Japanese deck and markup (vendored stb_truetype
  with CJK glyph-index fallback).
- **Audio** is covered by vendored miniaudio.
- **Testable** — the window backend is reached only from `window.zig`, which the
  test root never imports, so `zig build test` stays offline and headless.

## Status

Complete. The window form renders slides with proportional, scaled, CJK-aware
text (stb_truetype), images laid out in an equal grid (stb_image), and
audio on entry (miniaudio) — navigated through the tested `presentation.zig`.
The three media subsystems live in `src/{text,image,audio}.zig`
(GPU-independent: they return pixels / vertices / PCM that `window.zig` uploads
via sokol_gl). The full pipeline — markup, `@run`, `@image/@audio` — also drives
the terminal, HTML (self-contained) and PDF forms.

Tests: `zig build test` stays offline (32 logic/integration tests); the media
modules compile the vendored C and read fonts/fixtures from disk, so they run
under `zig build test-media` (verified: text incl. Japanese, image, audio).
