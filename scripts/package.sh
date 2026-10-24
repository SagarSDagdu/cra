#!/bin/bash
# Packages build/Cra.app into build/dist/: a zip, a DMG with an Applications
# shortcut, and SHA-256 checksums. Signs the DMG when CRA_SIGN_IDENTITY is set.
#   scripts/package.sh [path/to/Cra.app]
set -euo pipefail
cd "$(dirname "$0")/.."
APP="${1:-build/Cra.app}"
[ -d "$APP" ] || { echo "No app at $APP. Run scripts/build.sh first." >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
IDENTITY="${CRA_SIGN_IDENTITY:--}"
DIST="build/dist"
rm -rf "$DIST" && mkdir -p "$DIST"

ZIP="$DIST/Cra-$VERSION.zip"
DMG="$DIST/Cra-$VERSION.dmg"

# Zip: ditto keeps resource forks and symlinks, which codesign requires.
ditto -c -k --keepParent "$APP" "$ZIP"

# DMG: stage app + Applications link, build a compressed read-only image.
STAGE="$(mktemp -d /tmp/cra-dmg.XXXXXX)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Cra" -srcfolder "$STAGE" -ov -format UDZO -fs HFS+ "$DMG"
rm -rf "$STAGE"
if [ "$IDENTITY" != "-" ]; then
  codesign --force --sign "$IDENTITY" --timestamp "$DMG"
fi

(cd "$DIST" && shasum -a 256 "$(basename "$ZIP")" "$(basename "$DMG")" > "SHA256SUMS.txt")
echo "Packaged:"
ls -la "$DIST"
