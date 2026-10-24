#!/bin/bash
# Downloads the pinned CEF binary distribution into vendor/cef and builds the
# C++ wrapper library. Safe to re-run; skips what is already there.
set -euo pipefail
cd "$(dirname "$0")/.."

CEF_VERSION="${CEF_VERSION:-154.0.34+g14c5a08+chromium-154.0.8037.98}"
ARCH="${CEF_ARCH:-macosarm64}"
NAME="cef_binary_${CEF_VERSION}_${ARCH}_minimal"
URL="https://cef-builds.spotifycdn.com/${NAME}.tar.bz2"

mkdir -p vendor
if [ ! -d vendor/cef/Release ]; then
  echo "Downloading ${NAME} (about 130 MB)..."
  mkdir -p vendor/cef-download
  curl -fL --progress-bar -o "vendor/cef-download/${NAME}.tar.bz2" "$URL"
  tar -xjf "vendor/cef-download/${NAME}.tar.bz2" -C vendor/cef-download
  rm -rf vendor/cef
  mv "vendor/cef-download/${NAME}" vendor/cef
  rm -rf vendor/cef-download
fi

if [ ! -f vendor/cef/build/libcef_dll_wrapper/libcef_dll_wrapper.a ]; then
  echo "Building libcef_dll_wrapper..."
  cmake -S vendor/cef -B vendor/cef/build -G "Unix Makefiles" \
    -DCMAKE_BUILD_TYPE=Release -DPROJECT_ARCH=arm64 -DUSE_SANDBOX=OFF \
    -DCMAKE_OSX_ARCHITECTURES=arm64 > vendor/cef/build-configure.log
  cmake --build vendor/cef/build --target libcef_dll_wrapper -j "$(sysctl -n hw.ncpu)" > vendor/cef/build-wrapper.log
fi
echo "CEF ready: vendor/cef"
