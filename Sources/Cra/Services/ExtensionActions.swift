import AppKit
import CraCEF

/// Runs an extension's toolbar action on a page the way a click on its Chrome
/// toolbar button does: `Extensions.triggerAction` over the browser-level DevTools
/// pipe. Chrome then opens the real popup (with activeTab granted) or fires
/// chrome.action.onClicked. The popup anchors to the page's hidden Chrome toolbar,
/// so Cra moves it under its own button (Arc: right edges aligned, just below the bar).
@MainActor
final class ExtensionActions {
    static let shared = ExtensionActions()

    private struct CachedTab { weak var browser: CraBrowser?; let tabTarget: String }
    /// Page browser → its "tab" target (triggerAction only accepts tab targets).
    private var tabTargets: [ObjectIdentifier: CachedTab] = [:]
    /// Tab session → callback with the page target that auto-attaches under it.
    private var childWaiters: [String: (String?) -> Void] = [:]
    private var popupObservers: [NSObjectProtocol] = []

    var isAvailable: Bool { CraCEFRuntime.hasBrowserDevTools() }

    private init() {
        // The pipe delivers on the main queue.
        CraCEFRuntime.setBrowserDevToolsEventHandler { [weak self] method, params, sessionID in
            MainActor.assumeIsolated { self?.handleEvent(method, params: params, sessionID: sessionID) }
        }
    }

    /// Triggers the action; `anchor` is the top-right point (screen coordinates) the popup hangs from.
    /// Returns false when the pipe or the page is unavailable (the caller falls back).
    @discardableResult
    func run(_ extensionID: String, on browser: CraBrowser, anchor: NSPoint) async -> Bool {
        guard isAvailable else { return false }
        do {
            let tab = try await tabTarget(for: browser)
            let before = Set(NSApp.windows.map(ObjectIdentifier.init))
            _ = try await call("Extensions.triggerAction", ["id": extensionID, "targetId": tab])
            placePopup(appearingAfter: before, anchor: anchor)
            return true
        } catch {
            NSLog("Cra: extension action %@ failed: %@", extensionID, String(describing: error))
            tabTargets[ObjectIdentifier(browser)] = nil
            return false
        }
    }

    // MARK: Popup placement

    /// Chrome shows the popup once its page has loaded; watch for the new window and keep it
    /// under the anchor (Chrome re-anchors it to the hidden toolbar whenever it resizes).
    private func placePopup(appearingAfter before: Set<ObjectIdentifier>, anchor: NSPoint, attempt: Int = 0) {
        if let popup = NSApp.windows.first(where: { !before.contains(ObjectIdentifier($0)) && $0.isVisible && $0.frame.width > 1 }) {
            for o in popupObservers { NotificationCenter.default.removeObserver(o) }
            popupObservers = []
            let pin = { [weak popup] in
                guard let popup else { return }
                let screen = (popup.screen ?? NSScreen.main)?.visibleFrame ?? .infinite
                var origin = NSPoint(x: anchor.x - popup.frame.width, y: anchor.y - popup.frame.height)
                origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - popup.frame.width - 4)
                if popup.frame.origin != origin { popup.setFrameOrigin(origin) }
            }
            pin()
            for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
                popupObservers.append(NotificationCenter.default.addObserver(forName: name, object: popup, queue: .main) { _ in
                    MainActor.assumeIsolated { pin() }
                })
            }
            popupObservers.append(NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: popup, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for o in self.popupObservers { NotificationCenter.default.removeObserver(o) }
                    self.popupObservers = []
                }
            })
            return
        }
        // No popup yet (still loading), or an action without one (onClicked): keep looking for 3 s.
        guard attempt < 60 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated { self?.placePopup(appearingAfter: before, anchor: anchor, attempt: attempt + 1) }
        }
    }

    // MARK: Targets

    private enum Failure: Error { case protocolError(String), noTabTarget }

    /// The tab target that holds this browser's page: attach to each tab target and let it
    /// auto-attach its page (the protocol has no direct page → tab link). Cached per browser.
    private func tabTarget(for browser: CraBrowser) async throws -> String {
        if let cached = tabTargets[ObjectIdentifier(browser)], cached.browser === browser { return cached.tabTarget }
        let info = try await pageCall(browser, "Target.getTargetInfo")
        guard let page = info["targetInfo"] as? [String: Any], let pageID = page["targetId"] as? String else { throw Failure.noTabTarget }
        let url = page["url"] as? String
        let tabs = (try await call("Target.getTargets", ["filter": [["type": "tab"]]])["targetInfos"] as? [[String: Any]]) ?? []
        // Same URL first: usually the only one that needs checking.
        let ordered = tabs.filter { $0["url"] as? String == url } + tabs.filter { $0["url"] as? String != url }
        for tab in ordered {
            guard let tabID = tab["targetId"] as? String else { continue }
            if try await pageTarget(inTab: tabID) == pageID {
                tabTargets[ObjectIdentifier(browser)] = CachedTab(browser: browser, tabTarget: tabID)
                return tabID
            }
        }
        throw Failure.noTabTarget
    }

    private func pageTarget(inTab tabID: String) async throws -> String? {
        let attached = try await call("Target.attachToTarget", ["targetId": tabID, "flatten": true])
        guard let session = attached["sessionId"] as? String else { return nil }
        let page: String? = await withCheckedContinuation { cont in
            childWaiters[session] = { cont.resume(returning: $0) }
            Task {
                _ = try? await self.call("Target.setAutoAttach", ["autoAttach": true, "waitForDebuggerOnStart": false, "flatten": true],
                                         session: session)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                MainActor.assumeIsolated { self?.childWaiters.removeValue(forKey: session)?(nil) }
            }
        }
        _ = try? await call("Target.detachFromTarget", ["sessionId": session])
        return page
    }

    private func handleEvent(_ method: String, params: String, sessionID: String?) {
        guard method == "Target.attachedToTarget", let sessionID, childWaiters[sessionID] != nil,
              let p = try? JSONSerialization.jsonObject(with: Data(params.utf8)) as? [String: Any],
              let info = p["targetInfo"] as? [String: Any], info["type"] as? String == "page" else { return }
        childWaiters.removeValue(forKey: sessionID)?(info["targetId"] as? String)
    }

    // MARK: Protocol calls

    private func call(_ method: String, _ params: [String: Any] = [:], session: String? = nil) async throws -> [String: Any] {
        let json = String(decoding: try JSONSerialization.data(withJSONObject: params), as: UTF8.self)
        return try await withCheckedThrowingContinuation { cont in
            CraCEFRuntime.sendBrowserDevToolsMethod(method, params: json, sessionID: session) { result, error in
                if let result, let obj = try? JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any] {
                    cont.resume(returning: obj)
                } else {
                    cont.resume(throwing: Failure.protocolError(error ?? "bad reply to \(method)"))
                }
            }
        }
    }

    private func pageCall(_ browser: CraBrowser, _ method: String) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { cont in
            browser.sendDevToolsMethod(method, params: "{}") { result, error in
                if let result, let obj = try? JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any] {
                    cont.resume(returning: obj)
                } else {
                    cont.resume(throwing: Failure.protocolError(error ?? "bad reply to \(method)"))
                }
            }
        }
    }
}
