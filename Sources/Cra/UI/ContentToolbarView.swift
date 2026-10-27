import SwiftUI

/// Arc's toolbar above the page: lock + URL (monospaced), copy link, DevTools,
/// sidebar toggle. With no tab it carries the nav buttons and a centered
/// "Search or Enter URL…" placeholder instead.
struct ContentToolbarView: View {
    let palette: SpacePalette
    /// Split view: this toolbar belongs to one pane (nil = the window's single toolbar).
    var paneTabID: UUID? = nil
    @Environment(SidebarStore.self) private var store
    @Environment(SidebarUIState.self) private var ui
    @Environment(\.sidebarActions) private var actions
    @State private var hoverURL = false

    private var tab: SidebarItem? {
        if let id = paneTabID { return store.item(id) }
        return store.selectedTab(window: ui.windowID)
    }
    private var onCard: Bool { tab != nil && !isEmptyPane }
    /// Arc's empty pane ("Search or Enter URL…" on the tinted card).
    private var isEmptyPane: Bool { tab?.isEmptyTab ?? false }
    private var inSplit: Bool { paneTabID != nil && ui.splitPaneIDs.count > 1 }
    private var isFocusedPane: Bool { paneTabID == nil || store.selectedTabID(window: ui.windowID) == paneTabID }
    private var nav: TabNavState {
        if let id = paneTabID { return ui.navState(for: id) }
        return TabNavState(canGoBack: ui.canGoBack, canGoForward: ui.canGoForward, isLoading: ui.isLoading, themeColor: ui.pageThemeColor)
    }
    private func navigate(_ what: String) {
        if let id = paneTabID { actions.paneNavigate(id, what); return }
        switch what {
        case "goBack": actions.goBack()
        case "goForward": actions.goForward()
        default: actions.reload()
        }
    }
    private func editURL() {
        if let id = paneTabID { actions.editPaneURL(id) } else { actions.openCommandBar(tab == nil ? .newTab : .editURL) }
    }
    @Environment(FaviconCache.self) private var favicons

    /// Arc's toolbar colour: the page's theme-color when it declares one
    /// (Messenger's white included), else a dark favicon colour, else the
    /// space tint.
    private var cardHex: String? {
        let theme = nav.themeColor
        if theme != "none", !theme.isEmpty, HexColor.components(theme) != nil { return theme }
        return nil
    }
    // Arc: the bar is white until the page reports a colour, then takes that colour.
    private var cardFill: Color { cardHex.map { Color(hex: $0) } ?? .white }
    private var cardIsLight: Bool { (cardHex.flatMap(HexColor.luminance) ?? 1) > 0.6 }
    private var fg: Color { onCard ? (cardIsLight ? Color.black.opacity(0.8) : Color(hex: "#E4E0D4")) : palette.textSecondary }
    private var fgDim: Color { onCard ? (cardIsLight ? Color.black.opacity(0.6) : Color(hex: "#F0E6CC").opacity(0.9)) : palette.textTertiary }

    /// Dia's nav-bar status ("Copied Current URL") replaces the URL in the focused pane's bar.
    private var status: ToolbarStatus? { isFocusedPane ? ui.toolbarStatus : nil }

    private var developerMode: Bool { !inSplit && (tab?.tab.map { store.settings.isDeveloperMode(url: $0.url) } ?? false) }

