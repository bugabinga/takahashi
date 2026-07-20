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

| Option | Immediate mode | Dependencies | CJK / markup text | Audio / video |
| --- | --- | --- | --- | --- |
| raylib | yes | package; **non-lazy emsdk** | weak (no shaping) | audio; no video |
| dvui | yes (pure Zig) | all lazy, clean | **no CJK / complex text** | none |
| Mach | yes | heavy (WebGPU/Dawn); pins a custom Zig | freetype + harfbuzz | sysaudio; no video |
| **sokol** | yes (`sokol_gl`) | **single-header C, vendorable** | (bring your own) | (bring your own) |

taka is a CJK-heavy typographic tool (the Japanese deck is a core example) that
needs markup, audio and video — so text quality is first-class, which points to
FreeType + HarfBuzz directly rather than any toolkit's built-in text.

## Decision

A **fetch-free** stack:

- **Window + immediate-mode 2D:** vendored **sokol** (`sokol_app`, `sokol_gfx`,
  `sokol_gl`, `sokol_glue`, `sokol_debugtext`) under `vendor/sokol/`, compiled
  as one C unit. Cross-platform (X11/Wayland, macOS, Windows, web).
- **Text (CJK + bold/italic/mono/…):** system **FreeType** + **HarfBuzz**.
- **Images (`@image`):** vendored **stb_image** (`vendor/stb/`).
- **Audio (`@audio`):** vendored **miniaudio** (`vendor/miniaudio/`); it
  `dlopen`s ALSA/PulseAudio at runtime, so nothing extra is linked.
- **Video (`@video`):** system **FFmpeg** (`libav*`).

There are **no Zig package dependencies** (`build.zig.zon` has none), so the
build fetches nothing. The window backend links only system OpenGL/X11; text and
media link system FreeType/HarfBuzz/FFmpeg. The SessionStart hook installs those
`-dev` packages via `apt`.

## Why this holds up

- **Nothing to fetch** — vendored single-header C plus system libraries. The
  whole `zig fetch`/GitHub-policy problem disappears.
- **Right text engine** for the Japanese deck and markup (FreeType + HarfBuzz).
- **Audio and video** are covered by miniaudio and FFmpeg.
- **Testable** — the window backend is reached only from `window.zig`, which the
  test root never imports, so `zig build test` stays offline and headless.

## Status

- Done: sokol vendored and wired; the executable builds and links; the window
  opens on a display; navigation runs through the tested `presentation.zig`.
- Next: draw slide text scaled to fill the frame via FreeType + HarfBuzz
  (SPEC 1.2 / 3); images via stb_image; `@audio` via miniaudio; `@video` via
  FFmpeg.
