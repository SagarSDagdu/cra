import AppKit
import Observation
import ServiceManagement

/// Default browser, Dock tile and login item: what Dia's onboarding step
/// (NewDefaultBrowserController: DefaultBrowserClient, DockClient,
/// LaunchAtLoginClient) and Arc's "Set as Default Browser" menu item change.
/// See docs/arc-reverse-engineering.md, "Default browser".
@MainActor
@Observable
final class SystemIntegration {
    static let shared = SystemIntegration()

    private(set) var isDefaultBrowser = false
    /// The app that opens web links now, when it is not Cra.
    private(set) var defaultBrowserURL: URL?
    private(set) var isInDock = false
    private(set) var launchesAtLogin = false
    /// The system's "change your default web browser" dialog is up.
    private(set) var isPromptingDefault = false

    var defaultBrowserName: String? {
        defaultBrowserURL.map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
    }

    private init() {
        refresh()
        // The default browser and login items can change in System Settings while Cra runs.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func refresh() {
        let handler = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)
        let isCra = handler.flatMap { Bundle(url: $0)?.bundleIdentifier } == Bundle.main.bundleIdentifier
        if isDefaultBrowser != isCra { isDefaultBrowser = isCra }
        let other = isCra ? nil : handler
        if defaultBrowserURL != other { defaultBrowserURL = other }
        let docked = Dock.contains(bundleID: Bundle.main.bundleIdentifier ?? "", in: Dock.persistentApps())
        if isInDock != docked { isInDock = docked }
        let login = SMAppService.mainApp.status == .enabled
        if launchesAtLogin != login { launchesAtLogin = login }
    }

    /// Asks macOS to make Cra the default browser; the system shows its own
    /// confirmation, and declining it leaves the old browser in place.
    @discardableResult
    func makeDefaultBrowser() async -> Bool {
        refresh()
        guard !isDefaultBrowser, !isPromptingDefault else { return isDefaultBrowser }
        isPromptingDefault = true
        defer { isPromptingDefault = false }
        let app = Bundle.main.bundleURL
        do {
            // One confirmation covers http, https and HTML files; https is asked
            // for separately only if LaunchServices left it behind.
            try await NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "http")
            if NSWorkspace.shared.urlForApplication(toOpen: URL(string: "https://example.com")!)?.standardizedFileURL != app.standardizedFileURL {
                try await NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: "https")
            }
        } catch {
            NSLog("Cra: default browser not changed: \(error.localizedDescription)")
        }
        refresh()
        return isDefaultBrowser
    }

    /// Puts Cra's tile next to the current default browser's (Dia's DockClient
    /// order: beforeDefaultBrowser / afterDefaultBrowser) and restarts the Dock.
    @discardableResult
    func addToDock() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let apps = Dock.persistentApps()
        guard !Dock.contains(bundleID: id, in: apps) else { isInDock = true; return true }
        let updated = Dock.inserting(app: Bundle.main.bundleURL, bundleID: id, into: apps,
                                     after: defaultBrowserURL.flatMap { Bundle(url: $0)?.bundleIdentifier })
        guard Dock.write(updated) else { return false }
        isInDock = true
        return true
    }

    /// Returns an error message when macOS refused the change.
    @discardableResult
    func setLaunchAtLogin(_ on: Bool) -> String? {
        defer { refresh() }
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            if on && SMAppService.mainApp.status == .requiresApproval {
                return "Allow Cra in System Settings ▸ General ▸ Login Items."
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}

/// The Dock's `persistent-apps` list (com.apple.dock), read and written the way
/// `defaults` does; the Dock only picks a change up when it restarts.
enum Dock {
    static let domain = "com.apple.dock" as CFString
    static let key = "persistent-apps" as CFString

    static func persistentApps() -> [[String: Any]] {
        CFPreferencesCopyAppValue(key, domain) as? [[String: Any]] ?? []
    }

    static func bundleID(of tile: [String: Any]) -> String? {
        (tile["tile-data"] as? [String: Any])?["bundle-identifier"] as? String
    }

    static func contains(bundleID id: String, in apps: [[String: Any]]) -> Bool {
        !id.isEmpty && apps.contains { bundleID(of: $0) == id }
    }

    /// The list with a tile for `app` after the tile of `neighbour`, or at the end.
    static func inserting(app: URL, bundleID id: String, into apps: [[String: Any]], after neighbour: String?) -> [[String: Any]] {
        let tile: [String: Any] = [
            "tile-type": "file-tile",
            "tile-data": [
                "bundle-identifier": id,
                "file-label": FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: ""),
                "file-type": 41,
                "file-data": ["_CFURLString": app.absoluteString, "_CFURLStringType": 15] as [String: Any],
            ] as [String: Any],
        ]
        var out = apps
        let index = neighbour.flatMap { n in apps.firstIndex { bundleID(of: $0) == n } }.map { $0 + 1 } ?? apps.count
        out.insert(tile, at: index)
        return out
    }

    static func write(_ apps: [[String: Any]]) -> Bool {
        CFPreferencesSetAppValue(key, apps as CFArray, domain)
        guard CFPreferencesAppSynchronize(domain) else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        p.arguments = ["Dock"]
        do { try p.run() } catch { return false }
        return true
    }
}
