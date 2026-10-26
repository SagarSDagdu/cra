import Foundation
import Observation

/// The single source of truth for spaces, tabs, folders, favorites, the
/// archive and window preferences. Mutations here are what Arc's
/// SidebarDataStore mutations do; persistence mirrors its Storable*.json files.
@MainActor
@Observable
final class SidebarStore {
    // MARK: State

    private(set) var spaces: [UUID: Space] = [:]
    private(set) var spaceOrder: [UUID] = []
    private(set) var items: [UUID: SidebarItem] = [:]
    private(set) var archive: [ArchivedItem] = []
    var prefs = WindowPrefs() { didSet { prefsStore.save(prefs) } }
    var settings = AppSettings() { didSet { settingsStore.save(settings) } }
    private(set) var history: [String: HistoryEntry] = [:]
    private(set) var ranking = RankingData()
    /// Bumped on every structural change; cheap way for AppKit code to observe.
    private(set) var revision = 0

    // MARK: Persistence

    private let sidebarFile = JSONStore<SidebarDocument>("sidebar.json")
    private let archiveFile = JSONStore<[ArchivedItem]>("archive.json")
    private let prefsStore = JSONStore<WindowPrefs>("windows.json")
    private let settingsStore = JSONStore<AppSettings>("settings.json")
    private let historyFile = JSONStore<[HistoryEntry]>("history.json")
    private let rankingFile = JSONStore<RankingData>("commandbar.json")

    init() {
        let doc = sidebarFile.load(or: SidebarDocument.fresh)
        for s in doc.spaces { spaces[s.id] = s }
        spaceOrder = doc.spaceOrder.filter { spaces[$0] != nil }
        for s in doc.spaces where !spaceOrder.contains(s.id) { spaceOrder.append(s.id) }
        for it in doc.items { items[it.id] = it }
        archive = archiveFile.load(or: { [] })
        prefs = prefsStore.load(or: { WindowPrefs() })
        settings = settingsStore.load(or: { AppSettings() })
        for h in historyFile.load(or: { [] }) { history[h.url] = h }
        ranking = rankingFile.load(or: { RankingData() })
        repair()
        if prefs.focusedSpaceID == nil || spaces[prefs.focusedSpaceID!] == nil {
            prefs.focusedSpaceID = spaceOrder.first
        }
        splitSharedFavorites(doc.favoritesContainerID)
    }

    /// Make sure every space has its containers and no item points at a
    /// parent that is gone.
    func repair() {
        for (id, var space) in spaces {
            if items[space.favoritesContainerID] == nil {
                let c = SidebarItem.container(.favorites(spaceID: id), id: space.favoritesContainerID)
                items[c.id] = c
            }
            if items[space.pinnedContainerID] == nil {
                let c = SidebarItem.container(.pinned(spaceID: id), id: space.pinnedContainerID)
                items[c.id] = c
            }
            if items[space.todayContainerID] == nil {
                let c = SidebarItem.container(.today(spaceID: id), id: space.todayContainerID)
                items[c.id] = c
            }
            spaces[id] = space
            _ = space
        }
        if spaces.isEmpty {
            let doc = SidebarDocument.fresh()
            for s in doc.spaces { spaces[s.id] = s }
            spaceOrder = doc.spaceOrder
            for it in doc.items { items[it.id] = it }
        }
        // Drop children references that do not resolve and orphans.
        for (id, var it) in items {
            it.children = it.children.filter { items[$0] != nil && items[$0]?.parentID == id }
            items[id] = it
        }
        for (id, it) in items where it.container == nil {
            if let p = it.parentID, let parent = items[p], parent.children.contains(id) { continue }
            // Orphan: put it in the first space's today list rather than losing it.
            if let space = spaceOrder.first.flatMap({ spaces[$0] }) {
                var fixed = it
                fixed.parentID = space.todayContainerID
                items[id] = fixed
                items[space.todayContainerID]?.children.append(id)
            }
        }
    }

    /// Favorites used to be one set every space shared. Each space gets its own
    /// copy of that set so nothing disappears anywhere; the focused space keeps
    /// the original tabs, other spaces get copies.
    private func splitSharedFavorites(_ sharedID: UUID?) {
        guard let sharedID, let shared = items[sharedID] else { return }
        for sid in spaceOrder {
            guard let space = spaces[sid] else { continue }
            var copies: [UUID: UUID] = [:]
            for child in shared.children {
                if sid == focusedSpaceID {
                    items[child]?.parentID = space.favoritesContainerID
                    items[space.favoritesContainerID]?.children.append(child)
                } else {
                    copySubtree(child, into: space.favoritesContainerID, copies: &copies)
                }
            }
            // A favorite open in this space stays open: it is now this space's copy.
            if let sel = prefs.selectedTabPerSpace[sid], let copy = copies[sel] { prefs.selectedTabPerSpace[sid] = copy }
            for (old, new) in copies where prefs.expandedFolders.contains(old) { prefs.expandedFolders.insert(new) }
        }
        items[sharedID] = nil
        touch()
    }

