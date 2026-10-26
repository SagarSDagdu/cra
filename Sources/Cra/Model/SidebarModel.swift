import Foundation

// Cra's sidebar model. Shape follows what Arc persists in StorableSidebar.json
// (see docs/arc-reverse-engineering.md): spaces own a favorites, a pinned and a
// "today" container, tabs/folders are items in a tree keyed by id with explicit
// child ordering. Unlike Arc, favorites are not shared between spaces.

typealias ItemID = UUID

enum ContainerKind: Codable, Equatable, Hashable {
    case favorites(spaceID: UUID)
    case pinned(spaceID: UUID)
    case today(spaceID: UUID)

    var spaceID: UUID {
        switch self {
        case .favorites(let id), .pinned(let id), .today(let id): return id
        }
    }

    /// Stands in for the space of the favorites container every space shared
    /// before favorites became per space; SidebarStore splits it up on load.
    static let sharedFavoritesSpaceID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    private enum CodingKeys: String, CodingKey { case favorites, pinned, today }
    private enum SpaceKeys: String, CodingKey { case spaceID }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let key = c.allKeys.first else {
            throw DecodingError.dataCorrupted(.init(codingPath: c.codingPath, debugDescription: "No container kind"))
        }
        let s = try c.nestedContainer(keyedBy: SpaceKeys.self, forKey: key)
        switch key {
        case .favorites: self = .favorites(spaceID: try s.decodeIfPresent(UUID.self, forKey: .spaceID) ?? Self.sharedFavoritesSpaceID)
        case .pinned: self = .pinned(spaceID: try s.decode(UUID.self, forKey: .spaceID))
        case .today: self = .today(spaceID: try s.decode(UUID.self, forKey: .spaceID))
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        let key: CodingKeys
        switch self {
        case .favorites: key = .favorites
        case .pinned: key = .pinned
        case .today: key = .today
        }
        var s = c.nestedContainer(keyedBy: SpaceKeys.self, forKey: key)
        try s.encode(spaceID, forKey: .spaceID)
    }
}

struct TabData: Codable, Equatable {
    /// Where the tab currently is. Restored on relaunch.
    var url: String
    /// The "home" of the tab. For pinned tabs this is what reset returns to;
    /// for today tabs it is just the URL the tab was created with.
    var savedURL: String
    /// Last known page title.
    var savedTitle: String
    var muted: Bool = false
    var timeLastActiveAt: Date?
    var activeTabBeforeCreationID: UUID?
    /// Host used as favicon cache key.
    var faviconKey: String?

    init(url: String, title: String = "") {
        self.url = url
        self.savedURL = url
        self.savedTitle = title
        self.faviconKey = URL(string: url)?.host
    }
}

/// Arc's SidebarSplitViewData: a split is a sidebar item whose children are
/// the pane tabs (in pane order). Widths are stored as factors per child.
struct SplitData: Codable, Equatable {
    var widthFactors: [UUID: Double] = [:]
    var orientation: SplitOrientation = .horizontal
    /// The pane that has keyboard focus (Arc: focusItemID).
    var focusTabID: UUID?
    var timeLastActiveAt: Date?

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        widthFactors = try c.decodeIfPresent([UUID: Double].self, forKey: .widthFactors) ?? [:]
        orientation = try c.decodeIfPresent(SplitOrientation.self, forKey: .orientation) ?? .horizontal
        focusTabID = try c.decodeIfPresent(UUID.self, forKey: .focusTabID)
        timeLastActiveAt = try c.decodeIfPresent(Date.self, forKey: .timeLastActiveAt)
    }
}

enum SplitOrientation: String, Codable {
    /// Panes side by side (Arc's default).
    case horizontal
    /// Panes stacked top to bottom.
    case vertical
}

enum ItemData: Codable, Equatable {
    case tab(TabData)
    case folder
    case container(ContainerKind)
    case split(SplitData)
}

struct SidebarItem: Identifiable, Codable, Equatable {
    var id: UUID
    var parentID: UUID?
    /// Custom title set by renaming. nil means "use the page title".
    var title: String?
    var children: [UUID]
    var isUnread: Bool
    var createdAt: Date
    var data: ItemData

