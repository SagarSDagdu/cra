import AppKit
import CraCEF

/// One live Chromium browser for a tab. Tabs that have not been opened since
/// launch have no runtime; archiving a tab destroys its runtime.
@MainActor
final class TabRuntime {
    let tabID: UUID
    let browser: CraBrowser
    var progress: Double = 0
    var themeColor: String = ""
    init(tabID: UUID, browser: CraBrowser) {
        self.tabID = tabID
        self.browser = browser
    }
}

@MainActor
protocol BrowserManagerDelegate: AnyObject {
    func browserManagerDidUpdate(_ tabID: UUID)
    func browserManager(statusMessage: String)
    func browserManager(download: CraDownloadInfo)
    func browserManager(fullscreen: Bool, tabID: UUID)
    func browserManagerDevToolsHost(for tabID: UUID) -> NSView?
    /// A DevTools pane appeared or closed; the shell decides whether to show the dock.
    func browserManagerDevToolsChanged()
    func browserManagerHandleKey(_ event: NSEvent) -> Bool
    func browserManagerHandleUnhandledKey(_ event: NSEvent) -> Bool
    func browserManagerFocusedBrowser(_ tabID: UUID)
    func browserManagerOpenInternalURL(_ url: String)
}

/// Creates, shows, hides and tears down CEF browsers inside a container view.
@MainActor
final class BrowserManager: NSObject, @preconcurrency CraBrowserDelegate {
    let store: SidebarStore
    let favicons: FaviconCache
    let container: NSView
    weak var delegate: BrowserManagerDelegate?
    private(set) var runtimes: [UUID: TabRuntime] = [:]
    private(set) var visibleTabID: UUID?
    private var byBrowser: [ObjectIdentifier: UUID] = [:]

    init(store: SidebarStore, favicons: FaviconCache, container: NSView) {
        self.store = store
        self.favicons = favicons
        self.container = container
    }

    func runtime(for tabID: UUID) -> TabRuntime? { runtimes[tabID] }
    var visibleRuntime: TabRuntime? { visibleTabID.flatMap { runtimes[$0] } }

    @discardableResult
    func ensureRuntime(for tabID: UUID) -> TabRuntime? {
        if let r = runtimes[tabID] { return r }
        guard let item = store.item(tabID), let tab = item.tab else { return nil }
        let browser = CraBrowser(frame: container.bounds, url: tab.url.isEmpty ? "about:blank" : tab.url, delegate: self)
        return register(browser: browser, tabID: tabID)
    }

    /// Popup host: a browser shell CEF will fill with window.open content.
    func makePopupHost(for tabID: UUID) -> CraBrowser {
        let browser = CraBrowser(frame: container.bounds, url: nil, delegate: self)
        register(browser: browser, tabID: tabID)
        return browser
    }

    @discardableResult
    private func register(browser: CraBrowser, tabID: UUID) -> TabRuntime {
        browser.userInfo = tabID.uuidString
        let v = browser.containerView
        v.frame = container.bounds
        v.autoresizingMask = [.width, .height]
        v.isHidden = true
        container.addSubview(v)
        let rt = TabRuntime(tabID: tabID, browser: browser)
        runtimes[tabID] = rt
        byBrowser[ObjectIdentifier(browser)] = tabID
        if let t = store.item(tabID)?.tab, t.muted { browser.setAudioMuted(true) }
        return rt
    }

    func show(_ tabID: UUID?, focus: Bool) {
        if let tabID, let rt = ensureRuntime(for: tabID) {
            for (id, other) in runtimes where id != tabID { other.browser.containerView.isHidden = true }
            rt.browser.containerView.frame = container.bounds
            rt.browser.containerView.isHidden = false
            visibleTabID = tabID
            if focus { rt.browser.setFocused(true) }
        } else {
            for (_, other) in runtimes { other.browser.containerView.isHidden = true }
            visibleTabID = nil
        }
        syncDevToolsVisibility()
    }