    private func copySubtree(_ id: UUID, into parent: UUID, copies: inout [UUID: UUID]) {
        guard var it = items[id] else { return }
        let kids = it.children
        it.id = UUID()
        it.parentID = parent
        it.children = []
        copies[id] = it.id
        items[it.id] = it
        items[parent]?.children.append(it.id)
        for k in kids { copySubtree(k, into: it.id, copies: &copies) }
    }

    func save() {
        let doc = SidebarDocument(version: 1, spaceOrder: spaceOrder, spaces: spaceOrder.compactMap { spaces[$0] },
                                  items: Array(items.values))
        sidebarFile.save(doc)
        archiveFile.save(archive)
    }

    func saveAll() {
        let doc = SidebarDocument(version: 1, spaceOrder: spaceOrder, spaces: spaceOrder.compactMap { spaces[$0] },
                                  items: Array(items.values))
        sidebarFile.saveNow(doc)
        archiveFile.saveNow(archive)
        prefsStore.saveNow(prefs)
        settingsStore.saveNow(settings)
        historyFile.saveNow(Array(history.values))
        rankingFile.saveNow(ranking)
    }

    private func touch() {
        revision &+= 1
        save()
    }

    // MARK: Lookup

    var orderedSpaces: [Space] { spaceOrder.compactMap { spaces[$0] } }
    var focusedSpaceID: UUID { prefs.focusedSpaceID ?? spaceOrder.first! }
    var focusedSpace: Space { spaces[focusedSpaceID] ?? orderedSpaces.first! }

    func item(_ id: UUID) -> SidebarItem? { items[id] }
    func space(_ id: UUID) -> Space? { spaces[id] }

    func children(of id: UUID) -> [SidebarItem] {
        (items[id]?.children ?? []).compactMap { items[$0] }
    }

    /// Depth-first list of every tab under a container or folder.
    func tabs(under id: UUID) -> [SidebarItem] {
        var out: [SidebarItem] = []
        func walk(_ id: UUID) {
            for c in children(of: id) {
                if c.isTab { out.append(c) } else if c.isFolder || c.isSplit { walk(c.id) }
            }
        }
        walk(id)
        return out
    }

    func allTabs() -> [SidebarItem] { items.values.filter { $0.isTab } }

    /// Tab rows of a space's pinned and today lists in sidebar order, open
    /// folders included (what a ⇧-click range spans).
    func listedTabIDs(in spaceID: UUID) -> [UUID] {
        guard let space = spaces[spaceID] else { return [] }
        var out: [UUID] = []
        func walk(_ id: UUID) {
            for c in children(of: id) {
                if c.isTab { out.append(c.id) } else if c.isFolder, isExpanded(c.id) { walk(c.id) }
            }
        }
        walk(space.pinnedContainerID)
        walk(space.todayContainerID)
        return out
    }

    /// The top-level pinned rows a space's list draws. Collapsed, only the
    /// pinned item holding the open tab stays.
    func listedPinnedItems(in space: Space) -> [SidebarItem] {
        guard isPinnedCollapsed(space.id) else { return children(of: space.pinnedContainerID) }
        let selected = selectedTabID(in: space.id).flatMap { splitContaining($0) ?? item($0) }
        return selected.flatMap { rootContainer(of: $0.id) == .pinned(spaceID: space.id) ? [$0] : nil } ?? []
    }

    /// Favorites + pinned + today for a space, in sidebar order. This is what
    /// ⌘1…⌘9 index into (Arc: "Go to Sidebar Item N").
    func visibleTabs(in spaceID: UUID) -> [SidebarItem] {
        guard let space = spaces[spaceID] else { return [] }
        return tabs(under: space.favoritesContainerID) + tabs(under: space.pinnedContainerID) + tabs(under: space.todayContainerID)
    }

    /// Which container an item ultimately lives in.
    func rootContainer(of id: UUID) -> ContainerKind? {
        var cur = items[id]
        var hops = 0
        while let c = cur, hops < 64 {
            if let kind = c.container { return kind }
            guard let p = c.parentID else { return nil }
            cur = items[p]
            hops += 1
        }
        return nil
    }

    func spaceID(ofItem id: UUID) -> UUID? { rootContainer(of: id)?.spaceID }

    func isPinned(_ id: UUID) -> Bool {
        switch rootContainer(of: id) {
        case .pinned, .favorites: return true
        default: return false
        }
    }

    func isFavorite(_ id: UUID) -> Bool {
        if case .favorites? = rootContainer(of: id) { return true }
        return false
    }

    func selectedTabID(in spaceID: UUID) -> UUID? {
        guard let id = prefs.selectedTabPerSpace[spaceID], items[id]?.isTab == true else { return nil }
        return id
    }
    var selectedTabID: UUID? { selectedTabID(in: focusedSpaceID) }
    var selectedTab: SidebarItem? { selectedTabID.flatMap { items[$0] } }

    // MARK: Tabs

