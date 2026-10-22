#!/bin/bash
# Builds Perch.app.
#   ./build.sh          release build (what package.sh ships)
#   ./build.sh debug    adds the local debug channel used for testing
set -euo pipefail
cd "$(dirname "$0")"
APP="Perch.app"
FLAGS=(-O)
if [[ "${1:-}" == "debug" ]]; then FLAGS=(-Onone -g -D DEBUG); fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -swift-version 5 -parse-as-library "${FLAGS[@]}" -framework AppKit -framework WebKit \
  -target arm64-apple-macosx26.0 \
  Sources/Perch/*.swift \
  -o "$APP/Contents/MacOS/Perch"
cp Info.plist "$APP/Contents/Info.plist"

# App icon, drawn in code (scripts/make-icon.swift) on Apple's icon grid.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
swiftc -O -parse-as-library -framework AppKit \
  scripts/make-icon.swift Sources/Perch/PerchGlyph.swift -o "$WORK/make-icon"
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for spec in 16:16x16 32:16x16@2x 32:32x32 64:32x32@2x 128:128x128 256:128x128@2x 256:256x256 512:256x256@2x 512:512x512 1024:512x512@2x; do
  "$WORK/make-icon" "$ICONSET/icon_${spec#*:}.png" "${spec%%:*}"
done
cp "$ICONSET/icon_512x512@2x.png" Assets/AppIcon.png
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP"
echo "Built $APP"
