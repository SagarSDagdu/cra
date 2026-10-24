#!/bin/bash
# Full distributable build: build, sign, notarize, package, notarize the DMG.
#   CRA_VERSION=0.1.0 CRA_SIGN_IDENTITY="Developer ID Application: …" scripts/release.sh
# Without CRA_SIGN_IDENTITY it still produces an ad-hoc build and packages, so
# the pipeline can be exercised before certificates exist.
set -euo pipefail
cd "$(dirname "$0")/.."
export CRA_VERSION="${CRA_VERSION:-0.1.0}"
IDENTITY="${CRA_SIGN_IDENTITY:--}"

scripts/build.sh release
APP="build/Cra.app"

if [ "$IDENTITY" != "-" ]; then
  # Notarize the app first (as a zip), staple it, then package the stapled app.
  TMPZIP="$(mktemp -d /tmp/cra-notarize.XXXXXX)/Cra.zip"
  ditto -c -k --keepParent "$APP" "$TMPZIP"
  scripts/notarize.sh "$TMPZIP" "$APP"
  rm -rf "$(dirname "$TMPZIP")"
fi

scripts/package.sh "$APP"

if [ "$IDENTITY" != "-" ]; then
  scripts/notarize.sh "build/dist/Cra-$CRA_VERSION.dmg"
  # Re-zip the stapled app so the zip download carries the ticket too.
  ditto -c -k --keepParent "$APP" "build/dist/Cra-$CRA_VERSION.zip"
  (cd build/dist && shasum -a 256 "Cra-$CRA_VERSION.zip" "Cra-$CRA_VERSION.dmg" > SHA256SUMS.txt)
  spctl --assess --type execute --verbose=2 "$APP" && echo "Gatekeeper accepts $APP"
else
  echo "Ad-hoc build: not notarized. Set CRA_SIGN_IDENTITY and notary credentials for a distributable build." >&2
fi
echo "Release artifacts in build/dist"
