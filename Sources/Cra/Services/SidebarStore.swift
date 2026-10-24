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
    private(set) var favoritesContainerID: UUID = UUID()
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
        favoritesContainerID = doc.favoritesContainerID
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
    }

    /// Make sure every space has its containers, favorites exist, and no item
    /// points at a parent that is gone.
    func repair() {
        if items[favoritesContainerID] == nil {
            let fav = SidebarItem.container(.favorites, id: favoritesContainerID)
            items[fav.id] = fav
        }
        for (id, var space) in spaces {
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
            for it in doc.items where it.container != .favorites { items[it.id] = it }
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

    func save() {
        let doc = SidebarDocument(version: 1, spaceOrder: spaceOrder, spaces: spaceOrder.compactMap { spaces[$0] },
                                  favoritesContainerID: favoritesContainerID, items: Array(items.values))
        sidebarFile.save(doc)
        archiveFile.save(archive)
    }

    func saveAll() {
        let doc = SidebarDocument(version: 1, spaceOrder: spaceOrder, spaces: spaceOrder.compactMap { spaces[$0] },
                                  favoritesContainerID: favoritesContainerID, items: Array(items.values))
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
                if c.isTab { out.append(c) } else if c.isFolder { walk(c.id) }
            }
        }
        walk(id)
        return out
    }

    func allTabs() -> [SidebarItem] { items.values.filter { $0.isTab } }

    /// Favorites + pinned + today for a space, in sidebar order. This is what
    /// ⌘1…⌘9 index into (Arc: "Go to Sidebar Item N").
    func visibleTabs(in spaceID: UUID) -> [SidebarItem] {
        guard let space = spaces[spaceID] else { return [] }
        return tabs(under: favoritesContainerID) + tabs(under: space.pinnedContainerID) + tabs(under: space.todayContainerID)
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

    func spaceID(ofItem id: UUID) -> UUID? {
        switch rootContainer(of: id) {
        case .pinned(let s), .today(let s): return s
        case .favorites: return focusedSpaceID
        default: return nil
        }
    }

    func isPinned(_ id: UUID) -> Bool {
        switch rootContainer(of: id) {
        case .pinned, .favorites: return true
        default: return false
        }
    }

    func isFavorite(_ id: UUID) -> Bool { rootContainer(of: id) == .favorites }

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
                                         favoritesContainerID: favoritesContainerID, items: Array(items.values)), delay: 2)
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

    /// Replace the whole sidebar with a backup (cloud restore).
    func replaceDocument(_ doc: SidebarDocument) {
        spaces = [:]
        for s in doc.spaces { spaces[s.id] = s }
        spaceOrder = doc.spaceOrder.filter { spaces[$0] != nil }
        items = [:]
        for it in doc.items { items[it.id] = it }
        favoritesContainerID = doc.favoritesContainerID
        repair()
        prefs.focusedSpaceID = spaceOrder.first
        prefs.selectedTabPerSpace = [:]
        touch()
    }

    var document: SidebarDocument {
        SidebarDocument(version: 1, spaceOrder: spaceOrder, spaces: orderedSpaces, favoritesContainerID: favoritesContainerID, items: Array(items.values))
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
        let fromParent = it.parentID
        let oldIndex = fromParent.flatMap { items[$0]?.children.firstIndex(of: id) }
        if it.isFolder, case .today = rootContainerKind(newParent) ?? .favorites {
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
        touch()
    }

    private func rootContainerKind(_ id: UUID) -> ContainerKind? { rootContainer(of: id) }

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

    func addToFavorites(_ id: UUID) { moveItem(id, to: favoritesContainerID, index: nil) }

    func removeFromFavorites(_ id: UUID) {
        moveItem(id, to: focusedSpace.pinnedContainerID, index: nil)
    }

    func moveTab(_ id: UUID, toSpace sid: UUID) {
        guard let space = spaces[sid] else { return }
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
        touch()
        return folder
    }

    func deleteFolder(_ id: UUID) {
        guard let f = items[id], f.isFolder else { return }
        for t in tabs(under: id) { archiveTab(t.id, reason: .manual) }
        // Nested folders left behind (now empty) go too.
        for c in children(of: id) where c.isFolder { deleteFolder(c.id) }
        detach(id)
        items[id] = nil
        touch()
    }

    func isExpanded(_ id: UUID) -> Bool { prefs.expandedFolders.contains(id) }
    func setExpanded(_ id: UUID, _ expanded: Bool) {
        if expanded { prefs.expandedFolders.insert(id) } else { prefs.expandedFolders.remove(id) }
    }

    // MARK: Archive

    func archiveTab(_ id: UUID, reason: ArchiveReason) {
        guard let it = items[id], it.isTab else { return }
        let sid = spaceID(ofItem: id)
        let wasSelected = sid.flatMap { selectedTabID(in: $0) } == id
        let pinned = isPinned(id)
        detach(id)
        items[id] = nil
        archive.insert(ArchivedItem(archivedAt: Date(), reason: reason, sourceSpaceID: sid, wasPinned: pinned, item: it), at: 0)
        if archive.count > 2000 { archive.removeLast(archive.count - 2000) }
        if wasSelected, let sid {
            prefs.selectedTabPerSpace[sid] = nextSelection(after: it, in: sid)
        }
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
        let pinned = SidebarItem.container(.pinned(spaceID: id))
        let today = SidebarItem.container(.today(spaceID: id))
        items[pinned.id] = pinned
        items[today.id] = today
        let t = theme ?? SpaceTheme.presets[spaceOrder.count % SpaceTheme.presets.count]
        let space = Space(id: id, title: title, emoji: emoji, theme: t, pinnedContainerID: pinned.id,
                          todayContainerID: today.id, createdAt: Date())
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
        for t in tabs(under: space.pinnedContainerID) + tabs(under: space.todayContainerID) {
            archiveTab(t.id, reason: .spaceDeleted)
        }
        for c in children(of: space.pinnedContainerID) where c.isFolder { deleteFolder(c.id) }
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
