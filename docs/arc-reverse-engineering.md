# Arc reverse-engineering findings (for Cra)

Target: /Applications/Arc.app, version 1.168.0 (build 88413), bundle id company.thebrowser.Browser, min macOS 13.
Method: REA CLI (rea-agents 6.4.0) `decode-interface-builder`, `inspect-asset-catalog`; `strings` on the arm64 slice;
Arc's own JSON stores in ~/Library/Application Support/Arc; `defaults read company.thebrowser.Browser`.
No Ghidra/IDA/Hopper on this Mac, so no decompiled logic. Nothing below was observed at runtime.

Legend: [O] observed in shipped artifact or data file, [I] inference, [U] unknown.

## Architecture
- [O] Native Swift app. Framework "ARC" with feature modules (CommandBar, SidebarDataStore, StorableSidebar, Archive,
  SpaceStyleEditor, TypeTravel, LittleBrowser, HoverCards...). UI is AppKit: SidebarViewController, SidebarDockViewController,
  NSCollectionView layouts, CommandBarTextField, SuggestionsView.
- [O] Web content is embedded Chromium ("User Data/Default" is a Chrome profile: History, Cookies, Extensions, Preferences).
- [I] So Arc = native chrome + Chromium engine. Cra uses WKWebView instead (design choice, not a copy).

## Sidebar data model (StorableSidebar.json)
- [O] `sidebar.containers` = [ {global}, {spaces, topAppsContainerIDs, items} ]. Lists are flat [id, object, id, object...].
- [O] SpaceModel: id, title, profile, containerIDs = ["pinned", <id>, "unpinned", <id>], customInfo.iconType {emoji_v2, emoji},
  customInfo.windowTheme = blendedGradient { baseColors[2], overlayColors, modifiers{noiseFactor,intensityFactor,overlay:"grain"},
  wheel: analogous|complimentary, translucencyStyle light|dark } with appearanceBased light/dark variants, plus a
  semanticColorPalette (foregroundPrimary/Secondary/Tertiary, backgroundExtra, maxContrastColor...).
- [O] SidebarItem: id, parentID, title (null unless user renamed; custom title overrides page title), childrenIds[], isUnread,
  createdAt, originatingDevice, data = one of
  - tab { savedURL, savedTitle, savedMuteStatus, timeLastActiveAt, activeTabBeforeCreationID, referrerID?, liveItemID? }
  - list {} = folder (optional customInfo.iconType; optional automaticLiveFolderData for GitHub live folders)
  - itemContainer { containerType: topApps{profile} | spaceItems{spaceID} }
  - [O strings only] easel, splitView, arcDocument, tabGroup also exist.
- [O] Favorites = the "topApps" container, one per profile, shared by all spaces (StorableSidebar.topAppsContainerIDs).
- [O] Every space owns one pinned container and one unpinned ("Today") container; ordering = childrenIds; folders nest via parentID.
- [O] A pinned tab keeps savedURL/savedTitle as its home; strings: resetTab, resetCurrentTab, replacePinnedTab,
  PinnedTabNavigationProfile, renamePinnedTabsEnabled=1.
- [O] Section chrome: UnpinnedSectionDivider/Header (the line between pinned and Today), SidebarClearButton,
  SidebarTidyButton, SidebarPlusButton (new tab button with menu: newTab/newFolder/newEasel/newNote/newSpace),
  PinnedSectionExpansionState, spacesWithCollapsedPinnedSections.

## Window state (StorableWindows.json)
- [O] sidebarWidth 328, sidebarMode "anchored" (binary also has floating, hidden, collapsed), focusedSpaceID, lastFocusedSpaceID,
  expandedItems (folder expansion, per window), itemLastActiveDates, itemCreatedDates, splitViewState, windowContents.

## Spaces
- [O] SidebarDock = space switcher at the bottom (icons/emoji, tooltip), SidebarPagingContainer = horizontal paging between spaces,
  SpaceCreation view, SpaceStyleEditor (color pad, dial, color picker), SpaceIconPicker (emoji), SpaceManagement (reorder),
  focusNextSpace/previous, LinkRouting rules (URL match -> space or Little Arc), per-space profile.

## Archive (StorableArchiveItems.json)
- [O] { archivedAt, reason: manual|auto, source: space{id}|littleArc|standaloneSidebar|unknown, sidebarItem: <copy> }.
- [O] Auto-archive thresholds enum: twelveHours, twentyFourHours, sevenDays, thirtyDays (this Mac: sevenDays, per profile).
- [O] Actions: viewArchive, clearArchive, reopenClosedTab, resetSpace, archiveTab.

## Command bar (ARC_CommandBar.bundle + strings + StorableCommandBarAdditionalRanking.json)
- [O] Entry points: keyboardShortcutT, keyboardShortcutL, keyboardShortcutFocusSidebar, keyboardShortcutCommandOptionG,
  sidebarDoubleClick, sidebarNewTabButton, placeholderClick, littleArcPlaceholderClick, topbar, appMenu*,
  toggleBetweenTypeTravelAndCommandBar.
