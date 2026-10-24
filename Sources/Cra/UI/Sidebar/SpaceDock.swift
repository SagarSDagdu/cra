import SwiftUI

/// Bottom row like Arc's: library/archive at the left, tiny space icons in
/// the middle (inactive ones dimmed), "+" at the right.
struct SpaceDock: View {
    let palette: SpacePalette
    @Environment(SidebarStore.self) private var store
    @Environment(\.sidebarActions) private var actions

    var body: some View {
        HStack(spacing: 0) {
            SidebarIconButton(symbol: "archivebox", palette: palette, help: "Library (⇧⌘L)") { actions.showArchive() }
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                ForEach(store.orderedSpaces) { space in
                    SpaceDockButton(space: space, palette: palette, selected: space.id == store.focusedSpaceID)
                }
            }
            Spacer(minLength: 0)
            SidebarIconButton(symbol: "plus", palette: palette, help: "New Space") { actions.editSpace(nil) }
        }
        .frame(height: 36)
    }
}

struct SpaceDockButton: View {
    let space: Space
    let palette: SpacePalette
    let selected: Bool
    @Environment(SidebarStore.self) private var store
    @Environment(\.sidebarActions) private var actions
    @State private var hover = false
    @State private var targeted = false

    var body: some View {
        Text(space.emoji)
            .font(.system(size: 13))
            .frame(width: 26, height: 26)
            .opacity(selected || hover ? 1 : 0.45)
            .saturation(selected || hover ? 1 : 0.2)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(targeted ? palette.hoverFill : .clear))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture { store.focusSpace(space.id) }
            .help(space.title)
            .dropDestination(for: SidebarDragItem.self) { items, _ in
                guard let d = items.first else { return false }
                store.moveTab(d.id, toSpace: space.id)
                return true
            } isTargeted: { targeted = $0 }
            .contextMenu {
                Button("Edit Space…") { actions.editSpace(space) }
                Divider()
                Button("Move Left") { if let i = store.spaceOrder.firstIndex(of: space.id) { store.moveSpace(space.id, to: max(0, i - 1)) } }
                Button("Move Right") { if let i = store.spaceOrder.firstIndex(of: space.id) { store.moveSpace(space.id, to: i + 1) } }
                Divider()
                Button("Delete Space…") { store.focusSpace(space.id); actions.performAction("deleteSpace") }
            }
    }
}