    @discardableResult
    func createTab(url: String, title: String = "", in spaceID: UUID? = nil, pinned: Bool = false,
                   select: Bool = true, parent: UUID? = nil, index: Int? = nil) -> SidebarItem {
        let sid = spaceID ?? focusedSpaceID
        let space = spaces[sid] ?? focusedSpace
        let parentID = parent ?? (pinned ? space.pinnedContainerID : space.todayContainerID)
        var tab = SidebarItem.tab(url, title: title, parent: parentID)
        tab.data = .tab({ var t = TabData(url: url, title: title); t.activeTabBeforeCreationID = selectedTabID(in: sid); return t }())
        tab.isUnread = !select
        items[tab.id] = tab
        var p = items[parentID]!
        let at = index ?? (settings.newTabsAtTop && !pinned ? 0 : p.children.count)
        p.children.insert(tab.id, at: min(max(0, at), p.children.count))
        items[parentID] = p
        if select { selectTab(tab.id) } else { touch() }
        return tab
    }

    func selectTab(_ id: UUID?) {
        guard let id, let it = items[id], it.isTab else {
            prefs.selectedTabPerSpace[focusedSpaceID] = nil
            touch()
            return
        }
        let sid = spaceID(ofItem: id) ?? focusedSpaceID
        if sid != focusedSpaceID { prefs.focusedSpaceID = sid }
        prefs.selectedTabPerSpace[sid] = id
        var updated = it
        updated.isUnread = false
        if var t = updated.tab { t.timeLastActiveAt = Date(); updated.data = .tab(t) }
        items[id] = updated
        // Selecting a pane focuses it inside its split (Arc: focusItemID).
        if let p = it.parentID, var split = items[p], var s = split.split {
            s.focusTabID = id
            s.timeLastActiveAt = Date()
            split.data = .split(s)
            items[p] = split
        }
        var dates = ranking.recentlySwitchedToTabs[id] ?? []
        dates.append(Date())
        if dates.count > 10 { dates.removeFirst(dates.count - 10) }
        ranking.recentlySwitchedToTabs[id] = dates
        rankingFile.save(ranking)
        touch()
    }

    func updateTab(_ id: UUID, url: String? = nil, title: String? = nil) {
        guard var it = items[id], var t = it.tab else { return }
        if let url, !url.isEmpty, url != "about:blank" {
            t.url = url
            if !isPinned(id) { t.savedURL = url }
            if let key = FaviconCache.key(for: url) { t.faviconKey = key }
        }
        if let title { t.savedTitle = title }
        it.data = .tab(t)
        items[id] = it
        revision &+= 1
        sidebarFile.save(SidebarDocument(version: 1, spaceOrder: spaceOrder, spaces: orderedSpaces,
                                         items: Array(items.values)), delay: 2)
    }

    func markUnread(_ id: UUID, _ unread: Bool = true) {
        guard var it = items[id] else { return }
        it.isUnread = unread
        items[id] = it
        revision &+= 1
    }

    func setMuted(_ id: UUID, _ muted: Bool) {
        guard var it = items[id], var t = it.tab else { return }
        t.muted = muted
        it.data = .tab(t)
        items[id] = it
        touch()
    }

    func rename(_ id: UUID, to title: String?) {
        guard var it = items[id] else { return }
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        it.title = (trimmed?.isEmpty ?? true) ? nil : trimmed
        items[id] = it
        touch()
    }

    /// Pinned tabs have a home URL. Reset returns there (Arc: resetTab).
    func resetPinnedTab(_ id: UUID) -> String? {
        guard var it = items[id], var t = it.tab, isPinned(id) else { return nil }
        t.url = t.savedURL
        it.data = .tab(t)
        items[id] = it
        touch()
        return t.savedURL
    }

    /// Make the current page the pinned home (Arc: replacePinnedTab).
    func setPinnedHomeToCurrent(_ id: UUID) {
        guard var it = items[id], var t = it.tab else { return }
        t.savedURL = t.url
        it.data = .tab(t)
        items[id] = it
        touch()
    }

    func duplicateTab(_ id: UUID) -> SidebarItem? {
        guard let it = items[id], let t = it.tab, let parent = it.parentID else { return nil }
        let idx = (items[parent]?.children.firstIndex(of: id) ?? 0) + 1
        return createTab(url: t.url, title: t.savedTitle, in: spaceID(ofItem: id), pinned: false,
                         select: true, parent: parent, index: idx)
    }

    // MARK: Import helpers

    func insertItem(_ item: SidebarItem, into parent: UUID, at index: Int?) {
        var it = item
        it.parentID = parent
        items[it.id] = it
        guard var p = items[parent] else { return }
        p.children.insert(it.id, at: min(index ?? p.children.count, p.children.count))
        items[parent] = p
    }

    /// A Little Window closed: its page goes to the Library like a closed tab
    /// (Arc archives Little Arcs with source `littleArc`). It never had a
    /// sidebar slot, so `sourceSpaceID` is nil and restore uses the focused space.
    func archiveLittleWindowPage(url: String, title: String) {
        let it = SidebarItem.tab(url, title: title, parent: nil)
        archive.insert(ArchivedItem(archivedAt: Date(), reason: .manual, sourceSpaceID: nil, wasPinned: false, item: it, fromLittleWindow: true), at: 0)
        if archive.count > 2000 { archive.removeLast(archive.count - 2000) }
        touch()
    }

    func appendArchived(_ entry: ArchivedItem) {
        archive.append(entry)
        archive.sort { $0.archivedAt > $1.archivedAt }
    }

    func touchAfterImport() { touch() }

