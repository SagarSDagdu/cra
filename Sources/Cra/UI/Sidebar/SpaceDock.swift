import SwiftUI

/// Bottom row like Arc's: library/archive at the left, tiny space icons in
/// the middle (inactive ones dimmed), "+" at the right.
struct SpaceDock: View {
    let palette: SpacePalette
    @Environment(SidebarStore.self) private var store
    @Environment(SidebarUIState.self) private var ui
    @Environment(\.sidebarActions) private var actions
    @State private var reorder: SpaceReorder?
    @GestureState private var pressing: UUID?

    /// Arc 1.170 (SidebarDock, an NSCollectionView): 34×32 pt cells side by side with no
    /// gap, so a press anywhere between two icons still lands on a space.
    static let cell = CGSize(width: 34, height: 32)
    /// Marks the strip as draggable content so a press there never moves the window.
    private static let stripID = UUID()

    var body: some View {
        HStack(spacing: 0) {
            LibraryButton(palette: palette) { actions.showArchive() }
            Spacer(minLength: 0)
            // An incognito window has one space of its own: nothing to switch to or add.
            if !store.window(ui.windowID).isIncognito {
                let spaces = store.orderedSpaces
                HStack(spacing: 0) {
                    ForEach(Array(spaces.enumerated()), id: \.element.id) { index, space in
                        SpaceDockButton(space: space, palette: palette,
                                        selected: space.id == store.focusedSpaceID(window: ui.windowID),
                                        pressed: reorder?.id == space.id)
                            .offset(x: offset(of: space.id, at: index))
                            .zIndex(reorder?.id == space.id ? 1 : 0)
                            .gesture(press(space, at: index, count: spaces.count))
                    }
                }
                .coordinateSpace(name: Self.stripID)
                .background(SpaceDockStripAnchor(ui: ui).allowsHitTesting(false))
                .onHover { ui.hoverDraggable(Self.stripID, $0) }
                // A cancelled gesture never reaches onEnded; don't leave a cell pressed.
                .onChange(of: pressing) { _, now in
                    guard now == nil else { return }
                    DispatchQueue.main.async { if reorder?.settling == false { reorder = nil } }
                }
                Spacer(minLength: 0)
                SidebarIconButton(symbol: "plus", palette: palette, help: "New Space") { actions.editSpace(nil) }
            }
        }
        .frame(height: 36)
    }

    /// The dragged space follows the pointer; the ones it passes slide a cell the other way,
    /// like the gap Arc's collection view opens at the proposed drop index.
    private func offset(of id: UUID, at index: Int) -> CGFloat {
        guard let r = reorder else { return 0 }
        if r.id == id { return r.dx }
        if r.from < index && index <= r.to { return -Self.cell.width }
        if r.to <= index && index < r.from { return Self.cell.width }
        return 0
    }

    /// Arc's dock item handles mouseDown/mouseUp itself: the cell fills on press, a release
    /// switches space, and dragging reorders. A release inside the pressed cell that didn't
    /// move the space still switches, so a shaky click never ends up as a window drag or a no-op.
    private func press(_ space: Space, at index: Int, count: Int) -> some Gesture {
        let cell = CGRect(x: CGFloat(index) * Self.cell.width, y: 0, width: Self.cell.width, height: Self.cell.height)
        return DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.stripID))
            .updating($pressing) { _, state, _ in state = space.id }
            .onChanged { g in
                var r = reorder ?? SpaceReorder(id: space.id, from: index, to: index)
                guard r.id == space.id else { return }
                if !r.moved && abs(g.translation.width) < 3 && abs(g.translation.height) < 3 {
                    reorder = r
                    return
                }
                r.moved = true
                let w = Self.cell.width
                r.dx = min(max(g.translation.width, -CGFloat(index) * w), CGFloat(count - 1 - index) * w)
                let to = min(max(index + Int((r.dx / w).rounded()), 0), count - 1)
                if to != r.to {
                    reorder?.dx = r.dx
                    withAnimation(.easeOut(duration: 0.2)) { r.to = to; reorder = r }
                } else {
                    reorder = r
                }
            }
            .onEnded { g in
                guard let r = reorder, r.id == space.id, r.to != r.from else {
                    if cell.contains(g.location) { store.focusSpace(space.id, window: ui.windowID) }
                    if reorder?.id == space.id { withAnimation(.easeOut(duration: 0.15)) { reorder = nil } }
                    return
                }
                reorder?.settling = true
                withAnimation(.easeOut(duration: 0.15)) {
                    reorder?.dx = CGFloat(r.to - r.from) * Self.cell.width
                } completion: {
                    withTransaction(Transaction(animation: nil)) {
                        store.moveSpace(r.id, to: r.to)
                        reorder = nil
                    }
                }
            }
    }
}

private struct SpaceReorder {
    let id: UUID
    let from: Int
    var to: Int
    var dx: CGFloat = 0
    var moved = false
    /// Released; the space is sliding into its new cell.
    var settling = false
}

struct SpaceDockButton: View {
    let space: Space
    let palette: SpacePalette
    let selected: Bool
    var pressed = false
    @Environment(SidebarStore.self) private var store
    @Environment(SidebarUIState.self) private var ui
    @Environment(\.sidebarActions) private var actions
    @State private var hover = false
    @State private var targeted = false

    /// Arc's hovered/pressed cell on a dark space: white at ~7.8% (39,33,51 over 21,14,34), 6 pt corners.
    private var cellFill: Color { palette.isDark ? .white.opacity(0.078) : .black.opacity(0.05) }

    var body: some View {
        Text(space.emoji)
            .font(.system(size: 13))
            .frame(width: SpaceDock.cell.width, height: SpaceDock.cell.height)
            .opacity(selected || hover || pressed ? 1 : 0.45)
            .saturation(selected || hover || pressed ? 1 : 0.2)
            .background(RoundedRectangle(cornerRadius: 6).fill(targeted || hover || pressed ? cellFill : .clear))
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .arcTooltip(space.title)
            // Arc exposes each cell as a button named after the space.
            .accessibilityElement()
            .accessibilityLabel(space.title)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { store.focusSpace(space.id, window: ui.windowID) }
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

/// Hands the strip of space cells to the window, which keeps presses there from dragging it.
private struct SpaceDockStripAnchor: NSViewRepresentable {
    let ui: SidebarUIState
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        ui.spaceDockStrip = v
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) { ui.spaceDockStrip = nsView }
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
