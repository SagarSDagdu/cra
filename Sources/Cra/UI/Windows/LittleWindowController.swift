import AppKit
import CraCEF
import SwiftUI

/// Arc's Little Arc, here a "Little Window": links from other apps (and ⌥⌘N)
/// open in a small, sidebar-less window with its own Chromium browser. The
/// page is not in the sidebar. Closing the window archives it to the Library
/// (Arc: archive source `littleArc`); "Open in Space" promotes it into a
/// space's Today list, moving the live browser into the main window.
@MainActor
@Observable
final class LittleWindowState {
    var url = ""
    var title = ""
    var canGoBack = false
    var canGoForward = false
    var isLoading = false
    var progress: Double = 0
    var themeColor = ""
    var palette: SpacePalette
    /// Bumped to focus the URL field (⌘L, ⌘T, an empty window).
    var focusURLToken = 0

    init(palette: SpacePalette) { self.palette = palette }
}

/// What the toolbar needs AppKit to do.
@MainActor
final class LittleWindowActions {
    var goBack: () -> Void = {}
    var goForward: () -> Void = {}
    var reload: () -> Void = {}
    var navigate: (String) -> Void = { _ in }
    var focusPage: () -> Void = {}
    var promote: (UUID?) -> Void = { _ in }
}

enum LittleMetrics {
    static let toolbarHeight: CGFloat = 44
    static let defaultSize = NSSize(width: 1000, height: 700)
    static let minSize = NSSize(width: 480, height: 360)
}

@MainActor
final class LittleWindowController: NSWindowController, NSWindowDelegate, @preconcurrency CraBrowserDelegate {
    unowned let app: AppDelegate
    let state: LittleWindowState
    let actions = LittleWindowActions()
    private(set) var browser: CraBrowser?
    private let shell: LittleShellView
    private var favicon: NSImage?
    private var promoted = false

    var store: SidebarStore { app.store }
    var currentURL: String { browser?.currentURL ?? state.url }
    var hasPage: Bool { !currentURL.isEmpty && currentURL != "about:blank" }

    /// `url` nil makes a popup host: the browser adopts the next window.open
    /// CEF hands it (see `CraBrowserDelegate.browser:popupHostForURL:`).
    init(app: AppDelegate, url: String?) {
        self.app = app
        let palette = app.store.focusedSpace.theme.palette
        state = LittleWindowState(palette: palette)
        let size = app.store.prefs.littleWindowSize.map { NSSizeFromString($0) }
            .map { NSSize(width: max(LittleMetrics.minSize.width, $0.width), height: max(LittleMetrics.minSize.height, $0.height)) }
            ?? LittleMetrics.defaultSize
        let window = LittleWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                                  backing: .buffered, defer: false)
        shell = LittleShellView(frame: window.contentView!.bounds, background: SpaceBackground(palette: palette))
        super.init(window: window)
        window.delegate = self
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.minSize = LittleMetrics.minSize
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.title = "Little Window"
        window.contentView = shell
        shell.toolbarHost.rootView = AnyView(LittleToolbar(state: state, actions: actions).environment(app.store))
        applyPalette(palette)
        placeWindow()

        actions.goBack = { [weak self] in self?.browser?.goBack() }
        actions.goForward = { [weak self] in self?.browser?.goForward() }
        actions.reload = { [weak self] in
            guard let b = self?.browser else { return }
            b.isLoading ? b.stopLoading() : b.reload()
        }
        actions.navigate = { [weak self] text in self?.navigate(text) }
        actions.focusPage = { [weak self] in self?.focusPage() }
        actions.promote = { [weak self] sid in self?.promote(to: sid) }

        let b = CraBrowser(frame: shell.card.bounds, url: url.map { $0.isEmpty ? "about:blank" : $0 }, delegate: self)
        attach(b)
        state.url = (url == "about:blank" ? "" : url) ?? ""
        observeStore()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func attach(_ b: CraBrowser) {
        browser = b
        // Embedded (Alloy) hosting: the Chromium view lives inside the card.
        // Chrome-style hosting delivers a window later (-browser:didCreateHostWindow:).
        let v = b.containerView
        v.frame = shell.card.bounds
        v.autoresizingMask = [.width, .height]
        shell.card.addSubview(v)
        shell.onCardFrame = { [weak self] rect in self?.positionHostWindow(rect) }
        if let w = b.hostWindow { attachHostWindow(w) }
    }