    var document: SidebarDocument {
        SidebarDocument(version: 1, spaceOrder: spaceOrder, spaces: orderedSpaces, items: Array(items.values))
    }

    /// Most recently used tab other than the current one (⌃Tab).
    func mostRecentOtherTab() -> UUID? {
        let current = selectedTabID
        return ranking.recentlySwitchedToTabs
            .filter { $0.key != current && items[$0.key]?.isTab == true }
            .max { ($0.value.last ?? .distantPast) < ($1.value.last ?? .distantPast) }?.key
    }

    // MARK: Tree moves

    /// Detach an item from its parent without deleting it.
    private func detach(_ id: UUID) {
        guard let it = items[id], let p = it.parentID, var parent = items[p] else { return }
        parent.children.removeAll { $0 == id }
        items[p] = parent
    }

    private func isDescendant(_ candidate: UUID, of ancestor: UUID) -> Bool {
        var cur = items[candidate]?.parentID
        var hops = 0
        while let c = cur, hops < 64 {
            if c == ancestor { return true }
            cur = items[c]?.parentID
            hops += 1
        }
        return false
    }

    /// Move an item (tab or folder) under `newParent` at `index`. Folders may
    /// only live in pinned sections or favorites; dropping a folder into the
    /// today list unpacks it.
    func moveItem(_ id: UUID, to newParent: UUID, index: Int?) {
        guard var it = items[id], items[newParent] != nil, id != newParent, !isDescendant(newParent, of: id) else { return }
        // Only tabs live inside a split; dropping onto a split adds a pane.
        if items[newParent]?.isSplit == true {
            if it.isTab { addToSplit(newParent, tabID: id, at: index) }
            return
        }
        let fromParent = it.parentID
        let oldIndex = fromParent.flatMap { items[$0]?.children.firstIndex(of: id) }
        if it.isFolder, case .today? = rootContainerKind(newParent) {
            // Unpack: move the folder's tabs instead.
            let kids = it.children
            detach(id)
            items[id] = nil
            var at = index ?? 0
            for k in kids {
                moveItem(k, to: newParent, index: at)
                at += 1
            }
            touch()
            return
        }
        detach(id)
        var parent = items[newParent]!
        var at = index ?? parent.children.count
        if fromParent == newParent, let old = oldIndex, old < at { at -= 1 }
        at = min(max(0, at), parent.children.count)
        parent.children.insert(id, at: at)
        items[newParent] = parent
        it.parentID = newParent
        if var t = it.tab {
            // Moving into a pinned section makes the current page the home.
            let kind = rootContainerKind(newParent)
            switch kind {
            case .pinned, .favorites: t.savedURL = t.url
            default: break
            }
            it.data = .tab(t)
        }
        items[id] = it
        if let from = fromParent, from != newParent { collapseSplitIfNeeded(from) }
        touch()
    }

    /// Moves several items so they end up next to each other, in the given
    /// order, starting at `index` (appended when nil).
    func moveItems(_ ids: [UUID], to newParent: UUID, index: Int?) {
        var at = index
        for id in ids {
            moveItem(id, to: newParent, index: at)
            if at != nil, let i = items[newParent]?.children.firstIndex(of: id) { at = i + 1 }
        }
    }

    private func rootContainerKind(_ id: UUID) -> ContainerKind? { rootContainer(of: id) }

    // MARK: Split view (Arc: SidebarSplitViewData + WindowAction.SplitViewAction)

    /// The split item a tab is a pane of, if any.
    func splitContaining(_ tabID: UUID) -> SidebarItem? {
        guard let p = items[tabID]?.parentID, let parent = items[p], parent.isSplit else { return nil }
        return parent
    }

    /// The panes shown when `tabID` is selected: its split's children in pane
    /// order, or just the tab itself.
    func paneTabIDs(for tabID: UUID) -> [UUID] {
        if let split = splitContaining(tabID) { return split.children.filter { items[$0]?.isTab == true } }
        return [tabID]
    }

    /// Panes shown in a space right now (the selected tab's split).
    func visiblePaneTabIDs(in spaceID: UUID) -> [UUID] {
        guard let sel = selectedTabID(in: spaceID) else { return [] }
        return paneTabIDs(for: sel)
    }