    func unload(_ tabID: UUID) {
        guard let rt = runtimes[tabID] else { return }
        if visibleTabID == tabID { visibleTabID = nil }
        rt.browser.containerView.isHidden = true
        rt.browser.close()
    }

    /// Drop runtimes whose tabs no longer exist (archived, deleted).
    func pruneMissingTabs() {
        for id in runtimes.keys where store.item(id)?.isTab != true { unload(id) }
    }

    func closeAll() { for id in Array(runtimes.keys) { unload(id) } }

    func layoutVisible() {
        visibleRuntime?.browser.containerView.frame = container.bounds
    }

    private func tabID(of browser: CraBrowser) -> UUID? { byBrowser[ObjectIdentifier(browser)] }

    // MARK: CraBrowserDelegate

    func browser(_ browser: CraBrowser, didChangeTitle title: String) {
        guard let id = tabID(of: browser) else { return }
        store.updateTab(id, title: title)
        delegate?.browserManagerDidUpdate(id)
    }

    func browser(_ browser: CraBrowser, didChangeURL url: String) {
        guard let id = tabID(of: browser) else { return }
        // Our own error page is a data: URL; keep the real address in the model.
        if url.hasPrefix("data:text/html;base64,") { return }
        store.updateTab(id, url: url)
        delegate?.browserManagerDidUpdate(id)
    }

    func browser(_ browser: CraBrowser, didChangeLoading loading: Bool, canGoBack: Bool, canGoForward: Bool) {
        guard let id = tabID(of: browser) else { return }
        if !loading { runtimes[id]?.progress = 0 }
        delegate?.browserManagerDidUpdate(id)
    }

    func browser(_ browser: CraBrowser, didChangeProgress progress: Double) {
        guard let id = tabID(of: browser) else { return }
        runtimes[id]?.progress = progress
        delegate?.browserManagerDidUpdate(id)
    }

    func browser(_ browser: CraBrowser, didFinishLoadingURL url: String, title: String, statusCode: Int) {
        guard let id = tabID(of: browser) else { return }
        store.recordVisit(url: url, title: title.isEmpty ? (store.item(id)?.tab?.savedTitle ?? "") : title)
    }

    func browser(_ browser: CraBrowser, didLoadFavicon image: NSImage, forURL iconURL: String) {
        guard let id = tabID(of: browser), let tab = store.item(id)?.tab else { return }
        let key = FaviconCache.key(for: tab.url) ?? tab.faviconKey
        guard let key else { return }
        favicons.store(image, forKey: key)
        if tab.faviconKey != key { store.updateTab(id, url: tab.url) }
    }

    func browser(_ browser: CraBrowser, didReportThemeColor hex: String) {
        guard let id = tabID(of: browser) else { return }
        runtimes[id]?.themeColor = hex
        delegate?.browserManagerDidUpdate(id)
    }

    func browser(_ browser: CraBrowser, didChangeStatusMessage message: String) {
        delegate?.browserManager(statusMessage: message)
    }

    func browser(_ browser: CraBrowser, didChangeFullscreen fullscreen: Bool) {
        guard let id = tabID(of: browser) else { return }
        delegate?.browserManager(fullscreen: fullscreen, tabID: id)
    }

    func browser(_ browser: CraBrowser, requestsNewTabWithURL url: String, inBackground background: Bool) {
        if url.hasPrefix("cra://") { delegate?.browserManagerOpenInternalURL(url); return }
        let sourceSpace = tabID(of: browser).flatMap { store.spaceID(ofItem: $0) }
        let parentIndex = tabID(of: browser).flatMap { id -> Int? in
            guard let it = store.item(id), let p = it.parentID, store.rootContainer(of: id) != nil,
                  case .today = store.rootContainer(of: id)! else { return nil }
            return (store.item(p)?.children.firstIndex(of: id) ?? -1) + 1
        }
        // Links from a today tab open right below it (Arc); otherwise at the top.
        let tab = store.createTab(url: url, in: sourceSpace, select: !background,
                                  parent: parentIndex != nil ? store.item(tabID(of: browser)!)?.parentID : nil,
                                  index: parentIndex)
        if background {
            store.markUnread(tab.id, true)
            ensureRuntime(for: tab.id)  // load it so the title and favicon fill in
        }
    }