    /// Chrome-style hosting: the page is a frameless Chrome window; attach it
    /// as a child window over the card and round all four corners.
    private func attachHostWindow(_ w: NSWindow) {
        guard let window, w.parent !== window else { return }
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
            cv.layer?.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner, .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
            cv.layer?.masksToBounds = true
        }
        window.addChildWindow(w, ordered: .above)
        positionHostWindow(shell.convert(shell.card.frame, to: nil))
        w.orderFront(nil)
    }

    private func positionHostWindow(_ rectInWindow: NSRect) {
        guard let window, let w = browser?.hostWindow, w.parent === window, !rectInWindow.isEmpty else { return }
        let onScreen = window.convertToScreen(rectInWindow)
        if w.frame != onScreen { w.setFrame(onScreen, display: true) }
        if let cv = w.contentView { cv.layer?.cornerRadius = window.styleMask.contains(.fullScreen) ? 0 : CraMetrics.contentCornerRadius }
    }

    private func focusPage() {
        guard let b = browser else { return }
        if let w = b.hostWindow, w.parent === window { w.makeKey() }
        b.setFocused(true)
    }

    /// Centre on the screen under the pointer, cascaded off other little windows.
    private func placeWindow() {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let vf = screen.visibleFrame
        var frame = window.frame
        frame.size.width = min(frame.width, vf.width - 40)
        frame.size.height = min(frame.height, vf.height - 40)
        let n = CGFloat(app.littleWindows.count)
        frame.origin = NSPoint(x: vf.midX - frame.width / 2 + n * 24, y: vf.midY - frame.height / 2 - n * 24)
        frame.origin.x = min(max(vf.minX, frame.origin.x), vf.maxX - frame.width)
        frame.origin.y = min(max(vf.minY, frame.origin.y), vf.maxY - frame.height)
        window.setFrame(frame, display: false)
    }

    func show() {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if hasPage { focusPage() } else { focusURL() }
    }

    func focusURL() {
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(shell.toolbarHost)
        state.focusURLToken += 1
    }

    private func navigate(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { browser?.setFocused(true); return }
        let url = SuggestionEngine.looksLikeURL(t) ? SuggestionEngine.urlFromInput(t) : store.settings.searchEngine.searchURL(t)
        state.url = url
        browser?.loadURL(url)
        focusPage()
    }

    // MARK: Theme

    private func observeStore() {
        withObservationTracking {
            _ = store.prefs.focusedSpaceID
            _ = store.spaces
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let p = self.store.focusedSpace.theme.palette
                self.state.palette = p
                self.applyPalette(p)
                self.observeStore()
            }
        }
    }

    private func applyPalette(_ palette: SpacePalette) {
        guard let window else { return }
        shell.backgroundHost.rootView = SpaceBackground(palette: palette)
        shell.vibrancy.isHidden = !palette.vibrant
        shell.vibrancy.material = palette.isDark ? .underWindowBackground : .hudWindow
        shell.vibrancy.appearance = NSAppearance(named: .darkAqua)
        window.appearance = NSAppearance(named: palette.isDark ? .darkAqua : .aqua)
        window.isOpaque = !palette.vibrant
        window.backgroundColor = palette.vibrant ? .clear : NSColor(palette.gradientColors.first ?? .gray)
    }

    // MARK: Promote / close

    /// Move the page into a space (nil = the focused one) as a Today tab. The
    /// live browser goes with it, so history, scroll position and logins stay.
    func promote(to spaceID: UUID?) {
        guard let b = browser, hasPage else { return }
        let sid = spaceID.flatMap { store.space($0) != nil ? $0 : nil } ?? store.focusedSpaceID
        let tab = store.createTab(url: b.currentURL, title: b.currentTitle, in: sid, select: true)
        if let favicon, let key = FaviconCache.key(for: b.currentURL) { app.favicons.store(favicon, forKey: key) }
        promoted = true
        browser = nil
        app.main.browsers.adopt(b, for: tab.id)
        window?.close()
        app.main.showWindow(nil)
        app.main.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Archive the page to the Library (Arc keeps closed Little Arcs there too).
    func archivePage() {
        guard hasPage, !promoted else { return }
        store.archiveLittleWindowPage(url: currentURL, title: browser?.currentTitle ?? state.title)
        if let favicon, let key = FaviconCache.key(for: currentURL) { app.favicons.store(favicon, forKey: key) }
        promoted = true  // archived once; a later close must not archive again
    }

    /// Menu / key actions while this window is key. Returns false for actions
    /// that are not the little window's (the app handles those).
    func handle(action id: String) -> Bool {
        switch id {
        case "closeTab", "closeWindow": window?.performClose(nil)
        case "newTab", "editURL": focusURL()
        case "goBack": browser?.goBack()
        case "goForward": browser?.goForward()
        case "reload": browser?.reload()
        case "hardReload": browser?.reloadIgnoringCache()
        case "stop": browser?.stopLoading()
        case "zoomIn": if let b = browser { b.setZoomLevel(b.zoomLevel() + 0.5) }
        case "zoomOut": if let b = browser { b.setZoomLevel(b.zoomLevel() - 0.5) }
        case "resetZoom": browser?.setZoomLevel(0)
        case "copyURL": copy(currentURL)
        case "copyURLMarkdown": copy("[\(browser?.currentTitle ?? state.title)](\(currentURL))")
        case "viewSource": browser?.viewSource()
        case "devTools", "jsConsole", "inspectElement": browser?.showDevTools()
        case "print": browser?.print()
        case "promoteLittleWindow": promote(to: nil)
        // No find bar or capture in little windows; keep them off the main window.
        case "find", "findNext", "findPrevious", "capturePage", "toggleSidebar", "pinTab", "favoriteTab", "renameTab",
             "duplicateTab", "resetTab", "muteTab", "clearToday", "nextTab", "previousTab", "recentTab":
            break
        default: return false
        }
        return true
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        archivePage()
        if let b = browser {
            b.containerView.isHidden = true
            if let w = b.hostWindow, w.parent === sender { sender.removeChildWindow(w); w.orderOut(nil) }
            b.close()  // -browserDidClose: drops the controller
        }
        return true
    }

    func windowWillClose(_ notification: Notification) {
        if browser == nil { app.removeLittleWindow(self) }
    }

    func windowDidResize(_ notification: Notification) {
        guard let window, !window.styleMask.contains(.fullScreen) else { return }
        store.prefs.littleWindowSize = NSStringFromSize(window.frame.size)
    }

    // MARK: CraBrowserDelegate

    func browser(_ browser: CraBrowser, didChangeTitle title: String) {
        state.title = title
        window?.title = title.isEmpty ? "Little Window" : title
    }

    func browser(_ browser: CraBrowser, didChangeURL url: String) {
        if url.hasPrefix("data:text/html;base64,") { return }
        state.url = url == "about:blank" ? "" : url
    }

    func browser(_ browser: CraBrowser, didChangeLoading loading: Bool, canGoBack: Bool, canGoForward: Bool) {
        state.isLoading = loading
        state.canGoBack = canGoBack
        state.canGoForward = canGoForward
        if !loading { state.progress = 0 }
    }

    func browser(_ browser: CraBrowser, didChangeProgress progress: Double) { state.progress = progress }

    func browser(_ browser: CraBrowser, didFinishLoadingURL url: String, title: String, statusCode: Int) {
        store.recordVisit(url: url, title: title)
    }

    func browser(_ browser: CraBrowser, didLoadFavicon image: NSImage, forURL iconURL: String) {
        favicon = image
        if let key = FaviconCache.key(for: browser.currentURL) { app.favicons.store(image, forKey: key) }
    }

    func browser(_ browser: CraBrowser, didReportThemeColor hex: String) { state.themeColor = hex }
    func browser(_ browser: CraBrowser, didChangeStatusMessage message: String) {}

    func browser(_ browser: CraBrowser, didChangeFullscreen fullscreen: Bool) {
        guard let window else { return }
        if fullscreen != window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
    }

    /// Links that want a new tab open another little window (Arc does the same).
    func browser(_ browser: CraBrowser, requestsNewTabWithURL url: String, inBackground background: Bool) {
        if url.hasPrefix("cra://") { if let u = URL(string: url) { app.handleInternalURL(u) }; return }
        let w = app.openLittleWindow(url: url, activate: !background)
        if background { window?.makeKeyAndOrderFront(nil); _ = w }
    }

    func browser(_ browser: CraBrowser, popupHostForURL url: String, inBackground background: Bool) -> CraBrowser? {
        if url.hasPrefix("cra://") { if let u = URL(string: url) { app.handleInternalURL(u) }; return nil }
        let w = app.makeLittleWindow(url: nil)
        w.state.url = url
        w.show()
        if background { window?.makeKeyAndOrderFront(nil) }
        return w.browser
    }

    func devToolsHostView(for browser: CraBrowser) -> NSView? { nil }
    func browser(_ browser: CraBrowser, didCreateDevToolsView view: NSView) {}
    func browser(_ browser: CraBrowser, didCreateHostWindow window: NSWindow) {
        attachHostWindow(window)
        if hasPage, self.window?.isKeyWindow == true || window.isKeyWindow { focusPage() }
    }
    func browserDidCloseDevTools(_ browser: CraBrowser) {}
    func browser(_ browser: CraBrowser, handleKeyEvent event: NSEvent) -> Bool { app.handleReservedKey(event) }
    func browser(_ browser: CraBrowser, handleUnhandledKeyEvent event: NSEvent) -> Bool { app.handleUnhandledKey(event) }
    func browser(_ browser: CraBrowser, didUpdateDownload download: CraDownloadInfo) { app.main.browserManager(download: download) }

    func browser(_ browser: CraBrowser, requestsPermissionForOrigin origin: String, kinds: UInt, completion: @escaping (Bool) -> Void) {
        if kinds == 8 { completion(false); return }
        var what: [String] = []
        if kinds & 1 != 0 { what.append("camera") }
        if kinds & 2 != 0 { what.append("microphone") }
        if kinds & 4 != 0 { what.append("location") }
        if what.isEmpty { what.append("a browser permission") }
        let alert = NSAlert()
        alert.messageText = "\(origin) wants to use your \(what.joined(separator: " and "))"
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Block")
        guard let window else { completion(false); return }
        alert.beginSheetModal(for: window) { resp in completion(resp == .alertFirstButtonReturn) }
    }

    func browserDidReceiveFocus(_ browser: CraBrowser) {}

    func browserDidClose(_ browser: CraBrowser) {
        browser.containerView.removeFromSuperview()
        guard self.browser === browser else { return }
        self.browser = nil
        if let window, window.isVisible {
            // The page closed itself (window.close()); the window goes with it.
            archivePage()
            window.close()
        }
        app.removeLittleWindow(self)
    }
}

