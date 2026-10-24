import SwiftUI

/// Arc's toolbar above the page: lock + URL (monospaced), copy link, DevTools,
/// sidebar toggle. With no tab it carries the nav buttons and a centered
/// "Search or Enter URL…" placeholder instead.
struct ContentToolbarView: View {
    let palette: SpacePalette
    @Environment(SidebarStore.self) private var store
    @Environment(SidebarUIState.self) private var ui
    @Environment(\.sidebarActions) private var actions
    @State private var hoverURL = false

    private var onCard: Bool { store.selectedTab != nil }
    @Environment(FaviconCache.self) private var favicons

    /// Arc's toolbar colour: the page's theme-color when it declares one
    /// (Messenger's white included), else a dark favicon colour, else the
    /// space tint.
    private var cardHex: String? {
        let theme = ui.pageThemeColor
        if theme != "none", !theme.isEmpty, HexColor.components(theme) != nil { return theme }
        return nil
    }
    private var cardFill: Color { cardHex.map { Color(hex: $0) } ?? palette.toolbarFill }
    private var cardIsLight: Bool { (cardHex.flatMap(HexColor.luminance) ?? 0) > 0.6 }
    private var fg: Color { onCard ? (cardIsLight ? Color.black.opacity(0.8) : Color(hex: "#E4E0D4")) : palette.textSecondary }
    private var fgDim: Color { onCard ? (cardIsLight ? Color.black.opacity(0.6) : Color(hex: "#F0E6CC").opacity(0.9)) : palette.textTertiary }

    private var developerMode: Bool { store.selectedTab?.tab.map { store.settings.isDeveloperMode(url: $0.url) } ?? false }

    /// Arc's default bar: nav buttons at the left, the friendly URL centred
    /// (host bright, path dimmer) behind a link glyph.
    @ViewBuilder private func defaultBar(_ t: TabData) -> some View {
        let human = SuggestionEngine.humanURL(t.url)
        let host = AppSettings.siteKey(for: t.url) ?? human
        let path = human.hasPrefix(host) ? String(human.dropFirst(host.count)) : ""
        HStack(spacing: 0) {
            ToolbarIcon(symbol: "arrow.left", fg: fgDim, help: "Go Back (⌘[)", enabled: ui.canGoBack, width: 37, iconSize: 15) { actions.goBack() }
            ToolbarIcon(symbol: "arrow.right", fg: fgDim, help: "Go Forward (⌘])", enabled: ui.canGoForward, width: 37, iconSize: 15) { actions.goForward() }
            ToolbarIcon(symbol: ui.isLoading ? "xmark" : "arrow.clockwise", fg: fgDim, help: "Refresh (⌘R)", width: 37, iconSize: 15) { actions.reload() }
        }
        .padding(.leading, 1)
        Spacer(minLength: 8)
        Button { actions.openCommandBar(.editURL) } label: {
            HStack(spacing: 7) {
                Image(systemName: "link").font(.system(size: 12, weight: .medium)).foregroundStyle(fgDim)
                (Text(host).foregroundStyle(fg) + Text(path).foregroundStyle(fgDim))
                    .font(.system(size: 13))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(hoverURL ? Color.white.opacity(0.08) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hoverURL = $0 }
        .help(t.url)
        Spacer(minLength: 8)
    }

    var body: some View {
        let tab = store.selectedTab
        HStack(spacing: 6) {
            if let tab, let t = tab.tab, !developerMode {
                defaultBar(t)
            } else if let tab, let t = tab.tab {
                Button { actions.openCommandBar(.editURL) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: t.url.hasPrefix("https://") ? "lock.fill" : "globe")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(fgDim)
                            .frame(width: 14)
                        Text(t.url)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(fg)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
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
                    ToolbarIcon(symbol: "arrow.left", fg: fgDim, enabled: false, width: 37, iconSize: 15) {}
                    ToolbarIcon(symbol: "arrow.right", fg: fgDim, enabled: false, width: 37, iconSize: 15) {}
                    ToolbarIcon(symbol: "arrow.clockwise", fg: fgDim, enabled: false, width: 37, iconSize: 15) {}
                }
                .padding(.leading, 1)
                Spacer()
                Button { actions.openCommandBar(.newTab) } label: {
                    Text("Search or Enter URL…")
                        .font(.system(size: 13))
                        .foregroundStyle(palette.textTertiary)
                }
                .buttonStyle(.plain)
                Spacer()
            }
            if tab != nil && developerMode {
                Spacer(minLength: 8)
                ToolbarIcon(symbol: "link", fg: fgDim, help: "Copy URL (⇧⌘C)") { actions.performAction("copyURL") }
                toolbarDivider
                ToolbarIcon(symbol: "camera", fg: fgDim, help: "Capture page") { actions.performAction("capturePage") }
                toolbarDivider
                ToolbarIcon(symbol: "terminal", fg: fgDim, help: "Developer Tools (⌥⌘I)") { actions.performAction("devTools") }
                ToolbarIcon(symbol: "globe", fg: fgDim, help: "View Source (⌥⌘U)") { actions.performAction("viewSource") }
                toolbarDivider
            }
            ToolbarIcon(symbol: "sidebar.right", fg: fgDim, help: "Toggle Sidebar (⌘S)") { actions.toggleSidebar() }
                .padding(.trailing, 6)
        }
        .frame(height: CraMetrics.toolbarHeight)
        .background(onCard ? cardFill : (palette.isDark ? Color.white.opacity(0.025) : Color.black.opacity(0.03)))
        .overlay(alignment: .bottom) {
            if !onCard { Rectangle().fill(palette.isDark ? Color.white.opacity(0.07) : Color.black.opacity(0.07)).frame(height: 1) }
        }
        .ignoresSafeArea()
    }
}

private extension ContentToolbarView {
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
        .help(help)
    }
}
