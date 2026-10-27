import AppKit
import SwiftUI

/// Arc 1.170's Site Control Center: the sliders button at the end of the toolbar and of the
/// sidebar's URL pill (SiteControlCenterView in ARC_SiteControlCenter). Geometry and colours
/// were read from Arc's accessibility tree and captures of the open popover (26 Oct 2026):
/// a 236 pt column, a row of four 48×32 action buttons, "Extensions" with a 4-column grid of
/// 48×32 tiles (pinned first, then by name, then "+"), "Settings" rows of 208×33 and a footer
/// with the connection state and a More menu. A tile's 14 pt badge pins it to the toolbar:
/// filled for pinned extensions, grey on hover for the others.
struct SiteControlCenterActions {
    var share: () -> Void = {}
    var copyURL: () -> Void = {}
    var capture: () -> Void = {}
    var captureFullPage: () -> Void = {}
    var runExtension: (String) -> Void = { _ in }
    var addExtension: () -> Void = {}
    var manageExtensions: () -> Void = {}
    var clearCache: () -> Void = {}
    var clearCookies: () -> Void = {}
    var siteSettings: () -> Void = {}
}

enum SiteControlCenterMetrics {
    static let width: CGFloat = 236
    static let inset: CGFloat = 10
    static let tile = CGSize(width: 48, height: 32)
    static let gap: CGFloat = 8
}

struct SiteControlCenterView: View {
    let url: String
    let dark: Bool
    let actions: SiteControlCenterActions
    @Environment(SidebarStore.self) private var store
    private var extensions: ExtensionStore { .shared }

    private var colors: SiteControlCenterColors { SiteControlCenterColors(dark: dark) }

    /// Arc: pinned extensions in toolbar order, then the rest by name.
    private var orderedExtensions: [ExtensionStore.Entry] {
        let entries = extensions.entries
        let pinned = extensions.pinnedIDs.compactMap { id in entries.first { $0.extensionID == id } }
        let rest = entries.filter { !extensions.isPinned($0.extensionID) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return pinned + rest
    }

    private var isSecure: Bool { url.hasPrefix("https://") || url.hasPrefix("chrome://") || url.hasPrefix("chrome-extension://") }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            actionRow
                .padding(.bottom, 11)
            SiteControlCenterSection(title: "Extensions", hoverText: "Manage", colors: colors, onHeaderClick: actions.manageExtensions) {
                extensionGrid
            }
            .padding(.bottom, 15)
            SiteControlCenterSection(title: "Settings", hoverText: nil, colors: colors, onHeaderClick: {}) {
                settings
            }
            Rectangle().fill(colors.divider).frame(height: 1)
                .padding(.top, 13).padding(.bottom, 12)
            footer
        }
        .padding(.top, 9)
        .padding([.horizontal, .bottom], SiteControlCenterMetrics.inset)
        .frame(width: SiteControlCenterMetrics.width)
    }

    private var actionRow: some View {
        HStack(spacing: SiteControlCenterMetrics.gap) {
            SiteControlCenterActionButton(symbol: "square.and.arrow.up", help: "Share", colors: colors, action: actions.share)
            SiteControlCenterActionButton(symbol: "link", help: "Copy URL", colors: colors, action: actions.copyURL)
            SiteControlCenterActionButton(symbol: "camera", help: "Capture this page", colors: colors, action: actions.capture)
            SiteControlCenterActionButton(symbol: "text.viewfinder", help: "Capture the full page", colors: colors, action: actions.captureFullPage)
        }
    }

    private var extensionGrid: some View {
        let columns = Array(repeating: GridItem(.fixed(SiteControlCenterMetrics.tile.width), spacing: SiteControlCenterMetrics.gap), count: 4)
        return LazyVGrid(columns: columns, alignment: .leading, spacing: SiteControlCenterMetrics.gap) {
            ForEach(orderedExtensions) { e in
                SiteControlCenterExtensionButton(entry: e, pinned: extensions.isPinned(e.extensionID), colors: colors,
                                                 run: { actions.runExtension(e.extensionID) },
                                                 togglePin: { extensions.setPinned(e.extensionID, !extensions.isPinned(e.extensionID)) })
            }
            SiteControlCenterTile(colors: colors, help: "Add Extension", action: actions.addExtension) {
                Image(systemName: "plus").font(.system(size: 14, weight: .medium)).foregroundStyle(colors.text)
            }
        }
    }

    private var settings: some View {
        let developer = store.settings.isDeveloperMode(url: url)
        return VStack(alignment: .leading, spacing: 10) {
            SiteControlCenterSettingRow(symbol: "hammer.fill", title: "Developer Mode", subtitle: developer ? "On" : "Off",
                                        active: developer, colors: colors) { store.settings.toggleDeveloperMode(url: url) }
            SiteControlCenterSettingRow(symbol: "shield.fill", title: "Block Ads & Trackers",
                                        subtitle: store.settings.blockAdsAndTrackers ? "On" : "Off",
                                        active: store.settings.blockAdsAndTrackers, colors: colors) { store.settings.blockAdsAndTrackers.toggle() }
            SiteControlCenterSettingRow(symbol: "gearshape.fill", title: "Automatic Picture-In-Picture",
                                        subtitle: store.settings.autoPictureInPicture ? "Allowed" : "Disabled",
                                        active: store.settings.autoPictureInPicture, colors: colors) { store.settings.autoPictureInPicture.toggle() }
        }
    }

    private var footer: some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: isSecure ? "lock.fill" : "lock.open.fill").font(.system(size: 12, weight: .semibold))
                Text(isSecure ? "Secure" : "Not Secure").font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(colors.text)
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(colors.footerFill))
            .arcTooltip(isSecure ? "Your connection to this site is secure" : "Your connection to this site is not secure")
            Spacer(minLength: 0)
            SiteControlCenterMoreButton(colors: colors, actions: actions)
        }
    }
}

