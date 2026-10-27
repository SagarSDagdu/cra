import AppKit
import SwiftUI

/// The Library's pages Cra has (Arc's rail also lists Media, Easels, Spaces and Boosts).
enum LibraryPage: String, CaseIterable {
    case downloads, archive

    var title: String { self == .downloads ? "Downloads" : "Archived Tabs" }
    var symbol: String { self == .downloads ? "arrow.down.circle" : "archivebox" }
    var selectedSymbol: String { self == .downloads ? "arrow.down.circle.fill" : "archivebox.fill" }
    var searchPrompt: String { self == .downloads ? "Search Downloads…" : "Search Archive…" }
}

/// Arc's Library: not a window but a mode of the sidebar (WindowState+Library, HomeButton/*),
/// so it never ends up behind the browser. Measured on Arc 1.170 (window captures + AX tree,
/// 1728×1084 window, 27 Oct 2026):
/// - The sidebar widens from 347 to 417 pt: a 113 pt rail (a faint white wash brightening
///   toward its right edge, ending in a 1 pt hairline) and the page's list.
/// - Rail buttons 97×80 at x 8, 100 pt apart, the group centred vertically: an 18 pt glyph
///   22 pt from the top, the 12 pt semibold label under it (white 60 %). The page shown gets
///   a white 7 % fill and its glyph filled in the space's accent.
/// - The list column: a 36 pt search field ("Search Archive…") from x 120 and a Filter button
///   at the top, 10 pt from the window top; day headers ("Today", 13 pt semibold); rows 56 pt
///   apart with a 24 pt icon at x 130, the title at x 164 (14 pt) and the URL under it (12 pt).
/// - A back arrow (32×32 at x 8, 8 pt above the bottom) leaves the Library.
/// - Arc leaves it by the shortcut, Escape, that arrow or a swipe (LibraryCloseSource), never by
///   clicking elsewhere, and reopens it on the page last shown.
/// - Opening takes 2–3 frames (the Library slides in from a little to the left); closing slides
///   it left over ~0.1 s while the tab list fades back in.
enum LibraryMetrics {
    static let rail: CGFloat = 113
    /// Arc's Library sidebar was 70 pt wider than the 347 pt tab sidebar.
    static let extraWidth: CGFloat = 70
}

struct LibraryView: View {
    let page: LibraryPage
    let palette: SpacePalette
    @Environment(SidebarUIState.self) private var ui
    @Environment(\.sidebarActions) private var actions

    var body: some View {
        HStack(spacing: 0) {
            rail
            LibraryList(page: page, palette: palette)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .foregroundStyle(palette.textPrimary)
        .onExitCommand { actions.closeLibrary() }
    }

    private var ink: Color { palette.isDark ? .white : .black }

    private var rail: some View {
        VStack(spacing: 0) {
            Spacer(minLength: CraMetrics.titleAreaHeight)
            VStack(spacing: 20) {
                ForEach(LibraryPage.allCases, id: \.self) { p in
                    LibraryRailButton(page: p, selected: p == page, palette: palette) { actions.showLibrary(p) }
                }
            }
            Spacer(minLength: 0)
            HStack {
                SidebarIconButton(symbol: "arrow.left", palette: palette, help: "Exit the Library (Esc)", size: 32, height: 32,
                                  iconSize: 15, weight: .regular) { actions.closeLibrary() }
                Spacer(minLength: 0)
            }
            .padding(.leading, 8)
            .padding(.bottom, 8)
        }
        .frame(width: LibraryMetrics.rail - 1)
        .frame(maxHeight: .infinity)
        .background(LinearGradient(colors: [ink.opacity(0.02), ink.opacity(0.045)], startPoint: .leading, endPoint: .trailing))
        .overlay(alignment: .trailing) { Rectangle().fill(ink.opacity(0.09)).frame(width: 1).offset(x: 1) }
        .padding(.trailing, 1)
    }
}

private struct LibraryRailButton: View {
    let page: LibraryPage
    let selected: Bool
    let palette: SpacePalette
    let action: () -> Void
    @State private var hover = false
    private var ink: Color { palette.isDark ? .white : .black }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                Image(systemName: selected ? page.selectedSymbol : page.symbol)
                    .font(.system(size: 17, weight: .medium))
                    .symbolRenderingMode(selected ? .palette : .monochrome)
                    .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(ink.opacity(0.6)),
                                     selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(ink.opacity(0.6)))
                    .frame(height: 20)
                    .padding(.top, 21)
                Text(page.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ink.opacity(selected ? 0.82 : 0.6))
                    .lineLimit(1)
                    .padding(.top, 9)
                Spacer(minLength: 0)
            }
            .frame(width: 97, height: 80)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(ink.opacity(selected ? 0.07 : (hover ? 0.04 : 0))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(page.title)
    }
}

