#!/bin/bash
# Builds a release Perch.app and wraps it in a drag-to-Applications DMG at
# dist/Perch-<version>.dmg.
#
#   ./package.sh
#       Ad-hoc signed. Runs on your own Macs. Anyone you send it to gets a
#       Gatekeeper warning and has to allow it once in System Settings >
#       Privacy & Security > Open Anyway.
#
#   SIGN_ID="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE=perch-notary ./package.sh
#       Signed with your Developer ID, notarized by Apple, and stapled, so it
#       opens normally on any Mac running macOS 26. Needs a paid Apple
#       Developer account. Create the notary profile once with:
#         xcrun notarytool store-credentials perch-notary \
#           --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
set -euo pipefail
cd "$(dirname "$0")"

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Info.plist)
./build.sh

if [[ -n "${SIGN_ID:-}" ]]; then
  echo "Signing with $SIGN_ID"
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" Perch.app
fi
codesign --verify --strict Perch.app

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R Perch.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

mkdir -p dist
DMG="dist/Perch-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -quiet -volname "Perch" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"

if [[ -n "${SIGN_ID:-}" ]]; then
  codesign --force --timestamp --sign "$SIGN_ID" "$DMG"
fi
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  echo "Notarizing (this usually takes a few minutes)"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

echo "Packaged $DMG"
