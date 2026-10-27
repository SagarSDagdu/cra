#!/bin/bash
# Downloads the pinned CEF binary distribution into vendor/cef and builds the
# C++ wrapper library. Safe to re-run; skips what is already there.
#
# Cra ships its own CEF build (scripts/build-cef.sh: H.264/AAC plus the fixes in
# scripts/cef-patches), published as a GitHub release asset by scripts/publish-cef.sh.
# CEF_URL=https://cef-builds.spotifycdn.com/<name>.tar.bz2 fetches Spotify's stock
# build instead (no H.264/AAC).
set -euo pipefail
cd "$(dirname "$0")/.."

CEF_VERSION="${CEF_VERSION:-156.0.14+g4fa4ab5+chromium-156.0.8078.48}"
ARCH="${CEF_ARCH:-macosarm64}"
NAME="cef_binary_${CEF_VERSION}_${ARCH}_minimal"
# Bump the suffix (codecs2, …) when the build changes but CEF_VERSION does not.
CEF_RELEASE="${CEF_RELEASE:-cef-${CEF_VERSION%%+*}-codecs2}"
URL="${CEF_URL:-https://github.com/VictorKildahl/cra/releases/download/${CEF_RELEASE}/cef_binary_${ARCH}_minimal.tar.bz2}"

mkdir -p vendor
# A different pinned build replaces vendor/cef.
[ -d vendor/cef/Release ] && [ ! -f vendor/cef/.cra-source ] && echo "https://cef-builds.spotifycdn.com/${NAME}.tar.bz2" > vendor/cef/.cra-source
if [ -d vendor/cef/Release ] && [ "$(cat vendor/cef/.cra-source)" != "$URL" ]; then
  echo "CEF build changed, replacing vendor/cef"
  rm -rf vendor/cef
fi
if [ ! -d vendor/cef/Release ]; then
  echo "Downloading ${NAME} from ${URL%/*}..."
  rm -rf vendor/cef-download
  mkdir -p vendor/cef-download
  curl -fL --progress-bar -o "vendor/cef-download/${NAME}.tar.bz2" "$URL"
  tar -xjf "vendor/cef-download/${NAME}.tar.bz2" -C vendor/cef-download
  rm -rf vendor/cef
  mv "vendor/cef-download/${NAME}" vendor/cef
  rm -rf vendor/cef-download
  echo "$URL" > vendor/cef/.cra-source
fi

if [ ! -f vendor/cef/build/libcef_dll_wrapper/libcef_dll_wrapper.a ]; then
  echo "Building libcef_dll_wrapper..."
  cmake -S vendor/cef -B vendor/cef/build -G "Unix Makefiles" \
    -DCMAKE_BUILD_TYPE=Release -DPROJECT_ARCH=arm64 -DUSE_SANDBOX=OFF \
    -DCMAKE_OSX_ARCHITECTURES=arm64 > vendor/cef/build-configure.log
  cmake --build vendor/cef/build --target libcef_dll_wrapper -j "$(sysctl -n hw.ncpu)" > vendor/cef/build-wrapper.log
fi
echo "CEF ready: vendor/cef"
