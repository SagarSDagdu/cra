import SwiftUI

/// The whole left column, laid out like Arc: traffic lights + sidebar toggle,
/// nav buttons at the right of the top row, favorites, muted space header,
/// pinned, divider, today, new tab, and the dock at the bottom.
struct SidebarRootView: View {
    @Environment(SidebarStore.self) private var store
    @Environment(SidebarUIState.self) private var ui
    @Environment(\.sidebarActions) private var actions
    @State private var switchDirection: Edge = .trailing
    @State private var lastSpaceIndex = 0

    var body: some View {
        let space = store.focusedSpace
        let palette = space.theme.palette
        VStack(spacing: 0) {
            SidebarTopBar(palette: palette)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    FavoritesGrid(palette: palette)
                        .padding(.horizontal, 8)
                    SpaceSectionView(space: space, palette: palette)
                        .id(space.id)
                        .transition(.asymmetric(insertion: .move(edge: switchDirection).combined(with: .opacity),
                                                removal: .move(edge: switchDirection == .trailing ? .leading : .trailing).combined(with: .opacity)))
                }
                .padding(.bottom, 12)
            }
            .clipped()
            SpaceDock(palette: palette)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
        }
        .foregroundStyle(palette.textPrimary)
        .ignoresSafeArea()
        .onChange(of: store.focusedSpaceID) { _, new in
            let idx = store.spaceOrder.firstIndex(of: new) ?? 0
            switchDirection = idx >= lastSpaceIndex ? .trailing : .leading
            lastSpaceIndex = idx
        }
        .animation(.snappy(duration: 0.24, extraBounce: 0), value: store.focusedSpaceID)
        .onAppear { lastSpaceIndex = store.spaceOrder.firstIndex(of: store.focusedSpaceID) ?? 0 }
    }
}

/// Row 1: traffic lights, the sidebar toggle right after them, nav buttons
/// right-aligned (Arc puts them here when the toolbar shows the URL). When the
/// toolbar is hidden the URL pill moves into the sidebar on a second row.
struct SidebarTopBar: View {
    let palette: SpacePalette
    @Environment(SidebarStore.self) private var store
    @Environment(SidebarUIState.self) private var ui
    @Environment(\.sidebarActions) private var actions
    @State private var hoverPill = false

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 2) {
                Spacer().frame(width: 72)
                SidebarIconButton(symbol: "sidebar.left", palette: palette, help: "Hide Sidebar (⌘S)", iconSize: 15.5) { actions.toggleSidebar() }
                Spacer()
                if store.settings.showToolbar, let t = store.selectedTab?.tab, store.settings.isDeveloperMode(url: t.url) {
                    navButtons
                }
            }
            .frame(height: 28)
            .padding(.top, CraMetrics.titleRowCenter - 14)
            .padding(.bottom, CraMetrics.titleAreaHeight - CraMetrics.titleRowCenter - 14)
            .padding(.horizontal, 6)
            if !store.settings.showToolbar {
                HStack(spacing: 2) {
                    navButtons
                    urlPill
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            }
        }
    }

    private var navButtons: some View {
        HStack(spacing: 0) {
            SidebarIconButton(symbol: "arrow.left", palette: palette, help: "Go Back (⌘[)", enabled: ui.canGoBack, size: 34, iconSize: 15, weight: .regular) { actions.goBack() }
            SidebarIconButton(symbol: "arrow.right", palette: palette, help: "Go Forward (⌘])", enabled: ui.canGoForward, size: 34, iconSize: 15, weight: .regular) { actions.goForward() }
            SidebarIconButton(symbol: ui.isLoading ? "xmark" : "arrow.clockwise", palette: palette, help: "Refresh (⌘R)", size: 24, iconSize: 15, weight: .regular) { actions.reload() }
            Menu {
                Button("Refresh the Page") { actions.performAction("reload") }
                Button("Force Refresh the Page") { actions.performAction("hardReload") }
                Divider()
                Button("View Source") { actions.performAction("viewSource") }
                Button("Developer Tools") { actions.performAction("devTools") }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(palette.textTertiary)
                    .frame(width: 12, height: 28)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .frame(width: 12)
        }
    }

    private var urlPill: some View {
        let tab = store.selectedTab
        let url = tab?.tab?.url ?? ""
        let host = URL(string: url)?.host ?? ""
        let secure = url.hasPrefix("https://")
        return Button {
            actions.openCommandBar(tab == nil ? .newTab : .editURL)
        } label: {
            HStack(spacing: 6) {
                if tab != nil {
                    Image(systemName: secure ? "lock.fill" : "globe").font(.system(size: 10, weight: .semibold)).foregroundStyle(palette.textSecondary)
                }
                Text(tab == nil ? "Search or Enter URL…" : (host.isEmpty ? SuggestionEngine.humanURL(url) : host.replacingOccurrences(of: "www.", with: "")))
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(tab == nil ? palette.textTertiary : palette.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hoverPill ? palette.selectedFill : palette.pillFill))
        }
        .buttonStyle(.plain)
        .onHover { hoverPill = $0 }
        .help(url)
    }
}