    /// Arc's default bar: nav buttons at the left, the friendly URL centred
    /// (host bright, path dimmer) behind a link glyph. Split panes drop the
    /// refresh button (measured on Arc 1.170: only ← → in a pane).
    @ViewBuilder private func defaultBar(_ t: TabData) -> some View {
        let human = SuggestionEngine.humanURL(t.url)
        let host = AppSettings.siteKey(for: t.url) ?? human
        let path = human.hasPrefix(host) ? String(human.dropFirst(host.count)) : ""
        HStack(spacing: 0) {
            // Toggle first, centred 30 pt from the card edge (Arc, sidebar hidden), then ← → ↻ at 37 pt pitch.
            if !inSplit { sidebarToggle }
            ToolbarIcon(symbol: "arrow.left", fg: fgDim, help: "Go Back (⌘[)", enabled: nav.canGoBack, width: 37, iconSize: 15) { navigate("goBack") }
            ToolbarIcon(symbol: "arrow.right", fg: fgDim, help: "Go Forward (⌘])", enabled: nav.canGoForward, width: 37, iconSize: 15) { navigate("goForward") }
            if !inSplit {
                ToolbarIcon(symbol: nav.isLoading ? "xmark" : "arrow.clockwise", fg: fgDim, help: "Refresh (⌘R)", width: 37, iconSize: 15) { navigate("reload") }
            }
        }
        .padding(.leading, inSplit ? 2.5 : 11.5)
        Spacer(minLength: 8)
        Button { editURL() } label: {
            HStack(spacing: 7) {
                if let status {
                    Image(systemName: status.symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(fgDim)
                    Text(status.text).font(.system(size: 13)).foregroundStyle(fgDim).lineLimit(1)
                } else {
                    Image(systemName: "link").font(.system(size: 12, weight: .medium)).foregroundStyle(fgDim)
                    (Text(host).foregroundStyle(fg) + Text(path).foregroundStyle(fgDim))
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .id(status?.id)
            .transition(.opacity)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(hoverURL ? Color.white.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoverURL = $0 }
        .arcTooltip(t.url, followsCursor: true)
        Spacer(minLength: 8)
    }

    /// Arc's empty split pane: disabled ← →, the placeholder centred, nothing else.
    @ViewBuilder private var emptyPaneBar: some View {
        HStack(spacing: 0) {
            ToolbarIcon(symbol: "arrow.left", fg: fgDim, enabled: false, width: 37, iconSize: 15) {}
            ToolbarIcon(symbol: "arrow.right", fg: fgDim, enabled: false, width: 37, iconSize: 15) {}
        }
        .padding(.leading, 1)
        Spacer(minLength: 8)
        Button { editURL() } label: {
            Text("Search or Enter URL…")
                .font(.system(size: 13))
                .foregroundStyle(palette.textTertiary)
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        Spacer(minLength: 8)
    }

    var body: some View {
        let tab = self.tab
        HStack(spacing: 6) {
            if tab != nil, isEmptyPane {
                emptyPaneBar
            } else if let tab, let t = tab.tab, !developerMode {
                defaultBar(t)
            } else if let tab, let t = tab.tab {
                if !inSplit { sidebarToggle.padding(.leading, 11.5) }
                Button { editURL() } label: {
                    HStack(spacing: 12) {
                        Image(systemName: status?.symbol ?? (t.url.hasPrefix("https://") ? "lock.fill" : "globe"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(fgDim)
                            .frame(width: 14)
                        Text(status?.text ?? t.url)
                            .font(status == nil ? .system(size: 12, design: .monospaced) : .system(size: 13))
                            .foregroundStyle(status == nil ? fg : fgDim)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .id(status?.id)
                    .transition(.opacity)
                    .padding(.horizontal, 6)
                    .frame(height: 28)
                    .background(RoundedRectangle(cornerRadius: 6).fill(hoverURL ? Color.white.opacity(0.08) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hoverURL = $0 }
                .padding(.leading, 8)
            } else {
                HStack(spacing: 0) {
                    sidebarToggle
                    ToolbarIcon(symbol: "arrow.left", fg: fgDim, enabled: false, width: 37, iconSize: 15) {}
                    ToolbarIcon(symbol: "arrow.right", fg: fgDim, enabled: false, width: 37, iconSize: 15) {}
                    ToolbarIcon(symbol: "arrow.clockwise", fg: fgDim, enabled: false, width: 37, iconSize: 15) {}
                }
                .padding(.leading, 11.5)
                Spacer()
                Button { editURL() } label: {
                    Text("Search or Enter URL…")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.textTertiary)
                }
                .buttonStyle(.plain)
                Spacer()
            }
            if tab != nil && developerMode && !inSplit {
                Spacer(minLength: 8)
                ToolbarIcon(symbol: "link", fg: fgDim, help: "Copy URL (⇧⌘C)") { actions.performAction("copyURL") }
                toolbarDivider
                ToolbarIcon(symbol: "terminal", fg: fgDim, help: "Developer Tools (⌥⌘I)") { actions.performAction("devTools") }
            }
            // Also on the no-tab bar (Arc keeps them there).
            if !inSplit, !isEmptyPane { trailingButtons }
            if inSplit, let id = paneTabID {
                // Observed on Arc 1.170: the focused pane shows the split options
                // button before its close button; other panes only the close button.
                if isFocusedPane, !isEmptyPane {
                    Menu {
                        Button("Separate Tab from Split") { actions.separatePane(id) }
                        Button("Flip Split View Orientation") { actions.performAction("flipSplitOrientation") }
                        Divider()
                        Button("Copy Link") { actions.performAction("copyURL") }
                        Divider()
                        Button("Close this Split Pane") { actions.closePane(id) }
                    } label: {
                        Image(systemName: "rectangle.split.2x1")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(fgDim)
                            .frame(width: 26, height: 26)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                    .frame(width: 26)
                    .arcTooltip("Split View Options")
                }
                ToolbarIcon(symbol: "xmark", fg: isEmptyPane ? palette.textSecondary : fgDim, help: "Close this Split Pane (⌃⇧-)", width: 30, iconSize: 14) { actions.closePane(id) }
                    .padding(.trailing, 4)
            }
        }
        .frame(height: CraMetrics.toolbarHeight)
        .contentShape(Rectangle())
        // A click anywhere on the bar edits the URL (a pane's click also focuses it). No
        // double-click-to-zoom here: a count-2 gesture makes SwiftUI hold every single
        // click, the URL button's included, until the double-click interval has passed.
        .onTapGesture { editURL() }
        .background(onCard ? cardFill : (isEmptyPane ? Color.clear : (palette.isDark ? Color.white.opacity(0.025) : Color.black.opacity(0.03))))
        .overlay(alignment: .bottom) {
            // No hairline under the bar on the card: the bar and the page read as one surface (Arc draws one).
            if !onCard, !isEmptyPane { Rectangle().fill(palette.isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.07)).frame(height: 1) }
        }
        .ignoresSafeArea()
    }
}

private extension ContentToolbarView {
    /// Arc's right end of the bar: pinned extensions, the Extensions button (menu with
    /// every extension and pinning), then Split View.
    var trailingButtons: some View {
        let extensions = ExtensionStore.shared
        return HStack(spacing: 0) {
            ForEach(extensions.pinnedIDs, id: \.self) { id in
                if let e = extensions.entries.first(where: { $0.extensionID == id }) {
                    ToolbarImageButton(image: e.icon, help: e.name) { actions.runExtension(id) }
                }
            }
            if !extensions.entries.isEmpty {
                ToolbarIcon(symbol: "slider.horizontal.2.square", fg: fgDim, help: "Extensions", width: 34, iconSize: 16) {
                    actions.showExtensionsMenu()
                }
            }
            ToolbarIcon(symbol: "square.split.2x1", fg: fgDim, help: "Add Split View (⌃⇧=)", width: 34, iconSize: 16) {
                actions.performAction("addSplitView")
            }
        }
        .padding(.trailing, 6)
    }

    var sidebarToggle: some View {
        ToolbarIcon(symbol: "sidebar.left", fg: fgDim, help: store.window(ui.windowID).sidebarVisible ? "Hide Sidebar (⌘S)" : "Show Sidebar (⌘S)",
                    width: 37, iconSize: 15.5) { actions.toggleSidebar() }
    }

    var toolbarDivider: some View {
        Rectangle().fill(cardIsLight ? Color.black.opacity(0.15) : Color.white.opacity(0.22)).frame(width: 1, height: 14).padding(.horizontal, 5)
    }
}

struct ToolbarIcon: View {
    let symbol: String
    let fg: Color
    var help: String = ""
    var enabled: Bool = true
    var width: CGFloat = 26
    var iconSize: CGFloat = 13
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: iconSize, weight: .regular))
                .foregroundStyle(enabled ? fg : fg.opacity(0.4))
                .frame(width: width, height: 26)
                .background(RoundedRectangle(cornerRadius: 7).fill(hover && enabled ? Color.white.opacity(0.1) : .clear))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hover = $0 }
        .arcTooltip(help)
    }
}

/// A pinned extension in the toolbar: its manifest icon at 18 pt (Arc), puzzle piece without one.
struct ToolbarImageButton: View {
    let image: NSImage?
    var help: String = ""
    let action: () -> Void
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                } else {
                    Image(systemName: "puzzlepiece.extension").resizable().aspectRatio(contentMode: .fit)
                }
            }
            .frame(width: 18, height: 18)
            .frame(width: 34, height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(hover ? Color.white.opacity(0.1) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .arcTooltip(help)
    }
}
