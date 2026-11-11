#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' scripts/Info.plist)
release_dir="$PWD/dist/releases"
stage=$(mktemp -d /tmp/remotefinder-release.XXXXXX)
trap 'rm -rf "$stage"' EXIT
mkdir -p "$stage/image" "$release_dir"
app="$stage/image/RemoteFinder.app"
bash scripts/build.sh "$app"

# Build the other architecture, then sign the complete universal executable.
other_arch=x86_64
if [[ "$(uname -m)" == x86_64 ]]; then other_arch=arm64; fi
swiftc -O -target "$other_arch-apple-macos11.0" \
  Sources/RemoteFinderCore/*.swift Sources/RemoteFinder/*.swift -o "$stage/other"
lipo -create "$app/Contents/MacOS/RemoteFinder" "$stage/other" -output "$stage/universal"
mv "$stage/universal" "$app/Contents/MacOS/RemoteFinder"
codesign --force --sign - "$app"
codesign --verify --deep --strict "$app"
lipo "$app/Contents/MacOS/RemoteFinder" -verify_arch arm64 x86_64
test -x "$app/Contents/Resources/askpass"

cp docs/INSTALL.md "$stage/image/安装与权限说明.txt"
cp LICENSE "$stage/image/LICENSE.txt"
asset="RemoteFinder-$version-macOS-universal"
ditto -c -k --norsrc --noextattr "$stage/image" "$stage/$asset.zip"
ln -s /Applications "$stage/image/Applications"
hdiutil create -volname RemoteFinder -srcfolder "$stage/image" -fs HFS+ -format UDZO "$stage/$asset.dmg"
hdiutil verify "$stage/$asset.dmg"
mv "$stage/$asset.dmg" "$stage/$asset.zip" "$release_dir/"
cd "$release_dir"
shasum -a 256 "$asset.dmg" "$asset.zip" > SHA256SUMS.txt
shasum -a 256 -c SHA256SUMS.txt
printf 'Release assets: %s\n' "$release_dir"
