import SwiftUI

enum SidebarSection { case favorites, pinned, today }

/// A tab or a folder (with its children when expanded).
struct SidebarItemView: View {
    let item: SidebarItem
    let depth: Int
    let palette: SpacePalette
    let section: SidebarSection
    @Environment(SidebarStore.self) private var store

    var body: some View {
        if item.isFolder {
            FolderRow(item: item, depth: depth, palette: palette)
            if store.isExpanded(item.id) {
                ForEach(store.children(of: item.id)) { child in
                    SidebarItemView(item: child, depth: depth + 1, palette: palette, section: section)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: -6)), removal: .opacity))
                }
            }
        } else if item.isTab {
            TabRow(item: item, depth: depth, palette: palette, section: section)
        } else if item.isSplit {
            SplitRow(item: item, depth: depth, palette: palette, section: section)
        }
    }
}

struct FaviconView: View {
    let key: String?
    let palette: SpacePalette
    var size: CGFloat = CraMetrics.favicon
    @Environment(FaviconCache.self) private var favicons

    var body: some View {
        if let img = favicons.image(forKey: key) {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        } else {
            Image(systemName: "globe")
                .font(.system(size: size * 0.8, weight: .regular))
                .foregroundStyle(palette.textTertiary)
                .frame(width: size, height: size)
        }
    }
}

struct TabRow: View {
    let item: SidebarItem
    let depth: Int
    let palette: SpacePalette
    let section: SidebarSection
    @Environment(SidebarStore.self) private var store
    @Environment(SidebarUIState.self) private var ui
    @Environment(\.sidebarActions) private var actions
    @State private var hover = false
    @State private var draft = ""
    @FocusState private var renameFocused: Bool

    private var tab: TabData { item.tab! }
    private var selected: Bool { store.selectedTabID == item.id }
    /// While tabs are ⌘/⇧-picked the highlight follows the picks, not the open tab.
    private var highlighted: Bool { ui.multiSelection.isEmpty ? selected : ui.multiSelection.contains(item.id) }
    /// Close acts on every picked tab when this row is one of them.
    private var closeGroup: [UUID] { ui.multiSelection.contains(item.id) && ui.multiSelection.count > 1 ? Array(ui.multiSelection) : [item.id] }
    private var editing: Bool { ui.renamingID == item.id }
    private var loaded: Bool { ui.loadedTabIDs.contains(item.id) }
    private var pinned: Bool { section != .today }
    private var navigatedAway: Bool { pinned && tab.url != tab.savedURL && !tab.savedURL.isEmpty }
    /// Arc shows the host under a pinned tab only when it has left the pinned
    /// site (navigating within the same host shows nothing).
    private var subtitle: String? {
        guard navigatedAway, let host = URL(string: tab.url)?.host, let saved = URL(string: tab.savedURL)?.host,
              host.replacingOccurrences(of: "www.", with: "") != saved.replacingOccurrences(of: "www.", with: "") else { return nil }
        return host.replacingOccurrences(of: "www.", with: "")
    }