    /// Put tabs into a new split, panes in the given order, at the place of
    /// `anchorID` (default: the first tab) in the sidebar.
    @discardableResult
    func createSplit(with tabIDs: [UUID], at anchorID: UUID? = nil) -> SidebarItem? {
        let tabs = tabIDs.compactMap { items[$0] }.filter { $0.isTab }
        guard let first = anchorID.flatMap({ a in tabs.first { $0.id == a } }) ?? tabs.first else { return nil }
        if let existing = splitContaining(first.id) {
            for t in tabs where t.id != first.id { addToSplit(existing.id, tabID: t.id, at: nil) }
            return items[existing.id]
        }
        // Observed in Arc 1.170: splitting a favorite or pinned tab leaves it in
        // place and builds the split in Today from a copy of the page; a Today
        // tab moves into the split at its own slot.
        var parentID = first.parentID ?? focusedSpace.todayContainerID
        var at = items[parentID]?.children.firstIndex(of: first.id) ?? 0
        if isPinned(first.id) {
            parentID = (spaceID(ofItem: first.id).flatMap { spaces[$0] } ?? focusedSpace).todayContainerID
            at = 0
        }
        var split = SidebarItem.split(parent: parentID)
        var s = SplitData()
        s.timeLastActiveAt = Date()
        split.data = .split(s)
        items[split.id] = split
        var p = items[parentID]!
        p.children.insert(split.id, at: min(at, p.children.count))
        items[parentID] = p
        var paneIDs: [UUID] = []
        var anchorPane: UUID?
        for t in tabs {
            let paneID: UUID
            if isPinned(t.id), let data = t.tab {
                // Keep the pinned tab; the pane is a Today copy of its page.
                var copy = SidebarItem.tab(data.url, title: data.savedTitle, parent: split.id)
                copy.data = .tab({ var c = TabData(url: data.url, title: data.savedTitle); c.faviconKey = data.faviconKey; c.activeTabBeforeCreationID = t.id; return c }())
                items[copy.id] = copy
                paneID = copy.id
            } else {
                detach(t.id)
                var moved = items[t.id]!
                moved.parentID = split.id
                items[t.id] = moved
                paneID = t.id
            }
            items[split.id]!.children.append(paneID)
            paneIDs.append(paneID)
            if t.id == first.id { anchorPane = paneID }
        }
        if var sp = items[split.id], var sd = sp.split {
            sd.focusTabID = anchorPane ?? paneIDs.first
            sp.data = .split(sd)
            items[split.id] = sp
        }
        touch()
        return items[split.id]
    }

    /// The pane that stands for `tabID` in its split (the tab itself, or the
    /// Today copy made for a pinned tab).
    func paneID(for tabID: UUID, in split: SidebarItem) -> UUID? {
        if split.children.contains(tabID) { return tabID }
        return split.children.first { items[$0]?.tab?.activeTabBeforeCreationID == tabID }
    }

    /// Arc's "Add Split View": an empty page becomes a new pane next to `tabID`
    /// (after it by default). Returns the new tab.
    @discardableResult
    func addEmptyPane(nextTo tabID: UUID, after: Bool = true, url: String = "") -> SidebarItem? {
        guard let anchor = items[tabID], anchor.isTab else { return nil }
        let split: SidebarItem
        if let s = splitContaining(tabID) { split = s } else if let s = createSplit(with: [tabID]) { split = s } else { return nil }
        guard let anchorPane = paneID(for: tabID, in: items[split.id] ?? split),
              let idx = items[split.id]?.children.firstIndex(of: anchorPane) else { return nil }
        var tab = SidebarItem.tab(url, title: "", parent: split.id)
        tab.data = .tab({ var t = TabData(url: url, title: ""); t.activeTabBeforeCreationID = tabID; return t }())
        items[tab.id] = tab
        var sp = items[split.id]!
        sp.children.insert(tab.id, at: after ? idx + 1 : idx)
        items[split.id] = sp
        selectTab(tab.id)
        return tab
    }

    /// Add an existing tab as a pane of a split (Arc: onDropSidebarItem). A
    /// pinned or favorite tab stays where it is; a Today copy becomes the pane.
    func addToSplit(_ splitID: UUID, tabID: UUID, at index: Int?) {
        guard var split = items[splitID], split.isSplit, var tab = items[tabID], tab.isTab, tab.parentID != splitID else {
            if let i = index, let sp = items[splitID], sp.children.firstIndex(of: tabID) != nil { moveWithinSplit(splitID, tabID: tabID, to: i) }
            return
        }
        let from = tab.parentID
        var paneID = tabID
        if isPinned(tabID), let data = tab.tab {
            var copy = SidebarItem.tab(data.url, title: data.savedTitle, parent: splitID)
            copy.data = .tab({ var c = TabData(url: data.url, title: data.savedTitle); c.faviconKey = data.faviconKey; c.activeTabBeforeCreationID = tabID; return c }())
            items[copy.id] = copy
            paneID = copy.id
        } else {
            detach(tabID)
            tab.parentID = splitID
            items[tabID] = tab
        }
        split = items[splitID]!
        let at = min(max(0, index ?? split.children.count), split.children.count)
        split.children.insert(paneID, at: at)
        items[splitID] = split
        if paneID == tabID, let from, from != splitID { collapseSplitIfNeeded(from) }
        touch()
    }

    func moveWithinSplit(_ splitID: UUID, tabID: UUID, to index: Int) {
        guard var split = items[splitID], let old = split.children.firstIndex(of: tabID) else { return }
        split.children.remove(at: old)
        var at = index
        if old < at { at -= 1 }
        split.children.insert(tabID, at: min(max(0, at), split.children.count))
        items[splitID] = split
        touch()
    }

    /// Take a pane out of its split: it goes right after the split in the
    /// sidebar (Arc: "Separate Tab from Split"). A split with one pane left
    /// dissolves.
    func separateFromSplit(_ tabID: UUID) {
        guard let split = splitContaining(tabID), let gp = split.parentID, var grand = items[gp],
              let splitIndex = grand.children.firstIndex(of: split.id), var tab = items[tabID] else { return }
        detach(tabID)
        tab.parentID = gp
        items[tabID] = tab
        grand = items[gp]!
        grand.children.insert(tabID, at: min(splitIndex + 1, grand.children.count))
        items[gp] = grand
        collapseSplitIfNeeded(split.id)
        touch()
    }

