import SwiftUI

/// Bottom row like Arc's: library/archive at the left, tiny space icons in
/// the middle (inactive ones dimmed), "+" at the right.
struct SpaceDock: View {
    let palette: SpacePalette
    @Environment(SidebarStore.self) private var store
    @Environment(\.sidebarActions) private var actions

    var body: some View {
        HStack(spacing: 0) {
            LibraryButton(palette: palette) { actions.showArchive() }
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


/// Arc's Library glyph: a filled box with a small confetti puff (cloud, dot,
/// triangle) rising from it. Same hit area and hover fill as `SidebarIconButton`.
struct LibraryButton: View {
    let palette: SpacePalette
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        let ink = palette.isDark ? Color.white.opacity(0.55) : Color.black.opacity(0.26)
        Button(action: action) {
            ZStack(alignment: .top) {
                // Arc's box has no lid line: a 13×10 rounded box with a light slot near the top.
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .frame(width: 14, height: 11)
                    .overlay(alignment: .top) {
                        Capsule().fill(palette.isDark ? Color.black.opacity(0.5) : Color.white.opacity(0.7))
                            .frame(width: 5, height: 1.6).padding(.top, 2.4)
                    }
                    .offset(y: 8)
                HStack(alignment: .bottom, spacing: 1) {
                    Image(systemName: "cloud.fill").font(.system(size: 7, weight: .bold))
                    Circle().frame(width: 2, height: 2).offset(y: -4)
                    Image(systemName: "triangle.fill").font(.system(size: 4, weight: .bold)).offset(y: -1)
                }
                .offset(x: 2, y: -1)
            }
            .foregroundStyle(ink)
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hover ? palette.hoverFill : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help("Library (⇧⌘L)")
    }
}
