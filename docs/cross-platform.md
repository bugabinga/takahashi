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
| sokol impl compilation | C | **Objective-C** (`-x objective-c -fobjc-arc`) | C |

Images (stb_image) are vendored and portable on every target.

## Verification status

- **Linux** — built and tested in CI (`zig build`, `zig build test`,
  `zig build check`). Fully verified.
- **macOS / Windows** — the linking above follows sokol's documented backend
  requirements but has **not yet been verified on those machines**. Building
  there needs FreeType and HarfBuzz installed (Homebrew / vcpkg) so their
  headers and import libraries are present.

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