    func separateAll(_ splitID: UUID) {
        guard let split = items[splitID], split.isSplit else { return }
        for id in split.children.reversed() { separateFromSplit(id) }
    }

    func setSplitWidthFactors(_ splitID: UUID, _ factors: [UUID: Double]) {
        guard var split = items[splitID], var s = split.split else { return }
        s.widthFactors = factors
        split.data = .split(s)
        items[splitID] = split
        touch()
    }

    func flipSplitOrientation(_ splitID: UUID) {
        guard var split = items[splitID], var s = split.split else { return }
        s.orientation = s.orientation == .horizontal ? .vertical : .horizontal
        split.data = .split(s)
        items[splitID] = split
        touch()
    }

    /// Zero or one pane left: the split goes away and the pane takes its slot.
    private func collapseSplitIfNeeded(_ splitID: UUID) {
        guard let split = items[splitID], split.isSplit, split.children.count <= 1 else { return }
        let sid = spaceID(ofItem: splitID)
        if let gp = split.parentID, var grand = items[gp] {
            let at = grand.children.firstIndex(of: splitID) ?? grand.children.count
            grand.children.removeAll { $0 == splitID }
            for c in split.children {
                if var child = items[c] {
                    child.parentID = gp
                    items[c] = child
                    grand.children.insert(c, at: min(at, grand.children.count))
                }
            }
            items[gp] = grand
        }
        items[splitID] = nil
        if let sid, let sel = prefs.selectedTabPerSpace[sid], items[sel] == nil {
            prefs.selectedTabPerSpace[sid] = split.children.first
        }
    }

    func pinTab(_ id: UUID) {
        guard let sid = spaceID(ofItem: id), let space = spaces[sid] else { return }
        if isFavorite(id) {
            moveItem(id, to: space.pinnedContainerID, index: nil)
        } else {
            moveItem(id, to: space.pinnedContainerID, index: nil)
        }
    }

    func unpinTab(_ id: UUID) {
        guard let sid = spaceID(ofItem: id), let space = spaces[sid] else { return }
        moveItem(id, to: space.todayContainerID, index: 0)
    }

    func togglePinned(_ id: UUID) {
        if isPinned(id) { unpinTab(id) } else { pinTab(id) }
    }

    /// Favorites belong to one space: the tab's own unless another is given.
    func addToFavorites(_ id: UUID, in spaceID: UUID? = nil) {
        guard let space = spaces[spaceID ?? self.spaceID(ofItem: id) ?? focusedSpaceID] else { return }
        // A new favorite takes the tile color when every existing one shares it.
        let colors = Set(tabs(under: space.favoritesContainerID).map { $0.tab?.tileColor })
        moveItem(id, to: space.favoritesContainerID, index: nil)
        if colors.count == 1, let color = colors.first!, items[id]?.tab?.tileColor == nil { setTileColor(color, for: [id]) }
    }

    func setTileColor(_ hex: String?, for ids: [UUID]) {
        for id in ids {
            guard var it = items[id], var t = it.tab else { continue }
            t.tileColor = hex
            it.data = .tab(t)
            items[id] = it
        }
        touch()
    }

    func setCustomIcon(_ key: String?, for id: UUID) {
        guard var it = items[id], var t = it.tab else { return }
        t.customIconKey = key
        it.data = .tab(t)
        items[id] = it
        touch()
    }

    func removeFromFavorites(_ id: UUID) {
        guard let space = spaceID(ofItem: id).flatMap({ spaces[$0] }) else { return }
        moveItem(id, to: space.pinnedContainerID, index: nil)
    }

    func moveTab(_ id: UUID, toSpace sid: UUID) {
        guard let space = spaces[sid] else { return }
        if isFavorite(id) { return moveItem(id, to: space.favoritesContainerID, index: nil) }
        let pinned = isPinned(id)
        moveItem(id, to: pinned ? space.pinnedContainerID : space.todayContainerID, index: pinned ? nil : 0)
    }

    // MARK: Folders

    @discardableResult
    func createFolder(named name: String, in parent: UUID, index: Int? = nil) -> SidebarItem {
        var folder = SidebarItem.folder(name, parent: parent)
        folder.parentID = parent
        items[folder.id] = folder
        var p = items[parent]!
        p.children.insert(folder.id, at: min(index ?? p.children.count, p.children.count))
        items[parent] = p
        prefs.expandedFolders.insert(folder.id)
        // A collapsed pinned list would hide the new folder (and its rename field).
        if case .pinned(let sid)? = rootContainer(of: parent) { prefs.collapsedPinnedSpaces.remove(sid) }
        touch()
        return folder
    }

    /// Drop a tab onto another: both go into a new folder at the target's
    /// place. Folders only live in pinned sections, so a Today target puts
    /// the folder at the end of its space's pinned list.
    @discardableResult
    func createFolder(combining targetID: UUID, with tabID: UUID, named name: String = "New Folder") -> SidebarItem? {
        createFolder(combining: targetID, with: [tabID], named: name)
    }