- [O] Result archetypes: tab (switch to open tab; carries customTitle), chromiumHistory, chromiumSearchWhatYouTyped,
  chromiumSearchSuggestion, chromiumNavigateWhatYouTyped, chromiumSearchHistory, chromiumNavigateSuggestion, chromiumBookmark,
  chromiumSearchOtherEngine, chromiumSearchCalculatorAnswer, topDomain (bundled popularDomains.json), typeTravel
  (menuItem:<id>, focusSpace:<id>, moveToFolder:<id>, openFolder<id>, webContentExtension:<name>), askGPTWhatYouTyped,
  siteSearch (scoped pill), staticQuerySuggestions.
- [O] Ranking signals: recentlySwitchedToTabs (last 10 switch times per tab), queriesToSelectedArchetype (typed prefix ->
  what the user picked, i.e. it learns), typeTravelUsage (frequency + last 15 executions), siteEngagementScore,
  fuzzySearchConfidence, hotWords match %, title/url match % and position, recency, importance, customTitlePrefix boost,
  veryRecentTabOrDocumentBoost, derankCurrentItemURL, dedupByTitleAndHostList (figma, notion, github, zoom...).
- [O] Type-travel triggers e.g. "Go to Sidebar Item 3" / "3. tab" / "3. item".
- [U] Weights of the ranking model (a CoreML tensor, CommandBarRankingTensor) are not recoverable statically.

## Key bindings (StorableKeyBindings.json + strings)
- [O] Action = {identifier, name}; binding = {keyEquivalent, deviceIndependentModifierFlags}, priority, typeTravelTriggers;
  user overrides persisted. item1..item9 = "Go to Sidebar Item N" with flags 1048576 (= Command).
- [O] Action identifiers: newTab, newWindow, newBlankWindow, newSpace, newFolder, newEasel, newNote, closeWindow, archiveTab,
  reopenClosedTab, pinTab, rename, duplicate, resetTab, addressBar, typeTravel, toggleSidebar, showSidebar, focusSidebar,
  toggleToolbar, focusNextSpace, nextTab, previousTab, selectNextTab, cycleNextTab, cycleTabForward, goBack, goForward,
  reloadPage, forceReloadPage, stopLoading, findNext, findPrevious, findAndReplace, zoomIn, zoomOut, resetZoom, fullscreen,
  readerMode, copyCurrentURL, viewArchive, clearArchive, viewHistory, viewDownloads, viewLibrary, viewPreferences,
  developerTools, inspectElements, viewSource, printPage, savePageAs, capturePage, captureFullPage, showLittleArc, peekEmail,
  addSplitView, removeSplitView, muteAllTabs, resetSpace, clearCookies, openTabIn, gptMessage, hideArc, hideOthers, minimize,
  quitArc, moveToSpace, moveToTopApps, removeFromTopApps, replacePinnedTab, renameCurrentTab, duplicateCurrentTab.
- [O] Default key equivalents read from the running Arc's menu bar through Accessibility (AXMenuItemCmdChar/
  AXMenuItemCmdModifiers, 24 Oct 2026). File: New Tab ⌘T, New Window ⌘N, Blank Window ⌃⌘N, New Incognito Window ⇧⌘N,
  New Little Arc Window ⌥⌘N, Restore Last Closed Tab ⇧⌘T, Open Command Bar ⌘L, New Easel ⌃⇧E, Close Window ⇧⌘W,
  Close Tab ⌘W, Capture ⇧⌘2, Save Page As ⇧⌘S, Print ⌘P. Edit: Copy URL ⇧⌘C, Copy URL as Markdown ⇧⌥⌘C,
  Copy URL as Quote ⌃⇧⌘C, Paste and Match Style ⇧⌘V, Find ⌘F, Find and Replace ⌥⌘F, Find Next ⌘G, Find Previous ⇧⌘G,
  Jump to Selection ⌘J. View: Hide Sidebar ⌘S, Hide Toolbar ⇧⌘D, Stop Loading ⌘., Refresh ⌘R, Force Refresh ⇧⌘R,
  Add Split View ⌃⇧=, Close Split Pane ⌃⇧-, Zoom Actual ⌘0, Zoom In ⌘+, Zoom Out ⌘-, View Source ⌥⌘U,
  Developer Tools ⌥⌘I, Inspect Elements ⌥⌘C, JavaScript Console ⌥⌘J, Enter Full Screen ⌃⌘F. Spaces: Next ⌥⌘→,
  Previous ⌥⌘←, space N ⌃N. Tabs: Pin/Unpin ⌘D, Next Tab ⌥⌘↓, Previous Tab ⌥⌘↑, Clear Today ⇧⌘K, Go to Tab N ⌘N,
  Toggle recent tabs ⌃Tab. Archive: Go Back ⌘[ (shown as ⌘Æ on a Danish layout) / ⌘←, Go Forward ⌘] / ⌘→,
  View History ⌘Y. Window: Minimize ⌘M, Open Library ⇧⌘L, View Downloads ⇧⌘J.

