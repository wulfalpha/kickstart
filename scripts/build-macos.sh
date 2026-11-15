#!/bin/sh
# Bypass Zig 0.15.2's native build runner on macOS 27.
set -eu
cd "$(dirname "$0")/.."
if [ "$(uname -s)" != Darwin ]; then
    echo 'This workaround is for macOS; use zig build on other systems.' >&2
    exit 2
fi
case "$(uname -m)" in
    arm64) arch=aarch64 ;;
    x86_64) arch=x86_64 ;;
    *) echo 'Unsupported macOS architecture' >&2; exit 2 ;;
esac
case "${1:-build}" in
    build|test) mode=${1:-build} ;;
    *) echo 'Usage: scripts/build-macos.sh [build|test]' >&2; exit 2 ;;
esac
if [ "$#" -gt 1 ]; then
    echo 'Usage: scripts/build-macos.sh [build|test]' >&2
    exit 2
fi
# Keep default caches inside the workspace. Respect explicitly configured caches.
export ZIG_GLOBAL_CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$PWD/.zig-cache/global}"
export ZIG_LOCAL_CACHE_DIR="${ZIG_LOCAL_CACHE_DIR:-$PWD/.zig-cache}"
if [ "$mode" = test ]; then
    exec zig test src/main.zig -target "$arch-macos.26.0"
fi
mkdir -p zig-out/bin
zig build-exe src/main.zig -target "$arch-macos.26.0" -O ReleaseSafe \
    -femit-bin=zig-out/bin/kickstart
printf '%s\n' 'Built zig-out/bin/kickstart'