    func browser(_ browser: CraBrowser, popupHostForURL url: String, inBackground background: Bool) -> CraBrowser? {
        if url.hasPrefix("cra://") { delegate?.browserManagerOpenInternalURL(url); return nil }
        let sourceSpace = tabID(of: browser).flatMap { store.spaceID(ofItem: $0) }
        let tab = store.createTab(url: url, in: sourceSpace, select: !background)
        if background { store.markUnread(tab.id, true) }
        let host = makePopupHost(for: tab.id)
        if !background { show(tab.id, focus: true) }
        return host
    }

    func devToolsHostView(for browser: CraBrowser) -> NSView? {
        guard let id = tabID(of: browser) else { return nil }
        return delegate?.browserManagerDevToolsHost(for: id)
    }

    private(set) var devToolsViews: [UUID: NSView] = [:]
    var visibleTabHasDevTools: Bool { visibleTabID.flatMap { devToolsViews[$0] } != nil }

    func browser(_ browser: CraBrowser, didCreateDevToolsView view: NSView) {
        guard let id = tabID(of: browser) else { return }
        devToolsViews[id] = view
        delegate?.browserManagerDevToolsChanged()
    }

    func browserDidCloseDevTools(_ browser: CraBrowser) {
        guard let id = tabID(of: browser) else { return }
        devToolsViews[id] = nil
        delegate?.browserManagerDevToolsChanged()
    }

    /// CEF's window for the visible tab's DevTools, if any.
    var visibleDevToolsWindow: NSWindow? { visibleTabID.flatMap { devToolsViews[$0]?.window } }

    private func syncDevToolsVisibility() {
        delegate?.browserManagerDevToolsChanged()
    }

    func browser(_ browser: CraBrowser, handleKeyEvent event: NSEvent) -> Bool {
        delegate?.browserManagerHandleKey(event) ?? false
    }

    func browser(_ browser: CraBrowser, handleUnhandledKeyEvent event: NSEvent) -> Bool {
        delegate?.browserManagerHandleUnhandledKey(event) ?? false
    }

    func browser(_ browser: CraBrowser, didUpdateDownload download: CraDownloadInfo) {
        delegate?.browserManager(download: download)
    }

    func browser(_ browser: CraBrowser, requestsPermissionForOrigin origin: String, kinds: UInt, completion: @escaping (Bool) -> Void) {
        // Notification prompts are denied quietly (no modal), like Arc's default.
        if kinds == 8 { completion(false); return }
        var what: [String] = []
        if kinds & 1 != 0 { what.append("camera") }
        if kinds & 2 != 0 { what.append("microphone") }
        if kinds & 4 != 0 { what.append("location") }
        if kinds & 8 != 0 { what.append("notifications") }
        if what.isEmpty { what.append("a browser permission") }
        let alert = NSAlert()
        alert.messageText = "\(origin) wants to use your \(what.joined(separator: " and "))"
        alert.addButton(withTitle: "Allow")
        alert.addButton(withTitle: "Block")
        guard let window = container.window else { completion(false); return }
        alert.beginSheetModal(for: window) { resp in completion(resp == .alertFirstButtonReturn) }
    }

    func browserDidReceiveFocus(_ browser: CraBrowser) {
        guard let id = tabID(of: browser) else { return }
        delegate?.browserManagerFocusedBrowser(id)
    }

    func browserDidClose(_ browser: CraBrowser) {
        guard let id = tabID(of: browser) else { return }
        browser.containerView.removeFromSuperview()
        byBrowser[ObjectIdentifier(browser)] = nil
        if runtimes[id]?.browser === browser { runtimes[id] = nil }
        if visibleTabID == id { visibleTabID = nil }
        delegate?.browserManagerDidUpdate(id)
    }
}
