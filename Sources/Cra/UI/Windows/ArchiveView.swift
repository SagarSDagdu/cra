import SwiftUI

/// Searchable list of archived tabs grouped by day (Arc: Archive / ⌘Y).
struct ArchiveView: View {
    let onRestore: (UUID) -> Void
    @Environment(SidebarStore.self) private var store
    @Environment(FaviconCache.self) private var favicons
    @State private var query = ""

    private var filtered: [ArchivedItem] {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return store.archive }
        return store.archive.filter {
            $0.item.displayTitle.lowercased().contains(q) || ($0.item.tab?.url.lowercased().contains(q) ?? false)
        }
    }

    private var grouped: [(String, [ArchivedItem])] {
        let cal = Calendar.current
        let df = DateFormatter()
        df.dateStyle = .medium
        var order: [String] = []
        var groups: [String: [ArchivedItem]] = [:]
        for e in filtered {
            let label = cal.isDateInToday(e.archivedAt) ? "Today" : (cal.isDateInYesterday(e.archivedAt) ? "Yesterday" : df.string(from: e.archivedAt))
            if groups[label] == nil { order.append(label) }
            groups[label, default: []].append(e)
        }
        return order.map { ($0, groups[$0]!) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search archived tabs", text: $query).textFieldStyle(.plain)
                Spacer()
                Text("\(store.archive.count) tabs").foregroundStyle(.secondary).font(.system(size: 12))
                Button("Clear Archive") { store.clearArchive() }.disabled(store.archive.isEmpty)
            }
            .padding(12)
            Divider()
            if filtered.isEmpty {
                Spacer()
                Text(store.archive.isEmpty ? "Tabs you close end up here." : "No matches.").foregroundStyle(.secondary)
                Spacer()
            } else {
                List {
                    ForEach(grouped, id: \.0) { label, items in
                        Section(label) {
                            ForEach(items) { e in
                                ArchiveRow(entry: e)
                                    .contentShape(Rectangle())
                                    .onTapGesture { onRestore(e.id) }
                                    .contextMenu {
                                        Button("Restore") { onRestore(e.id) }
                                        Button("Copy Link") {
                                            NSPasteboard.general.clearContents()
                                            NSPasteboard.general.setString(e.item.tab?.url ?? "", forType: .string)
                                        }
                                        Divider()
                                        Button("Remove from Archive") { store.removeFromArchive(e.id) }
                                    }
                            }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }
}

private struct ArchiveRow: View {
    let entry: ArchivedItem
    @Environment(SidebarStore.self) private var store
    @Environment(FaviconCache.self) private var favicons
    var body: some View {
        HStack(spacing: 10) {
            if let img = favicons.image(forKey: entry.item.tab?.faviconKey) {
                Image(nsImage: img).resizable().frame(width: 16, height: 16).clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                Image(systemName: "globe").foregroundStyle(.secondary).frame(width: 16)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.item.displayTitle).lineLimit(1)
                Text(SuggestionEngine.humanURL(entry.item.tab?.url ?? "")).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            if let sid = entry.sourceSpaceID, let s = store.space(sid) {
                Text("\(s.emoji) \(s.title)").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Text(entry.reason == .auto ? "auto" : "").font(.system(size: 10)).foregroundStyle(.tertiary)
            Text(entry.archivedAt, style: .time).font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(.vertical, 2)
    }
}
