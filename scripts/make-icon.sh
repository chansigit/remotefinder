#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
iconset="$PWD/.build/RemoteFinder.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Assets/RemoteFinder.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
    doubled=$((size * 2))
    sips -z "$doubled" "$doubled" Assets/RemoteFinder.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o Assets/RemoteFinder.icns