struct SidebarIconButton: View {
    let symbol: String
    let palette: SpacePalette
    var help: String = ""
    var enabled: Bool = true
    var size: CGFloat = 28
    var iconSize: CGFloat = 13
    var weight: Font.Weight = .medium
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: iconSize, weight: weight))
                .foregroundStyle(enabled ? palette.textSecondary : palette.textTertiary.opacity(0.55))
                .frame(width: size, height: min(size, 28))
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hover && enabled ? palette.hoverFill : .clear))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hover = $0 }
        .help(help)
    }
}

/// Space header, pinned (folders allowed), divider, today, new-tab row.
struct SpaceSectionView: View {
    let space: Space
    let palette: SpacePalette
    @Environment(SidebarStore.self) private var store
    @Environment(SidebarUIState.self) private var ui
    @Environment(\.sidebarActions) private var actions
    @State private var hoverDivider = false
    @State private var dropOnPinned = false
    @State private var dropOnToday = false

    var body: some View {
        let todayItems = store.children(of: space.todayContainerID)
        VStack(alignment: .leading, spacing: 0) {
            SpaceHeader(space: space, palette: palette)
                .padding(.horizontal, 10)
            Rectangle().fill(palette.separator.opacity(0.35)).frame(height: 1).padding(.bottom, 5)

            VStack(spacing: CraMetrics.rowSpacing) {
                ForEach(store.children(of: space.pinnedContainerID)) { item in
                    SidebarItemView(item: item, depth: 0, palette: palette, section: .pinned)
                }
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(dropOnPinned ? palette.hoverFill : .clear).padding(.horizontal, 8))
            .dropDestination(for: SidebarDragItem.self) { items, _ in
                guard let d = items.first else { return false }
                store.moveItem(d.id, to: space.pinnedContainerID, index: nil)
                return true
            } isTargeted: { dropOnPinned = $0 }

            // Divider between pinned and today; "Clear" shows on hover.
            HStack {
                Rectangle().fill(palette.separator).frame(height: 1)
                    .opacity(todayItems.isEmpty ? 0 : 1)
                if hoverDivider && !todayItems.isEmpty {
                    Button("Clear") { store.clearToday(space.id) }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(palette.textSecondary)
                        .transition(.opacity)
                }
            }
            .frame(height: 18)
            .padding(.horizontal, 20)
            .contentShape(Rectangle())
            .onHover { hoverDivider = $0 }
            .animation(.easeOut(duration: 0.15), value: hoverDivider)

            VStack(spacing: CraMetrics.rowSpacing) {
                ForEach(todayItems) { item in
                    SidebarItemView(item: item, depth: 0, palette: palette, section: .today)
                }
                NewTabRow(palette: palette)
            }
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(dropOnToday ? palette.hoverFill : .clear).padding(.horizontal, 8))
            .dropDestination(for: SidebarDragItem.self) { items, _ in
                guard let d = items.first else { return false }
                store.moveItem(d.id, to: space.todayContainerID, index: nil)
                return true
            } isTargeted: { dropOnToday = $0 }
        }
    }
}

struct SpaceHeader: View {
    let space: Space
    let palette: SpacePalette
    @Environment(SidebarStore.self) private var store
    @Environment(\.sidebarActions) private var actions
    @State private var hover = false

    var body: some View {
        Menu {
            Button("Edit Space…") { actions.editSpace(space) }
            Button("New Folder") { actions.performAction("newFolder") }
            Divider()
            Button("Clear Today") { store.clearToday(space.id) }
            Divider()
            Button("New Space…") { actions.editSpace(nil) }
            Button("Delete Space…") { actions.performAction("deleteSpace") }
        } label: {
            HStack(spacing: 8) {
                Text(space.emoji).font(.system(size: 12))
                Text(space.title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(palette.textSecondary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(palette.textTertiary)
                    .opacity(hover ? 1 : 0)
                Spacer()
            }
            .padding(.horizontal, 7)
            .frame(height: 31)
            .background(RoundedRectangle(cornerRadius: 8).fill(hover ? palette.hoverFill : .clear))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { hover = $0 }
    }
}

struct NewTabRow: View {
    let palette: SpacePalette
    @Environment(\.sidebarActions) private var actions
    @State private var hover = false
    var body: some View {
        Button { actions.openCommandBar(.newTab) } label: {
            HStack(spacing: 9) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: CraMetrics.favicon)
                Text("New Tab")
                    .font(.system(size: 14))
                Spacer()
            }
            .foregroundStyle(hover ? palette.textPrimary : palette.textSecondary)
            .padding(.leading, 8)
            .padding(.trailing, 10)
            .frame(height: CraMetrics.rowHeight)
            .background(RoundedRectangle(cornerRadius: CraMetrics.rowCorner, style: .continuous).fill(hover ? palette.selectedFill : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
