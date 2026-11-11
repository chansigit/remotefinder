#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="${1:-$PWD/dist/RemoteFinder.app}"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" .build
swiftc -O -target "$(uname -m)-apple-macos11.0" \
  Sources/RemoteFinderCore/*.swift Sources/RemoteFinder/*.swift \
  -o .build/RemoteFinder
cp .build/RemoteFinder "$app/Contents/MacOS/RemoteFinder"
cp scripts/askpass "$app/Contents/Resources/askpass"
chmod 755 "$app/Contents/Resources/askpass"
cp scripts/Info.plist "$app/Contents/Info.plist"
if [[ ! -f Assets/RemoteFinder.icns || Assets/RemoteFinder.png -nt Assets/RemoteFinder.icns ]]; then
    bash scripts/make-icon.sh
fi
cp Assets/RemoteFinder.icns Assets/RemoteFinder.png "$app/Contents/Resources/"
# Finder / synced folders can attach metadata that prevents local signing.
xattr -dr com.apple.FinderInfo "$app" 2>/dev/null || true
xattr -dr com.apple.ResourceFork "$app" 2>/dev/null || true
codesign --force --sign - "$app"
printf 'Built: %s\n' "$app"