/// The page's list column: search, then the downloads or the archived tabs by day.
private struct LibraryList: View {
    let page: LibraryPage
    let palette: SpacePalette
    @Environment(SidebarStore.self) private var store
    @Environment(\.sidebarActions) private var actions
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    private var ink: Color { palette.isDark ? .white : .black }

    var body: some View {
        VStack(spacing: 0) {
            searchRow
                .padding(.top, 10)
                .padding(.leading, 7)
                .padding(.trailing, 8)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                    switch page {
                    case .downloads: downloads
                    case .archive: archive
                    }
                }
                .padding(.bottom, 12)
            }
            .scrollIndicators(.never)
        }
        .onChange(of: page) { _, _ in query = "" }
        .onAppear { searchFocused = true }
    }

    private var searchRow: some View {
        HStack(spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 14))
                    .foregroundStyle(ink.opacity(0.5))
                TextField(page.searchPrompt, text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($searchFocused)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(ink.opacity(0.08)))
            menu
        }
    }

    /// Arc's Filter button; Cra's holds the page's actions.
    private var menu: some View {
        Menu {
            switch page {
            case .downloads:
                Button("Open Downloads Folder") {
                    NSWorkspace.shared.open(FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0])
                }
            case .archive:
                Button("Clear Archive") { store.clearArchive() }.disabled(store.archive.isEmpty)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(ink.opacity(0.7))
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(ink.opacity(0.05)))
                .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .frame(width: 36)
    }

    private var needle: String { query.lowercased().trimmingCharacters(in: .whitespaces) }

    // MARK: Downloads

    @ViewBuilder private var downloads: some View {
        let all = DownloadHistory.shared.entries.reversed().filter { FileManager.default.fileExists(atPath: $0.path) }
        let shown = needle.isEmpty ? all : all.filter { ($0.path as NSString).lastPathComponent.lowercased().contains(needle) }
        if shown.isEmpty {
            empty(symbol: "arrow.down.circle", title: all.isEmpty ? "Nothing here yet!" : "No matches",
                  detail: all.isEmpty ? "Files you download show up here." : nil)
        } else {
            ForEach(grouped(shown, date: \.date), id: \.0) { label, entries in
                header(label)
                ForEach(entries) { LibraryDownloadRow(entry: $0, palette: palette) }
            }
        }
    }

    // MARK: Archive

    @ViewBuilder private var archive: some View {
        let shown = needle.isEmpty ? store.archive : store.archive.filter {
            $0.item.displayTitle.lowercased().contains(needle) || ($0.item.tab?.url.lowercased().contains(needle) ?? false)
        }
        if shown.isEmpty {
            empty(symbol: "archivebox", title: store.archive.isEmpty ? "Nothing here yet!" : "No matches",
                  detail: store.archive.isEmpty ? "Tabs you close end up here." : nil)
        } else {
            ForEach(grouped(shown, date: \.archivedAt), id: \.0) { label, entries in
                header(label)
                ForEach(entries) { e in
                    LibraryArchiveRow(entry: e, palette: palette) { actions.restoreArchived(e.id) }
                }
            }
        }
    }

    // MARK: Pieces

    private func header(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(ink.opacity(0.6))
            .padding(.leading, 11)
            .padding(.top, 18)
            .padding(.bottom, 6)
    }

    private func empty(symbol: String, title: String, detail: String?) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(ink.opacity(0.45))
                .padding(.bottom, 4)
            Text(title).font(.system(size: 17, weight: .semibold)).foregroundStyle(ink.opacity(0.9))
            if let detail {
                Text(detail).font(.system(size: 14)).foregroundStyle(ink.opacity(0.7)).multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.top, 260)
    }

    private func grouped<T>(_ items: [T], date: KeyPath<T, Date>) -> [(String, [T])] {
        let cal = Calendar.current
        let df = DateFormatter()
        df.dateStyle = .medium
        var order: [String] = []
        var groups: [String: [T]] = [:]
        for e in items {
            let d = e[keyPath: date]
            let label = cal.isDateInToday(d) ? "Today" : (cal.isDateInYesterday(d) ? "Yesterday" : df.string(from: d))
            if groups[label] == nil { order.append(label) }
            groups[label, default: []].append(e)
        }
        return order.map { ($0, groups[$0]!) }
    }
}

