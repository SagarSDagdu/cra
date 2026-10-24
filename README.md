# Cra

A native macOS browser built on Chromium (CEF), shaped after the parts of Arc
worth keeping: a sidebar instead of a tab strip, spaces, pinned tabs with a
home URL, favorites shared across spaces, a command bar for new tabs that
searches open and archived tabs, auto-archiving, folders, and Chrome DevTools.

Shell: Swift (AppKit + SwiftUI). Engine: Chromium Embedded Framework.

## Build

    scripts/build.sh          # fetches CEF on first run, builds build/Cra.app
    scripts/run.sh            # build if needed, then open

Requirements: Xcode 16+, CMake (`brew install cmake`).

## Layout

- `Sources/Cra` — the app (model, store, sidebar, command bar, windows)
- `Sources/CraCEF` — Objective-C++ bridge to CEF
- `Sources/CraHelper` — Chromium subprocess executable
- `docs/arc-reverse-engineering.md` — what was learned from Arc and how
- `vendor/cef` — CEF binary distribution (not committed)

Data lives in `~/Library/Application Support/Cra`.

## Scripting hooks

Cra registers the `cra://` scheme so it can be driven from a shell (handy for
testing without touching the keyboard):

    open "cra://action/newTab"              # any action id from KeyBindings.swift
    open "cra://commandbar?query=github"    # open the command bar with text
    open "cra://open?url=https://example.com&background=1"
    open "cra://dismiss"                    # close sheets, command bar, find bar

## Import

Cra menu → Import from Arc or Dia…, or Settings → Import. Reads Arc's
StorableSidebar.json / StorableArchiveItems.json and Dia's profile containers +
bookmarks. Spaces with the same name merge; tabs already present are skipped.
Headless: `open "cra://import?source=arc&archive=1&settings=1"`.

## Account (Convex)

Backend in `backend/convex` (team victor-kildahl, project cra): dev
`helpful-stoat-265`, prod `artful-albatross-857` (eu-west-1). The app uses prod;
set `CRA_CONVEX_DEV=1` to use dev. Email/password and Google sign-in (the Google
OAuth client needs `https://<deployment>.convex.site/google-callback` as an
authorized redirect URI). Settings sync on change; the sidebar is backed up
every 10 minutes while signed in (Settings → Account → Restore).

Deploy changes to both deployments: `cd backend && npx convex dev --once && npx convex deploy -y`.

## Keyboard

Arc's defaults: ⌘T new tab · ⌘L command bar / edit URL · ⌘W close tab (window
when no tab) · ⇧⌘W close window · ⇧⌘T restore closed tab · ⌘S sidebar ·
⇧⌘D toolbar · ⌘D pin/unpin · ⇧⌘C copy URL · ⇧⌥⌘C copy as Markdown ·
⌘1…9 go to tab · ⌃1…9 go to space · ⌥⌘←/→ spaces · ⌥⌘↑/↓ tabs · ⌃Tab recent
tab · ⇧⌘K clear Today · ⌘[ / ⌘] back/forward · ⌘Y history · ⇧⌘L library ·
⇧⌘J downloads · ⌥⌘I DevTools · ⌥⌘J console · ⌥⌘U source · ⌘F find.
Like Chrome, pages get first chance at unreserved shortcuts (⌘F in Docs works).
Shortcuts can be changed in `~/Library/Application Support/Cra/keybindings.json`.

## Rendering calibration hook

`open "cra://debug?lift=0&liftInactive=0.75&alpha=1&material=13&state=follows&appearance=dark"`
changes the vibrancy parameters live (see `Sources/Cra/UI/Tuning.swift`). `material` is the
raw `NSVisualEffectView.Material` value, `alpha` scales the gradient opacity.

## DevTools

⌥⌘I toggles Chrome DevTools docked on the right of the page (drag the divider to resize);
Inspect Element from the context menu opens it at the clicked node. Each tab keeps its own
DevTools; the dock follows the selected tab.

## Brand

`brand/` holds the marks; `resources/brand/*.png` are WebKit renders of them (so the
multiply blends survive) used by `BrandMark`, and `resources/AppIcon.icns` is built from
`brand/cra-segments-icon.svg` (render at 1024 px, `iconutil`).

## Website and brand

The marketing site lives in a separate private repository (VictorKildahl/cra-website).
Logo sources are in `brand/` (see `brand/README.md`); `resources/brand` holds the PNGs the
app loads and `resources/AppIcon.icns` the app icon.
