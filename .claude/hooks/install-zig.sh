#!/usr/bin/env bash
# SessionStart hook: install a native, stable Zig toolchain (from ziglang.org,
# never the pip/python `ziglang` package) so web sessions can build, test and
# format this project. Idempotent and quiet on the fast path.
set -euo pipefail

ZIG_VERSION="0.16.0"
# sha256 of zig-x86_64-linux-<version>.tar.xz (verified for x86_64 only).
ZIG_SHA256_X86_64="70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00"
DEST="/opt/zig"
LINK="/usr/local/bin/zig"

# Fast path: already the right version.
if command -v zig >/dev/null 2>&1 && [ "$(zig version 2>/dev/null)" = "$ZIG_VERSION" ]; then
    exit 0
fi

arch="$(uname -m)"
tarball="zig-${arch}-linux-${ZIG_VERSION}.tar.xz"
url="https://ziglang.org/download/${ZIG_VERSION}/${tarball}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

if ! curl -fsSL "$url" -o "$tmp/$tarball"; then
    echo "install-zig: could not download $url" >&2
    exit 0 # do not block the session on a network hiccup
fi

if [ "$arch" = "x86_64" ]; then
    echo "${ZIG_SHA256_X86_64}  $tmp/$tarball" | sha256sum -c - >/dev/null
fi

mkdir -p "$DEST"
tar -xf "$tmp/$tarball" -C "$DEST" --strip-components=1
ln -sf "$DEST/zig" "$LINK"

echo "install-zig: installed zig ${ZIG_VERSION} at ${LINK}"