## Visual reference (Arc 1.168, measured at 2x from window captures)
- [O] Sidebar 328pt wide. Row 1: traffic lights, sidebar toggle right after them (~93pt), nav ← → ↻ right-aligned when a
  tab is selected and the toolbar shows the URL; with no tab the nav moves into the toolbar and the toolbar shows a
  centered "Search or Enter URL…". Favorites: 4 tiles, ~44pt tall, active tile gets a dashed outline. Space header: emoji +
  name, 13pt medium, secondary color. Rows 40pt pitch, 14pt titles, 16pt favicons, custom-titled/navigated pinned tabs show
  the host as an 11pt second line, folders use a blue folder glyph, nested rows indent ~18pt. Bottom row: library icon
  left, tiny space emoji centered (inactive dimmed), + right.
- [O] Content: rounded card inset ~8-10pt with the toolbar strip (42pt: lock + monospaced URL, copy link, extensions,
  capture, DevTools, sidebar toggle) on top; no card at all when no tab is selected.
- [O] Command bar: ~766pt wide, vertically centered, dark translucent in dark mode. Input row 60pt with the top match's
  favicon; rows 50pt single-line "Title — url"; the completion row comes first, then the typed query, then matches; open
  tabs show "Switch to Tab" + arrow box (other-space tabs show the space name); the selected row is tinted with the
  space color. ⌘L with the toolbar visible edits inline: dropdown hangs under the toolbar across the content width.

## Dia 1.54 (company.thebrowser.dia)
- [O] ~/Library/Application Support/Dia/StorableProfileContainers.json: containers per profile with `window` or
  `favorites` kinds; tabs[].contents[].variant = webContent{_0:{title,url}} | newTabPage. StorableAutoArchive.json:
  containers[].archivedTabs (empty here). Chromium profile at User Data/Profile 7 with Bookmarks whose bookmark-bar
  folders mirror Arc spaces ("Favorites", "Victor", "JYSK").

## Other observed features (not in Cra's first scope)
- Little Arc (LittleBrowser), Peek, Easels, Boosts, split view, hover cards, site control center, sidebar banners,
  sync via CloudKit + Firebase, Chromium extensions, "Tidy", Ask Arc.

## Rendering recipe fitted to Victor's Arc captures (24 Oct 2026)
- [O] Light "Victor" theme (isVibrant, intensity 0.25) renders as #93926A–#AA9470 on this desktop: gradient at 25% over the
  blurred desktop. Cra reproduces it with a behind-window NSVisualEffectView, a 22% white lift and gradient alpha = intensity.