    var tab: TabData? {
        if case .tab(let t) = data { return t }
        return nil
    }
    var isTab: Bool { tab != nil }
    var isFolder: Bool { if case .folder = data { return true }; return false }
    var split: SplitData? {
        if case .split(let s) = data { return s }
        return nil
    }
    var isSplit: Bool { split != nil }
    /// A tab with no page yet: Arc's empty split pane ("Search or Enter URL…").
    var isEmptyTab: Bool { tab.map { $0.url.isEmpty || $0.url == "about:blank" } ?? false }
    var container: ContainerKind? {
        if case .container(let c) = data { return c }
        return nil
    }

    /// What the sidebar shows: the custom name wins over the page title,
    /// which wins over the host.
    var displayTitle: String {
        if let t = title, !t.isEmpty { return t }
        if let tab {
            if isEmptyTab { return "New Tab" }
            if !tab.savedTitle.isEmpty { return tab.savedTitle }
            if let host = URL(string: tab.url)?.host { return host }
            return tab.url
        }
        if isSplit { return "Split View" }
        return "Untitled"
    }

    static func split(parent: UUID?) -> SidebarItem {
        SidebarItem(id: UUID(), parentID: parent, title: nil, children: [], isUnread: false,
                    createdAt: Date(), data: .split(SplitData()))
    }

    static func tab(_ url: String, title: String = "", parent: UUID?) -> SidebarItem {
        SidebarItem(id: UUID(), parentID: parent, title: nil, children: [], isUnread: false,
                    createdAt: Date(), data: .tab(TabData(url: url, title: title)))
    }

    static func folder(_ name: String, parent: UUID?) -> SidebarItem {
        SidebarItem(id: UUID(), parentID: parent, title: name, children: [], isUnread: false,
                    createdAt: Date(), data: .folder)
    }

    static func container(_ kind: ContainerKind, id: UUID = UUID()) -> SidebarItem {
        SidebarItem(id: id, parentID: nil, title: nil, children: [], isUnread: false,
                    createdAt: Date(), data: .container(kind))
    }
}

struct SpaceTheme: Codable, Equatable {
    /// One or two hex colors blended into a gradient (Arc: blendedGradient.baseColors).
    var colors: [String]
    /// 0...1, how saturated the gradient is rendered (Arc: intensityFactor).
    var intensity: Double
    /// 0...1 grain overlay (Arc: noiseFactor).
    var noise: Double
    /// "auto" | "light" | "dark" (Arc: contentOverBackgroundAppearance).
    var appearance: String
    /// Arc's isVibrant: the gradient is laid over the blurred desktop at
    /// `intensity` opacity instead of being painted opaque.
    var vibrant: Bool = false
    /// The theme's raw first colour (Arc's base colour); drives the toolbar band.
    var accent: String? = nil

    init(colors: [String], intensity: Double, noise: Double, appearance: String, vibrant: Bool = false, accent: String? = nil) {
        self.colors = colors
        self.intensity = intensity
        self.noise = noise
        self.appearance = appearance
        self.vibrant = vibrant
        self.accent = accent
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        colors = try c.decodeIfPresent([String].self, forKey: .colors) ?? ["#1C242B", "#3A3660"]
        intensity = try c.decodeIfPresent(Double.self, forKey: .intensity) ?? 0.8
        noise = try c.decodeIfPresent(Double.self, forKey: .noise) ?? 0.15
        appearance = try c.decodeIfPresent(String.self, forKey: .appearance) ?? "auto"
        vibrant = try c.decodeIfPresent(Bool.self, forKey: .vibrant) ?? false
        accent = try c.decodeIfPresent(String.self, forKey: .accent)
    }

