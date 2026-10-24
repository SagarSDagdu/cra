import AppKit
import CraCEF
import SwiftUI

@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate, BrowserManagerDelegate {
    unowned let app: AppDelegate
    var store: SidebarStore { app.store }
    let sidebarUI = SidebarUIState()
    let sidebarActions = SidebarActions()
    let overlay = OverlayState()
    let commandBar: CommandBarController
    private(set) var browsers: BrowserManager!
    private(set) var shell: ShellView!
    private var commandPanel: CommandBarPanel!
    private var commandHost: NSHostingView<AnyView>!
    private var spaceEditor: NSWindow?
    private var importPanel: NSWindow?
    private var scrollMonitor: Any?
    private var swipeX: CGFloat = 0
    private var swipeY: CGFloat = 0
    private var swipeFired = false
    private var enteredFullscreenForContent = false
    private var lastSidebarVisible = true
    private var lastSidebarWidth: CGFloat = 0
    private var commandBarOpenedAt = Date.distantPast
    private var commandObserving = false

    var currentBrowser: CraBrowser? { browsers.visibleRuntime?.browser }

    init(app: AppDelegate) {
        self.app = app
        commandBar = CommandBarController(engine: app.engine, store: app.store)
        let frame = app.store.prefs.windowFrame.map { NSRectFromString($0) } ?? NSRect(x: 0, y: 0, width: 1400, height: 880)
        let window = CraWindow(contentRect: frame,
                               styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                               backing: .buffered, defer: false)
        super.init(window: window)
        window.delegate = self
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 640, height: 420)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.title = "Cra"
        if app.store.prefs.windowFrame == nil { window.center() }

        let store = app.store
        let palette = store.focusedSpace.theme.palette
        let env: (AnyView) -> AnyView = { v in
            AnyView(v.environment(store).environment(self.sidebarUI).environment(app.favicons).environment(\.sidebarActions, self.sidebarActions))
        }
        shell = ShellView(frame: window.contentView!.bounds,
                          background: SpaceBackground(palette: palette),
                          sidebar: env(AnyView(SidebarRootView())),
                          toolbar: env(AnyView(ContentToolbarView(palette: palette))),
                          placeholder: AnyView(EmptyContentView(space: store.focusedSpace)),
                          status: AnyView(StatusBubble(overlay: overlay)),
                          toasts: AnyView(ToastStack(overlay: overlay)),
                          find: AnyView(FindBar(overlay: overlay, onFind: { [weak self] q, fwd, next in self?.find(q, forward: fwd, next: next) },
                                                onClose: { [weak self] in self?.hideFindBar() })))
        shell.sidebarWidth = CGFloat(store.prefs.sidebarWidth)
        shell.sidebarVisible = store.prefs.sidebarVisible
        shell.showToolbar = store.settings.showToolbar
        lastSidebarVisible = store.prefs.sidebarVisible
        lastSidebarWidth = CGFloat(store.prefs.sidebarWidth)
        window.contentView = shell
        window.backgroundColor = NSColor(palette.gradientColors.first ?? .gray)

        browsers = BrowserManager(store: store, favicons: app.favicons, container: shell.webContainer)
        browsers.delegate = self

        commandPanel = CommandBarPanel()
        commandHost = NSHostingView(rootView: AnyView(CommandBarView(controller: commandBar).environment(app.favicons)))
        commandPanel.contentView = commandHost
        commandPanel.delegate = self

        wireActions()
        shell.resizeHandle.onDrag = { [weak self] dx in
            guard let self else { return }
            let w = min(max(CraMetrics.sidebarMinWidth, shell.sidebarWidth + dx), CraMetrics.sidebarMaxWidth)
            shell.sidebarWidth = w
            shell.layoutSubtreeIfNeeded()
        }
        shell.resizeHandle.onEnd = { [weak self] in
            guard let self else { return }
            store.prefs.sidebarWidth = Double(shell.sidebarWidth)
            lastSidebarWidth = shell.sidebarWidth
        }
        shell.onEdgeHover = { [weak self] show in self?.setFloatingSidebar(show) }

        installSwipeMonitor()
        observeStore()
        refresh()
        shell.onDevToolsFrame = { [weak self] rect in self?.positionDevToolsWindow(rect) }
        shell.onWebFrame = { [weak self] rect in self?.positionPageWindows(rect) }
        shell.onAnimateWebFrame = { [weak self] rect, d in self?.animatePageWindows(to: rect, duration: d) }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.shell.windowActive = true }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.shell.windowActive = false }
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: Wiring

    private func wireActions() {
        sidebarActions.titleBarDoubleClick = { [weak self] in (self?.window as? CraWindow)?.performTitleDoubleClickAction() }
        sidebarActions.openCommandBar = { [weak self] mode in self?.openCommandBar(mode) }
        sidebarActions.closeTab = { [weak self] id in self?.closeTab(id) }
        sidebarActions.goBack = { [weak self] in self?.currentBrowser?.goBack() }
        sidebarActions.goForward = { [weak self] in self?.currentBrowser?.goForward() }
        sidebarActions.reload = { [weak self] in
            guard let b = self?.currentBrowser else { return }
            b.isLoading ? b.stopLoading() : b.reload()
        }
        sidebarActions.editSpace = { [weak self] s in self?.showSpaceEditor(space: s) }
        sidebarActions.toggleSidebar = { [weak self] in self?.toggleSidebar() }
        sidebarActions.showArchive = { [weak self] in self?.app.showArchiveWindow() }
        sidebarActions.resetPinnedTab = { [weak self] id in self?.resetPinnedTab(id) }
        sidebarActions.openURL = { [weak self] url in self?.store.createTab(url: url) }
        sidebarActions.performAction = { [weak self] id in
            if id.hasPrefix("muteTab:"), let uuid = UUID(uuidString: String(id.dropFirst(8))) {
                let muted = self?.store.item(uuid)?.tab?.muted ?? false
                self?.browsers.runtime(for: uuid)?.browser.setAudioMuted(muted)
            } else {
                self?.app.perform(id)
            }
        }
        commandBar.onCommit = { [weak self] s, typed, mode, force in self?.handleCommit(s, typed: typed, mode: mode, forceNewTab: force) }
        commandBar.onClose = { [weak self] in self?.hideCommandPanel() }
        commandBar.spaceName = { [weak self] id in self?.store.space(id)?.title ?? "" }
    }

    // MARK: Observation

    private func observeStore() {
        withObservationTracking {
            _ = store.revision
            _ = store.prefs
            _ = store.settings
            _ = store.spaces
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refresh()
                self?.observeStore()
            }
        }
    }

    func refresh() {
        let space = store.focusedSpace
        let palette = space.theme.palette
        shell.backgroundHost.rootView = SpaceBackground(palette: palette)
        shell.toolbarHost.rootView = AnyView(ContentToolbarView(palette: palette)
            .environment(store).environment(sidebarUI).environment(app.favicons).environment(\.sidebarActions, sidebarActions))
        shell.placeholderHost.rootView = AnyView(EmptyContentView(space: space))
        window?.appearance = NSAppearance(named: palette.isDark ? .darkAqua : .aqua)
        // Vibrant themes see through to the desktop like Arc; others are opaque.
        shell.vibrancy.isHidden = !palette.vibrant
        shell.vibrancyLift.isHidden = !palette.vibrant
        shell.vibrantDark = palette.isDark
        shell.refreshLift()
        window?.isOpaque = !palette.vibrant
        window?.backgroundColor = palette.vibrant ? .clear : NSColor(palette.gradientColors.first ?? .gray)

        browsers.pruneMissingTabs()
        let selected = store.selectedTabID
        if selected != browsers.visibleTabID || (selected != nil && browsers.runtime(for: selected!) == nil) {
            browsers.show(selected, focus: !commandBar.isOpen)
        }
        shell.hasTab = selected != nil
        shell.showToolbar = store.settings.showToolbar
        shell.placeholderHost.isHidden = selected != nil
        shell.layoutContentChildren()
        syncSidebarUI()
        window?.title = store.selectedTab?.displayTitle ?? space.title

        if store.prefs.sidebarVisible != lastSidebarVisible {
            lastSidebarVisible = store.prefs.sidebarVisible
            shell.animateSidebar(visible: lastSidebarVisible, floating: false, fullscreen: shell.contentFullscreen, width: shell.sidebarWidth)
        }
        if CGFloat(store.prefs.sidebarWidth) != lastSidebarWidth {
            lastSidebarWidth = CGFloat(store.prefs.sidebarWidth)
            shell.sidebarWidth = lastSidebarWidth
        }
    }

    private func syncSidebarUI() {
        sidebarUI.loadedTabIDs = Set(browsers.runtimes.keys)
        let b = browsers.visibleRuntime?.browser
        sidebarUI.canGoBack = b?.canGoBack ?? false
        sidebarUI.canGoForward = b?.canGoForward ?? false
        sidebarUI.isLoading = b?.isLoading ?? false
        sidebarUI.pageThemeColor = browsers.visibleRuntime?.themeColor ?? ""
        for (id, rt) in browsers.runtimes { sidebarUI.progress[id] = rt.progress }
    }

    // MARK: BrowserManagerDelegate

    func browserManagerDidUpdate(_ tabID: UUID) {
        syncSidebarUI()
        if tabID == browsers.visibleTabID { window?.title = store.item(tabID)?.displayTitle ?? "Cra" }
    }

    func browserManager(statusMessage: String) {
        overlay.status = statusMessage
        shell.statusVisible = !statusMessage.isEmpty
        shell.layoutContentChildren()
    }

    func browserManager(download: CraDownloadInfo) {
        let name = (download.fullPath as NSString).lastPathComponent.isEmpty ? download.suggestedName : (download.fullPath as NSString).lastPathComponent
        let toast = DownloadToast(id: download.identifier, name: name, percent: download.percent, state: download.state.rawValue, path: download.fullPath)
        if let i = overlay.toasts.firstIndex(where: { $0.id == toast.id }) { overlay.toasts[i] = toast } else { overlay.toasts.append(toast) }
        shell.toastCount = overlay.toasts.count
        overlayPanel?.ignoresMouseEvents = overlay.toasts.isEmpty && !overlay.findVisible
        shell.layoutContentChildren()
        if download.state != .inProgress {
            let id = toast.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                guard let self else { return }
                self.overlay.toasts.removeAll { $0.id == id }
                self.shell.toastCount = self.overlay.toasts.count
                self.shell.layoutContentChildren()
            }
        }
    }

    func browserManager(fullscreen: Bool, tabID: UUID) {
        guard let window else { return }
        shell.contentFullscreen = fullscreen
        if fullscreen, !window.styleMask.contains(.fullScreen) {
            enteredFullscreenForContent = true
            window.toggleFullScreen(nil)
        } else if !fullscreen, enteredFullscreenForContent, window.styleMask.contains(.fullScreen) {
            enteredFullscreenForContent = false
            window.toggleFullScreen(nil)
        }
    }

    /// CEF owns the DevTools window (embedding in our NSView trips a Chromium CHECK on macOS).
    /// DevTools docks inside the content card (Chrome's default), to the right of the page.
    func browserManagerDevToolsHost(for tabID: UUID) -> NSView? {
        shell.devToolsVisible = true
        shell.needsLayout = true
        shell.layoutSubtreeIfNeeded()
        return shell.devToolsHost
    }

    // MARK: Chrome-style page windows

    private var overlayPanel: NSPanel?
    private var lastWebRectInWindow: NSRect = .zero

    private func ensureOverlayPanel() {
        guard overlayPanel == nil, let window else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.contentView = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        shell.moveOverlays(to: panel.contentView!)
        window.addChildWindow(panel, ordered: .above)
        overlayPanel = panel
    }

    /// Attaches the visible tab's Chrome window over the page area, hides the others.
    func browserManagerPageWindowsChanged(focus: Bool) {
        guard let window else { return }
        ensureOverlayPanel()
        let visible = browsers.visibleRuntime?.hostWindow
        for rt in browsers.runtimes.values {
            guard let w = rt.hostWindow else { continue }
            if w !== visible { if w.isVisible { w.orderOut(nil) }; continue }
            if w.parent !== window {
                w.styleMask.insert(.fullSizeContentView)
                w.titlebarAppearsTransparent = true
                w.titleVisibility = .hidden
                w.isMovable = false
                w.hasShadow = false
                w.isOpaque = false
                w.backgroundColor = .clear
                if let cv = w.contentView {
                    cv.wantsLayer = true
                    cv.layer?.cornerRadius = CraMetrics.contentCornerRadius
                    cv.layer?.cornerCurve = .continuous
                    cv.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
                    cv.layer?.masksToBounds = true
                }
                window.addChildWindow(w, ordered: .above)
            }
            positionPageWindows(lastWebRectInWindow)
            w.orderFront(nil)
            if focus { w.makeKey() }
        }
        // Keep the overlay panel above the page windows.
        if let panel = overlayPanel {
            window.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
            panel.orderFront(nil)
        }
    }

    private func positionPageWindows(_ rectInWindow: NSRect) {
        guard let window, !rectInWindow.isEmpty else { return }
        lastWebRectInWindow = rectInWindow
        let onScreen = window.convertToScreen(rectInWindow)
        for rt in browsers.runtimes.values {
            if let w = rt.hostWindow, w.frame != onScreen { w.setFrame(onScreen, display: true) }
        }
        if let panel = overlayPanel, panel.frame != onScreen { panel.setFrame(onScreen, display: true) }
    }

    private func animatePageWindows(to rectInWindow: NSRect, duration: TimeInterval) {
        guard let window, let w = browsers.visibleRuntime?.hostWindow else { return }
        lastWebRectInWindow = rectInWindow
        let onScreen = window.convertToScreen(rectInWindow)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.85, 0.25, 1)
            w.animator().setFrame(onScreen, display: true)
            overlayPanel?.animator().setFrame(onScreen, display: true)
        }
    }

    /// Docks the visible tab's DevTools window (CEF-owned, borderless) over the
    /// dock area as a child window; other tabs' DevTools windows are hidden.
    func browserManagerDevToolsChanged() {
        guard let window else { return }
        let visible = browsers.visibleDevToolsWindow
        for (_, view) in browsers.devToolsViews {
            if let w = view.window, w !== visible { w.orderOut(nil) }
        }
        shell.devToolsVisible = visible != nil
        shell.needsLayout = true
        shell.layoutSubtreeIfNeeded()
        guard let w = visible else { return }
        if w.parent !== window {
            // CEF made a normal titled window; strip its chrome so only the DevTools content shows.
            w.styleMask.insert(.fullSizeContentView)
            w.styleMask.remove([.closable, .miniaturizable])
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            for type in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { w.standardWindowButton(type)?.isHidden = true }
            w.hasShadow = false
            w.isMovable = false
            w.isMovableByWindowBackground = false
            // Round the right-hand corners to the card radius; the left edge meets the divider.
            w.isOpaque = false
            w.backgroundColor = .clear
            if let cv = w.contentView {
                cv.wantsLayer = true
                cv.layer?.cornerRadius = CraMetrics.contentCornerRadius
                cv.layer?.cornerCurve = .continuous
                cv.layer?.maskedCorners = [.layerMaxXMaxYCorner, .layerMaxXMinYCorner]
                cv.layer?.masksToBounds = true
            }
            window.addChildWindow(w, ordered: .above)
        }
        positionDevToolsWindow(shell.contentContainer.convert(shell.devToolsHost.frame, to: nil))
        w.orderFront(nil)
    }


    private func positionDevToolsWindow(_ rectInWindow: NSRect) {
        guard let window, let w = browsers.visibleDevToolsWindow else { return }
        let onScreen = window.convertToScreen(rectInWindow)
        if w.frame != onScreen { w.setFrame(onScreen, display: true) }
        if let cv = w.contentView, let id = browsers.visibleTabID, let v = browsers.devToolsViews[id], v.frame != cv.bounds {
            v.frame = cv.bounds
        }
    }

    func browserManagerHandleKey(_ event: NSEvent) -> Bool { app.handleReservedKey(event) }
    func browserManagerHandleUnhandledKey(_ event: NSEvent) -> Bool { app.handleUnhandledKey(event) }
    /// A hidden page asked for focus: the Picture in Picture window's "back to tab" button.
    func browserManagerFocusedBrowser(_ tabID: UUID) {
        guard tabID != browsers.visibleTabID, browsers.runtime(for: tabID)?.browser.isInPictureInPicture == true else { return }
        store.selectTab(tabID)
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func browserManagerOpenInternalURL(_ url: String) {
        if let u = URL(string: url) { app.handleInternalURL(u) }
    }

    // MARK: Tabs

    func closeCurrentTab() {
        guard let id = store.selectedTabID else { return }
        closeTab(id)
    }

    /// Today tabs are archived. Pinned tabs and favorites stay; they unload
    /// and return to their pinned page (Arc's close-on-pinned behaviour).
    func closeTab(_ id: UUID) {
        guard let item = store.item(id), item.isTab else { return }
        if store.isPinned(id) {
            let wasSelected = store.selectedTabID == id
            _ = store.resetPinnedTab(id)
            browsers.unload(id)
            if wasSelected {
                let back = item.tab?.activeTabBeforeCreationID
                if let back, store.item(back)?.isTab == true, store.spaceID(ofItem: back) == store.focusedSpaceID {
                    store.selectTab(back)
                } else {
                    store.selectTab(nil)
                }
            }
        } else {
            store.archiveTab(id, reason: .manual)
        }
    }

    func resetPinnedTab(_ id: UUID) {
        guard let home = store.resetPinnedTab(id) else { return }
        browsers.runtime(for: id)?.browser.loadURL(home)
    }

    func cycleTab(_ delta: Int) {
        let tabs = store.visibleTabs(in: store.focusedSpaceID)
        guard !tabs.isEmpty else { return }
        let idx = store.selectedTabID.flatMap { id in tabs.firstIndex { $0.id == id } } ?? -1
        let n = tabs.count
        store.selectTab(tabs[((idx + delta) % n + n) % n].id)
    }

    func zoom(by delta: Double) {
        guard let b = currentBrowser else { return }
        b.setZoomLevel(b.zoomLevel() + delta)
    }

    /// Arc's Capture: save a PNG of the page area to ~/Downloads.
    func capturePage() {
        guard let window else { return }
        let rectInWindow = shell.webContainer.convert(shell.webContainer.bounds, to: nil)
        var screenRect = window.convertToScreen(rectInWindow)
        // CGWindowList uses top-left origin.
        if let screen = NSScreen.screens.first {
            screenRect.origin.y = screen.frame.height - screenRect.maxY
        }
        let captureWindow = browsers.visibleRuntime?.hostWindow ?? window
        guard let image = CGWindowListCreateImage(screenRect, .optionIncludingWindow, CGWindowID(captureWindow.windowNumber), [.bestResolution]) else { return }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cra Capture \(f.string(from: Date())).png")
        try? png.write(to: url)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    // MARK: Sidebar

    func toggleSidebar() {
        store.prefs.sidebarVisible.toggle()
        if !store.prefs.sidebarVisible { setFloatingSidebar(false) }
    }

    private func setFloatingSidebar(_ show: Bool) {
        guard !store.prefs.sidebarVisible, shell.floatingSidebar != show else { return }
        shell.animateSidebar(visible: false, floating: show, fullscreen: shell.contentFullscreen, width: shell.sidebarWidth, duration: 0.18)
    }

    private func installSwipeMonitor() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, event.window === self.window, self.shell.sidebarVisible || self.shell.floatingSidebar else { return event }
            let p = self.shell.convert(event.locationInWindow, from: nil)
            guard self.shell.sidebarHost.frame.contains(p) else { return event }
            switch event.phase {
            case .began:
                self.swipeX = 0; self.swipeY = 0; self.swipeFired = false
            case .changed:
                self.swipeX += event.scrollingDeltaX
                self.swipeY += event.scrollingDeltaY
                if !self.swipeFired, abs(self.swipeX) > 70, abs(self.swipeX) > abs(self.swipeY) * 1.5 {
                    self.swipeFired = true
                    self.store.focusSpace(offset: self.swipeX < 0 ? 1 : -1)
                }
            default: break
            }
            return event
        }
    }

    // MARK: Command bar

    private var commandBarAttached: Bool {
        commandBar.mode == .editURL && store.settings.showToolbar && store.selectedTab != nil && store.prefs.sidebarVisible
    }

    func openCommandBar(_ mode: CommandBarMode) {
        guard let window else { return }
        let prefill = mode == .editURL ? store.selectedTab?.tab?.url : nil
        let effectiveMode: CommandBarMode = (mode == .editURL && store.selectedTab == nil) ? .newTab : mode
        commandBar.highlight = store.focusedSpace.theme.palette.commandHighlight
        commandBar.focusedSpaceID = store.focusedSpaceID
        commandBar.open(mode: effectiveMode, prefill: prefill)
        commandBar.attached = commandBarAttached
        commandBar.panelWidth = commandBarAttached ? shell.contentContainer.frame.width : min(CraMetrics.commandBarWidth, window.frame.width - 80)
        commandPanel.appearance = nil
        positionCommandPanel()
        if commandPanel.parent == nil { window.addChildWindow(commandPanel, ordered: .above) }
        commandBarOpenedAt = Date()
        NSApp.activate(ignoringOtherApps: true)
        // Key immediately (typing never waits); CommandBarView fades itself in.
        commandPanel.makeKeyAndOrderFront(nil)
        observeCommandBar()
    }

    private func observeCommandBar() {
        guard !commandObserving else { return }
        commandObserving = true
        withObservationTracking {
            _ = commandBar.result.items.count
            _ = commandBar.isOpen
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.commandObserving = false
                guard let self, self.commandBar.isOpen else { return }
                self.positionCommandPanel()
                self.observeCommandBar()
            }
        }
    }

    private func positionCommandPanel() {
        guard let window else { return }
        let rows = commandBar.result.items.count
        let h = CommandBarView.height(forRows: rows)
        let w = commandBar.panelWidth
        let wf = window.frame
        if commandBar.attached {
            // Hang off the toolbar: same x and width as the content card.
            let cardInWindow = shell.convert(shell.contentContainer.frame, to: nil)
            let cardOnScreen = window.convertToScreen(cardInWindow)
            commandPanel.setFrame(NSRect(x: cardOnScreen.minX, y: cardOnScreen.maxY - h, width: w, height: h), display: true)
        } else {
            // Arc centers the bar in the window.
            let x = wf.midX - w / 2
            let y = wf.midY - h / 2 + 40
            commandPanel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        }
    }

    private func hideCommandPanel() {
        if commandPanel.parent != nil { window?.removeChildWindow(commandPanel) }
        let panel = commandPanel!
        // Let CommandBarView's fade-out (0.08 s) play before the panel goes away.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.09) { [weak self] in
            guard let self, !self.commandBar.isOpen else { return }
            panel.orderOut(nil)
        }
        window?.makeKeyAndOrderFront(nil)
        currentBrowser?.setFocused(true)
    }

    private func handleCommit(_ s: Suggestion?, typed: String, mode: CommandBarMode, forceNewTab: Bool) {
        let query = commandBar.query
        func open(_ url: String) {
            store.recordQuerySelection(query: query, url: url)
            if mode == .editURL && !forceNewTab, let id = store.selectedTabID {
                store.updateTab(id, url: url)
                if let rt = browsers.ensureRuntime(for: id) { rt.browser.loadURL(url) } else { refresh() }
                browsers.show(id, focus: true)
            } else {
                store.createTab(url: url)
            }
        }
        guard let s else {
            if typed.isEmpty { return }
            open(SuggestionEngine.looksLikeURL(typed) ? SuggestionEngine.urlFromInput(typed) : store.settings.searchEngine.searchURL(typed))
            return
        }
        switch s.kind {
        case .switchToTab(let id):
            store.recordQuerySelection(query: query, url: s.url ?? "")
            store.selectTab(id)
        case .archived(let id):
            store.restoreArchived(id)
        case .navigate:
            let url = typed == commandBar.query ? (s.url ?? SuggestionEngine.urlFromInput(typed)) : SuggestionEngine.urlFromInput(typed)
            open(url)
        case .search:
            open(s.url ?? store.settings.searchEngine.searchURL(typed))
        case .history, .topDomain:
            open(s.url ?? "")
        case .command(let id):
            app.perform(id)
        case .switchSpace(let id):
            store.focusSpace(id)
        case .moveToSpace(let id):
            if let t = store.selectedTabID { store.moveTab(t, toSpace: id) }
        case .moveToFolder(let id):
            if let t = store.selectedTabID { store.moveItem(t, to: id, index: nil) }
        }
    }

    // MARK: Find

    func showFindBar() {
        overlay.findVisible = true
        overlay.findFocusToken += 1
        shell.findVisible = true
        overlayPanel?.ignoresMouseEvents = false
        overlayPanel?.makeKeyAndOrderFront(nil)
        shell.layoutContentChildren()
        window?.makeFirstResponder(shell.findHost)
    }

    func hideFindBar() {
        overlay.findVisible = false
        shell.findVisible = false
        overlayPanel?.ignoresMouseEvents = overlay.toasts.isEmpty
        currentBrowser?.stopFinding(true)
        shell.layoutContentChildren()
        currentBrowser?.setFocused(true)
    }

    func findNext(forward: Bool) {
        if !overlay.findVisible { showFindBar(); return }
        find(overlay.findQuery, forward: forward, next: true)
    }

    private func find(_ q: String, forward: Bool, next: Bool) {
        guard let b = currentBrowser else { return }
        if q.isEmpty { b.stopFinding(true); return }
        b.findText(q, forward: forward, matchCase: false, findNext: next)
    }

    // MARK: Sheets

    func showSpaceEditor(space: Space?) {
        guard let window else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
        let view = SpaceEditorView(existing: space, onSave: { [weak self, weak panel] title, emoji, theme in
            guard let self else { return }
            if var s = space {
                s.title = title; s.emoji = emoji; s.theme = theme
                self.store.updateSpace(s)
            } else {
                self.store.createSpace(title: title, emoji: emoji, theme: theme)
            }
            if let panel { window.endSheet(panel) }
        }, onCancel: { [weak panel] in if let panel { window.endSheet(panel) } })
        panel.contentView = NSHostingView(rootView: view)
        spaceEditor = panel
        window.beginSheet(panel) { [weak self] _ in self?.spaceEditor = nil }
    }

    func showImport() {
        guard let window, importPanel == nil else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 360), styleMask: [.titled], backing: .buffered, defer: false)
        let view = ImportView(onDone: { [weak self, weak panel] in if let panel { window.endSheet(panel) }; self?.importPanel = nil })
            .environment(store).environment(app.favicons)
        panel.contentView = NSHostingView(rootView: view)
        importPanel = panel
        window.beginSheet(panel) { [weak self] _ in self?.importPanel = nil }
    }

    /// Close whatever transient UI is up (used by cra://dismiss for scripting).
    func dismissTransientUI() {
        if let sheet = window?.attachedSheet { window?.endSheet(sheet) }
        importPanel = nil
        commandBar.close()
        if overlay.findVisible { hideFindBar() }
    }

    // MARK: NSWindowDelegate

    func windowDidResize(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        shell.needsLayout = true
        browsers.layoutVisible()
        if commandBar.isOpen { positionCommandPanel() }
        saveFrame()
    }

    func windowDidMove(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        if commandBar.isOpen { positionCommandPanel() }
        saveFrame()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if (notification.object as? NSWindow) === window { shell.windowActive = true }
    }

    func windowDidResignKey(_ notification: Notification) {
        guard (notification.object as? NSWindow) === commandPanel, commandBar.isOpen else { return }
        if Date().timeIntervalSince(commandBarOpenedAt) < 0.6 {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.commandBar.isOpen else { return }
                self.commandPanel.makeKeyAndOrderFront(nil)
            }
            return
        }
        commandBar.close()
    }

    func windowDidEnterFullScreen(_ notification: Notification) { shell.needsLayout = true }
    func windowDidExitFullScreen(_ notification: Notification) {
        if shell.contentFullscreen { shell.contentFullscreen = false }
        enteredFullscreenForContent = false
        shell.needsLayout = true
    }

    private func saveFrame() {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        store.prefs.windowFrame = NSStringFromRect(window.frame)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === window { commandBar.close() }
        return true
    }
}