/// Gradient background, toolbar strip on the gradient, rounded page card below.
final class LittleShellView: NSView {
    let vibrancy = NSVisualEffectView()
    let backgroundHost: NSHostingView<SpaceBackground>
    let toolbarHost = NSHostingView(rootView: AnyView(EmptyView()))
    let card = NSView()
    /// Reports the card (window coordinates) so a Chrome-style page window can follow it.
    var onCardFrame: ((NSRect) -> Void)?

    init(frame: NSRect, background: SpaceBackground) {
        backgroundHost = NSHostingView(rootView: background)
        super.init(frame: frame)
        wantsLayer = true
        vibrancy.blendingMode = .behindWindow
        vibrancy.state = .active
        vibrancy.isHidden = true
        addSubview(vibrancy)
        addSubview(backgroundHost)
        toolbarHost.sizingOptions = []
        addSubview(toolbarHost)
        card.wantsLayer = true
        card.layer?.cornerRadius = CraMetrics.contentCornerRadius
        card.layer?.cornerCurve = .continuous
        card.layer?.masksToBounds = true
        card.layer?.backgroundColor = NSColor.white.cgColor
        card.autoresizesSubviews = true
        addSubview(card)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let b = bounds
        vibrancy.frame = b
        backgroundHost.frame = b
        let fullscreen = window?.styleMask.contains(.fullScreen) ?? false
        let toolbarH = LittleMetrics.toolbarHeight
        toolbarHost.frame = NSRect(x: 0, y: b.height - toolbarH, width: b.width, height: toolbarH)
        let inset = fullscreen ? 0 : CraMetrics.contentInset
        card.frame = NSRect(x: inset, y: inset, width: max(0, b.width - 2 * inset), height: max(0, b.height - toolbarH - inset))
        card.layer?.cornerRadius = fullscreen ? 0 : CraMetrics.contentCornerRadius
        for sub in card.subviews where sub.frame != card.bounds { sub.frame = card.bounds }
        onCardFrame?(convert(card.frame, to: nil))
    }
}