    /// Dark first: colors borrowed from Victor's other projects (GhostWriter
    /// ink + brand purple, Spook's "wall" browns, Phantom's greys, moss, gold,
    /// ember), then a few lighter Arc-style gradients.
    static let presets: [SpaceTheme] = [
        SpaceTheme(colors: ["#1C242B", "#3A3660"], intensity: 0.85, noise: 0.18, appearance: "dark"),  // Ink
        SpaceTheme(colors: ["#1C1712", "#2E2620"], intensity: 0.9, noise: 0.22, appearance: "dark"),   // Wall
        SpaceTheme(colors: ["#181818", "#262626"], intensity: 0.9, noise: 0.12, appearance: "dark"),   // Phantom
        SpaceTheme(colors: ["#0F2420", "#2F6F5E"], intensity: 0.75, noise: 0.18, appearance: "dark"),  // Moss
        SpaceTheme(colors: ["#2A1A14", "#A2481D"], intensity: 0.7, noise: 0.2, appearance: "dark"),    // Ember
        SpaceTheme(colors: ["#2A2310", "#7A5C0F"], intensity: 0.75, noise: 0.2, appearance: "dark"),   // Gold
        SpaceTheme(colors: ["#241C3A", "#6944AE"], intensity: 0.75, noise: 0.18, appearance: "dark"),  // Brand
        SpaceTheme(colors: ["#F8D558", "#A4F554"], intensity: 0.45, noise: 0.25, appearance: "light"),
        SpaceTheme(colors: ["#C7CAFF", "#FFE5E5"], intensity: 0.5, noise: 0.1, appearance: "light"),
        SpaceTheme(colors: ["#F4F1EA", "#E6DCC8"], intensity: 0.6, noise: 0.15, appearance: "light"),  // Parchment
    ]

    var isDark: Bool {
        if appearance == "dark" { return true }
        if appearance == "light" { return false }
        // auto: judge by the first color's luminance
        return (colors.first.flatMap(HexColor.luminance) ?? 1) < 0.45
    }
}

enum HexColor {
    static func components(_ hex: String) -> (r: Double, g: Double, b: Double)? {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        return (Double((v >> 16) & 0xff) / 255, Double((v >> 8) & 0xff) / 255, Double(v & 0xff) / 255)
    }
    static func luminance(_ hex: String) -> Double? {
        guard let c = components(hex) else { return nil }
        return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
    }
}

struct Space: Identifiable, Codable, Equatable {
    var id: UUID
    var title: String
    var emoji: String
    var theme: SpaceTheme
    var favoritesContainerID: UUID
    var pinnedContainerID: UUID
    var todayContainerID: UUID
    var createdAt: Date
}

struct SidebarDocument: Codable {
    var version: Int = 1
    var spaceOrder: [UUID]
    var spaces: [Space]
    /// The favorites container all spaces shared in older files. Only read, to
    /// split it up between the spaces; new files leave it out.
    var favoritesContainerID: UUID?
    var items: [SidebarItem]

    static func fresh() -> SidebarDocument {
        let spaceID = UUID()
        let fav = SidebarItem.container(.favorites(spaceID: spaceID))
        let pinned = SidebarItem.container(.pinned(spaceID: spaceID))
        let today = SidebarItem.container(.today(spaceID: spaceID))
        let space = Space(id: spaceID, title: "Personal", emoji: "🌱", theme: SpaceTheme.presets[0], favoritesContainerID: fav.id,
                          pinnedContainerID: pinned.id, todayContainerID: today.id, createdAt: Date())
        return SidebarDocument(spaceOrder: [spaceID], spaces: [space], items: [fav, pinned, today])
    }
}

enum ArchiveReason: String, Codable {
    case manual, auto, clear, spaceDeleted
}

struct ArchivedItem: Codable, Identifiable, Equatable {
    var id: UUID { item.id }
    var archivedAt: Date
    var reason: ArchiveReason
    var sourceSpaceID: UUID?
    var wasPinned: Bool
    var item: SidebarItem
    /// Closed from a Little Window (Arc: archive source `littleArc`); never
    /// had a place in the sidebar, so restoring puts it in the focused space.
    var fromLittleWindow: Bool? = nil
}

enum AutoArchiveThreshold: String, Codable, CaseIterable, Identifiable {
    case twelveHours, twentyFourHours, sevenDays, thirtyDays
    var id: String { rawValue }
    var seconds: TimeInterval {
        switch self {
        case .twelveHours: return 12 * 3600
        case .twentyFourHours: return 24 * 3600
        case .sevenDays: return 7 * 86400
        case .thirtyDays: return 30 * 86400
        }
    }
    var label: String {
        switch self {
        case .twelveHours: return "12 hours"
        case .twentyFourHours: return "24 hours"
        case .sevenDays: return "7 days"
        case .thirtyDays: return "30 days"
        }
    }
}