    var body: some View {
        let session = ui
        HStack(spacing: 11) {
            FaviconView(key: tab.faviconKey, palette: palette)
                .frame(width: CraMetrics.favicon)
            if editing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($renameFocused)
                    .onSubmit { commitRename() }
                    .onExitCommand { ui.renamingID = nil }
                    .onAppear { draft = item.title ?? item.displayTitle; renameFocused = true }
                    .onChange(of: renameFocused) { _, f in if !f && editing { commitRename() } }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.displayTitle)
                        .font(.system(size: 14))
                        .foregroundStyle(palette.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let subtitle {
                        Text(subtitle).font(.system(size: 11)).foregroundStyle(palette.textTertiary).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 4)
            if tab.muted {
                Image(systemName: "speaker.slash.fill").font(.system(size: 10)).foregroundStyle(palette.textTertiary)
            }
            if item.isUnread && !selected && !hover {
                Circle().fill(palette.textPrimary.opacity(0.55)).frame(width: 6, height: 6)
            }
            if hover && !editing {
                if navigatedAway {
                    SidebarIconButton(symbol: "arrow.uturn.backward", palette: palette, help: "Back to pinned page", size: 22) {
                        actions.resetPinnedTab(item.id)
                    }
                }
                SidebarIconButton(symbol: "xmark", palette: palette,
                                  help: closeGroup.count > 1 ? "Close \(closeGroup.count) Tabs (⌘W)" : (pinned ? "Close (keeps the pinned tab)" : "Archive (⌘W)"), size: 22) {
                    closeTabs(closeGroup)
                }
            }
        }
        .padding(.leading, 8 + CGFloat(depth) * CraMetrics.indent)
        .padding(.trailing, 6)
        .frame(height: CraMetrics.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: CraMetrics.rowCorner, style: .continuous)
                .fill(highlighted ? palette.selectedFill : (hover ? palette.hoverFill : .clear))
                .shadow(color: highlighted && !palette.isDark ? .black.opacity(0.06) : .clear, radius: 3, y: 1)
        )
        .overlay { if ui.keyboardFocusID == item.id { FocusRing(radius: CraMetrics.rowCorner) } }
        .contentShape(Rectangle())
        .onHover { hover = $0; ui.hoverDraggable(item.id, $0) }
        .onTapGesture {
            let event = NSApp.currentEvent
            let flags = event?.modifierFlags.intersection([.command, .shift]) ?? []
            if !flags.isEmpty {
                ui.pick(item.id, range: flags.contains(.shift), in: store)
            } else if event?.clickCount == 2 {
                ui.renamingID = item.id
            } else {
                // A click on the row (not the field) ends a rename, so it can never get stuck.
                if editing { commitRename() }
                ui.clearPicks(anchor: item.id)
                ui.keyboardFocusID = nil
                store.selectTab(item.id)
            }
        }
        .draggable(SidebarDragItem.begin(item.id, session)) {
            HStack(spacing: 8) {
                FaviconView(key: tab.faviconKey, palette: palette)
                Text(item.displayTitle).font(.system(size: 14)).lineLimit(1)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(.regularMaterial))
        }
        .contextMenu { contextMenu }
        .help(tab.url)
        .modifier(SidebarDropPreview(id: item.id, palette: palette, depth: depth))
    }

    private func commitRename() {
        guard editing else { return }
        store.rename(item.id, to: draft)
        ui.renamingID = nil
    }

    private func closeTabs(_ ids: [UUID]) {
        // The open tab goes last so closing it doesn't hop through tabs about to close.
        let ordered = ids.filter { $0 != store.selectedTabID } + ids.filter { $0 == store.selectedTabID }
        withAnimation(.snappy(duration: 0.22, extraBounce: 0)) {
            for id in ordered { actions.closeTab(id) }
            ui.multiSelection.subtract(ids)
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        if closeGroup.count > 1 {
            Button("Close \(closeGroup.count) Tabs") { closeTabs(closeGroup) }
            Button("Deselect All") { ui.clearPicks() }
        } else {
            singleTabMenu
        }
    }

    @ViewBuilder
    private var singleTabMenu: some View {
        if pinned {
            Button("Unpin Tab") { store.unpinTab(item.id) }
        } else {
            Button("Pin Tab") { store.pinTab(item.id) }
        }
        if store.isFavorite(item.id) {
            Button("Remove from Favorites") { store.removeFromFavorites(item.id) }
        } else {
            Button("Add to Favorites") { store.addToFavorites(item.id) }
        }
        Divider()
        Button("Rename…") { ui.renamingID = item.id }
        if item.title != nil { Button("Use Page Title") { store.rename(item.id, to: nil) } }
        Button("Duplicate") { store.duplicateTab(item.id) }
        Button("Copy Link") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(tab.url, forType: .string)
        }
        Button(tab.muted ? "Unmute" : "Mute") { store.setMuted(item.id, !tab.muted); actions.performAction("muteTab:\(item.id)") }
        if pinned {
            Divider()
            if navigatedAway { Button("Back to Pinned Page") { actions.resetPinnedTab(item.id) } }
            Button("Make This the Pinned Page") { store.setPinnedHomeToCurrent(item.id) }
        }
        Divider()
        Menu("Move to Space") {
            ForEach(store.orderedSpaces) { s in
                Button("\(s.emoji) \(s.title)") { store.moveTab(item.id, toSpace: s.id) }
                    .disabled(s.id == store.spaceID(ofItem: item.id))
            }
        }
        let folders = store.children(of: store.focusedSpace.pinnedContainerID).filter { $0.isFolder }
        if !folders.isEmpty {
            Menu("Move to Folder") {
                ForEach(folders) { f in
                    Button(f.title ?? "Folder") { store.moveItem(item.id, to: f.id, index: nil) }
                        .disabled(f.id == item.parentID)
                }
            }
        }
        Button("New Folder with Tab") {
            let f = store.createFolder(named: "New Folder", in: store.focusedSpace.pinnedContainerID, index: 0)
            store.moveItem(item.id, to: f.id, index: nil)
            ui.renamingID = f.id
        }
        Divider()
        Button(pinned ? "Close" : "Archive") { actions.closeTab(item.id) }
        if pinned { Button("Unpin and Archive") { store.archiveTab(item.id, reason: .manual) } }
    }
}

