#!/bin/bash
# Downloads the pinned Sparkle release (the updater framework Arc ships) into
# vendor/sparkle: Sparkle.framework for the app, bin/ (generate_keys,
# sign_update) for releases. Safe to re-run; skips what is already there.
set -euo pipefail
cd "$(dirname "$0")/.."

SPARKLE_VERSION="2.10.0"
SPARKLE_SHA256="c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"

if [ "$(cat vendor/sparkle/VERSION 2>/dev/null)" != "$SPARKLE_VERSION" ]; then
  echo "Downloading Sparkle ${SPARKLE_VERSION}..."
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  curl -fL --progress-bar -o "$TMP/Sparkle.tar.xz" \
    "https://github.com/sparkle-project/Sparkle/releases/download/${SPARKLE_VERSION}/Sparkle-${SPARKLE_VERSION}.tar.xz"
  echo "${SPARKLE_SHA256}  $TMP/Sparkle.tar.xz" | shasum -a 256 -c - >/dev/null
  mkdir "$TMP/x"
  tar -xJf "$TMP/Sparkle.tar.xz" -C "$TMP/x"
  rm -rf vendor/sparkle
  mkdir -p vendor/sparkle
  mv "$TMP/x/Sparkle.framework" "$TMP/x/bin" "$TMP/x/LICENSE" vendor/sparkle/
  echo "$SPARKLE_VERSION" > vendor/sparkle/VERSION
fi
echo "Sparkle ready: vendor/sparkle"