/// Traffic lights centred on the toolbar strip.
final class LittleWindow: NSWindow {
    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        positionTrafficLights()
    }

    override func makeKeyAndOrderFront(_ sender: Any?) {
        super.makeKeyAndOrderFront(sender)
        positionTrafficLights()
    }

    private func positionTrafficLights() {
        guard !styleMask.contains(.fullScreen) else { return }
        for (i, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let b = standardWindowButton(type), let sv = b.superview else { continue }
            let target = NSPoint(x: 13 + CGFloat(i) * 20, y: sv.bounds.height - LittleMetrics.toolbarHeight / 2 - b.frame.height / 2)
            if abs(b.frame.origin.x - target.x) > 0.5 || abs(b.frame.origin.y - target.y) > 0.5 { b.setFrameOrigin(target) }
        }
    }
}

/// Nav buttons, the URL field, and "Open in Space" on the gradient strip.
struct LittleToolbar: View {
    let state: LittleWindowState
    let actions: LittleWindowActions
    @Environment(SidebarStore.self) private var store
    @State private var text = ""
    @State private var hoverURL = false
    @FocusState private var editing: Bool

    private var palette: SpacePalette { state.palette }
    private var fg: Color { palette.textPrimary }
    private var fgDim: Color { palette.textSecondary }
    private var human: String { SuggestionEngine.humanURL(state.url) }