struct FolderRow: View {
    let item: SidebarItem
    let depth: Int
    let palette: SpacePalette
    @Environment(SidebarStore.self) private var store
    @Environment(SidebarUIState.self) private var ui
    @State private var hover = false
    @State private var draft = ""
    @FocusState private var renameFocused: Bool

    private var expanded: Bool { store.isExpanded(item.id) }
    private var editing: Bool { ui.renamingID == item.id }

    var body: some View {
        let session = ui
        HStack(spacing: 11) {
            ZStack {
                if !expanded {
                    Image(systemName: "folder.fill").foregroundStyle(palette.folderFill)
                }
                Image(systemName: "folder").foregroundStyle(palette.folderTint)
            }
            .font(.system(size: 15, weight: .regular))
            .frame(width: CraMetrics.favicon)
            if editing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .focused($renameFocused)
                    .onSubmit { commitRename() }
                    .onExitCommand { ui.renamingID = nil }
                    .onAppear { draft = item.title ?? ""; renameFocused = true }
                    .onChange(of: renameFocused) { _, f in if !f && editing { commitRename() } }
            } else {
                Text(item.title ?? "Folder")
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(1)
            }
            Spacer()
            if hover && !expanded {
                Text("\(store.tabs(under: item.id).count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(palette.textTertiary)
                    .padding(.trailing, 8)
            }
        }
        .padding(.leading, 8 + CGFloat(depth) * CraMetrics.indent)
        .frame(height: CraMetrics.rowHeight)
        .background(RoundedRectangle(cornerRadius: CraMetrics.rowCorner, style: .continuous).fill(hover ? palette.hoverFill : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0; ui.hoverDraggable(item.id, $0) }
        // Every click toggles, however fast they come: double-click-to-rename made
        // quick open/close clicks start a rename that then swallowed the clicks.
        // Rename stays in the context menu. No count: 2 gesture either: it makes
        // SwiftUI hold every single click for the double-click interval.
        .onTapGesture {
            if editing { commitRename() }
            withAnimation(.snappy(duration: 0.22, extraBounce: 0)) { store.setExpanded(item.id, !expanded) }
        }
        .draggable(SidebarDragItem.begin(item.id, session))
        .contextMenu {
            Button("Rename…") { ui.renamingID = item.id }
            Button("New Folder Inside") {
                let f = store.createFolder(named: "New Folder", in: item.id, index: 0)
                store.setExpanded(item.id, true)
                ui.renamingID = f.id
            }
            Divider()
            Button("Delete Folder (archives tabs)") { store.deleteFolder(item.id) }
        }
        .modifier(SidebarDropPreview(id: item.id, palette: palette))
    }

    private func commitRename() {
        guard editing else { return }
        store.rename(item.id, to: draft.isEmpty ? "Folder" : draft)
        ui.renamingID = nil
    }
}
