import AppKit
import CraCEF
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    let store = SidebarStore()
    let bindings = KeyBindingRegistry()
    let favicons = FaviconCache()
    let account = AccountStore()
    lazy var engine = SuggestionEngine(store: store, bindings: bindings)

    private(set) var main: MainWindowController!
    private var bootstrapped = false
    private var pendingURLs: [String] = []
    private var autoArchiveTimer: Timer?
    private var backupTimer: Timer?
    private var settingsWindow: NSWindow?
    private var archiveWindow: NSWindow?
    private var accountWindow: NSWindow?
    private var lastPushedSettings: AppSettings?
    /// Arc's Little Arc windows: small, sidebar-less, disposable (see LittleWindowController).
    private(set) var littleWindows: [LittleWindowController] = []

    /// Shortcuts the app takes before the web page sees them (Chrome calls
    /// these reserved). Everything else goes to the page first.
    static let reservedActions: Set<String> = Set([
        "newTab", "newWindow", "closeTab", "closeWindow", "reopenClosedTab", "editURL", "toggleSidebar", "toggleToolbar",
        "nextTab", "previousTab", "recentTab", "nextSpace", "previousSpace", "devTools", "jsConsole", "inspectElement",
        "viewArchive", "openLibrary", "settings", "clearToday", "newLittleWindow", "promoteLittleWindow",
    ] + (1...9).flatMap { ["item\($0)", "space\($0)"] })

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) { bootstrapIfNeeded() }

    func bootstrapIfNeeded() {
        guard !bootstrapped else { return }
        bootstrapped = true
        NSApp.setActivationPolicy(.regular)
        installURLEventHandler()
        CraCEFRuntime.setChromeHosting(store.settings.chromeEngine)
        buildMenus()
        NotificationCenter.default.addObserver(forName: .craKeyBindingsChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.buildMenus() }
        }
        main = MainWindowController(app: self)
        main.showWindow(nil)
        store.runAutoArchive()
        autoArchiveTimer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.store.runAutoArchive() }
        }
        backupTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.backupIfSignedIn() }
        }
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.installURLEventHandler() }
        CraCEFRuntime.setRelaunchHandler { [weak self] urls in
            Task { @MainActor in
                guard let self else { return }
                self.main.showWindow(nil)
                NSApp.activate(ignoringOtherApps: true)
                for u in urls { self.openExternalURL(u) }
            }
        }
        let urls = pendingURLs
        pendingURLs = []
        for u in urls { openExternalURL(u) }

        Task { await account.restore(); await pullSettingsIfNewer() }
        observeSettingsForSync()
        maybeOfferImport()
    }

    private func maybeOfferImport() {
        guard !store.settings.hasSeenImportPrompt, ArcImporter.isAvailable || DiaImporter.isAvailable, store.allTabs().count <= 2 else { return }
        store.settings.hasSeenImportPrompt = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.main.showImport() }
    }

    private func observeSettingsForSync() {
        withObservationTracking {
            _ = store.settings
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.account.isSignedIn, self.lastPushedSettings != self.store.settings {
                    self.lastPushedSettings = self.store.settings
                    self.account.pushSettings(self.store.settings)
                }
                self.observeSettingsForSync()
            }
        }
    }

    private func pullSettingsIfNewer() async {
        guard account.isSignedIn, let remote = await account.pullSettings() else { return }
        var merged = remote
        merged.hasSeenImportPrompt = store.settings.hasSeenImportPrompt || remote.hasSeenImportPrompt
        if merged != store.settings {
            lastPushedSettings = merged
            store.settings = merged
        }
    }

    private func backupIfSignedIn() async {
        guard account.isSignedIn else { return }
        await account.backupSidebar(store.document, tabCount: store.allTabs().count)
    }

    private func installURLEventHandler() {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleGetURLEvent(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    func applicationDidBecomeActive(_ notification: Notification) { installURLEventHandler() }

    @objc private func handleGetURLEvent(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue else { return }
        if bootstrapped { openExternalURL(s) } else { pendingURLs.append(s) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for u in urls {
            if bootstrapped { openExternalURL(u.absoluteString) } else { pendingURLs.append(u.absoluteString) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        main?.showWindow(nil)
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Little Windows are not in the sidebar; keep their pages in the Library.
        for w in littleWindows { w.archivePage() }
        store.saveAll()
        return .terminateNow
    }

    func applicationWillShutdown() { store.saveAll() }

    func openExternalURL(_ url: String) {
        if let u = URL(string: url), u.scheme == "cra" {
            handleInternalURL(u)
            return
        }
        // Arc: "Links from other apps open in Little Arc".
        if store.settings.openExternalLinksInLittleWindow {
            openLittleWindow(url: url)
            return
        }
        store.createTab(url: url, select: true)
        main.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Little Windows

    /// The little window that owns the key window (the window itself, or its
    /// Chrome-style page window, which is a child).
    var keyLittleWindow: LittleWindowController? {
        guard let key = NSApp.keyWindow else { return nil }
        return littleWindows.first { $0.window === key || $0.window === key.parent }
    }

    /// Creates a little window without showing it (`url` nil = popup host).
    func makeLittleWindow(url: String?) -> LittleWindowController {
        let w = LittleWindowController(app: self, url: url)
        littleWindows.append(w)
        return w
    }

    @discardableResult
    func openLittleWindow(url: String, activate: Bool = true) -> LittleWindowController {
        let w = makeLittleWindow(url: url)
        if activate { w.show() } else { w.window?.orderFront(nil) }
        return w
    }

    func removeLittleWindow(_ w: LittleWindowController) {
        littleWindows.removeAll { $0 === w }
    }

    func closeLittleWindows() {
        for w in littleWindows { w.window?.performClose(nil) }
    }

    /// cra://commandbar?query=…&mode=edit, cra://action/<id>, cra://open?url=…,
    /// cra://dismiss, cra://auth-callback?data=… (Google sign-in return).
    /// Arc marks a tab chosen from the keyboard with its yellow/black focus ring.
    private func markKeyboardFocus() { main.sidebarUI.keyboardFocusID = store.selectedTabID }

    func handleInternalURL(_ u: URL) {
        let comps = URLComponents(url: u, resolvingAgainstBaseURL: false)
        func q(_ name: String) -> String? { comps?.queryItems?.first { $0.name == name }?.value }
        // Actions keep their target: a key Little Window stays key (perform routes to it).
        if u.host != "action" || keyLittleWindow == nil {
            main.showWindow(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        switch u.host {
        case "commandbar":
            main.openCommandBar(q("mode") == "edit" ? .editURL : .newTab)
            if let text = q("query") { main.commandBar.setQuery(text) }
        case "action":
            perform(String(u.path.dropFirst()))
        case "open":
            if let url = q("url"), q("little") == "1" {
                openLittleWindow(url: url)
            } else if let url = q("url") {
                let tab = store.createTab(url: url, select: q("background") != "1")
                if q("background") == "1" { store.markUnread(tab.id, true); main.browsers.ensureRuntime(for: tab.id) }
            }
        case "key":
            // Scripted key press through the normal event path (testing).
            guard let chars = q("chars"), let window = main.window else { break }
            var flags: NSEvent.ModifierFlags = []
            if q("cmd") == "1" { flags.insert(.command) }
            if q("shift") == "1" { flags.insert(.shift) }
            if q("opt") == "1" { flags.insert(.option) }
            if q("ctrl") == "1" { flags.insert(.control) }
            let codes: [String: UInt16] = ["a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
                                           "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25,
                                           "7": 26, "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
                                           "k": 40, ";": 41, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47, "\t": 48]
            let code = codes[chars] ?? 0
            window.makeKeyAndOrderFront(nil)
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let ev = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                             windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                             isARepeat: false, keyCode: code) {
                    NSApp.sendEvent(ev)
                }
            }
        case "import":
            // Headless import (scripting): cra://import?source=arc&archive=1&settings=1
            let plan = try? (q("source") == "dia" ? DiaImporter.plan() : ArcImporter.plan())
            if let plan {
                let r = store.apply(plan, includeArchive: q("archive") != "0", includeSettings: q("settings") != "0")
                favicons.reset()
                NSLog("Cra: imported %d spaces, %d tabs, %d folders, %d archived", r.spaces, r.tabs, r.folders, r.archived)
            }
        case "debug":
            var dict: [String: String] = [:]
            for item in comps?.queryItems ?? [] { if let v = item.value { dict[item.name] = v } }
            if let spikeURL = dict["chromeSpike"] {
                CraCEFRuntime.spikeChromeWindow(withURL: spikeURL) { [weak self] w in
                    guard let self, let host = self.main.window else { return }
                    w.styleMask.insert(.fullSizeContentView)
                    w.titlebarAppearsTransparent = true
                    w.titleVisibility = .hidden
                    w.isMovable = false
                    w.hasShadow = false
                    host.addChildWindow(w, ordered: .above)
                    let rect = self.main.shell.contentContainer.convert(self.main.shell.webContainer.frame, to: nil)
                    w.setFrame(host.convertToScreen(rect), display: true)
                    w.orderFront(nil)
                }
                return
            }
            if dict["windows"] != nil {
                for w in NSApp.windows {
                    NSLog("Cra windows: %@ '%@' frame=%@ parent=%@ visible=%d key=%d mask=%lu class=%@ children=%d",
                          String(describing: w.windowController.map { type(of: $0) } ?? nil as AnyClass?), w.title, NSStringFromRect(w.frame),
                          w.parent.map { NSStringFromRect($0.frame) } ?? "-", w.isVisible ? 1 : 0, w.isKeyWindow ? 1 : 0, w.styleMask.rawValue,
                          NSStringFromClass(type(of: w)), w.childWindows?.count ?? 0)
                }
                NSLog("Cra windows: little=%d tabs=%d runtimes=%d", littleWindows.count, store.allTabs().count, main.browsers.runtimes.count)
                return
            }
            CraTuning.shared.apply(dict)
            main.refresh()
            if let w = main.window {
                let v = main.shell.vibrancy
                NSLog("Cra debug: opaque=%d bg=%@ key=%d main=%d vibHidden=%d state=%ld material=%ld blend=%ld appearance=%@ shellLayerOpaque=%d contentViewIsShell=%d",
                      w.isOpaque ? 1 : 0, String(describing: w.backgroundColor), w.isKeyWindow ? 1 : 0, w.isMainWindow ? 1 : 0,
                      v.isHidden ? 1 : 0, v.state.rawValue, v.material.rawValue, v.blendingMode.rawValue, String(describing: v.effectiveAppearance.name.rawValue),
                      (main.shell.layer?.isOpaque ?? false) ? 1 : 0, (w.contentView === main.shell) ? 1 : 0)
            }
        case "dismiss":
            main.dismissTransientUI()
            settingsWindow?.close()
            archiveWindow?.close()
            accountWindow?.close()
        case "auth-callback":
            if account.handleAuthCallback(u) {
                // Close the Google consent tab, if it is still around.
                for t in store.allTabs() where (t.tab?.url ?? "").contains("/google-callback") || (t.tab?.url ?? "").contains("accounts.google.com") {
                    store.archiveTab(t.id, reason: .manual)
                }
                Task { await pullSettingsIfNewer(); await account.refreshBackups() }
                showAccountWindow()
            }
        default:
            break
        }
    }

    // MARK: Actions

    @objc func menuAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        perform(id)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.representedObject as? String {
        case "toggleSidebar": item.title = store.prefs.sidebarVisible ? "Hide Sidebar" : "Show Sidebar"
        case "toggleToolbar": item.title = store.settings.showToolbar ? "Hide Toolbar" : "Show Toolbar"
        case "toggleDeveloperMode":
            let on = store.selectedTab?.tab.map { store.settings.isDeveloperMode(url: $0.url) } ?? false
            item.title = on ? "Turn off Developer Mode for this Site" : "Turn on Developer Mode for this Site"
        case "pinTab": item.title = store.selectedTabID.map { store.isPinned($0) ? "Unpin Tab" : "Pin Tab" } ?? "Pin/Unpin Tab"
        case "signIn": item.title = account.isSignedIn ? "Account…" : "Sign In…"
        case "pictureInPicture":
            item.title = main.currentBrowser?.isInPictureInPicture == true ? "Exit Picture in Picture" : "Picture in Picture"
        case "promoteLittleWindow": return keyLittleWindow?.hasPage ?? false
        case "closeLittleWindows": return !littleWindows.isEmpty
        default: break
        }
        return true
    }

    /// Reserved shortcuts (CEF OnPreKeyEvent).
    func handleReservedKey(_ event: NSEvent) -> Bool {
        guard let action = bindings.action(for: event), Self.reservedActions.contains(action.id) else { return false }
        perform(action.id)
        return true
    }

    /// Keys the page let through (CEF OnKeyEvent). Anything we know runs here;
    /// returning false lets CEF pass the key on to the menu bar (⌘Q, ⌘H…).
    func handleUnhandledKey(_ event: NSEvent) -> Bool {
        guard let action = bindings.action(for: event) else { return false }
        perform(action.id)
        return true
    }

    func perform(_ id: String) {
        store.recordCommandUse(id)
        // A key Little Window takes the page/window actions first (⌘W, ⌘L, ⌘R…).
        if let little = keyLittleWindow, little.handle(action: id) { return }
        let current = store.selectedTabID
        switch id {
        case "newLittleWindow": openLittleWindow(url: "")
        case "closeLittleWindows": closeLittleWindows()
        case "promoteLittleWindow": break  // only meaningful while a little window is key
        case "newTab", "newWindow": main.openCommandBar(.newTab)
        case "editURL": main.openCommandBar(.editURL)
        case "newFolder":
            let f = store.createFolder(named: "New Folder", in: store.focusedSpace.pinnedContainerID, index: 0)
            main.sidebarUI.renamingID = f.id
        case "newSpace": main.showSpaceEditor(space: nil)
        case "editSpace": main.showSpaceEditor(space: store.focusedSpace)
        case "deleteSpace": confirmDeleteSpace(store.focusedSpace)
        case "closeTab":
            // Arc: "Close current tab or window".
            if current != nil { main.closeCurrentTab() } else { main.window?.performClose(nil) }
        case "closeWindow": main.window?.performClose(nil)
        case "reopenClosedTab": store.reopenLastArchived()
        case "copyURL":
            if let url = current.flatMap({ store.item($0)?.tab?.url }) { copy(url) }
        case "copyURLMarkdown":
            if let c = current, let it = store.item(c), let url = it.tab?.url { copy("[\(it.displayTitle)](\(url))") }
        case "print": main.currentBrowser?.print()
        case "capturePage": main.capturePage()
        case "find": main.showFindBar()
        case "findNext": main.findNext(forward: true)
        case "findPrevious": main.findNext(forward: false)
        case "toggleSidebar": main.toggleSidebar()
        case "toggleToolbar": store.settings.showToolbar.toggle()
        case "toggleDeveloperMode": if let url = store.selectedTab?.tab?.url { store.settings.toggleDeveloperMode(url: url) }
        case "reload": main.currentBrowser?.reload()
        case "hardReload": main.currentBrowser?.reloadIgnoringCache()
        case "stop": main.currentBrowser?.stopLoading()
        case "zoomIn": main.zoom(by: 0.5)
        case "zoomOut": main.zoom(by: -0.5)
        case "resetZoom": main.currentBrowser?.setZoomLevel(0)
        case "viewSource": main.currentBrowser?.viewSource()
        case "devTools", "jsConsole":
            // Toggle, like Chrome: ⌥⌘I closes the dock when it is already open.
            if let b = main.currentBrowser { b.hasDevTools ? b.closeDevTools() : b.showDevTools() }
        case "inspectElement": main.currentBrowser?.showDevTools()
        case "viewArchive", "openLibrary": showArchiveWindow()
        case "viewDownloads":
            NSWorkspace.shared.open(FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0])
        case "goBack": main.currentBrowser?.goBack()
        case "goForward": main.currentBrowser?.goForward()
        case "pinTab": if let c = current { store.togglePinned(c) }
        case "favoriteTab":
            if let c = current { store.isFavorite(c) ? store.removeFromFavorites(c) : store.addToFavorites(c) }
        case "renameTab": main.sidebarUI.renamingID = current
        case "duplicateTab": if let c = current { store.duplicateTab(c) }
        case "resetTab": if let c = current { main.resetPinnedTab(c) }
        case "muteTab":
            if let c = current, let t = store.item(c)?.tab {
                store.setMuted(c, !t.muted)
                main.browsers.runtime(for: c)?.browser.setAudioMuted(!t.muted)
            }
        case "clearToday": store.clearToday()
        case "pictureInPicture": main.currentBrowser?.requestPictureInPictureAutomatic(false)
        case "nextTab": main.cycleTab(1); markKeyboardFocus()
        case "previousTab": main.cycleTab(-1); markKeyboardFocus()
        case "recentTab": if let id = store.mostRecentOtherTab() { store.selectTab(id); markKeyboardFocus() }
        case "nextSpace": store.focusSpace(offset: 1)
        case "previousSpace": store.focusSpace(offset: -1)
        case "settings": showSettingsWindow()
        case "signIn": showAccountWindow()
        case "importData": main.showImport()
        default:
            if id.hasPrefix("item"), let n = Int(id.dropFirst(4)) {
                let tabs = store.visibleTabs(in: store.focusedSpaceID)
                if n - 1 < tabs.count { store.selectTab(tabs[n - 1].id); markKeyboardFocus() }
            } else if id.hasPrefix("space"), let n = Int(id.dropFirst(5)) {
                if n - 1 < store.spaceOrder.count { store.focusSpace(store.spaceOrder[n - 1]) }
            }
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    func confirmDeleteSpace(_ space: Space) {
        guard store.spaceOrder.count > 1 else {
            let a = NSAlert()
            a.messageText = "You need at least one space."
            a.runModal()
            return
        }
        let a = NSAlert()
        a.messageText = "Delete “\(space.title)”?"
        a.informativeText = "Its tabs move to the archive, where you can restore them."
        a.addButton(withTitle: "Delete")
        a.addButton(withTitle: "Cancel")
        a.alertStyle = .warning
        if a.runModal() == .alertFirstButtonReturn { store.deleteSpace(space.id) }
    }

    func startGoogleSignIn() {
        Task {
            guard let url = await account.googleSignInURL() else {
                account.lastError = "Google sign-in is not configured on the server."
                return
            }
            store.createTab(url: url.absoluteString, select: true)
            main.showWindow(nil)
        }
    }

    // MARK: Windows

    func showSettingsWindow() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 640), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Settings"
            w.contentView = NSHostingView(rootView: SettingsView(onImport: { [weak self] in self?.main.showImport() }, onOpenURL: { [weak self] url in guard let self else { return }; _ = self.store.createTab(url: url, select: true); self.settingsWindow?.close() },
                                                                onAccount: { [weak self] in self?.showAccountWindow() })
                .environment(store).environment(bindings).environment(account))
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func showAccountWindow() {
        if accountWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 360), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "Cra Account"
            w.contentView = NSHostingView(rootView: AccountView(onGoogle: { [weak self] in self?.startGoogleSignIn() },
                                                               onRestore: { [weak self] doc in self?.store.replaceDocument(doc) })
                .environment(account).environment(store))
            w.isReleasedWhenClosed = false
            w.center()
            accountWindow = w
        }
        accountWindow?.makeKeyAndOrderFront(nil)
    }

    func showArchiveWindow() {
        if archiveWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "Library"
            w.contentView = NSHostingView(rootView: ArchiveView(onRestore: { [weak self] id in
                self?.store.restoreArchived(id)
                self?.archiveWindow?.close()
                self?.main.showWindow(nil)
            }).environment(store).environment(favicons))
            w.isReleasedWhenClosed = false
            w.center()
            archiveWindow = w
        }
        archiveWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: Menus (Arc's layout)

    private func item(_ id: String) -> NSMenuItem {
        guard let a = bindings.action(id) else { return NSMenuItem() }
        let m = NSMenuItem(title: a.name, action: #selector(menuAction(_:)), keyEquivalent: "")
        m.representedObject = a.id
        m.target = self
        if let s = a.primary {
            m.keyEquivalent = s.key
            m.keyEquivalentModifierMask = s.flags
        }
        return m
    }

    private func std(_ title: String, _ sel: Selector, _ key: String = "", _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let m = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        m.keyEquivalentModifierMask = mods
        return m
    }

    func buildMenus() {
        let menubar = NSMenu()

        let appMenu = NSMenu(title: "Cra")
        appMenu.addItem(withTitle: "About Cra", action: #selector(showAbout), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(item("settings"))
        appMenu.addItem(item("signIn"))
        appMenu.addItem(item("importData"))
        appMenu.addItem(.separator())
        appMenu.addItem(std("Hide Cra", #selector(NSApplication.hide(_:)), "h"))
        appMenu.addItem(std("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]))
        appMenu.addItem(std("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        appMenu.addItem(.separator())
        appMenu.addItem(std("Quit Cra", #selector(NSApplication.terminate(_:)), "q"))
        menubar.addItem(submenu: appMenu, title: "Cra")

        let file = NSMenu(title: "File")
        for id in ["newTab", "newWindow", "newLittleWindow", "reopenClosedTab", "editURL", "newFolder", "newSpace"] { file.addItem(item(id)) }
        file.addItem(.separator())
        file.addItem(item("closeWindow")); file.addItem(item("closeTab"))
        file.addItem(.separator())
        file.addItem(item("capturePage")); file.addItem(item("print"))
        menubar.addItem(submenu: file, title: "File")

        let edit = NSMenu(title: "Edit")
        edit.addItem(std("Undo", Selector(("undo:")), "z"))
        edit.addItem(std("Redo", Selector(("redo:")), "z", [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(std("Cut", #selector(NSText.cut(_:)), "x"))
        edit.addItem(std("Copy", #selector(NSText.copy(_:)), "c"))
        edit.addItem(item("copyURL")); edit.addItem(item("copyURLMarkdown"))
        edit.addItem(std("Paste", #selector(NSText.paste(_:)), "v"))
        edit.addItem(std("Paste and Match Style", Selector(("pasteAsPlainText:")), "v", [.command, .shift]))
        edit.addItem(std("Delete", #selector(NSText.delete(_:))))
        edit.addItem(std("Select All", #selector(NSText.selectAll(_:)), "a"))
        edit.addItem(.separator())
        let find = NSMenu(title: "Find")
        find.addItem(item("find")); find.addItem(item("findNext")); find.addItem(item("findPrevious"))
        edit.addItem(submenu: find, title: "Find")
        menubar.addItem(submenu: edit, title: "Edit")

        let view = NSMenu(title: "View")
        view.addItem(item("toggleSidebar")); view.addItem(item("toggleToolbar"))
        view.addItem(.separator())
        view.addItem(item("stop")); view.addItem(item("reload")); view.addItem(item("hardReload"))
        view.addItem(.separator())
        view.addItem(item("resetZoom")); view.addItem(item("zoomIn")); view.addItem(item("zoomOut"))
        view.addItem(.separator())
        view.addItem(item("pictureInPicture"))
        view.addItem(.separator())
        let dev = NSMenu(title: "Developer")
        for id in ["viewSource", "devTools", "inspectElement", "jsConsole"] { dev.addItem(item(id)) }
        dev.addItem(.separator())
        dev.addItem(item("toggleDeveloperMode"))
        view.addItem(submenu: dev, title: "Developer")
        view.addItem(.separator())
        view.addItem(std("Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control]))
        menubar.addItem(submenu: view, title: "View")

        let spaces = NSMenu(title: "Spaces")
        spaces.addItem(item("nextSpace")); spaces.addItem(item("previousSpace"))
        spaces.addItem(.separator())
        spaces.addItem(item("editSpace")); spaces.addItem(item("deleteSpace"))
        spaces.addItem(.separator())
        for n in 1...9 { spaces.addItem(item("space\(n)")) }
        menubar.addItem(submenu: spaces, title: "Spaces")

        let tabs = NSMenu(title: "Tabs")
        for id in ["newTab", "pinTab", "nextTab", "previousTab", "recentTab", "clearToday"] { tabs.addItem(item(id)) }
        tabs.addItem(.separator())
        for id in ["favoriteTab", "renameTab", "duplicateTab", "resetTab", "muteTab"] { tabs.addItem(item(id)) }
        tabs.addItem(.separator())
        for n in 1...9 { tabs.addItem(item("item\(n)")) }
        menubar.addItem(submenu: tabs, title: "Tabs")

        let archive = NSMenu(title: "Archive")
        archive.addItem(item("goBack")); archive.addItem(item("goForward")); archive.addItem(item("viewArchive"))
        menubar.addItem(submenu: archive, title: "Archive")

        let window = NSMenu(title: "Window")
        window.addItem(std("Minimize Window", #selector(NSWindow.performMiniaturize(_:)), "m"))
        window.addItem(std("Zoom", #selector(NSWindow.performZoom(_:))))
        window.addItem(.separator())
        window.addItem(item("openLibrary")); window.addItem(item("viewDownloads"))
        window.addItem(.separator())
        window.addItem(item("promoteLittleWindow")); window.addItem(item("closeLittleWindows"))
        window.addItem(.separator())
        window.addItem(std("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        menubar.addItem(submenu: window, title: "Window")
        NSApp.windowsMenu = window

        let help = NSMenu(title: "Help")
        help.addItem(withTitle: "Chromium \(CraCEFRuntime.chromiumVersion()) · CEF \(CraCEFRuntime.cefVersion())", action: nil, keyEquivalent: "")
        menubar.addItem(submenu: help, title: "Help")
        NSApp.helpMenu = help

        NSApp.mainMenu = menubar
    }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Cra",
            .applicationVersion: "0.2",
            .version: "Chromium \(CraCEFRuntime.chromiumVersion())",
        ])
    }
}

private extension NSMenu {
    func addItem(submenu: NSMenu, title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        addItem(item)
    }
}
