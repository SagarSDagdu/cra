import AppKit

/// A browser the import can read: Dia's list (Arc, Brave, Chrome, Edge,
/// Firefox, Opera, Opera GX, Safari) plus Dia itself, Vivaldi, Chromium and Zen.
struct ImportSource: Identifiable, Hashable {
    enum Kind: Hashable {
        /// Arc and Dia: their own sidebar stores, and a Chromium profile for passwords and cookies.
        case arc, dia
        case chromium, firefox
        /// Safari: only what Safari exports itself.
        case safari
    }

    let id: String
    let name: String
    let bundleID: String
    let kind: Kind
    /// Chromium's "User Data" root, Firefox's profiles root, or Safari's folder.
    let dataDir: URL
    /// "<Name> Safe Storage" in the login Keychain, which encrypts passwords and cookies.
    var keychainService: String?
    var keychainAccount: String?

    var rawValue: String { name }

    private static var support: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    private static func chromium(_ id: String, _ name: String, _ bundleID: String, _ path: String, account: String) -> ImportSource {
        ImportSource(id: id, name: name, bundleID: bundleID, kind: .chromium, dataDir: support.appendingPathComponent(path, isDirectory: true),
                     keychainService: "\(account) Safe Storage", keychainAccount: account)
    }

    static let arc = ImportSource(id: "arc", name: "Arc", bundleID: "company.thebrowser.Browser", kind: .arc,
                                  dataDir: support.appendingPathComponent("Arc/User Data", isDirectory: true),
                                  keychainService: "Arc Safe Storage", keychainAccount: "Arc")
    static let dia = ImportSource(id: "dia", name: "Dia", bundleID: "company.thebrowser.dia", kind: .dia,
                                  dataDir: support.appendingPathComponent("Dia/User Data", isDirectory: true),
                                  keychainService: "Dia Safe Storage", keychainAccount: "Dia")

    static let allCases: [ImportSource] = [
        arc, dia,
        chromium("chrome", "Chrome", "com.google.Chrome", "Google/Chrome", account: "Chrome"),
        chromium("brave", "Brave", "com.brave.Browser", "BraveSoftware/Brave-Browser", account: "Brave"),
        chromium("edge", "Edge", "com.microsoft.edgemac", "Microsoft Edge", account: "Microsoft Edge"),
        chromium("opera", "Opera", "com.operasoftware.Opera", "com.operasoftware.Opera", account: "Opera"),
        chromium("operagx", "Opera GX", "com.operasoftware.OperaGX", "com.operasoftware.OperaGX", account: "Opera GX"),
        chromium("vivaldi", "Vivaldi", "com.vivaldi.Vivaldi", "Vivaldi", account: "Vivaldi"),
        chromium("chromium", "Chromium", "org.chromium.Chromium", "Chromium", account: "Chromium"),
        ImportSource(id: "firefox", name: "Firefox", bundleID: "org.mozilla.firefox", kind: .firefox,
                     dataDir: support.appendingPathComponent("Firefox", isDirectory: true)),
        ImportSource(id: "zen", name: "Zen", bundleID: "app.zen-browser.zen", kind: .firefox,
                     dataDir: support.appendingPathComponent("zen", isDirectory: true)),
        ImportSource(id: "safari", name: "Safari", bundleID: "com.apple.Safari", kind: .safari,
                     dataDir: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Safari", isDirectory: true)),
    ]

    /// Installed with data to bring over. Arc and Dia only need their data
    /// (the import also runs after they are deleted); Safari is always there.
    var isAvailable: Bool {
        switch kind {
        case .arc: return ArcImporter.isAvailable
        case .dia: return DiaImporter.isAvailable
        case .safari: return true
        case .chromium:
            return isInstalled && !ChromiumImporter.profiles(userData: dataDir).isEmpty
        case .firefox:
            return isInstalled && FirefoxImporter.defaultProfile(root: dataDir) != nil
        }
    }

    var isInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil }

    /// Safari's data arrives as an exported file instead of a plan read from disk.
    var needsExportedFile: Bool { kind == .safari }

    func plan() throws -> ImportPlan {
        switch kind {
        case .arc: return try ArcImporter.plan()
        case .dia: return try DiaImporter.plan()
        case .chromium: return try ChromiumImporter.plan(browser: name, userData: dataDir)
        case .firefox: return try FirefoxImporter.plan(browser: name, root: dataDir)
        case .safari: return ImportPlan(source: name)
        }
    }

    /// Chromium profiles whose passwords and cookies can come over.
    var credentialProfiles: [ChromiumProfile] {
        keychainService == nil ? [] : ChromiumImporter.profiles(userData: dataDir)
    }

    func topSites(limit: Int) -> [TopSite] {
        switch kind {
        case .arc, .dia, .chromium: return ChromiumImporter.topSites(userData: dataDir, limit: limit)
        case .firefox: return FirefoxImporter.topSites(root: dataDir, limit: limit)
        case .safari: return []
        }
    }

    func favicons(hosts: [String]) -> [String: NSImage] {
        switch kind {
        case .arc, .dia, .chromium: return ChromiumImporter.favicons(userData: dataDir, hosts: hosts)
        case .firefox: return FirefoxImporter.favicons(root: dataDir, hosts: hosts)
        case .safari: return [:]
        }
    }

    func extensions() -> [ImportableExtension] {
        switch kind {
        case .arc, .dia, .chromium: return ExtensionImporter.extensions(inUserData: dataDir)
        case .firefox, .safari: return []
        }
    }

    /// The installed app's own icon (Dia shows its bundled browser logos here).
    var icon: NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        return NSImage(systemSymbolName: "globe", accessibilityDescription: name) ?? NSImage()
    }
}