/// Arc's site control center palette (dark values sampled from Arc 1.170; light ones mirror them).
struct SiteControlCenterColors {
    let dark: Bool
    var background: Color { dark ? Color(hex: "#272728") : Color(hex: "#F4F4F5") }
    var tile: Color { dark ? .white.opacity(0.07) : .black.opacity(0.05) }
    var tileHover: Color { dark ? .white.opacity(0.09) : .black.opacity(0.08) }
    var text: Color { dark ? Color(hex: "#DCDCDC") : Color(hex: "#232325") }
    var header: Color { dark ? Color(hex: "#D4D4D5") : Color(hex: "#2A2A2C") }
    var secondary: Color { dark ? Color(hex: "#979798") : Color(hex: "#6E6E73") }
    var divider: Color { dark ? .white.opacity(0.1) : .black.opacity(0.1) }
    var footerFill: Color { dark ? Color(hex: "#363536") : .black.opacity(0.05) }
    var moreFill: Color { dark ? Color(hex: "#403F40") : .black.opacity(0.08) }
    /// Pinned badge and active setting circles.
    /// Light themes invert Arc's dark-theme pair: a near-white badge vanishes on light tiles.
    var accent: Color { dark ? Color(hex: "#F0F1FE") : Color(hex: "#232325") }
    var inactive: Color { dark ? Color(hex: "#6A6A6F") : Color(hex: "#C7C7CC") }
    var pinHover: Color { dark ? Color(hex: "#7F7E85") : Color(hex: "#8E8E93") }
    var glyphOnAccent: Color { dark ? Color(hex: "#232325") : .white }
    var glyphOnInactive: Color { dark ? Color(hex: "#232325") : Color(hex: "#3A3A3C") }
    /// The pin glyph: cut out of the badge in the panel colour (dark), white on light themes.
    var pinGlyph: Color { dark ? background : .white }
    func actionFill(hovered: Bool) -> [Color] {
        dark ? [Color(hex: hovered ? "#3C3C3C" : "#363636"), Color(hex: hovered ? "#272727" : "#212121")]
             : [Color(hex: hovered ? "#FFFFFF" : "#FDFDFD"), Color(hex: hovered ? "#F2F2F2" : "#EDEDED")]
    }
    var actionHighlight: Color { dark ? Color(hex: "#69696A") : .white }
    var actionOutline: Color { dark ? Color(hex: "#141115") : .black.opacity(0.14) }
}

