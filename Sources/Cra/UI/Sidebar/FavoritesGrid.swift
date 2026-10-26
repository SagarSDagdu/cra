import SwiftUI

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
    @Environment(\.sidebarActions) private var actions
    @State private var hover = false
    @State private var targeted = false

    private var selected: Bool { store.selectedTabID(in: space.id) == item.id }

    var body: some View {
        let session = ui
        ZStack {
            // Arc 1.170: 13pt circular corners; the active tile is the hover fill
            // with a 2pt darker rim, inactive tiles sit ~4.5% darker than the sidebar.
            RoundedRectangle(cornerRadius: 13)
                // Arc 1.170 over white: tile 207/194/166, hovered tile 197/184/158 (another ~4.5% black on top of the tile fill).
                .fill(selected ? (palette.isDark ? Color.white.opacity(0.13) : Color.white.opacity(0.38))
                      : (hover || targeted ? (palette.isDark ? Color.white.opacity(0.15) : Color.black.opacity(0.09)) : palette.pillFill))
            if selected {
                RoundedRectangle(cornerRadius: 13)
                    .strokeBorder(palette.isDark ? Color.white.opacity(0.14) : Color.black.opacity(0.17), lineWidth: 2)
            }
            if ui.keyboardFocusID == item.id { FocusRing(radius: 13) }
            FaviconView(key: item.tab?.faviconKey, palette: palette, size: 20)
            if item.isUnread && !selected {
                Circle().fill(palette.textPrimary.opacity(0.6)).frame(width: 6, height: 6)
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
            Button("Close") { actions.closeTab(item.id) }
            Button("Archive") { store.archiveTab(item.id, reason: .manual) }
        }
    }
}
