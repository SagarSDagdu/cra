#!/bin/bash
# Builds Cra.app into build/Cra.app.
#   scripts/build.sh            release build
#   scripts/build.sh debug      debug build
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
CONFIG="${1:-release}"
VERSION="${CRA_VERSION:-0.1.0}"
BUILD_NUMBER="${CRA_BUILD:-$(date +%Y%m%d%H%M)}"

scripts/fetch-cef.sh

swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

# Stage the bundle, then sync it into place so the existing Cra.app directory
# keeps its identity (LaunchServices otherwise launches duplicate instances).
FINAL_APP="$ROOT/build/Cra.app"
STAGE="$(mktemp -d /tmp/cra-stage.XXXXXX)"
APP="$STAGE/Cra.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cp "$BIN/Cra" "$APP/Contents/MacOS/Cra"
sed -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" resources/Info.plist > "$APP/Contents/Info.plist"
echo -n "APPL????" > "$APP/Contents/PkgInfo"
[ -f resources/AppIcon.icns ] && cp resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
[ -d resources/web ] && cp -R resources/web "$APP/Contents/Resources/web"
[ -d resources/brand ] && cp -R resources/brand "$APP/Contents/Resources/brand"

FRAMEWORK_SRC="$ROOT/vendor/cef/Release/Chromium Embedded Framework.framework"
cp -R "$FRAMEWORK_SRC" "$APP/Contents/Frameworks/"

# CEF needs one helper app per process type (see cef_variables.cmake,
# CEF_HELPER_APP_SUFFIXES). Format: "<name suffix>|<plist suffix>".
for entry in "|" " (Alerts)|.alerts" " (GPU)|.gpu" " (Plugin)|.plugin" " (Renderer)|.renderer"; do
  NAME_SUFFIX="${entry%%|*}"
  PLIST_SUFFIX="${entry#*|}"
  HELPER="$APP/Contents/Frameworks/Cra Helper${NAME_SUFFIX}.app"
  mkdir -p "$HELPER/Contents/MacOS"
  cp "$BIN/CraHelper" "$HELPER/Contents/MacOS/Cra Helper${NAME_SUFFIX}"
  sed -e "s/__NAME_SUFFIX__/${NAME_SUFFIX}/g" -e "s/__PLIST_SUFFIX__/${PLIST_SUFFIX}/g" \
      -e "s/__VERSION__/$VERSION/" -e "s/__BUILD__/$BUILD_NUMBER/" \
      resources/Helper-Info.plist > "$HELPER/Contents/Info.plist"
  echo -n "APPL????" > "$HELPER/Contents/PkgInfo"
done

# Ad-hoc signatures, innermost first.
FW="$APP/Contents/Frameworks/Chromium Embedded Framework.framework"
find "$FW/Libraries" -name '*.dylib' -exec codesign --force --sign - {} \; 2>/dev/null || true
codesign --force --sign - "$FW"
for h in "$APP"/Contents/Frameworks/*.app; do codesign --force --sign - "$h"; done
codesign --force --sign - "$APP"

LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
mkdir -p "$FINAL_APP"
rsync -a --delete "$APP/" "$FINAL_APP/"
"$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true
rm -rf "$STAGE"
"$LSREGISTER" -f "$FINAL_APP" || true
echo "Built $FINAL_APP"

# Install outside ~/Documents: an app that runs from Documents makes macOS ask for
# folder access and blocks the main thread until answered. The installed copy is the
# one LaunchServices opens for cra:// URLs.
INSTALL_APP="${CRA_INSTALL_DIR:-$HOME/Applications}/Cra.app"
mkdir -p "$(dirname "$INSTALL_APP")"
rsync -a --delete "$FINAL_APP/" "$INSTALL_APP/"
"$LSREGISTER" -u "$FINAL_APP" >/dev/null 2>&1 || true
"$LSREGISTER" -f "$INSTALL_APP" >/dev/null 2>&1 || true
echo "Installed $INSTALL_APP"
