# Developing Cra

Notes for working on the code. How to send a change is in
[CONTRIBUTING.md](../CONTRIBUTING.md); user-facing docs live in the help centre at
[crabrowser.app/help](https://crabrowser.app/help).

## Build

    scripts/build.sh          # fetches CEF on first run, builds build/Cra.app
    scripts/build.sh debug    # debug build
    scripts/run.sh            # build if needed, then open (--rebuild forces a build)
    scripts/dev.sh            # dev loop: debug CraDev.app, rebuilds + relaunches on save (~4 s)

Requirements: macOS 14+ on Apple silicon, Xcode 16+, CMake (`brew install cmake`), about
1 GB of disk for CEF and the build products.

`scripts/fetch-cef.sh` pins the CEF version and downloads it into `vendor/cef` (not
committed). It fetches Cra's own CEF build, made by `scripts/build-cef.sh` with H.264/AAC
and the patches in `scripts/cef-patches` and published as a `cef-*` release by
`scripts/publish-cef.sh`; `CEF_URL` points it at Spotify's stock build instead. A daily workflow (`.github/workflows/cef-updates.yml`) opens an
issue when a newer stable CEF is out; `scripts/update-cef.sh` moves the pin.

## Layout

- `Sources/Cra` — the app: `App` (delegate, key bindings), `Model`, `Services` (sidebar
  store, persistence, import, updates, extensions, live folders), `UI` (sidebar, command
  bar, split view, windows, settings, onboarding)
- `Sources/CraCEF` — Objective-C++ bridge between Swift and CEF
- `Sources/CraHelper` — Chromium subprocess executable
- `resources/` — app icon, brand PNGs, the ad and tracker blocklist with its licence notices
- `scripts/` — build, release, CEF and test tooling; `scripts/clips` records release clips
- `docs/arc-reverse-engineering.md` — what was learned from Arc and how
- `docs/release.md` — signing, notarization and the release workflow
- `vendor/cef` — CEF binary distribution (fetched, not committed)

Data lives in `~/Library/Application Support/Cra`: the sidebar and archive as JSON,
`keybindings.json`, cached favicons, `chromium.log` and a Chromium profile folder. Delete
it to start over.

## Running a test instance

Cra is single-instance and the installed copy receives every `cra://` URL, so test a
build next to your daily Cra with its own data folder and a command file:

    CRA_DATA_DIR=/tmp/cra-test CRA_COMMAND_FILE=/tmp/cra-test.cmd build/Cra.app/Contents/MacOS/Cra &
    echo "cra://action/newTab" >> /tmp/cra-test.cmd

Every line appended to `CRA_COMMAND_FILE` is handled like a `cra://` URL, including the
scripting hosts below.

## Scripting hooks

Cra registers the `cra://` scheme so it can be driven from a shell:

    open "cra://action/newTab"              # any action id from KeyBindings.swift
    open "cra://commandbar?query=github"    # open the command bar with text
    open "cra://open?url=https://example.com&background=1"
    open "cra://open?url=https://example.com&little=1"   # in a Little Window
    open "cra://import?source=arc&archive=1&settings=1"  # headless import
    open "cra://dismiss"                    # close sheets, command bar, find bar

Links from other apps and browsers only reach `commandbar`, `dismiss` and `open` with an
http(s) URL; pages inside Cra reach none of them. The rest (`action`, `navigate`, `key`,
`import`, `debug`) run scripts and DevTools Protocol commands, so they need either
`defaults write dk.kildahl.cra scriptingURLs -bool YES` or a test instance's
`CRA_COMMAND_FILE`. See `AppDelegate.isUserFacing` before adding a host.

## Rendering calibration

`open "cra://debug?lift=0&liftInactive=0.75&alpha=1&material=13&state=follows&appearance=dark"`
changes the vibrancy parameters live (see `Sources/Cra/UI/Tuning.swift`). `material` is the
raw `NSVisualEffectView.Material` value, `alpha` scales the gradient opacity.

## Brand assets

Logo sources are in `brand/` (see `brand/README.md`). `resources/brand/*.png` are WebKit
renders of them (so the multiply blends survive) used by `BrandMark`, and
`resources/AppIcon.icns` is built from `brand/cra-segments-icon.svg` (render at 1024 px,
`iconutil`). The marketing site lives in a separate private repository.

## Releasing

`scripts/release.sh` builds, signs with a Developer ID, notarizes, and packages a DMG and
zip into `build/dist`. Pushing a `v*` tag runs the same through GitHub Actions and
publishes a release. Releases with UI changes get short clips on the release notes first
(`scripts/clips`, `.claude/skills/release-clips`). See [release.md](release.md) for the
one-time certificate setup.
