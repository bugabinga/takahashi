# Cross-platform build

taka is designed to build **natively on Linux, macOS, and Windows** with every
output form always available — no build flags, no per-platform feature gating
(see the "no optionality" rule). This document records how the build selects
platform libraries and the verified build status on all three.

## What is portable already

- **The core pipeline** — parsing, markup, functions, `@run`, `@note`, watch
  mode, the sync channel — is pure Zig and target-independent.
- **The file forms** (HTML, PDF) are pure Zig: no system libraries at all.
- **The terminal form** is interactive on every platform: POSIX `termios` on
  Linux/macOS and the Win32 Console API (virtual-terminal mode) on Windows.
- **Text** (SPEC 3) is the vendored single-header `stb_truetype` — no system
  text library on any platform. Fonts are discovered from the host's standard
  font directories at startup (see `candidate_paths` in `src/text.zig`), so no
  large font asset is committed to the repository.

The remaining platform-specific part is the **window form** and the **audio
library** it needs.

## How the build selects platform libraries

`build.zig` branches on the target OS (`target.result.os.tag`):

| Concern | Linux | macOS | Windows |
| --- | --- | --- | --- |
| sokol backend | GL | Metal | D3D11 |
| window/graphics libs | `GL X11 Xi Xcursor` | `Metal QuartzCore AppKit` | `kernel32 user32 gdi32 ole32 d3d11 dxgi` |
| text (stb_truetype) | vendored | vendored | vendored |
| images (stb_image) | vendored | vendored | vendored |
| audio (miniaudio backend) | `pthread m dl` (ALSA) | `CoreFoundation CoreAudio AudioToolbox` | `ole32` (WASAPI) |
| sokol impl compilation | C | **Objective-C** (`-ObjC`, no ARC) | C |

The sokol backend is selected per target in `vendor/sokol/sokol.{c,h}` (not
hard-coded), so the impl and the translate-c bindings agree. Text and images are
vendored single-header C, portable on every target; only the window/graphics and
audio system libraries vary per platform.

## Verification status

CI (`.github/workflows/ci.yml`) runs on Linux, macOS, and Windows:

- **Offline tests** (`zig build test`, `zig build check`) — the pure-Zig core,
  parser, forms, watch, and sync — pass on **all three** platforms. POSIX-only
  fixtures (`@run` spawning real utilities, the `/tmp` state/watch files) skip
  on Windows.
- **Full build** (`zig build`, incl. the window form) — a **required CI job on
  all three** platforms. macOS compiles sokol_app as Objective-C (`-ObjC`) and
  links the Metal backend; Windows links the D3D11/DXGI backend; Linux links GL
  + X11. No platform installs a text library.

Because text no longer needs a system library, the full app also
**cross-compiles** from a Linux host to `x86_64-windows` (verified locally);
only macOS still requires its SDK to link the Apple frameworks.

## Notes

- **Windows terminal.** The interactive terminal uses the Console API
  (`GetConsoleMode`/`SetConsoleMode` with `ENABLE_VIRTUAL_TERMINAL_PROCESSING`
  and `ENABLE_VIRTUAL_TERMINAL_INPUT`), so ANSI escapes and arrow-key sequences
  work the same as the POSIX `termios` path. The two share the key decoder and
  frame renderers; only raw-mode setup and key reads differ.
- **Fonts.** Every desktop OS ships a Latin sans, a bold companion, and a
  pan-CJK face; `candidate_paths` lists the standard locations per OS and the
  first that exists is used. If none is found the window form logs and skips
  text rather than failing the whole presentation.