/// A titled section; hovering it shows `hoverText` at the header's right end (Arc: "Manage").
private struct SiteControlCenterSection<Content: View>: View {
    let title: String
    let hoverText: String?
    let colors: SiteControlCenterColors
    let onHeaderClick: () -> Void
    @ViewBuilder let content: Content
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 0) {
                Text(title).font(.system(size: 14, weight: .bold)).foregroundStyle(colors.header)
                Spacer(minLength: 0)
                if let hoverText, hovered {
                    Button(action: onHeaderClick) {
                        Text(hoverText).font(.system(size: 12, weight: .semibold)).foregroundStyle(colors.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(height: 17)
            content
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
    }
}

private struct SiteControlCenterTile<Label: View>: View {
    let colors: SiteControlCenterColors
    var help: String = ""
    let action: () -> Void
    @ViewBuilder let label: Label
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            label
                .frame(width: SiteControlCenterMetrics.tile.width, height: SiteControlCenterMetrics.tile.height)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovered ? colors.tileHover : colors.tile))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .arcTooltip(help)
    }
}

private struct SiteControlCenterActionButton: View {
    let symbol: String
    let help: String
    let colors: SiteControlCenterColors
    let action: () -> Void

    @State private var hovered = false

    /// Arc draws these raised: a top-lit gradient, a light top edge and a dark outline.
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 7, style: .continuous)
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 15, weight: .regular)).foregroundStyle(colors.text)
                .frame(width: SiteControlCenterMetrics.tile.width, height: SiteControlCenterMetrics.tile.height)
                .background(shape.fill(LinearGradient(colors: colors.actionFill(hovered: hovered), startPoint: .top, endPoint: .bottom)))
                .overlay(shape.inset(by: 0.5).stroke(LinearGradient(colors: [colors.actionHighlight, .clear], startPoint: .top, endPoint: .center), lineWidth: 1))
                .overlay(shape.stroke(colors.actionOutline, lineWidth: 0.5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .arcTooltip(help)
    }
}

/// An extension tile: click runs it, the badge pins or unpins it (Arc's
/// SiteControlCenterExtensionPinButton, "Pin" / "Unpin").
private struct SiteControlCenterExtensionButton: View {
    let entry: ExtensionStore.Entry
    let pinned: Bool
    let colors: SiteControlCenterColors
    let run: () -> Void
    let togglePin: () -> Void
    @State private var hovered = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Button(action: run) {
                Group {
                    if let icon = entry.icon {
                        Image(nsImage: icon).resizable().interpolation(.high).frame(width: 16, height: 16)
                    } else {
                        Image(systemName: "puzzlepiece.extension.fill").font(.system(size: 13)).foregroundStyle(colors.secondary)
                    }
                }
                .frame(width: SiteControlCenterMetrics.tile.width, height: SiteControlCenterMetrics.tile.height)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovered ? colors.tileHover : colors.tile))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .arcTooltip(entry.name)
            .accessibilityLabel(entry.name)
            if pinned || hovered {
                Button(action: togglePin) {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8, weight: .bold))
                        .rotationEffect(.degrees(45))
                        .foregroundStyle(colors.pinGlyph)
                        .frame(width: 14, height: 14)
                        .background(Circle().fill(pinned ? colors.accent : colors.pinHover))
                        .overlay(Circle().strokeBorder(colors.background, lineWidth: 1))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .arcTooltip(pinned ? "Unpin" : "Pin")
                .accessibilityLabel(pinned ? "Unpin" : "Pin")
                .offset(x: 37, y: 21)
            }
        }
        .frame(width: SiteControlCenterMetrics.tile.width, height: SiteControlCenterMetrics.tile.height, alignment: .topLeading)
        .onHover { hovered = $0 }
    }
}

