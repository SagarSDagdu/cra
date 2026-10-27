import SwiftUI

/// Bottom row like Arc's: library/archive at the left, tiny space icons in
/// the middle (inactive ones dimmed), "+" at the right.
struct SpaceDock: View {
    let palette: SpacePalette
    @Environment(SidebarStore.self) private var store
    @Environment(SidebarUIState.self) private var ui
    @Environment(\.sidebarActions) private var actions

    var body: some View {
        HStack(spacing: 0) {
            LibraryButton(palette: palette) { actions.showArchive() }
            Spacer(minLength: 0)
            // An incognito window has one space of its own: nothing to switch to or add.
            if !store.window(ui.windowID).isIncognito {
                HStack(spacing: 6) {
                    ForEach(store.orderedSpaces) { space in
                        SpaceDockButton(space: space, palette: palette, selected: space.id == store.focusedSpaceID(window: ui.windowID))
                    }
                }
                Spacer(minLength: 0)
                SidebarIconButton(symbol: "plus", palette: palette, help: "New Space") { actions.editSpace(nil) }
            }
        }
        .frame(height: 36)
    }
}

struct SpaceDockButton: View {
    let space: Space
    let palette: SpacePalette
    let selected: Bool
    @Environment(SidebarStore.self) private var store
    @Environment(SidebarUIState.self) private var ui
    @Environment(\.sidebarActions) private var actions
    @State private var hover = false
    @State private var targeted = false

    var body: some View {
        Text(space.emoji)
            .font(.system(size: 13))
            .frame(width: 26, height: 26)
            .opacity(selected || hover ? 1 : 0.45)
            .saturation(selected || hover ? 1 : 0.2)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(targeted ? palette.hoverFill : .clear))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture { store.focusSpace(space.id, window: ui.windowID) }
            .arcTooltip(space.title)
            .dropDestination(for: SidebarDragItem.self) { items, _ in
                guard let d = items.first else { return false }
                store.moveTab(d.id, toSpace: space.id)
                return true
            } isTargeted: { t in
                targeted = t
                // Arc: holding a dragged item over a space switches to it, so the
                // item can be carried into that space's list and dropped in place.
                guard t, !selected else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if targeted { store.focusSpace(space.id, window: ui.windowID) }
                }
            }
            .contextMenu {
                Button("Edit Space…") { actions.editSpace(space) }
                Divider()
                Button("Move Left") { if let i = store.spaceOrder.firstIndex(of: space.id) { store.moveSpace(space.id, to: max(0, i - 1)) } }
                Button("Move Right") { if let i = store.spaceOrder.firstIndex(of: space.id) { store.moveSpace(space.id, to: i + 1) } }
                Divider()
                Button("Delete Space…") { store.focusSpace(space.id, window: ui.windowID); actions.performAction("deleteSpace") }
            }
    }
}


/// Arc's Library glyph: a filled box with a small confetti puff (cloud, dot,
/// triangle) rising from it. Same hit area and hover fill as `SidebarIconButton`.
struct LibraryButton: View {
    let palette: SpacePalette
    let action: () -> Void
    @Environment(SidebarUIState.self) private var ui
    @State private var hover = false

    /// Where Arc's download bin rests relative to the Library glyph's centre: up and to
    /// the right, the glyph's box peeking out under its lower-left corner.
    static let binOffset = CGSize(width: 9, height: -12)

    var body: some View {
        libraryGlyph
            .background(LibraryAnchor(ui: ui))
            .overlay {
                if let download = ui.recentDownload {
                    DownloadBin(download: download, dimmed: !ui.appActive)
                        .offset(Self.binOffset)
                }
            }
    }

    private var libraryGlyph: some View {
        let ink = palette.isDark ? Color.white.opacity(0.55) : Color.black.opacity(0.26)
        return Button(action: action) {
            ZStack(alignment: .top) {
                // Arc's box has no lid line: a 13×10 rounded box with a light slot near the top.
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .frame(width: 14, height: 11)
                    .overlay(alignment: .top) {
                        Capsule().fill(palette.isDark ? Color.black.opacity(0.5) : Color.white.opacity(0.7))
                            .frame(width: 5, height: 1.6).padding(.top, 2.4)
                    }
                    .offset(y: 8)
                HStack(alignment: .bottom, spacing: 1) {
                    Image(systemName: "cloud.fill").font(.system(size: 7, weight: .bold))
                    Circle().frame(width: 2, height: 2).offset(y: -4)
                    Image(systemName: "triangle.fill").font(.system(size: 4, weight: .bold)).offset(y: -1)
                }
                .offset(x: 2, y: -1)
            }
            .foregroundStyle(ink)
            .frame(width: 28, height: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hover ? palette.hoverFill : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0; ui.libraryHovered = $0; ui.downloadsHoverChanged() }
        .arcTooltip("Library (⇧⌘L)")
    }
}

/// Arc's download "bin" (DownloadsUI.DownloadToLibrary): the file's thumbnail, 32 pt with
/// 8 pt corners, lands over the Library button as the download glyph is launched at it.
/// It drops in from 6 pt above, overshoots 12 pt below, and settles (measured on Arc 1.170
/// at 60 fps). Arc draws it faint while its window is in the background.
private struct DownloadBin: View {
    let download: RecentDownload
    let dimmed: Bool
    @Environment(SidebarUIState.self) private var ui
    /// Keyframes run when their trigger changes, and the bin is a new view per download.
    @State private var drops = 0

    var body: some View {
        Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: download.path)]) } label: {
            Image(nsImage: download.image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .opacity(dimmed ? 0.4 : 1)
                .keyframeAnimator(initialValue: BinMotion(), trigger: drops) { content, m in
                    content.offset(y: m.y).opacity(m.opacity)
                } keyframes: { _ in
                    KeyframeTrack(\.y) {
                        LinearKeyframe(-6, duration: 0)
                        CubicKeyframe(12, duration: 0.15)
                        LinearKeyframe(12, duration: 0.05)
                        CubicKeyframe(-2, duration: 0.13)
                        CubicKeyframe(0, duration: 0.07)
                    }
                    KeyframeTrack(\.opacity) {
                        LinearKeyframe(0, duration: 0)
                        LinearKeyframe(1, duration: 0.05)
                    }
                }
        }
        .buttonStyle(.plain)
        .frame(width: 28, height: 28)
        .onHover { ui.libraryHovered = $0; ui.downloadsHoverChanged() }
        .arcTooltip((download.path as NSString).lastPathComponent)
        .onAppear { drops += 1 }
        .onChange(of: download.id) { drops += 1 }
    }
}

private struct BinMotion {
    var y: CGFloat = 0
    var opacity: Double = 1
}

/// Hands the Library button's NSView to the window controller, which aims download
/// flights at it (the sidebar can live in the window or in the floating sidebar panel).
private struct LibraryAnchor: NSViewRepresentable {
    let ui: SidebarUIState
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        ui.libraryAnchor = v
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) { ui.libraryAnchor = nsView }
}
