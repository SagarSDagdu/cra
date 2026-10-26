import SwiftUI

/// The whole left column, laid out like Arc: traffic lights + sidebar toggle,
/// nav buttons at the right of the top row, favorites, muted space header,
/// pinned, divider, today, new tab, and the dock at the bottom.
struct SidebarRootView: View {
    @Environment(SidebarStore.self) private var store
    @Environment(SidebarUIState.self) private var ui
    @Environment(\.sidebarActions) private var actions

    var body: some View {
        let space = store.focusedSpace
        let palette = space.theme.palette
        VStack(spacing: 0) {
            SidebarTopBar(palette: palette)
            // Arc 1.170 keeps favorites and the space header fixed; only the
            // space's tab list scrolls (SpaceSectionView owns that scroll view).
            FavoritesGrid(palette: palette)
                .padding(.horizontal, 8)
            // Dia's paging container: every space's list sits side by side and the
            // strip follows the swipe 1:1, then a spring settles it on a page.
            GeometryReader { g in
                let spaces = store.orderedSpaces
                let index = CGFloat(spaces.firstIndex { $0.id == space.id } ?? 0)
                HStack(alignment: .top, spacing: 0) {
                    ForEach(spaces) { s in
                        SpaceSectionView(space: s, palette: s.theme.palette)
                            .foregroundStyle(s.theme.palette.textPrimary)
                            .frame(width: g.size.width, height: g.size.height, alignment: .top)
                    }
                }
                .offset(x: -(index + ui.spaceSwipe) * g.size.width)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .clipped()
            UpdateBanner(palette: palette)
                .padding(.horizontal, 8)
            // Arc's list viewport ends 50pt above the window bottom; the dock sits centred in that band.
            SpaceDock(palette: palette)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 6)
        }
        .foregroundStyle(palette.textPrimary)
        .ignoresSafeArea()
        .onChange(of: store.focusedSpaceID) { _, _ in ui.clearPicks() }
        .animation(ui.spaceSettleAnimation, value: store.focusedSpaceID)
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
                // The toolbar carries the sidebar toggle; this one only stands in while the toolbar is hidden.
                if !store.settings.showToolbar {
                    SidebarIconButton(symbol: "sidebar.left", palette: palette, help: "Hide Sidebar (⌘S)", iconSize: 15.5, weight: .regular) { actions.toggleSidebar() }
                }
                Spacer()
                if store.settings.showToolbar, let t = store.selectedTab?.tab, store.settings.isDeveloperMode(url: t.url) {
                    navButtons
                }
            }
            .frame(height: 28)
            .padding(.top, CraMetrics.titleRowCenter - 14)
            .padding(.bottom, CraMetrics.titleAreaHeight - CraMetrics.titleRowCenter - 14)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { actions.titleBarDoubleClick() }
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
                // Without the toolbar, the nav-bar status ("Copied Current URL") shows here.
                if let status = ui.toolbarStatus {
                    Image(systemName: status.symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(palette.textSecondary)
                    Text(status.text)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(palette.textSecondary)
                        .lineLimit(1)
                } else {
                    if tab != nil {
                        Image(systemName: secure ? "lock.fill" : "globe").font(.system(size: 10, weight: .semibold)).foregroundStyle(palette.textSecondary)
                    }
                    Text(tab == nil ? "Search or Enter URL…" : (host.isEmpty ? SuggestionEngine.humanURL(url) : host.replacingOccurrences(of: "www.", with: "")))
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(tab == nil ? palette.textTertiary : palette.textPrimary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .id(ui.toolbarStatus?.id)
            .transition(.opacity)
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
                // Arc 1.170 draws these glyphs at roughly 26% black (sidebar toggle, library, +).
                .foregroundStyle(enabled ? (palette.isDark ? Color.white.opacity(0.55) : Color.black.opacity(0.26)) : palette.textTertiary.opacity(0.55))
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
    @State private var rowsFrame = CGRect.zero
    @State private var viewportHeight: CGFloat = 0

    /// Arc 1.170 draws a full-width 1pt hairline (~5% black over the light theme) at an edge of
    /// the list only while rows are hidden past it, fading over ~0.25s.
    private var scrolledUnderTop: Bool { rowsFrame.minY < -0.5 }
    private var rowsBelowBottom: Bool { rowsFrame.maxY > viewportHeight + 0.5 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SpaceHeader(space: space, palette: palette)
                .padding(.horizontal, 10)
                .padding(.bottom, 3)
            ScrollView(.vertical, showsIndicators: false) {
                rows
                    .padding(.top, 3)
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.scrollSpace)) } action: { rowsFrame = $0 }
                    // Arc leaves ~121pt of empty list after the last row at full scroll.
                    .padding(.bottom, 121)
                    .overlay(alignment: .topLeading) { dropLine }
                    .contentShape(Rectangle())
                    .onDrop(of: [.craSidebarItem], delegate: SidebarListDropDelegate(space: space, store: store, ui: ui))
                    // Safety net: a drag that ended without an exit callback leaves no preview behind.
                    .onContinuousHover { _ in if ui.listDrop != nil, NSEvent.pressedMouseButtons == 0 { ui.listDrop = nil } }
                    .coordinateSpace(name: SidebarListDropDelegate.coordinateSpace)
            }
            .coordinateSpace(name: Self.scrollSpace)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewportHeight = $0 }
            .overlay(alignment: .top) { edgeHairline.opacity(scrolledUnderTop ? 1 : 0) }
            .overlay(alignment: .bottom) { edgeHairline.opacity(rowsBelowBottom ? 1 : 0) }
            .animation(.easeInOut(duration: 0.25), value: scrolledUnderTop)
            .animation(.easeInOut(duration: 0.25), value: rowsBelowBottom)
        }
    }

    private static let scrollSpace = "spaceSectionScroll"

    @ViewBuilder
    private var dropLine: some View {
        if let line = ui.listDrop?.line {
            Capsule()
                .fill(palette.textPrimary.opacity(0.5))
                .frame(width: max(0, line.maxX - line.minX), height: 2)
                .offset(x: line.minX, y: line.y - 1)
                .transition(.opacity)
                .allowsHitTesting(false)
        }
    }

    /// Which list a drop lands in, when that pins or unpins the dragged item;
    /// that list lights up while the drag hovers.
    private var dropSection: SidebarSection? {
        guard let drop = ui.listDrop, let target = drop.target else { return nil }
        let lands: SidebarSection
        switch target {
        case .insert(let parent, _): lands = isPinnedList(parent) ? .pinned : .today
        case .into(let id): lands = isPinnedList(id) ? .pinned : .today
        case .newFolder: lands = .pinned
        case .split: lands = .today
        }
        return lands == (isPinnedList(drop.draggedID) ? .pinned : .today) ? nil : lands
    }

    private func isPinnedList(_ id: UUID) -> Bool {
        if case .pinned? = store.rootContainer(of: id) { return true }
        return false
    }

    private var pinPlaceholder: some View {
        let active = dropSection == .pinned
        return HStack(spacing: 6) {
            Image(systemName: "pin").font(.system(size: 11, weight: .semibold))
            Text("Drop to Pin").font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(palette.textSecondary)
        .frame(maxWidth: .infinity)
        .frame(height: CraMetrics.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: CraMetrics.rowCorner, style: .continuous)
                .strokeBorder(palette.textTertiary.opacity(active ? 0.6 : 0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .background(RoundedRectangle(cornerRadius: CraMetrics.rowCorner, style: .continuous).fill(active ? palette.hoverFill : .clear))
        )
        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
    }

    private var edgeHairline: some View {
        Rectangle()
            .fill(palette.isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.05))
            .frame(height: 1)
            .allowsHitTesting(false)
    }

    private var rows: some View {
        let todayItems = store.children(of: space.todayContainerID)
        let pinnedItems = store.children(of: space.pinnedContainerID)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(spacing: CraMetrics.rowSpacing) {
                ForEach(pinnedItems) { item in
                    SidebarItemView(item: item, depth: 0, palette: palette, section: .pinned)
                }
                // With nothing pinned the list is 8pt tall; a drag opens a real target.
                if pinnedItems.isEmpty && ui.listDrop != nil { pinPlaceholder }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(SidebarListDropDelegate.coordinateSpace)) } action: { ui.rowFrames[space.pinnedContainerID] = $0 }
            .padding(.horizontal, 10)
            .frame(minHeight: 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(dropSection == .pinned && !pinnedItems.isEmpty ? palette.hoverFill : .clear).padding(.horizontal, 8))

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
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(SidebarListDropDelegate.coordinateSpace)) } action: { ui.rowFrames[space.todayContainerID] = $0 }
            .padding(.horizontal, 10)
            .background(RoundedRectangle(cornerRadius: 10).fill(dropSection == .today ? palette.hoverFill : .clear).padding(.horizontal, 8))
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