    var body: some View {
        HStack(spacing: 2) {
            Spacer().frame(width: 72)  // traffic lights
            ToolbarIcon(symbol: "arrow.left", fg: fgDim, help: "Go Back (⌘[)", enabled: state.canGoBack, width: 32, iconSize: 15) { actions.goBack() }
            ToolbarIcon(symbol: "arrow.right", fg: fgDim, help: "Go Forward (⌘])", enabled: state.canGoForward, width: 32, iconSize: 15) { actions.goForward() }
            ToolbarIcon(symbol: state.isLoading ? "xmark" : "arrow.clockwise", fg: fgDim, help: "Refresh (⌘R)", width: 32, iconSize: 15) { actions.reload() }
            Spacer(minLength: 8)
            urlField
                .frame(maxWidth: 640)
            Spacer(minLength: 8)
            openInSpace
                .padding(.trailing, 10)
        }
        .frame(height: LittleMetrics.toolbarHeight)
        .overlay(alignment: .bottomLeading) {
            if state.isLoading && state.progress > 0 {
                GeometryReader { g in
                    Capsule().fill(palette.folderTint.opacity(0.9))
                        .frame(width: max(8, g.size.width * state.progress), height: 2)
                }
                .frame(height: 2)
                .padding(.horizontal, CraMetrics.contentInset)
            }
        }
        .onAppear { text = human }
        .onChange(of: state.url) { _, _ in if !editing { text = human } }
        .onChange(of: editing) { _, on in text = on ? state.url : human }
        .onChange(of: state.focusURLToken) { _, _ in editing = true }
        .ignoresSafeArea()
    }

    private var urlField: some View {
        HStack(spacing: 7) {
            Image(systemName: editing ? "magnifyingglass" : (state.url.hasPrefix("https://") ? "lock.fill" : "link"))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(fgDim)
            TextField("Search or enter URL…", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: editing ? .monospaced : .default))
                .foregroundStyle(fg)
                .multilineTextAlignment(editing ? .leading : .center)
                .focused($editing)
                .onSubmit { editing = false; actions.navigate(text) }
                .onExitCommand { editing = false; text = human; actions.focusPage() }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(editing || hoverURL ? palette.selectedFill : palette.pillFill))
        .onHover { hoverURL = $0 }
        .help(state.url)
    }

    private var openInSpace: some View {
        let focused = store.focusedSpace
        return Menu {
            Button("\(focused.emoji) \(focused.title)") { actions.promote(focused.id) }
            if store.orderedSpaces.count > 1 {
                Divider()
                ForEach(store.orderedSpaces.filter { $0.id != focused.id }) { s in
                    Button("\(s.emoji) \(s.title)") { actions.promote(s.id) }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.forward.app").font(.system(size: 12, weight: .medium))
                Text("Open in Space").font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(fg)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(palette.pillFill))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(state.url.isEmpty)
        .help("Move this page into a space as a tab")
    }
}
