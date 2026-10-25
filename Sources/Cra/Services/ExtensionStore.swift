import AppKit
import CryptoKit
import Observation

/// Unpacked Chrome extensions, one folder each, loaded at start-up with
/// --load-extension by the Chrome-style page windows.
@MainActor
@Observable
final class ExtensionStore {
    struct Entry: Identifiable, Hashable {
        let id: String          // folder name
        let name: String
        let version: String
        let description: String
        let url: URL
        /// Chromium's extension ID (from the manifest key, else the folder path).
        var extensionID: String = ""
        /// Manifest icon for menus (16 px preferred).
        var icon: NSImage?
        /// action / browser_action / page_action default_popup, relative to the folder.
        var popupPath: String?
        /// options_ui.page or options_page, relative to the folder.
        var optionsPath: String?
    }

    /// The menu bar's Extensions menu and the toolbar read this one.
    static let shared = ExtensionStore()

    /// CraCEF loads the same folder (it also honours CRA_DATA_DIR).
    nonisolated static var directory: URL { AppPaths.supportDir.appendingPathComponent("Extensions", isDirectory: true) }

    nonisolated static func isInstalled(id: String) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(id).appendingPathComponent("manifest.json").path)
    }

    /// Copies an extension imported from Arc or Dia in as Extensions/<id>,
    /// replacing an older copy of the same extension.
    nonisolated static func importExtension(_ ext: ImportableExtension) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let dest = directory.appendingPathComponent(ext.id, isDirectory: true)
        let staging = directory.appendingPathComponent(".\(ext.id).importing", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.copyItem(at: ext.folder, to: staging)
        // Web Store verification hashes (_metadata) do not apply to an unpacked copy.
        try? fm.removeItem(at: staging.appendingPathComponent("_metadata"))
        try? fm.removeItem(at: dest)
        try fm.moveItem(at: staging, to: dest)
    }

    private(set) var entries: [Entry] = []
    /// Set once the folder changed in this session; a restart loads the change.
    private(set) var needsRestart = false

    init() { reload() }

    func reload() {
        let fm = FileManager.default
        try? fm.createDirectory(at: ExtensionStore.directory, withIntermediateDirectories: true)
        let names = (try? fm.contentsOfDirectory(atPath: ExtensionStore.directory.path)) ?? []
        entries = names.sorted().compactMap { name in
            let dir = ExtensionStore.directory.appendingPathComponent(name, isDirectory: true)
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
                  let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            func str(_ k: String) -> String { (m[k] as? String) ?? "" }
            var title = ExtensionImporter.localized(str("name"), manifest: m, folder: dir)
            if title.hasPrefix("__MSG_") { title = name }
            let action = (m["action"] ?? m["browser_action"] ?? m["page_action"]) as? [String: Any]
            let options = (m["options_ui"] as? [String: Any])?["page"] as? String ?? m["options_page"] as? String
            return Entry(id: name, name: title.isEmpty ? name : title, version: str("version"), description: str("description"), url: dir,
                         extensionID: Self.chromiumID(key: m["key"] as? String, folder: dir),
                         icon: ExtensionImporter.icon(manifest: m, folder: dir, minPixels: 16),
                         popupPath: (action?["default_popup"] as? String).flatMap { $0.isEmpty ? nil : $0 }, optionsPath: options)
        }
        pinnedIDs.removeAll { id in !entries.contains { $0.extensionID == id } }
    }

    /// Chromium's ID: the first 128 bits of SHA-256 over the manifest key (or the
    /// unpacked folder's path), each hex digit mapped 0-f → a-p.
    static func chromiumID(key: String?, folder: URL) -> String {
        let input = key.flatMap { Data(base64Encoded: $0) } ?? Data(folder.path.utf8)
        let digest = SHA256.hash(data: input).prefix(16)
        let a = UInt8(ascii: "a")
        return String(decoding: digest.flatMap { [a + ($0 >> 4), a + ($0 & 0xF)] }, as: UTF8.self)
    }

    // MARK: Pinned extensions (Dia's Extensions ▸ Pin Extensions…; toolbar buttons)

    private static var pinnedFile: URL { AppPaths.file("pinned-extensions.json") }

    /// Chromium extension IDs in toolbar order.
    private(set) var pinnedIDs: [String] = (try? JSONDecoder().decode([String].self, from: Data(contentsOf: ExtensionStore.pinnedFile))) ?? []

    func isPinned(_ id: String) -> Bool { pinnedIDs.contains(id) }

    func setPinned(_ id: String, _ pinned: Bool) {
        guard pinned != isPinned(id) else { return }
        if pinned { pinnedIDs.append(id) } else { pinnedIDs.removeAll { $0 == id } }
        savePinned()
    }

    func movePinned(_ id: String, to index: Int) {
        guard let from = pinnedIDs.firstIndex(of: id) else { return }
        pinnedIDs.remove(at: from)
        pinnedIDs.insert(id, at: min(max(0, index), pinnedIDs.count))
        savePinned()
    }

    private func savePinned() {
        try? JSONEncoder().encode(pinnedIDs).write(to: Self.pinnedFile, options: .atomic)
        NotificationCenter.default.post(name: .craPinnedExtensionsChanged, object: self)
    }

    /// Copies an unpacked extension folder (one that holds manifest.json) in.
    func add(folder: URL) throws {
        let fm = FileManager.default
        guard fm.fileExists(atPath: folder.appendingPathComponent("manifest.json").path) else {
            throw NSError(domain: "Cra", code: 1, userInfo: [NSLocalizedDescriptionKey: "That folder has no manifest.json."])
        }
        var dest = ExtensionStore.directory.appendingPathComponent(folder.lastPathComponent, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: dest.path) {
            dest = ExtensionStore.directory.appendingPathComponent("\(folder.lastPathComponent)-\(n)", isDirectory: true)
            n += 1
        }
        try fm.copyItem(at: folder, to: dest)
        needsRestart = true
        reload()
    }

    func remove(_ entry: Entry) {
        try? FileManager.default.removeItem(at: entry.url)
        needsRestart = true
        reload()
    }
}

extension Notification.Name {
    static let craPinnedExtensionsChanged = Notification.Name("craPinnedExtensionsChanged")
}
