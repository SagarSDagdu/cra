import AppKit
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
    }

    static let directory: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Cra/Extensions", isDirectory: true)

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
            var title = str("name")
            if title.hasPrefix("__MSG_") { title = name }   // localized names need the extension's locale files
            return Entry(id: name, name: title.isEmpty ? name : title, version: str("version"), description: str("description"), url: dir)
        }
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