/// Arc's archive row: 24 pt icon, title over the URL, 56 pt apart.
private struct LibraryArchiveRow: View {
    let entry: ArchivedItem
    let palette: SpacePalette
    let restore: () -> Void
    @Environment(SidebarStore.self) private var store
    @Environment(FaviconCache.self) private var favicons
    @State private var hover = false
    private var ink: Color { palette.isDark ? .white : .black }

    var body: some View {
        Button(action: restore) {
            HStack(spacing: 10) {
                Group {
                    if let img = favicons.image(forKey: entry.item.tab?.faviconKey) {
                        Image(nsImage: img).resizable().frame(width: 16, height: 16)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(ink.opacity(0.04)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.item.displayTitle)
                        .font(.system(size: 14))
                        .foregroundStyle(ink.opacity(0.82))
                        .lineLimit(1)
                    Text(SuggestionEngine.humanURL(entry.item.tab?.url ?? ""))
                        .font(.system(size: 12))
                        .foregroundStyle(ink.opacity(0.55))
                        .lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 9)
            .padding(.trailing, 8)
            .frame(height: 52)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hover ? palette.hoverFill : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .onHover { hover = $0 }
        .arcTooltip(entry.item.tab?.url ?? "")
        .contextMenu {
            Button("Restore", action: restore)
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.item.tab?.url ?? "", forType: .string)
            }
            Divider()
            Button("Remove from Archive") { store.removeFromArchive(entry.id) }
        }
    }
}

/// A download: its Quick Look thumbnail, the file name and when it arrived (the hover list's row).
private struct LibraryDownloadRow: View {
    let entry: DownloadHistory.Entry
    let palette: SpacePalette
    @State private var hover = false
    private var ink: Color { palette.isDark ? .white : .black }
    private var url: URL { URL(fileURLWithPath: entry.path) }

    var body: some View {
        Button { NSWorkspace.shared.open(url) } label: {
            HStack(spacing: 10) {
                Group {
                    if let image = DownloadHistory.shared.thumbnail(for: entry.path) {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        ink.opacity(0.04)
                    }
                }
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent)
                        .font(.system(size: 14))
                        .foregroundStyle(ink.opacity(0.82))
                        .lineLimit(1).truncationMode(.middle)
                    Text(Self.age.localizedString(for: min(entry.date, Date()), relativeTo: Date()))
                        .font(.system(size: 12))
                        .foregroundStyle(ink.opacity(0.55))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 5)
            .padding(.trailing, 8)
            .frame(height: 52)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hover ? palette.hoverFill : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .onHover { hover = $0 }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            Divider()
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([url as NSURL])
            }
        }
    }

    private static let age: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()
}