    @discardableResult
    func createFolder(combining targetID: UUID, with tabIDs: [UUID], named name: String = "New Folder") -> SidebarItem? {
        let tabIDs = tabIDs.filter { $0 != targetID && items[$0]?.isTab == true }
        guard !tabIDs.isEmpty, items[targetID]?.isTab == true,
              let parent = items[targetID]?.parentID, let sid = spaceID(ofItem: targetID), let space = spaces[sid] else { return nil }
        let inPinned = rootContainer(of: targetID) == .pinned(spaceID: sid)
        let folder = createFolder(named: name, in: inPinned ? parent : space.pinnedContainerID,
                                  index: inPinned ? items[parent]?.children.firstIndex(of: targetID) : nil)
        moveItems([targetID] + tabIDs, to: folder.id, index: nil)
        return items[folder.id]
    }

    func setFolderIcon(_ style: FolderIconStyle?, for id: UUID) {
        guard var it = items[id], it.isFolder else { return }
        it.folderIcon = style
        items[id] = it
        touch()
    }

    /// A new folder at the top of the space's pinned list holding these tabs.
    @discardableResult
    func createFolder(with tabIDs: [UUID], named name: String = "New Folder") -> SidebarItem {
        let folder = createFolder(named: name, in: focusedSpace.pinnedContainerID, index: 0)
        moveItems(tabIDs, to: folder.id, index: nil)
        return items[folder.id] ?? folder
    }

    func deleteFolder(_ id: UUID) {
        guard let f = items[id], f.isFolder else { return }
        for t in tabs(under: id) { archiveTab(t.id, reason: .manual) }
        // Nested folders left behind (now empty) go too.
        for c in children(of: id) where c.isFolder { deleteFolder(c.id) }
        for c in children(of: id) where c.isSplit { items[c.id] = nil }
        detach(id)
        items[id] = nil
        touch()
    }

    func isExpanded(_ id: UUID) -> Bool { prefs.expandedFolders.contains(id) }
    func setExpanded(_ id: UUID, _ expanded: Bool) {
        if expanded { prefs.expandedFolders.insert(id) } else { prefs.expandedFolders.remove(id) }
    }

    /// Arc's spacesWithCollapsedPinnedSections: clicking the space name hides its pinned tabs.
    func isPinnedCollapsed(_ spaceID: UUID) -> Bool { prefs.collapsedPinnedSpaces.contains(spaceID) }
    func togglePinnedCollapsed(_ spaceID: UUID) {
        if prefs.collapsedPinnedSpaces.remove(spaceID) == nil { prefs.collapsedPinnedSpaces.insert(spaceID) }
    }

    // MARK: Archive

    func archiveTab(_ id: UUID, reason: ArchiveReason) {
        guard let it = items[id], it.isTab else { return }
        let sid = spaceID(ofItem: id)
        let wasSelected = sid.flatMap { selectedTabID(in: $0) } == id
        let pinned = isPinned(id)
        let split = splitContaining(id)
        detach(id)
        items[id] = nil
        // Empty panes never had a page; nothing to keep in the Library.
        if !it.isEmptyTab {
            archive.insert(ArchivedItem(archivedAt: Date(), reason: reason, sourceSpaceID: sid, wasPinned: pinned, item: it), at: 0)
            if archive.count > 2000 { archive.removeLast(archive.count - 2000) }
        }
        if wasSelected, let sid {
            // Closing a pane keeps the split on screen: focus a neighbour pane.
            if let split, let remaining = items[split.id]?.children.first(where: { items[$0]?.isTab == true }) {
                prefs.selectedTabPerSpace[sid] = remaining
            } else {
                prefs.selectedTabPerSpace[sid] = nextSelection(after: it, in: sid)
            }
        }
        if let split { collapseSplitIfNeeded(split.id) }
        touch()
    }

    /// Arc goes back to the tab you came from (activeTabBeforeCreationID) and
    /// otherwise to the neighbour in the list.
    private func nextSelection(after closed: SidebarItem, in sid: UUID) -> UUID? {
        if let back = closed.tab?.activeTabBeforeCreationID, items[back]?.isTab == true, spaceID(ofItem: back) == sid {
            return back
        }
        let list = visibleTabs(in: sid)
        guard !list.isEmpty else { return nil }
        if let p = closed.parentID, let siblings = items[p]?.children {
            // Prefer the sibling that took the closed tab's slot (the one below it).
            let today = tabs(under: p)
            if let first = today.first { _ = first }
            _ = siblings
        }
        // Fall back to the top-most today tab, then the first visible tab.
        if let space = spaces[sid], let first = tabs(under: space.todayContainerID).first { return first.id }
        return list.first?.id
    }

    @discardableResult
    func restoreArchived(_ id: UUID, select: Bool = true) -> SidebarItem? {
        guard let idx = archive.firstIndex(where: { $0.id == id }) else { return nil }
        let entry = archive.remove(at: idx)
        var it = entry.item
        let sid = entry.sourceSpaceID.flatMap { spaces[$0] != nil ? $0 : nil } ?? focusedSpaceID
        let space = spaces[sid]!
        let parent = entry.wasPinned ? space.pinnedContainerID : space.todayContainerID
        it.parentID = parent
        it.children = []
        it.isUnread = false
        items[it.id] = it
        var p = items[parent]!
        p.children.insert(it.id, at: entry.wasPinned ? p.children.count : 0)
        items[parent] = p
        if select { selectTab(it.id) } else { touch() }
        return it
    }

