import SwiftUI
import UniformTypeIdentifiers

/// Arc's "top apps": a 4-wide grid of favorite tiles. Arc shares them between
/// spaces; in Cra every space has its own.
struct FavoritesGrid: View {
    let space: Space
    let palette: SpacePalette
    @Environment(SidebarStore.self) private var store
    @Environment(SidebarUIState.self) private var ui
    @Environment(\.sidebarActions) private var actions
    @State private var targeted = false

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)

    var body: some View {
        let favorites = store.tabs(under: space.favoritesContainerID)
        VStack(spacing: 0) {
            if !favorites.isEmpty {
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(favorites) { item in FavoriteCell(item: item, space: space, palette: palette) }
                }
            }
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(palette.textTertiary.opacity(targeted ? 0.6 : 0), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .background(RoundedRectangle(cornerRadius: 10).fill(targeted ? palette.hoverFill : .clear))
                .frame(height: targeted ? 36 : (favorites.isEmpty ? 8 : 6))
                .overlay {
                    if targeted { Text("Add to Favorites").font(.system(size: 11, weight: .medium)).foregroundStyle(palette.textSecondary) }
                }
                .padding(.top, favorites.isEmpty ? 0 : 4)
                .animation(.easeOut(duration: 0.15), value: targeted)
                .dropDestination(for: SidebarDragItem.self) { items, _ in
                    guard let d = items.first else { return false }
                    store.addToFavorites(d.id, in: space.id)
                    return true
                } isTargeted: { targeted = $0 }
        }
    }
}

/// Arc's keyboard-focus ring: 2pt systemYellow with black 6/6 dashes, inside the edge.
struct FocusRing: View {
    let radius: CGFloat
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color(red: 1, green: 0.8, blue: 0), lineWidth: 2)
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Color.black.opacity(0.92), style: StrokeStyle(lineWidth: 2, dash: [6, 6]))
        }
        .allowsHitTesting(false)
    }
}

struct FavoriteCell: View {
    let item: SidebarItem
    let space: Space
    let palette: SpacePalette
    @Environment(SidebarStore.self) private var store
    @Environment(SidebarUIState.self) private var ui
    @Environment(FaviconCache.self) private var favicons
    @Environment(\.sidebarActions) private var actions
    @State private var hover = false
    @State private var targeted = false

    private var selected: Bool { store.selectedTabID(in: space.id) == item.id }
    private var tileColor: String? { item.tab?.tileColor }
    private var tileIsDark: Bool { tileColor.flatMap(HexColor.luminance).map { $0 < 0.5 } ?? palette.isDark }

