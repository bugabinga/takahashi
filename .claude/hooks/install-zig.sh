#!/usr/bin/env bash
# SessionStart hook: provision the toolchain this project builds with.
#   1. A native, stable Zig (from ziglang.org, never the pip/python package).
#   2. The system C libraries taka links: OpenGL/X11 for the sokol window form
#      (SPEC 3.1). Text (stb_truetype) is vendored, so no text library is needed;
#      the DejaVu + Noto CJK fonts it discovers at runtime are installed instead.
# taka has no Zig package dependencies, so nothing is fetched via zig; this is
# all the build needs. Idempotent and quiet on the fast paths.
set -uo pipefail

ZIG_VERSION="0.16.0"
ZIG_SHA256_X86_64="70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00"
DEST="/opt/zig"
LINK="/usr/local/bin/zig"

# --- 1. Native stable Zig -------------------------------------------------
if ! { command -v zig >/dev/null 2>&1 && [ "$(zig version 2>/dev/null)" = "$ZIG_VERSION" ]; }; then
    arch="$(uname -m)"
    tarball="zig-${arch}-linux-${ZIG_VERSION}.tar.xz"
    tmp="$(mktemp -d)"
    if curl -fsSL "https://ziglang.org/download/${ZIG_VERSION}/${tarball}" -o "$tmp/$tarball"; then
        if [ "$arch" = "x86_64" ]; then
            echo "${ZIG_SHA256_X86_64}  $tmp/$tarball" | sha256sum -c - >/dev/null || {
                echo "install-zig: checksum mismatch" >&2
                rm -rf "$tmp"
                exit 0
            }
        fi
        mkdir -p "$DEST"
        tar -xf "$tmp/$tarball" -C "$DEST" --strip-components=1
        ln -sf "$DEST/zig" "$LINK"
        echo "setup: installed zig ${ZIG_VERSION}"
    else
        echo "setup: could not download zig ${ZIG_VERSION}" >&2
    fi
    rm -rf "$tmp"
fi

# --- 2. System C libraries the build links --------------------------------
if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq >/dev/null 2>&1 || true
    apt-get install -y --no-install-recommends \
        libgl1-mesa-dev libx11-dev libxi-dev libxcursor-dev \
        libxrandr-dev libxinerama-dev libxext-dev \
        fonts-dejavu-core fonts-noto-cjk \
        >/dev/null 2>&1 || echo "setup: some system libraries failed to install" >&2
fi
