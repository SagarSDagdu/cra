#!/bin/bash
# Builds the CEF binary distribution Cra ships, from source, with H.264/AAC.
#
# Spotify's prebuilt CEF (cef-builds.spotifycdn.com) leaves proprietary codecs out,
# so MP4/HLS video (X, Instagram, Reddit, most news sites) never plays. Codecs are a
# compile-time switch in Chromium and FFmpeg is linked into the framework, so the
# only fix is building CEF ourselves with proprietary_codecs + ffmpeg_branding=Chrome.
#
# Same CEF commit as the pinned prebuilt (scripts/fetch-cef.sh); besides the codecs
# only the fixes in scripts/cef-patches/ change. Needs ~80 GB free and several hours on an M2 Max. Re-running
# resumes: the checkout is kept and ninja only rebuilds what changed.
#
# Output: $CEF_BUILD_DIR/chromium/src/cef/binary_distrib/cef_binary_<ver>_macosarm64_minimal.tar.bz2
# Publish it with scripts/publish-cef.sh, then bump CEF_FLAVOR in fetch-cef.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

CEF_BRANCH="${CEF_BRANCH:-8037}"
CEF_COMMIT="${CEF_COMMIT:-14c5a08}"
# .noindex keeps Spotlight out of ~40 GB of sources.
CEF_BUILD_DIR="${CEF_BUILD_DIR:-$HOME/cef-build.noindex}"

# ANGLE compiles Metal shaders; Xcode 26 ships the Metal toolchain separately.
xcrun metal --version >/dev/null 2>&1 || xcodebuild -downloadComponent MetalToolchain

mkdir -p "$CEF_BUILD_DIR"
tmutil addexclusion "$CEF_BUILD_DIR" 2>/dev/null || true

if [ ! -d "$CEF_BUILD_DIR/depot_tools" ]; then
  git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git "$CEF_BUILD_DIR/depot_tools"
fi
# Bootstrap once (python, gn); DEPOT_TOOLS_UPDATE=0 below keeps it from updating.
[ -f "$CEF_BUILD_DIR/depot_tools/python3_bin_reldir.txt" ] || "$CEF_BUILD_DIR/depot_tools/ensure_bootstrap" || true
if [ ! -f "$CEF_BUILD_DIR/automate/automate-git.py" ]; then
  mkdir -p "$CEF_BUILD_DIR/automate"
  git -C "$CEF_BUILD_DIR" clone --depth 1 --branch "$CEF_BRANCH" https://github.com/chromiumembedded/cef.git cef-tools
  cp "$CEF_BUILD_DIR/cef-tools/tools/automate/automate-git.py" "$CEF_BUILD_DIR/automate/"
  rm -rf "$CEF_BUILD_DIR/cef-tools"
fi

export PATH="$CEF_BUILD_DIR/depot_tools:$PATH"
export DEPOT_TOOLS_UPDATE=0
export CEF_ARCHIVE_FORMAT=tar.bz2
# symbol_level=0: full debug info would need another ~50 GB and is never shipped.
export GN_DEFINES="is_official_build=true proprietary_codecs=true ffmpeg_branding=Chrome symbol_level=0 blink_symbol_level=0 v8_symbol_level=0 enable_dsyms=false"

automate() {
  python3 "$CEF_BUILD_DIR/automate/automate-git.py" \
    --download-dir="$CEF_BUILD_DIR" \
    --depot-tools-dir="$CEF_BUILD_DIR/depot_tools" \
    --branch="$CEF_BRANCH" \
    --checkout="$CEF_COMMIT" \
    --arm64-build \
    --no-chromium-history \
    --no-depot-tools-update \
    --with-pgo-profiles \
    --no-debug-build \
    --minimal-distrib-only \
    --no-distrib-docs \
    --no-distrib-symbols \
    "$@"
}

PATCHES="$PWD/scripts/cef-patches"
cd "$CEF_BUILD_DIR"
# 1. Check out Chromium + CEF and apply CEF's own patches.
automate --no-build --no-distrib
# 2. Cra's Chromium fixes on top (skipped when already applied).
for p in "$PATCHES"/*.patch; do
  if git -C chromium/src apply --check "$p" 2>/dev/null; then
    git -C chromium/src apply "$p" && echo "Applied $(basename "$p")"
  else
    git -C chromium/src apply --check --reverse "$p" || { echo "$(basename "$p") does not apply" >&2; exit 1; }
  fi
done
# 3. Build and package without touching the checkout again.
automate --no-update --force-build --force-distrib