/// Window with Arc's taller title row: the traffic lights sit 24pt from the top
/// and, like Arc, stay hidden until the pointer reaches the sidebar's title row.
final class CraWindow: NSWindow {
    var trafficLightsRevealed = false {
        didSet { if oldValue != trafficLightsRevealed { updateTrafficLightAlpha(animated: true) } }
    }

    /// The real title bar is hidden under the content, so double-clicks on the
    /// header strip never reach AppKit's zoom handling. The SwiftUI header rows
    /// call this on a double-click of their empty parts; it performs the system
    /// "double-click a window's title bar" action from System Settings.
    func performTitleDoubleClickAction() {
        guard !styleMask.contains(.fullScreen) else { return }
        let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
        switch action {
        case "None": break
        case "Minimize": miniaturize(nil)
        default: zoom(nil)   // "Maximize" and "Fill"
        }
    }

    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        positionTrafficLights()
    }

    private var dimDots: [NSView] = []

    /// Arc shows the window buttons as muted grey discs and only colours them
    /// while the pointer is over the sidebar's title row.
    private func updateTrafficLightAlpha(animated: Bool) {
        let revealed = trafficLightsRevealed || styleMask.contains(.fullScreen)
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for (i, type) in buttons.enumerated() {
            guard let b = standardWindowButton(type), let sv = b.superview else { continue }
            if dimDots.count <= i {
                let dot = NSView(frame: .zero)
                dot.wantsLayer = true
                dot.layer?.cornerRadius = 5.5
                dot.layer?.backgroundColor = NSColor(white: 0, alpha: 0.11).cgColor
                dot.layer?.borderColor = NSColor(white: 0, alpha: 0.06).cgColor
                dot.layer?.borderWidth = 0.5
                dimDots.append(dot)
            }
            let dot = dimDots[i]
            if dot.superview !== sv { sv.addSubview(dot, positioned: .above, relativeTo: b) }
            dot.frame = NSRect(x: b.frame.midX - 5.5, y: b.frame.midY - 5.5, width: 11, height: 11)
            let set = { b.alphaValue = revealed ? 1 : 0; dot.alphaValue = revealed ? 0 : 1 }
            if animated {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.15
                    b.animator().alphaValue = revealed ? 1 : 0
                    dot.animator().alphaValue = revealed ? 0 : 1
                }
            } else {
                set()
            }
        }
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        super.makeKeyAndOrderFront(sender)
        positionTrafficLights()
    }

    private func positionTrafficLights() {
        guard !styleMask.contains(.fullScreen) else { return }
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for (i, type) in buttons.enumerated() {
            guard let b = standardWindowButton(type), let sv = b.superview else { continue }
            let x: CGFloat = 13 + CGFloat(i) * 24
            let y = sv.bounds.height - CraMetrics.titleRowCenter - b.frame.height / 2
            let target = NSPoint(x: x, y: y)
            if abs(b.frame.origin.x - target.x) > 0.5 || abs(b.frame.origin.y - target.y) > 0.5 {
                b.setFrameOrigin(target)
            }
        }
        updateTrafficLightAlpha(animated: false)
    }
}