- [O] Dark "JYSK" theme renders #292538 from base #01021F/#1A001F: about 27% of the colour over #2B2632.
- [O] Toolbar strip = first theme colour at 46% (#72601D), URL #E4E0D4 12pt monospaced starting 40pt from the card edge.
- [O] Title row centre 24pt (traffic lights at x 19/43/67, sidebar toggle at 93, nav ← → ↻⌄ at 236/270/299/314).
  Favorites tiles 70×47 with 8pt gaps, first row at y≈45. Space header centre y≈118, rows 41pt pitch, favicon centre x=26,
  text x=45. With no tab selected the content area is a faintly lighter card with a 40pt toolbar strip and a hairline.

## Calibration update, 24 Oct 2026 (afternoon)

Method that finally worked: put a full-screen solid window (white, then black) directly
behind each browser, capture the same screen region, and fit per channel
`out = c + k · backdrop`. `screencapture` output samples as sRGB (a solid #72601D window
reads back as #72601D), so no P3 conversion is needed. Window-id captures (`-l`) show
Arc's sidebar without its backdrop (equal to its inactive look) and include the window
shadow unless `-o` is passed.

Measured on the "Victor" theme (Arc base #F8D558 / #A4F454, overlay → #FF7567, intensity 0.25):

| | over white | over black |
|---|---|---|
| Arc sidebar, top | 206 200 160 | 124 118 77 |
| Arc sidebar, bottom | 212 181 141 | 154 124 82 |
| Cra (final) top | 199 192 152 | 124 117 76 |
| Cra (final) bottom | 213 184 142 | 154 125 82 |

Cra's recipe for light vibrant themes: `NSVisualEffectView` `.hudWindow`, dark appearance,
`state` driven explicitly from app activation (`.active` / `.inactive`; the key-window
heuristic left the blur half flat), no white lift while active, 0.75 lift while inactive.
Gradient top → bottom, stop opacity `intensity·1.8 → intensity·2.33`; stops from the Arc
theme: top = mix(mix(base0, base1, 0.15), white, 0.30), bottom =
mix(mix(base0, overlayEnd ?? base1, 0.30), white, 0.20). Over a dark backdrop Cra is within
2/255 of Arc at every height; over pure white the top is 7–8 darker (the HUD material
passes ~55 % of the backdrop, Arc's blur a little more). Dark vibrant themes keep the
earlier `.underWindowBackground` + 15 % lift calibration.

Toolbar band is opaque and theme-derived (same colour over any backdrop):
light = HSB(h, s + 0.10, v · 0.46) of the raw base colour (#F8D558 → #725F1D; Arc #72601D),
dark = HSB(h, s · 0.6, v · 0.8) (#010220 → #0A0B19; Arc #0E0B16). Pages with a
`theme-color` meta use that colour instead (Kildash #1A1917, Messenger white).

Other measured details: window buttons are muted grey discs (bg −10 %) until the pointer
reaches the sidebar's title row; favicons 16 pt centred 25.75 pt from the window edge; space
header 14 pt medium with no top padding above it; favorites tiles 72 × 47 with 8 pt margins
and gaps; the yellow/black dashed ring (2 pt, systemYellow, 6/6 black dashes) is Arc's
keyboard-focus indicator, shown on a tab chosen without the mouse (it appeared on every
tab selected through AppleScript, never on clicked ones). Host subtitles under pinned
tabs appear only when the tab left the pinned host (Phantom at /signin shows none); the
"Ahrefs / ahrefs.com" row in Arc stays unexplained (same host, same URL, loaded).

### DevTools docking (CEF 154 note)

`ShowDevTools` with a `SetAsChild` window info (which forces Alloy style on macOS) hits a
CHECK inside CEF 154 regardless of the parent view (tested with the real host and with a
hidden temp window). An Alloy-style top-level DevTools window works, so Cra creates that
hidden (`windowInfo.hidden`), then attaches CEF's window as a borderless child window over
the dock area and keeps its frame in sync from `ShellView.layoutContentChildren`. Moving the
DevTools NSView into Cra's window would be unsafe: CEF closes `view.window` when DevTools
closes.

### Measuring while the Mac is in use (lessons)

A TCC prompt left behind by a Cra instance launched from the agent's shell blocked every
GUI helper spawned from that shell (they never reached `applicationDidFinishLaunching`),
which silently invalidated three colour runs; `killall UserNotificationCenter` cleared it.
Run the app from ~/Applications (scripts/build.sh installs there) so no prompt appears.
Animations were verified with `screencapture -V` recordings and a per-frame difference
tool: space switch 11 consecutive 60 Hz frames, sidebar hide 10 frames with a fast start
and soft landing, command bar fade-in 7 frames; the 80 ms fade-out still lands in one frame.

### DevTools dock, final shape (24 Oct, evening)

Arc shows Chrome's docked DevTools (close button, device toggle, rounded card corner).
In CEF 154 the docked frontend (`can_dock=true`) reserves a 150 px "inspected page"
placeholder inside its own window and, after a second navigation, loses its target
connection (empty Elements panel, blue toolbar). Cra therefore keeps the undocked frontend
(fills the pane, stays connected) and injects a plain HTML close button after the ⋮ menu in
the main toolbar; that button and `InspectorFrontendHost.closeWindow()` reach the shell as a
console message, which calls `CloseDevTools()`. The CEF window is non-opaque with its right
corners masked to the card radius. Still missing versus Arc: the device-mode toggle, which
the frontend only offers when it can dock.

### Developer Mode, shortcuts, extensions (24 Oct, evening)

Arc's View ▸ Developer submenu (read via Accessibility): View Source ⌥⌘U, Developer Tools
⌥⌘I, Inspect Elements ⌥⌘C, JavaScript Console ⌥⌘J, "Turn off Developer Mode for this
site" ⌃D. ⇧⌘D is Hide Toolbar and ⌘D is Pin/Unpin Tab. Developer Mode is per site and
swaps the toolbar: default = nav buttons left, centred friendly URL (host bright, path dim)
behind a link glyph, sidebar toggle right; developer = lock + full monospace URL left,
copy/capture/DevTools/source icons right, nav buttons in the sidebar's title row. Cra
stores the hosts in `AppSettings.developerHosts`.

Extensions: CEF 154 has no extension API for Alloy-style browsers. A spike
(`cra://debug?chromeSpike=<url>`) proved the alternative: a Chrome-style Views window
(`CefWindow` + `CefBrowserView`, `GetChromeToolbarType = CEF_CTT_NONE`, frameless, runtime
style CHROME) attached as a child window over the content area loads unpacked extensions
from `~/Library/Application Support/Cra/Extensions/*` via `--load-extension` (an MV3
content script rendered its banner). Chrome style also docks DevTools natively. Moving the
page browsers to that hosting is the route to extensions; one Chrome-style window per tab.

## Split View (Arc 1.170.0, 24 Oct 2026, evening)

Method: REA CLI 6.4.0 `inspect-macho` (Evidence ev_84b238…, arm64 SHA-256 25af5f4e…) and `demangle-swift`
(ev_026c6350…); REA's `inspect-native-dispatch-metadata` refuses the 80 MB executable (64 MiB budget). The
model below comes from parsing the arm64 slice's Swift reflection metadata (`__swift5_types` /
`__swift5_fieldmd` / `__swift5_proto`, nominal types with their stored properties and enum cases) and
`otool -oV` Objective-C class data (selectors, ivars), plus the user's own
~/Library/Application Support/Arc/StorableSidebar.json (21 split items) and StorableWindows.json.
No decompiler, so property names and types are observed; the algorithms are inferred from them.

### Where it lives
- [O] Everything is in Arc's native Swift shell, not in Chromium. ArcCore (Chromium) only carries upstream
  Chrome's own `tabs.createSplit` / `splitViewId` extension API and "Cannot create split view with
  non-adjacent tabs" strings; the Arc UI never references them.
- [O] Generic engine: `ARCUI.SplitViewController: NSViewController` (module ARCUI, file
  ARCUI/SplitViewController.swift) with `SplitViewControllerLayout` (pure layout types) and
  `SplitViewContentPaneView`. It is NOT built on NSSplitView: no Arc class implements any
  `splitView:…` delegate selector (the NSSplitViewDelegate selectors in the binary are protocol metadata
  only). The one NSSplitView subclass, `WebContentViewControllerSplitView` (private to
  WindowContentViewController, overrides mouseDown/mouseUp/viewDidEndLiveResize, `onDidEndLiveResize`),
  is a per-pane inner split, not the pane layout. [I]
- [O] Arc-specific glue: `Arc.WindowContentsContainerViewController: XiblessViewController<NSView>`
  conforms to `SplitViewControllerDelegate`, owns one lazy `splitViewController`, a
  `LayoutConstraintsMap<SplitViewConstraintType>` (leading, trailing, top, bottom, minHeight) and a lazy
  `splitViewTopConstraint`. Each pane is an `Arc.WindowContentViewController` (conforms to
  `SplitViewContentPaneWithInsets`); an empty/drop pane is `SplitViewContentPlaceholderView` (NSView with
  `contentInsets`, a `BorderView` with `borderColor`, also `SplitViewContentPaneWithInsets`).
- [O] State is TCA (ComposableArchitecture): `Store<WindowState, WindowAction>` with view stores; feature
  modules WindowContents (`SplitViewState`, `SplitViewLayoutCache`, `WindowSplitViewLayout`,
  `WindowContentPresentationDisposition`), SharedWindowFeature (`WindowAction.SplitViewAction`),
  BaseModels (`SidebarSplitViewData`, `SplitViewPaneMenuOperation`), SidebarUI (`SplitViewCellState`).

### Data model
- [O] Sidebar: a split is a sidebar item like a folder. `SidebarItemData.splitView(SidebarSplitViewData)`
  with `itemWidthFactors: [Identifier<SidebarItem>: CGFloat]`, `layoutOrientation: horizontal|vertical`,
  `timeLastActiveAt: Date?`, `customInfo: { iconType: SidebarCustomIcon }?` (user icon, used together with
  the item `title` when renamed), `focusItemID: Identifier<SidebarItem>?`. The tabs are the item's
  `childrenIds` (order = pane order, left→right / top→bottom). JSON on this Mac:
  `{"data":{"splitView":{"itemWidthFactors":[<id>,0.3835,<id>,0.6165],"layoutOrientation":"horizontal",
  "focusItemID":<id>,"timeLastActiveAt":…,"customInfo":null}},"childrenIds":[…],"parentID":<container>,…}`.
  All 21 local splits: 2 children, horizontal, parent = a space's pinned/unpinned container (not inside
  folders here), title/customInfo never set. Untouched splits store a single factor `[firstChild, 0.5]`;
  after a drag both factors are stored and sum to 1.0. One zombie split with 0 children exists; the
  binary logs "Noticed zombie split view (without any children)" (`ZombieSplitSeenLocation`:
  rawUpdate/appliedChange/publishedValue) and repairs it on sync. [I] Missing factors = equal share of
  the remainder.
- [O] Window: `WindowContents.State { windowContents: [WindowContentID: WindowContent], splitViewState,
  modalWindowContentV2State, windowContentSidebarItemMap: BidirectionalMap<WindowContentID,
  Identifier<SidebarItem>> }`. `SplitViewState { windowContentIDs: OrderedSet<WindowContentID>,
  layoutOrientation, interactionState, focusedContentID }`; only `windowContentIDs` + `focusedContentID`
  are Codable (StorableWindows.json `splitViewState`), orientation and widths are rebuilt from the
  sidebar item. `InteractionState { activePaneEditStyles: Set<.dragAndDrop>, proposedWindowContentDropTarget:
  WindowContentID?, isResizingPanes }`. Legacy `SplitViewState_Legacy { windowContentIDs }`.
- [O] Per-window width cache: `WindowSplitViewLayout { paneWidths: [CGFloat] }` kept by
  `SplitViewLayoutCache { storeLayoutForWindowID, layoutForWindowID }` (a TCA DependencyKey) and
  handed to the view as `restorableSplitViewLayout`; `SplitViewWindowContentContext { numPanes,
  restorablePaneWidths: [CGFloat]?, splitViewLayoutOrientation }` is what the container passes to
  `SplitViewController`.
- [O] Container view state (`WindowContentsContainerViewController.ViewState`): `splitViewWindowContentIDs:
  OrderedSet<WindowContentID>`, `focusedContentID`, `splitViewLayoutOrientation`, `restorableSplitViewLayout`,
  `canDragOntoSplit`, `isDraggingToCreateSplitView`, `shouldShowInteractivePaneInsertionHandle`,
  `contentInsets`, `contentCornerRadius`, `hiddenScrimEdges`, `sidebarPresentation`.

### The layout engine (ARCUI.SplitViewController)
- [O] Properties: `draggerHandleWidth`, `draggerHandleHitTargetOutset`, `minimumPaneWidth`,
  `layoutOrientation`, `displayInteractivePaneInsertionDraggerHandle`, `allowInteractivePaneInsertion`,
  `verticalLayoutOrientationFromDragAllowed`, `shouldDisplayDraggerPaneForSecondaryAxis`,
  `isDragDropHapticFeedbackEnabled`, weak `delegate`, `contentPanes: OrderedDictionary<Identifier<ContentPane>,
  ContentPane>`, `paneResizeState?`, `dragDestinationState?`, `dragSourceState?`,
  `dragInfoSubject: PassthroughSubject<NSDraggingInfo, Never>`, lazy `minimumWidthConstraint`.
- [O] `SplitViewControllerLayout.ContentPane { id, view: NSView & SplitViewContentPane, trailingDraggerHandle,
  bottomDraggerHandle: DraggerHandle { view: NSView & SplitViewControllerDraggerHandleType }, widthFactor: CGFloat,
  resizeStyle: flexible|fixed, displayState: collapsed|expanded, inFlightTransition: StateTransition?,
  content: .dropRegion(NSView) | .viewController(SplitViewContentPaneContentViewController) }`.
  `StateTransition { identifier: UUID, targetState, style: .animated(removePaneOnCompletion: Bool) | .immediate,
  draggerHandleWidth: CGFloat? }`. `ContentPanePair { leading, trailing? }`.
- [O] `SplitViewControllerLayout.Context { contentPanes, containerSize, backingScaleFactor, minimumPaneWidth,
  draggerHandleWidth, displayInteractivePaneInsertionDraggerHandle, shouldDisplayDraggerPaneForSecondaryAxis,
  layoutOrientation, yAxisOriginAtTop }` → frames are a pure function of the context (pixel-snapped via
  backingScaleFactor). [I] Each pane gets `widthFactor × (container − handles)` along the main axis, clamped to
  `minimumPaneWidth`; every pane carries its own trailing (horizontal) and bottom (vertical) handle view, the
  last one hidden or used as the "insert a pane here" handle when `displayInteractivePaneInsertionDraggerHandle`.
- [O] Resize: `PaneResizeState { initialClickLocationInDragHandle: CGPoint, canSnapToCenter, isCenterSnapped }`
  driven by `handleDraggerPanGesture:` (NSPanGestureRecognizer) and `handleDraggerDoubleClickGesture:`
  (double-click a handle = reset to equal widths, [I]). Dragging snaps to the 50/50 centre when allowed.
  Pane add/remove animates via `StateTransition` (collapsed ↔ expanded, remove on completion).
- [O] Panes are hosted in `SplitViewContentPaneView: NSView { contentView, contentConstraints:
  LayoutConstraintsMap<NSLayoutConstraint.Attribute>, lockContentWidth: Bool, lockedContentAlignment:
  leading|center|trailing, userInteractionEnabled }` (overrides hitTest). [I] While a handle is being
  dragged the web content keeps its old width and is pinned to one edge instead of relayouting Chromium on
  every mouse move; `userInteractionEnabled=false` blocks the page from eating the drag.
  `WindowContentViewController` adds `ContentResizeMode { intrinsic, throttle, locked }`,
  `pendingResizeFrames`, `resizeTimer`, `lockedContentSize`, `contentResizeThrottleSubscription`; the
  container has `isAnimatingResize` and `ContentSizeThrottleFlags` (OptionSet).
- [O] Handles: Arc's `SplitViewDraggerHandleView: FlippedView` (vertical divider: lazy `handle` NSView pill,
  `backgroundView: WindowBackgroundContainerView?` so the space theme shows through the gap, `isHighlighted`,
  `draggableArea: NSTrackingArea`, `draggableRegion: CGRect`, `resetCursorRects`, mouseEntered/Exited,
  `contentAppearance`) with `ViewState { displayBackgroundView, windowBackgroundConfiguration,
  contentOverBackgroundAppearance, isHandleVisible, metalWindowBackgroundRenderingEnabled }`;
  `SplitViewBottomDraggerHandleView` for vertical layouts adds `handle: .dragger | .scrimLoader` and
  `isContentBelowLoading` (the handle doubles as a loading scrim). ARCUI ships a plain
  `SplitViewControllerDefaultDraggerHandleView`.

### Drag and drop (how a split is created with the mouse)
- [O] `SplitViewController` is both `NSDraggingSource` and `NSDraggingDestination` (draggingEntered/Updated/
  Exited/Ended, prepareForDragOperation, performDragOperation, wantsPeriodicDraggingUpdates,
  updateDraggingItemsForDrag, draggingSession:…). `DragSourceState { contentPaneID, initialIndex,
  initialWidthFactor, contentPaneSnapshot: NSImage?, contentPaneSize }` = reordering a pane by dragging its
  toolbar (snapshot image as drag preview). `DragDestinationState { operation: NSDragOperation,
  isDraggingInView, proposedTarget: DropTarget?, isDraggingContentPane }`.
- [O] `DropTarget = .replaceContent(index) | .insertContent(index)`; `ProposedDropTargetInfo { target,
  dropRegionInsertionIndex: Int?, existingDropRegion: ContentPane?, layoutOrientation }`. [I] Hovering near an
  edge inserts a temporary `.dropRegion` pane (placeholder view, animated open) at that index; hovering over
  the middle of a pane proposes replacing it; `verticalLayoutOrientationFromDragAllowed` lets a drop on the
  top/bottom edge flip the layout to vertical.
- [O] What can be dropped (`WindowContentsContainerViewController.SplitViewDragItem`): `.sidebarItem(id)`
  or `.url(URL)`. Actions: `onDropSidebarItem(itemID, target, layoutOrientation, maybeMoveDecision)`,
  `onDropURL(url, target, layoutOrientation)`, `onDidUpdateSplitViewProposedDropTarget(WindowContentID?)`,
  `onDidBegin/EndSplitViewInteractivePaneEditingWith(.dragAndDrop)`.
- [O] Sidebar side: dragging a tab over another tab's left/right half (`SidebarDropTargetRegion = left|right`,
  `TabSplitViewPosition = left|right`) shows `SplitDragPreviewView` (title, favicon, "tab info" and "empty"
  background containers) after `splitDropTargetDelaySatisfied`; dropping makes a split item. Flags:
  `drag-to-combine-tabs-into-split-enabled`, `sidebar-drag-to-split-preview-ui-enabled`, `win-drag-to-split-enabled`.
  Onboarding copy: "Drag a tab from your sidebar into the middle of the screen to create a Split View."

### Commands, menus, entry points
- [O] `WindowAction.SplitViewAction`: `addPanel(index: InsertionLocation, showCommandBar: Bool)`,
  `movePanel(from:to:)`, `onDropSidebarItem`, `onDropURL`, `onDidBeginWindowContentsSplitViewPaneResize`,
  `onDidEndWindowContentsSplitViewPaneResize(WindowSplitViewLayout)`, `onDidUpdateSplitViewProposedDropTarget`,
  `onPaneCreated(source)`, `onPaneClosed`, `onDidRestoreSplitViewState`, `containerDelegate(…)`,
  `panelAction(ContentToolbarAction)`. Container delegate: `onDidAddItemsToContainer`,
  `onDidMoveItemsWithinContainer`, `onDidRemoveItemsFromContainers(itemIDs)`, `onDidAdjustLayoutOrientation`.
- [O] Where a new pane goes: `WindowContentPresentationDisposition.splitView(SplitViewTarget)` with
  `.paneAtIndex(Int) | .newPane(InsertionLocation) | .pane(WindowContentID) | .replaceAllPanes |
  .firstEmptyOrNewPane`; `InsertionLocation = .index(Int) | .after(id) | .before(id) | .last | .afterFocusedPane`.
- [O] Pane menu (`SplitViewPaneMenuOperation`, each `.enabled|.disabled`): moveLeft, moveRight, addPaneLeft,
  addPaneRight, addPaneTop, addPaneBottom, separate, copyLink, flipLayoutOrientation. Toolbar menu items
  (`ContentPanelSplitViewMenuItemType`): move/add/separate/copyLink × horizontal/vertical, flipToVertical,
  flipToHorizontal. Sidebar context menu on a split: `childItem(id, .separateFromSplitView)`, `separateAllItems`,
  `addPanel`, `flipLayoutOrientation`. Toolbar hover actions: separate, close, addHorizontal, addVertical,
  move, copyLink (`split-view-actions-hover-button-enabled`).
- [O] Menu strings: "Add Vertical Split View", "New Bottom Split", "Add Bottom Split", "Convert to
  Horizontal/Vertical Split View", "Flip to horizontal/vertical split view", "Close Split View Pane", "Separate Tab
  from Split", "Remove Tab from Split View", "Open in Split View", "Add to Split View", "Share Split View",
  "Multitask with Split View", "Switch to next/previous Split View", "Jumps to the first…fourth Split View page".
  Type-travel candidates: AddLeft/Right/Top/BottomSplit, ConvertToHorizontal/VerticalSplitView,
  NewVerticalSplitViewPane. Key bindings (see above): Add Split View ⌃⇧=, Close Split Pane ⌃⇧−.
- [O] Entry sources tracked (`SplitViewEnteredSource`): plusButton, windowContent, dragAndDrop, menu,
  contextMenu, alternateClick (option-click a tab), typeTravel, tabCreation, easel, navigationBar, tabHoverMenu.
  Option-click on a split child's close button un-splits (`option-click-split-tab-close-button-to-unsplit-enabled`).
- [O] Limits: errors `splitViewMaximumPanesExceeded`, `splitViewTargetOutOfRange`,
  `unableToInsertSplitViewContainer`, `missingSplitViewContainer`; `ModalParentSplitState { parentIsSplitCompatible,
  numberOfPanels, maximumNumberOfPanels, layoutOrientation }`. [I] Max is 4 panes (shortcuts stop at "fourth").
  Toolbar `shouldShowSplitViewClose` only in a split; `maximizeCurrentSplitViewPane:` exists (notification token).

### Sidebar cell
- [O] `SplitViewCellView: SelectableCellView<SplitViewCellState>` with `SplitViewCellState { sidebarItemID,
  isCurrentItem, isContentVisible, isKeyDraggedItem, isHighlighted, isMultiSelected, shouldDim, canResetTab,
  layoutStyle: .childItems(OrderedDictionary<id, ChildItemState>) | .customInfo(CustomInfo), colorPalette,
  closeItemShortcut, lastUpdatedLocally, hasLeadingRecordingIndicator, dropTargetRegion?, closeButtonConfiguration,
  closeButtonAction, shouldPerformUserAttentionAnimation }`. `ChildItemState { itemID, iconType: FaviconType?,
  title, isGroupSelected, isRecording, closeButtonConfiguration, optionClickSplitTabCloseButtonToUnsplitEnabled,
  newSplitSeparationMechanismsEnabled }`. `CustomInfo { title, isEditingTitle, icon: .childItemCount(Int) |
  .customIcon(SidebarCustomIcon) }`.
- [O] Views: `SplitViewCellChildrenContainerView` (one `SplitViewCellChildItemView` per tab, `separatorLayers:
  [CALayer]` between them, `isGroupHovered`, `InsetSpec { defaultInset, extendedInset }`), each child with
  favicon + title + its own close button and recording dot; renamed splits show `SplitViewCellCustomInfoView`
  (icon or item-count badge `SplitViewCellItemCountIconView`, editable title, hover subtitle). Icons:
  icon-split-add-left/right/top/bottom, icon-split-horizontal/vertical, icon-split-move-*, icon-separate-from-split,
  icon-split-share-*, icon-split-x; colour asset SplitViewLeftBackground.

### Plan for Cra (design, not observation)
1. Model: add `ItemData.split(SplitData)` to SidebarModel with `widthFactors: [UUID: Double]`,
   `orientation`, `focusTabID`; children = the pane tabs (reuse `childrenIds`/`parentID` like folders). Store
   per-window `splitState { paneTabIDs, focusedTabID }` in WindowPrefs; rebuild widths from the item.
2. Engine: a `SplitPaneLayout` value type (panes with widthFactor, min width, handle width, orientation,
   pixel snap) → frames; a `SplitContainerView` in ShellView's `webContainer` that owns one pane view and one
   handle view per visible tab. Cra's CEF browsers are child windows positioned by
   `MainWindowController.positionPageWindows`, so each pane needs its own screen rect: change
   `BrowserManager.show` to a set of visible tabs and `onWebFrame` to deliver per-tab rects.
3. Resize: pan on the handle updates factors; during the drag freeze each page window's size (Cra already
   has `frozenWebBounds`) and only move it, resize once on mouse-up (Arc's lockContentWidth/throttle);
   double-click = equal widths; snap at 50/50.
4. Creation: ⌃⇧= adds an empty pane (placeholder with dashed border + command bar); drag a sidebar tab onto
   the content card: edges insert, centre replaces; option-click a tab adds it as a pane; context menu
   "Open in Split View"; "Separate", "Flip orientation", "Close pane".
5. Sidebar: a grouped row showing each pane's favicon+title with hairline separators, group selection
   highlight, per-child close, rename → icon/count badge.