enum SearchEngine: String, Codable, CaseIterable, Identifiable {
    case google, duckduckgo, bing, kagi
    var id: String { rawValue }
    var label: String {
        switch self {
        case .google: return "Google"
        case .duckduckgo: return "DuckDuckGo"
        case .bing: return "Bing"
        case .kagi: return "Kagi"
        }
    }
    func searchURL(_ query: String) -> String {
        let q = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)?
            .replacingOccurrences(of: "&", with: "%26") ?? query
        switch self {
        case .google: return "https://www.google.com/search?q=\(q)"
        case .duckduckgo: return "https://duckduckgo.com/?q=\(q)"
        case .bing: return "https://www.bing.com/search?q=\(q)"
        case .kagi: return "https://kagi.com/search?q=\(q)"
        }
    }
}

struct AppSettings: Codable, Equatable {
    var autoArchive: AutoArchiveThreshold = .twelveHours
    var searchEngine: SearchEngine = .google
    var newTabsAtTop: Bool = true
    var showStatusBar: Bool = true
    /// Arc's toolbar above the page (URL, copy link, DevTools). ⇧⌘D toggles. Off by
    /// default like Arc, which keeps the URL at the top of the sidebar.
    var showToolbar: Bool = false
    /// Cra 0.1.0 saved `showToolbar` as on for everyone; settings without this mark
    /// take the toolbar from Arc's own preference once (off without Arc).
    var toolbarDefaultMigrated: Bool = true
    var hasSeenImportPrompt: Bool = false
    /// Arc's per-site Developer Mode (⌃D): the toolbar shows the full URL in
    /// monospace with the developer icons, and the nav buttons move to the sidebar.
    var developerHosts: Set<String> = []
    /// Host pages in Chrome-style windows: Chrome extensions and Chrome's own
    /// DevTools docking. Needs a restart to change.
    var chromeEngine: Bool = true
    /// Arc's "Links from other apps open in Little Arc": URLs handed to Cra by
    /// other apps open in a small disposable window instead of a sidebar tab.
    var openExternalLinksInLittleWindow: Bool = true
    /// Arc: "Enable Picture in Picture when you leave a video tab".
    var autoPictureInPicture: Bool = true
    /// Dia's onboarding privacy choice "Block third-party ads and trackers": requests
    /// to listed ad and tracker domains are cancelled unless they are first-party.
    var blockAdsAndTrackers: Bool = true
    /// Dia's Tabs ▸ "Haptic feedback when reordering tabs" (tabReorderingHapticsEnabled).
    var hapticFeedbackOnReorder: Bool = true
    /// Dia's Advanced ▸ "Warn before quitting" (shouldWarnBeforeQuitting, off by default).
    var warnBeforeQuitting: Bool = false
    /// Dia's Tabs ▸ "Clean up tabs I haven't used in:" checkbox; `autoArchive` keeps the
    /// threshold while this is off.
    var autoArchiveEnabled: Bool = true

    init() {}

    static func siteKey(for url: String) -> String? {
        URL(string: url)?.host?.lowercased().replacingOccurrences(of: "www.", with: "")
    }
    func isDeveloperMode(url: String) -> Bool { AppSettings.siteKey(for: url).map(developerHosts.contains) ?? false }
    mutating func toggleDeveloperMode(url: String) {
        guard let k = AppSettings.siteKey(for: url) else { return }
        if developerHosts.contains(k) { developerHosts.remove(k) } else { developerHosts.insert(k) }
    }
}

struct WindowPrefs: Codable, Equatable {
    var sidebarWidth: Double = 328
    var sidebarVisible: Bool = true
    var focusedSpaceID: UUID?
    var expandedFolders: Set<UUID> = []
    var collapsedPinnedSpaces: Set<UUID> = []
    var selectedTabPerSpace: [UUID: UUID] = [:]
    var windowFrame: String?
    /// Last Little Window size (Arc: LittleBrowserWindow_size).
    var littleWindowSize: String?
}

struct HistoryEntry: Codable, Equatable {
    var url: String
    var title: String
    var lastVisit: Date
    var visitCount: Int
}

/// Signals the command bar learns from, mirroring Arc's
/// StorableCommandBarAdditionalRanking.json (recentlySwitchedToTabs,
/// queriesToSelectedArchetype, typeTravelUsage).
struct RankingData: Codable, Equatable {
    var recentlySwitchedToTabs: [UUID: [Date]] = [:]
    var queriesToSelected: [String: String] = [:]
    var commandUsage: [String: Int] = [:]
}


