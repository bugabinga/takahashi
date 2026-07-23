# Cross-platform build

taka is designed to build **natively on Linux, macOS, and Windows** with every
output form always available — no build flags, no per-platform feature gating
(see the "no optionality" rule). This document records how the build selects
platform libraries and what remains to reach verified builds on all three.

## What is portable already

- **The core pipeline** — parsing, markup, functions, `@run`, `@note`, watch
  mode, the sync channel — is pure Zig and target-independent.
- **The file forms** (HTML, PDF) are pure Zig: no system libraries at all.
- **The terminal form** uses POSIX `termios` for raw mode, which covers Linux
  and macOS. (It also *compiles* for Windows today; see below.)

These compile for every target. The platform-specific part is the **window
form** and the **media libraries** it needs.

## How the build selects platform libraries

`build.zig` branches on the target OS (`target.result.os.tag`):

| Concern | Linux | macOS | Windows |
| --- | --- | --- | --- |
| sokol backend | GL | Metal | D3D11 |
| window/graphics libs | `GL X11 Xi Xcursor` | `Cocoa QuartzCore Metal MetalKit` | `gdi32 user32 shell32 ole32 d3d11 dxgi` |
| text (FreeType+HarfBuzz) | apt `-dev` pkgs | Homebrew | vcpkg / vendored |
| audio (miniaudio backend) | `pthread m dl` (ALSA) | `CoreFoundation CoreAudio AudioToolbox` | `ole32` (WASAPI) |
| sokol impl compilation | C | **Objective-C** (`-ObjC`, no ARC) | C |

Images (stb_image) are vendored and portable on every target.

## Verification status

CI (`.github/workflows/ci.yml`) runs on Linux, macOS, and Windows:

- **Offline tests** (`zig build test`, `zig build check`) — the pure-Zig core,
  parser, forms, watch, and sync — pass on **all three** platforms. POSIX-only
  fixtures (`@run` spawning real utilities, the `/tmp` state/watch files) skip
  on Windows, where the interactive terminal falls back to the dump.
- **Full build** (`zig build`, incl. the window form) — verified on **Linux**.
  On **macOS** it runs but is still being brought up: Homebrew's FreeType/
  HarfBuzz are found and sokol compiles as Objective-C, but the sokol_app
  Objective-C unit against the system SDK does not build cleanly yet, so the
  macOS build job is marked non-blocking.
- **Windows full build** is not attempted in CI: FreeType/HarfBuzz have no
  standard system location there (needs vcpkg or vendoring).

## Remaining work

1. **Provision FreeType + HarfBuzz on macOS and Windows** and run a native
   build. On macOS the headers live under `/opt/homebrew/include` (Apple
   Silicon) or `/usr/local/include` (Intel); on Windows there is no standard
   location, so vcpkg (or vendoring, below) must supply the include path.
2. **Verify the macOS Objective-C compilation** of the sokol implementation
   unit and the framework links.
3. **Windows terminal raw mode.** The interactive terminal uses POSIX `termios`;
   it compiles for Windows but is runtime-untested there. A Windows console path
   (`ENABLE_VIRTUAL_TERMINAL_PROCESSING`) is the follow-up; the non-interactive
   dump already works as a fallback.
4. **Optional but decisive: vendor FreeType + HarfBuzz from source** (as sokol,
   stb_image, and miniaudio already are). That removes the last system
   dependency and makes taka *cross-compilable* from any host, not just
   natively buildable. It is a large undertaking (HarfBuzz is C++), so it is
   tracked as its own step.

## Cross-compilation note

Cross-compiling from a Linux host to macOS/Windows currently stops at the text
headers — the target has no FreeType/HarfBuzz sysroot. Until those libraries are
vendored (item 4), **build natively on each platform** with the libraries
installed. The `.claude/hooks/install-zig.sh` setup script provisions the Linux
`-dev` packages only; the equivalent for macOS/Windows is Homebrew / vcpkg.