private struct SiteControlCenterSettingRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    let active: Bool
    let colors: SiteControlCenterColors
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(active ? colors.glyphOnAccent : colors.glyphOnInactive)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(active ? colors.accent : colors.inactive))
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(colors.text)
                        .lineLimit(1).truncationMode(.tail)
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(colors.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(width: 208, height: 33, alignment: .leading)
            .contentShape(Rectangle())
            .opacity(hovered ? 0.85 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityLabel("\(title), \(subtitle)")
    }
}

/// Arc's footer "…": Clear Cache, Clear Cookies, Manage Extensions, Add Extension, All Site Settings.
private struct SiteControlCenterMoreButton: View {
    let colors: SiteControlCenterColors
    let actions: SiteControlCenterActions
    @State private var hovered = false

    var body: some View {
        Button(action: showMenu) {
            Image(systemName: "ellipsis").font(.system(size: 13, weight: .bold)).foregroundStyle(colors.text)
                .frame(width: 32, height: 32)
                .background(Circle().fill(colors.moreFill).brightness(hovered ? 0.04 : 0))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .arcTooltip("More")
        .accessibilityLabel("More")
    }

    private func showMenu() {
        let menu = NSMenu()
        func add(_ title: String, _ action: @escaping () -> Void) { menu.addItem(BlockMenuItem(title: title, action: action)) }
        add("Clear Cache", actions.clearCache)
        add("Clear Cookies", actions.clearCookies)
        menu.addItem(.separator())
        add("Manage Extensions", actions.manageExtensions)
        add("Add Extension", actions.addExtension)
        menu.addItem(.separator())
        add("All Site Settings", actions.siteSettings)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}

final class BlockMenuItem: NSMenuItem {
    private let block: () -> Void
    init(title: String, action: @escaping () -> Void) {
        block = action
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { block() }
}

/// Shows the Site Control Center in an NSPopover under a toolbar or pill button.
@MainActor
final class SiteControlCenterPopover: NSObject, NSPopoverDelegate {
    private var popover: NSPopover?

    var isShown: Bool { popover?.isShown == true }

    func show(relativeTo rect: NSRect, of view: NSView, url: String, dark: Bool, store: SidebarStore, actions: SiteControlCenterActions) {
        if let popover, popover.isShown { popover.performClose(nil); return }
        let p = NSPopover()
        p.behavior = .transient
        p.animates = true
        p.delegate = self
        p.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        var acts = actions
        // Every action ends the popover, as in Arc (pinning keeps it open).
        func closing(_ f: @escaping () -> Void) -> () -> Void { { [weak p] in p?.performClose(nil); f() } }
        acts.share = closing(actions.share)
        acts.copyURL = closing(actions.copyURL)
        acts.capture = closing(actions.capture)
        acts.captureFullPage = closing(actions.captureFullPage)
        acts.runExtension = { [weak p] id in p?.performClose(nil); actions.runExtension(id) }
        acts.addExtension = closing(actions.addExtension)
        acts.manageExtensions = closing(actions.manageExtensions)
        acts.siteSettings = closing(actions.siteSettings)
        acts.clearCache = closing(actions.clearCache)
        acts.clearCookies = closing(actions.clearCookies)
        let root = SiteControlCenterView(url: url, dark: dark, actions: acts)
            .environment(store)
            .background(SiteControlCenterColors(dark: dark).background)
        let host = NSHostingController(rootView: AnyView(root))
        host.sizingOptions = [.preferredContentSize]
        p.contentViewController = host
        popover = p
        p.show(relativeTo: rect, of: view, preferredEdge: .minY)
    }

    func close() { popover?.performClose(nil) }

    func popoverDidClose(_ notification: Notification) { popover = nil }
}