// Tolerant decoding so new preference keys never reset the file.
extension AppSettings {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        autoArchive = try c.decodeIfPresent(AutoArchiveThreshold.self, forKey: .autoArchive) ?? .twelveHours
        searchEngine = try c.decodeIfPresent(SearchEngine.self, forKey: .searchEngine) ?? .google
        newTabsAtTop = try c.decodeIfPresent(Bool.self, forKey: .newTabsAtTop) ?? true
        showStatusBar = try c.decodeIfPresent(Bool.self, forKey: .showStatusBar) ?? true
        if try c.decodeIfPresent(Bool.self, forKey: .toolbarDefaultMigrated) == true {
            showToolbar = try c.decodeIfPresent(Bool.self, forKey: .showToolbar) ?? false
        } else {
            showToolbar = ArcImporter.showsToolbar ?? false
        }
        hasSeenImportPrompt = try c.decodeIfPresent(Bool.self, forKey: .hasSeenImportPrompt) ?? false
        developerHosts = try c.decodeIfPresent(Set<String>.self, forKey: .developerHosts) ?? []
        chromeEngine = try c.decodeIfPresent(Bool.self, forKey: .chromeEngine) ?? true
        autoPictureInPicture = try c.decodeIfPresent(Bool.self, forKey: .autoPictureInPicture) ?? true
        blockAdsAndTrackers = try c.decodeIfPresent(Bool.self, forKey: .blockAdsAndTrackers) ?? true
        openExternalLinksInLittleWindow = try c.decodeIfPresent(Bool.self, forKey: .openExternalLinksInLittleWindow) ?? true
        hapticFeedbackOnReorder = try c.decodeIfPresent(Bool.self, forKey: .hapticFeedbackOnReorder) ?? true
        warnBeforeQuitting = try c.decodeIfPresent(Bool.self, forKey: .warnBeforeQuitting) ?? false
        autoArchiveEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoArchiveEnabled) ?? true
    }
}

extension WindowPrefs {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sidebarWidth = try c.decodeIfPresent(Double.self, forKey: .sidebarWidth) ?? 328
        sidebarVisible = try c.decodeIfPresent(Bool.self, forKey: .sidebarVisible) ?? true
        focusedSpaceID = try c.decodeIfPresent(UUID.self, forKey: .focusedSpaceID)
        expandedFolders = try c.decodeIfPresent(Set<UUID>.self, forKey: .expandedFolders) ?? []
        collapsedPinnedSpaces = try c.decodeIfPresent(Set<UUID>.self, forKey: .collapsedPinnedSpaces) ?? []
        selectedTabPerSpace = try c.decodeIfPresent([UUID: UUID].self, forKey: .selectedTabPerSpace) ?? [:]
        windowFrame = try c.decodeIfPresent(String.self, forKey: .windowFrame)
        littleWindowSize = try c.decodeIfPresent(String.self, forKey: .littleWindowSize)
    }
}

extension Space {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        emoji = try c.decode(String.self, forKey: .emoji)
        theme = try c.decode(SpaceTheme.self, forKey: .theme)
        // Spaces saved while favorites were shared get a container on load (SidebarStore.repair).
        favoritesContainerID = try c.decodeIfPresent(UUID.self, forKey: .favoritesContainerID) ?? UUID()
        pinnedContainerID = try c.decode(UUID.self, forKey: .pinnedContainerID)
        todayContainerID = try c.decode(UUID.self, forKey: .todayContainerID)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
    }
}

extension TabData {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        savedURL = try c.decodeIfPresent(String.self, forKey: .savedURL) ?? url
        savedTitle = try c.decodeIfPresent(String.self, forKey: .savedTitle) ?? ""
        muted = try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false
        timeLastActiveAt = try c.decodeIfPresent(Date.self, forKey: .timeLastActiveAt)
        activeTabBeforeCreationID = try c.decodeIfPresent(UUID.self, forKey: .activeTabBeforeCreationID)
        faviconKey = try c.decodeIfPresent(String.self, forKey: .faviconKey) ?? URL(string: url)?.host
    }
}