    @discardableResult
    func reopenLastArchived() -> SidebarItem? {
        guard let last = archive.first else { return nil }
        return restoreArchived(last.id)
    }

    func removeFromArchive(_ id: UUID) {
        archive.removeAll { $0.id == id }
        touch()
    }

    func clearArchive() {
        archive.removeAll()
        touch()
    }

    func clearToday(_ sid: UUID? = nil) {
        guard let space = spaces[sid ?? focusedSpaceID] else { return }
        for t in tabs(under: space.todayContainerID) { archiveTab(t.id, reason: .clear) }
    }

    /// Today tabs idle longer than the threshold are archived (Arc:
    /// ArchiveState+AutoArchive, autoArchiveTimeThreshold).
    func runAutoArchive() {
        guard settings.autoArchiveEnabled else { return }
        let cutoff = Date().addingTimeInterval(-settings.autoArchive.seconds)
        for space in orderedSpaces {
            let selected = selectedTabID(in: space.id)
            for t in tabs(under: space.todayContainerID) where t.id != selected {
                let last = t.tab?.timeLastActiveAt ?? t.createdAt
                if last < cutoff { archiveTab(t.id, reason: .auto) }
            }
        }
    }

    // MARK: Spaces

    @discardableResult
    func createSpace(title: String, emoji: String, theme: SpaceTheme? = nil, focus: Bool = true) -> Space {
        let id = UUID()
        let favorites = SidebarItem.container(.favorites(spaceID: id))
        let pinned = SidebarItem.container(.pinned(spaceID: id))
        let today = SidebarItem.container(.today(spaceID: id))
        items[favorites.id] = favorites
        items[pinned.id] = pinned
        items[today.id] = today
        let t = theme ?? SpaceTheme.presets[spaceOrder.count % SpaceTheme.presets.count]
        let space = Space(id: id, title: title, emoji: emoji, theme: t, favoritesContainerID: favorites.id,
                          pinnedContainerID: pinned.id, todayContainerID: today.id, createdAt: Date())
        spaces[id] = space
        spaceOrder.append(id)
        if focus { prefs.focusedSpaceID = id }
        touch()
        return space
    }

    func updateSpace(_ space: Space) {
        guard spaces[space.id] != nil else { return }
        spaces[space.id] = space
        touch()
    }

    func deleteSpace(_ id: UUID) {
        guard spaces.count > 1, let space = spaces[id] else { return }
        for t in tabs(under: space.favoritesContainerID) + tabs(under: space.pinnedContainerID) + tabs(under: space.todayContainerID) {
            archiveTab(t.id, reason: .spaceDeleted)
        }
        for c in children(of: space.favoritesContainerID) + children(of: space.pinnedContainerID) where c.isFolder { deleteFolder(c.id) }
        items[space.favoritesContainerID] = nil
        items[space.pinnedContainerID] = nil
        items[space.todayContainerID] = nil
        spaces[id] = nil
        spaceOrder.removeAll { $0 == id }
        prefs.selectedTabPerSpace[id] = nil
        if prefs.focusedSpaceID == id { prefs.focusedSpaceID = spaceOrder.first }
        touch()
    }

    func moveSpace(_ id: UUID, to index: Int) {
        guard let from = spaceOrder.firstIndex(of: id) else { return }
        spaceOrder.remove(at: from)
        spaceOrder.insert(id, at: min(max(0, index), spaceOrder.count))
        touch()
    }

    func focusSpace(_ id: UUID) {
        guard spaces[id] != nil, id != focusedSpaceID else { return }
        prefs.focusedSpaceID = id
        revision &+= 1
    }

    func focusSpace(offset: Int) {
        guard let idx = spaceOrder.firstIndex(of: focusedSpaceID), spaceOrder.count > 1 else { return }
        let n = spaceOrder.count
        focusSpace(spaceOrder[((idx + offset) % n + n) % n])
    }

    // MARK: History and ranking signals

    func recordVisit(url: String, title: String) {
        guard url.hasPrefix("http") else { return }
        var e = history[url] ?? HistoryEntry(url: url, title: title, lastVisit: Date(), visitCount: 0)
        e.visitCount += 1
        e.lastVisit = Date()
        if !title.isEmpty { e.title = title }
        history[url] = e
        if history.count > 5000 {
            let drop = history.values.sorted { $0.lastVisit < $1.lastVisit }.prefix(history.count - 5000)
            for d in drop { history[d.url] = nil }
        }
        historyFile.save(Array(history.values), delay: 5)
    }

    func recordQuerySelection(query: String, url: String) {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        ranking.queriesToSelected[q] = url
        if ranking.queriesToSelected.count > 500 {
            if let k = ranking.queriesToSelected.keys.first { ranking.queriesToSelected[k] = nil }
        }
        rankingFile.save(ranking)
    }

    func recordCommandUse(_ id: String) {
        ranking.commandUsage[id, default: 0] += 1
        rankingFile.save(ranking)
    }
}
