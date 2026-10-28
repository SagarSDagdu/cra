import SwiftUI

/// Arc's sidebar cell for a split (SplitViewCellView): one row holding the
/// panes side by side, each with favicon + title and its own close button,
/// hairlines between them; the whole row highlights when the split is shown.
struct SplitRow: View {
    let item: SidebarItem
    let depth: Int
    let palette: SpacePalette
    let section: SidebarSection
    @Environment(SidebarStore.self) private var store
    @Environment(SidebarUIState.self) private var ui
    @Environment(\.sidebarActions) private var actions
    @State private var hover = false

    private var children: [SidebarItem] { store.children(of: item.id).filter { $0.isTab } }
    private var selected: Bool { children.contains { store.isSelected($0.id, window: ui.windowID) } }

    enum Metrics {
        static let separatorInset: CGFloat = 9
    }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(children.enumerated()), id: \.element.id) { i, child in
                if i > 0 {
                    Rectangle().fill(palette.separator).frame(width: 1).padding(.vertical, Metrics.separatorInset)
                }
                SplitChildCell(item: child, palette: palette, groupHovered: hover, groupSelected: selected, focused: store.isSelected(child.id, window: ui.windowID))
            }
        }
        .padding(.leading, CGFloat(depth) * CraMetrics.indent)
        .frame(height: CraMetrics.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: CraMetrics.rowCorner, style: .continuous)
                .fill(selected ? palette.selectedFill : (hover ? palette.hoverFill : .clear))
                .shadow(color: selected && !palette.isDark ? .black.opacity(0.06) : .clear, radius: 3, y: 1)
        )
        .overlay { if let f = ui.keyboardFocusID, children.contains(where: { $0.id == f }) { FocusRing(radius: CraMetrics.rowCorner) } }
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .contextMenu {
            Button("Separate All Tabs") { store.separateAll(item.id) }
            Button(item.split?.orientation == .vertical ? "Convert to Horizontal Split View" : "Convert to Vertical Split View") { store.flipSplitOrientation(item.id) }
            Button("Add Pane") { if let first = children.first { actions.focusPane(first.id); actions.performAction("addSplitView") } }
            Divider()
            Button("Rename…") { ui.renamingID = item.id }
            Divider()
            Button(section == .today ? "Archive All" : "Close All") { for c in children { actions.closeTab(c.id) } }
        }
        .modifier(SidebarDropPreview(id: item.id, palette: palette))
    }
}

/// One pane inside the split row (Arc: SplitViewCellChildItemView).
struct SplitChildCell: View {
    let item: SidebarItem
    let palette: SpacePalette
    let groupHovered: Bool
    let groupSelected: Bool
    let focused: Bool
    @Environment(SidebarStore.self) private var store
    @Environment(SidebarUIState.self) private var ui
    @Environment(\.sidebarActions) private var actions
    @State private var hover = false

    var body: some View {
        let session = ui
        HStack(spacing: 8) {
            FaviconView(key: item.tab?.iconKey, palette: palette)
                .frame(width: CraMetrics.favicon)
            Text(item.displayTitle)
                .font(.system(size: 14))
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 2)
            if hover {
                SidebarIconButton(symbol: "xmark", palette: palette, help: "Close pane", optionHelp: "Separate from Split View", size: 20, iconSize: 11) {
                    // Option-click un-splits instead of closing (Arc flag option-click-split-tab-close-button-to-unsplit).
                    if NSEvent.modifierFlags.contains(.option) { store.separateFromSplit(item.id) } else { actions.closeTab(item.id) }
                }
                .transition(.opacity)
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { hover = $0; ui.hoverDraggable(item.id, $0) }
        .onTapGesture { store.selectTab(item.id, window: ui.windowID) }
        .draggable(SidebarDragItem.begin(item.id, session)) {
            HStack(spacing: 8) {
                FaviconView(key: item.tab?.iconKey, palette: palette)
                Text(item.displayTitle).font(.system(size: 14)).lineLimit(1)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
        }
        .contextMenu {
            Button("Separate Tab from Split") { store.separateFromSplit(item.id) }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.tab?.url ?? "", forType: .string)
            }
            Divider()
            Button("Close") { actions.closeTab(item.id) }
        }
        .arcTooltip(item.displayTitle, followsCursor: true)
    }
}