    var body: some View {
        let session = ui
        ZStack {
            if let tileColor {
                // A picked color keeps its hue in every state; hover and selection shade it.
                RoundedRectangle(cornerRadius: 13).fill(Color(hex: tileColor))
                if selected || hover || targeted {
                    RoundedRectangle(cornerRadius: 13).fill(tileIsDark ? Color.white.opacity(0.12) : Color.black.opacity(0.07))
                }
            } else {
                // Arc 1.170: 13pt circular corners; the active tile is the hover fill
                // with a 2pt darker rim, inactive tiles sit ~4.5% darker than the sidebar.
                RoundedRectangle(cornerRadius: 13)
                    // Arc 1.170 over white: tile 207/194/166, hovered tile 197/184/158 (another ~4.5% black on top of the tile fill).
                    .fill(selected ? (palette.isDark ? Color.white.opacity(0.13) : Color.white.opacity(0.38))
                          : (hover || targeted ? (palette.isDark ? Color.white.opacity(0.15) : Color.black.opacity(0.09)) : palette.pillFill))
            }
            if selected {
                RoundedRectangle(cornerRadius: 13)
                    .strokeBorder(tileIsDark ? Color.white.opacity(0.14) : Color.black.opacity(0.17), lineWidth: 2)
            }
            if ui.keyboardFocusID == item.id { FocusRing(radius: 13) }
            FaviconView(key: item.tab?.iconKey, palette: palette, size: 20, onDark: tileIsDark)
            if item.isUnread && !selected {
                Circle().fill((tileColor == nil ? palette.textPrimary : (tileIsDark ? .white : .black)).opacity(0.6)).frame(width: 6, height: 6)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(5)
            }
        }
        .frame(height: 47)
        .contentShape(RoundedRectangle(cornerRadius: 13))
        .onHover { hover = $0; ui.hoverDraggable(item.id, $0) }
        .onTapGesture { ui.keyboardFocusID = nil; store.selectTab(item.id) }
        .help(item.displayTitle)
        .draggable(SidebarDragItem.begin(item.id, session))
        .dropDestination(for: SidebarDragItem.self) { items, location in
            guard let d = items.first, d.id != item.id,
                  let idx = store.item(space.favoritesContainerID)?.children.firstIndex(of: item.id) else { return false }
            store.moveItem(d.id, to: space.favoritesContainerID, index: idx + (location.x > 30 ? 1 : 0))
            return true
        } isTargeted: { targeted = $0 }
        .contextMenu {
            Button("Remove from Favorites") { store.removeFromFavorites(item.id) }
            Button("Rename…") { ui.renamingID = item.id }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.tab?.url ?? "", forType: .string)
            }
            if let t = item.tab, t.url != t.savedURL { Button("Back to Pinned Page") { actions.resetPinnedTab(item.id) } }
            Button("Make This the Pinned Page") { store.setPinnedHomeToCurrent(item.id) }
            Divider()
            Button("Change Icon…") { pickIcon() }
            if let key = item.tab?.customIconKey {
                Button("Use Site Icon") {
                    store.setCustomIcon(nil, for: item.id)
                    favicons.removeCustomIcon(key)
                }
            }
            tileColorMenu
            Divider()
            Button("Close") { actions.closeTab(item.id) }
            Button("Archive") { store.archiveTab(item.id, reason: .manual) }
        }
    }

    private var tileColorMenu: some View {
        Menu("Tile Color") {
            colorToggle("Default", hex: nil)
            ForEach(TileColor.presets, id: \.hex) { colorToggle($0.name, hex: $0.hex) }
            if let tileColor, !TileColor.presets.contains(where: { $0.hex == tileColor }) {
                colorToggle("Custom", hex: tileColor)
            }
            Button("Other Color…") {
                let id = item.id
                TileColorPanel.shared.show(tileColor) { [store] hex in store.setTileColor(hex, for: [id]) }
            }
            Divider()
            Button("Use This Color for All Favorites") {
                store.setTileColor(tileColor, for: store.tabs(under: space.favoritesContainerID).map(\.id))
            }
        }
    }

    private func colorToggle(_ name: String, hex: String?) -> some View {
        Toggle(isOn: Binding(get: { tileColor == hex }, set: { _ in store.setTileColor(hex, for: [item.id]) })) {
            Label { Text(name) } icon: { Image(nsImage: TileColor.swatch(hex)) }
        }
    }

    private func pickIcon() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Icon"
        panel.message = "Choose an image for \(item.displayTitle)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let key = favicons.importCustomIcon(from: url) else { NSSound.beep(); return }
        let old = item.tab?.customIconKey
        store.setCustomIcon(key, for: item.id)
        if let old { favicons.removeCustomIcon(old) }
    }
}

/// Tile backgrounds offered in a favorite's "Tile Color" menu.
enum TileColor {
    static let presets: [(name: String, hex: String)] = [
        ("White", "#FFFFFF"), ("Light Gray", "#D9D9DE"), ("Graphite", "#48484A"), ("Black", "#000000"),
        ("Red", "#FF453A"), ("Orange", "#FF9F0A"), ("Yellow", "#FFD60A"), ("Green", "#30D158"),
        ("Teal", "#40C8E0"), ("Blue", "#0A84FF"), ("Purple", "#BF5AF2"), ("Pink", "#FF375F"),
    ]

    /// A 12pt dot for the menu; Default is drawn hollow.
    static func swatch(_ hex: String?) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            if let hex { NSColor(hex: hex).setFill(); path.fill() }
            NSColor.secondaryLabelColor.setStroke()
            path.lineWidth = 1
            path.stroke()
            return true
        }
    }
}

/// Routes the shared color panel to whichever favorite asked for it last.
@MainActor
final class TileColorPanel: NSObject {
    static let shared = TileColorPanel()
    private var onChange: ((String) -> Void)?

    func show(_ hex: String?, onChange: @escaping (String) -> Void) {
        let panel = NSColorPanel.shared
        // Detach first so seeding the color doesn't recolor the previous tile.
        panel.setTarget(nil)
        panel.setAction(nil)
        panel.showsAlpha = false
        panel.isContinuous = true
        if let hex { panel.color = NSColor(hex: hex) }
        self.onChange = onChange
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        panel.orderFront(nil)
    }

    @objc private func changed(_ panel: NSColorPanel) {
        guard let c = panel.color.usingColorSpace(.sRGB) else { return }
        onChange?(String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()),
                         Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded())))
    }
}
