import AppKit
import Observation
import QuickLookThumbnailing

/// Finished downloads, newest last, for the list Arc shows when you hover the Library
/// button (its downloads tray). Kept in downloads.json; files deleted since drop out.
@MainActor
@Observable
final class DownloadHistory {
    static let shared = DownloadHistory()

    struct Entry: Codable, Identifiable, Equatable {
        let id: UUID
        var path: String
        var date: Date
    }

    /// Arc 1.170 listed every recent download it still had on disk (four, oldest at the
    /// top); how many it shows at most was not observed.
    static let listLimit = 5

    private(set) var entries: [Entry]
    /// Quick Look thumbnails by path, made on demand.
    private(set) var thumbnails: [String: NSImage] = [:]
    @ObservationIgnored private let file = JSONStore<[Entry]>("downloads.json")
    @ObservationIgnored private var loading: Set<String> = []

    private init() {
        entries = file.load(or: { [] })
    }

    /// The hover list: newest downloads still on disk, oldest first.
    var recent: [Entry] {
        Array(entries.filter { FileManager.default.fileExists(atPath: $0.path) }.suffix(Self.listLimit))
    }

    @discardableResult
    func add(path: String) -> Entry {
        let entry = Entry(id: UUID(), path: path, date: Date())
        entries.append(entry)
        if entries.count > 200 { entries.removeFirst(entries.count - 200) }
        file.save(entries)
        return entry
    }

    /// A renamed (or reverted) file keeps its place in the list.
    func move(from old: String, to new: String) {
        guard let i = entries.lastIndex(where: { $0.path == old }) else { return }
        entries[i].path = new
        thumbnails[new] = thumbnails.removeValue(forKey: old)
        file.save(entries)
    }

    func thumbnail(for path: String) -> NSImage? {
        if let image = thumbnails[path] { return image }
        loadThumbnail(path)
        return nil
    }

    private func loadThumbnail(_ path: String) {
        guard !loading.contains(path) else { return }
        loading.insert(path)
        let request = QLThumbnailGenerator.Request(fileAt: URL(fileURLWithPath: path), size: CGSize(width: 40, height: 40),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 2, representationTypes: .thumbnail)
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] thumbnail, _ in
            let image = thumbnail?.nsImage
            DispatchQueue.main.async {
                guard let self else { return }
                self.loading.remove(path)
                self.thumbnails[path] = image ?? NSWorkspace.shared.icon(forFile: path)
            }
        }
    }
}
