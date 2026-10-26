import AppKit
import SwiftUI

/// What releasing a sidebar drag over the space's list would do right now. The
/// rows read it to draw the live preview (insertion line, rows easing apart,
/// the row a drop would combine with) and the delegate applies it on drop.
struct SidebarListDrop: Equatable {
    enum Target: Equatable {
        /// Before the child at `index` of `parent` (`index == count` appends).
        case insert(parent: UUID, index: Int)
        /// A new folder holding this tab and the dragged one (a pinned tab).
        case newFolder(with: UUID)
        /// A split of this tab and the dragged one (a Today tab); the dragged
        /// tab takes the left pane when `leading`, else the right.
        case split(with: UUID, leading: Bool)
        /// Into a folder or a split row.
        case into(UUID)
    }

    struct Line: Equatable {
        var y: CGFloat
        var minX: CGFloat
        var maxX: CGFloat
    }

    var draggedID: UUID
    /// nil while the drop would leave the item where it is.
    var target: Target?
    /// Insertion line in the list's coordinate space.
    var line: Line?
    /// The rows on either side of the line, nudged apart.
    var rowAbove: UUID?
    var rowBelow: UUID?
}

/// Scrolls a space's list while a drag hovers near its top or bottom edge.
/// SwiftUI's ScrollView has no autoscroll for custom drops, so with a long
/// pinned list everything past the fold (Today included) was out of reach.
@MainActor
final class DragAutoscroller {
    /// Edge band, and the speed at the very edge in points per second.
    static let band: CGFloat = 48
    static let maxSpeed: CGFloat = 900

    fileprivate weak var anchor: NSView?
    private var timer: Timer?
    private var lastTick: CFTimeInterval = 0

    /// Starts or stops scrolling for where the pointer is now.
    func update() {
        guard speed() != 0 else { stop(); return }
        guard timer == nil else { return }
        lastTick = CACurrentMediaTime()
        let t = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // A drag keeps the run loop in event-tracking mode.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func speed() -> CGFloat {
        guard NSEvent.pressedMouseButtons != 0, let sv = anchor?.enclosingScrollView, let window = sv.window else { return 0 }
        let p = sv.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let fromTop = sv.isFlipped ? p.y : sv.bounds.height - p.y
        let fromBottom = sv.bounds.height - fromTop
        guard p.x >= 0, p.x <= sv.bounds.width, fromTop >= 0, fromBottom >= 0 else { return 0 }
        if fromTop < Self.band { return -Self.maxSpeed * (1 - fromTop / Self.band) }
        if fromBottom < Self.band { return Self.maxSpeed * (1 - fromBottom / Self.band) }
        return 0
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(now - lastTick, 0.05)
        lastTick = now
        let v = speed()
        guard v != 0, let sv = anchor?.enclosingScrollView else { stop(); return }
        let clip = sv.contentView
        var origin = clip.bounds.origin
        origin.y += v * dt * (sv.documentView?.isFlipped ?? true ? 1 : -1)
        let r = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size))
        guard r.origin != clip.bounds.origin else { return }
        clip.scroll(to: r.origin)
        sv.reflectScrolledClipView(clip)
    }

    /// Placed inside the list so the scroller can find the scroll view around it.
    struct Anchor: NSViewRepresentable {
        let scroller: DragAutoscroller
        func makeNSView(context: Context) -> NSView { PassThroughView() }
        func updateNSView(_ view: NSView, context: Context) { scroller.anchor = view }
    }

    private final class PassThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

/// One drop delegate for the whole pinned + today list. Per-row drop
/// destinations only report entered/exited, so the list hit-tests the pointer
/// against the rows' frames itself on every move.
struct SidebarListDropDelegate: DropDelegate {
    static let coordinateSpace = "sidebarList"
    static let nudge: CGFloat = 3
    static let animation = Animation.snappy(duration: 0.2, extraBounce: 0)

    let space: Space
    let store: SidebarStore
    let ui: SidebarUIState
    let autoscroller: DragAutoscroller

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.craSidebarItem]) }

    func dropEntered(info: DropInfo) {
        // Rows here set draggingID when the drag starts; a drag from another
        // window only says what it carries through the pasteboard.
        if let provider = info.itemProviders(for: [.craSidebarItem]).first {
            _ = provider.loadTransferable(type: SidebarDragItem.self) { [ui] result in
                guard case .success(let d) = result else { return }
                DispatchQueue.main.async { ui.draggingID = d.id }
            }
        }
        update(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        autoscroller.stop()
        withAnimation(Self.animation) { ui.listDrop = nil }
    }

    func performDrop(info: DropInfo) -> Bool {
        autoscroller.stop()
        guard let id = ui.draggingID, store.item(id) != nil else { return false }
        let drop = ui.listDrop ?? resolve(dragged: id, at: info.location)
        withAnimation(Self.animation) {
            ui.listDrop = nil
            apply(drop)
        }
        // Dia: Tabs ▸ "Haptic feedback when reordering tabs".
        if drop.target != nil, store.settings.hapticFeedbackOnReorder {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .drawCompleted)
        }
        ui.draggingID = nil
        return true
    }

    private func update(_ info: DropInfo) {
        autoscroller.update()
        guard let id = ui.draggingID, store.item(id) != nil else { return }
        let drop = resolve(dragged: id, at: info.location)
        guard drop != ui.listDrop else { return }
        withAnimation(Self.animation) { ui.listDrop = drop }
        // A tick when a row starts offering to combine, so the change of meaning is felt as well as seen.
        switch drop.target {
        case .split?, .newFolder?:
            if store.settings.hapticFeedbackOnReorder {
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            }
        default: break
        }
        // Spring-loaded folders: hovering a closed folder opens it.
        if case .into(let f)? = drop.target, store.item(f)?.isFolder == true, !store.isExpanded(f) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [ui, store] in
                guard ui.listDrop?.target == .into(f) else { return }
                withAnimation(.snappy(duration: 0.22, extraBounce: 0)) { store.setExpanded(f, true) }
            }
        }
    }

    private func apply(_ drop: SidebarListDrop) {
        let id = drop.draggedID
        switch drop.target {
        case .insert(let parent, let index)?:
            store.moveItem(id, to: parent, index: index)
        case .newFolder(let tab)?:
            if let folder = store.createFolder(combining: tab, with: id) { ui.renamingID = folder.id }
        case .split(let tab, let leading)?:
            store.createSplit(with: leading ? [id, tab] : [tab, id], at: tab)
        case .into(let target)?:
            store.moveItem(id, to: target, index: nil)
            if store.item(target)?.isFolder == true { store.setExpanded(target, true) }
        case nil:
            break
        }
    }

    // MARK: Hit testing

    private struct Row {
        let item: SidebarItem
        let parent: UUID
        let index: Int
        let depth: Int
        let frame: CGRect
    }

    /// Rows as drawn: pinned (expanded folders open), then today. Frames stay
    /// recorded for rows that are no longer drawn (a collapsed pinned list),
    /// so only drawn rows may be hit.
    private func visibleRows() -> [Row] {
        var out: [Row] = []
        func walk(_ rows: [SidebarItem], _ depth: Int) {
            for c in rows {
                guard let f = ui.rowFrames[c.id], let parent = c.parentID,
                      let i = store.item(parent)?.children.firstIndex(of: c.id) else { continue }
                out.append(Row(item: c, parent: parent, index: i, depth: depth, frame: f))
                if c.isFolder, store.isExpanded(c.id) { walk(store.children(of: c.id), depth + 1) }
            }
        }
        walk(store.listedPinnedItems(in: space), 0)
        walk(store.children(of: space.todayContainerID), 0)
        return out
    }

    private func isInside(_ id: UUID, _ ancestor: UUID) -> Bool {
        var cur = store.item(id)?.parentID
        var hops = 0
        while let c = cur, hops < 64 {
            if c == ancestor { return true }
            cur = store.item(c)?.parentID
            hops += 1
        }
        return false
    }

    /// Top and bottom quarters of a row insert before/after it; the middle
    /// combines: a folder takes the item, a Today tab makes a split (the
    /// dragged tab goes on the side of the row it hovers), a pinned tab makes
    /// a new folder, a split row takes a pane.
    func resolve(dragged id: UUID, at p: CGPoint) -> SidebarListDrop {
        let rows = visibleRows()
        let isTab = store.item(id)?.isTab == true
        let half = CraMetrics.rowSpacing / 2
        var target: SidebarListDrop.Target?

        if let r = rows.first(where: { p.y >= $0.frame.minY - half && p.y < $0.frame.maxY + half }) {
            let f = (p.y - r.frame.minY) / max(1, r.frame.height)
            let middle = (0.25..<0.75).contains(f)
            let before = SidebarListDrop.Target.insert(parent: r.parent, index: r.index)
            let after = SidebarListDrop.Target.insert(parent: r.parent, index: r.index + 1)
            if r.item.id == id || isInside(r.item.id, id) {
                target = nil
            } else if r.item.isFolder {
                if f < 0.25 { target = before }
                else if f >= 0.75 { target = store.isExpanded(r.item.id) ? .insert(parent: r.item.id, index: 0) : after }
                else { target = .into(r.item.id) }
            } else if middle && isTab && r.item.isTab {
                target = isInside(r.item.id, space.todayContainerID)
                    ? .split(with: r.item.id, leading: p.x < r.frame.midX)
                    : .newFolder(with: r.item.id)
            } else if middle && isTab && r.item.isSplit {
                target = .into(r.item.id)
            } else {
                target = f < 0.5 ? before : after
            }
        } else {
            // Between sections or past the last row: the divider splits pinned from today.
            let pinned = ui.rowFrames[space.pinnedContainerID] ?? .zero
            let today = ui.rowFrames[space.todayContainerID] ?? .zero
            if p.y < (pinned.maxY + today.minY) / 2 {
                target = .insert(parent: space.pinnedContainerID, index: p.y < pinned.minY ? 0 : store.children(of: space.pinnedContainerID).count)
            } else {
                target = .insert(parent: space.todayContainerID, index: p.y < today.minY ? 0 : store.children(of: space.todayContainerID).count)
            }
        }

        // Dropping next to itself, or a folder into itself, changes nothing.
        if case .insert(let parent, let index)? = target {
            if parent == id || isInside(parent, id) {
                target = nil
            } else if store.item(id)?.parentID == parent, let old = store.item(parent)?.children.firstIndex(of: id), index == old || index == old + 1 {
                target = nil
            }
        }

        var drop = SidebarListDrop(draggedID: id, target: target)
        guard case .insert(let parent, let index)? = target else { return drop }
        let kids = store.item(parent)?.children ?? []
        var y: CGFloat?
        if index < kids.count, let f = rows.first(where: { $0.item.id == kids[index] })?.frame {
            y = f.minY - half
        } else if index > 0, let r = rows.last(where: { $0.item.id == kids[index - 1] || isInside($0.item.id, kids[index - 1]) }) {
            y = r.frame.maxY + half
        } else if store.item(parent)?.isFolder == true, let f = ui.rowFrames[parent] {
            y = f.maxY + half
        }
        // An empty pinned list shows its own placeholder instead of a line.
        guard let y, let section = ui.rowFrames[space.todayContainerID] else { return drop }
        let depth = rows.first { $0.item.id == parent }.map { $0.depth + 1 } ?? 0
        drop.line = .init(y: y, minX: section.minX + 8 + CGFloat(depth) * CraMetrics.indent, maxX: section.maxX - 6)
        drop.rowAbove = rows.last { $0.frame.maxY <= y + 1 }?.item.id
        drop.rowBelow = rows.first { $0.frame.minY >= y - 1 }?.item.id
        return drop
    }
}

/// Registers a row's frame for the list's drop delegate and draws the live
/// drop preview on it: the dragged row dims, the rows either side of the
/// insertion line ease apart, a tab the drop would combine with turns into
/// what it becomes (a split row or a folder), and a folder or split that
/// would take the item lights up with a label.
struct SidebarDropPreview: ViewModifier {
    let id: UUID
    let palette: SpacePalette
    var depth = 0
    @Environment(SidebarStore.self) private var store
    @Environment(SidebarUIState.self) private var ui

    func body(content: Content) -> some View {
        let drop = ui.listDrop
        let nudge: CGFloat = drop?.rowAbove == id ? -SidebarListDropDelegate.nudge : (drop?.rowBelow == id ? SidebarListDropDelegate.nudge : 0)
        let badge = badge(for: drop?.target)
        let combine = combine(for: drop)
        content
            .background {
                if badge != nil {
                    RoundedRectangle(cornerRadius: CraMetrics.rowCorner, style: .continuous)
                        .fill(palette.selectedFill)
                        .transition(.opacity)
                }
            }
            .overlay {
                if let badge {
                    RoundedRectangle(cornerRadius: CraMetrics.rowCorner, style: .continuous)
                        .strokeBorder(palette.textPrimary.opacity(0.3), lineWidth: 1.5)
                        .overlay(alignment: .trailing) {
                            HStack(spacing: 4) {
                                Image(systemName: badge.symbol).font(.system(size: 10, weight: .semibold))
                                Text(badge.label).font(.system(size: 11, weight: .semibold))
                            }
                            .foregroundStyle(palette.textPrimary)
                            .padding(.horizontal, 8)
                            .frame(height: 22)
                            .background(Capsule().fill(palette.isDark ? Color.white.opacity(0.14) : Color.white.opacity(0.9)))
                            .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
                            .padding(.trailing, 8)
                        }
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .opacity(combine != nil ? 0 : (drop?.draggedID == id ? 0.4 : 1))
            .overlay {
                if let combine, let target = store.item(id), let dragged = store.item(combine.dragged) {
                    CombineDropPreview(kind: combine.kind, target: target, dragged: dragged, depth: depth, palette: palette)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(SidebarListDropDelegate.coordinateSpace)) } action: { ui.rowFrames[id] = $0 }
            .visualEffect { content, _ in content.offset(y: nudge) }
    }

    private func combine(for drop: SidebarListDrop?) -> (kind: CombineDropPreview.Kind, dragged: UUID)? {
        switch drop?.target {
        case .split(let t, let leading)? where t == id: return (.split(leading: leading), drop!.draggedID)
        case .newFolder(let t)? where t == id: return (.folder, drop!.draggedID)
        default: return nil
        }
    }

    private func badge(for target: SidebarListDrop.Target?) -> (symbol: String, label: String)? {
        guard case .into(let t)? = target, t == id else { return nil }
        return store.item(id)?.isFolder == true ? ("folder", "Move to Folder") : ("rectangle.split.3x1", "Add to Split")
    }
}

/// A tab row while another tab hovers over its middle, drawn as the row the
/// drop makes: in Today the row splits open and the dragged tab slides into a
/// dashed pane on the side it will take (the split row's own layout), moving
/// across when the pointer crosses the row's middle; in Pinned it becomes a
/// "New Folder" row with both tabs' icons dropping into a stack.
struct CombineDropPreview: View {
    enum Kind: Equatable { case split(leading: Bool), folder }

    let kind: Kind
    let target: SidebarItem
    let dragged: SidebarItem
    let depth: Int
    let palette: SpacePalette
    @State private var open = false

    var body: some View {
        Group {
            switch kind {
            case .split(let leading): split(leading: leading)
            case .folder: folder
            }
        }
        .frame(height: CraMetrics.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: CraMetrics.rowCorner, style: .continuous)
                .fill(palette.selectedFill)
                .shadow(color: .black.opacity(palette.isDark ? 0.25 : 0.1), radius: open ? 6 : 2, y: open ? 2 : 1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CraMetrics.rowCorner, style: .continuous)
                .strokeBorder(palette.textPrimary.opacity(open ? 0.35 : 0), lineWidth: 1.5)
        )
        .scaleEffect(open ? 1 : 0.97)
        .onAppear {
            withAnimation(.spring(duration: 0.34, bounce: 0.22)) { open = true }
        }
    }

    private func split(leading: Bool) -> some View {
        GeometryReader { geo in
            let pane = max(0, (geo.size.width - 1) / 2)
            HStack(spacing: 0) {
                // Identified cells, so switching sides slides them past each other.
                ForEach(leading ? [dragged, target] : [target, dragged]) { item in
                    if item.id == target.id {
                        cell(target)
                            .frame(maxWidth: .infinity)
                    } else {
                        cell(dragged)
                            .background(
                                RoundedRectangle(cornerRadius: CraMetrics.rowCorner - 3, style: .continuous)
                                    .fill(palette.hoverFill)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: CraMetrics.rowCorner - 3, style: .continuous)
                                            .strokeBorder(palette.textPrimary.opacity(0.45), style: StrokeStyle(lineWidth: 1.25, dash: [4, 3]))
                                    )
                                    .padding(4)
                            )
                            .frame(width: open ? pane : 0)
                            .opacity(open ? 1 : 0)
                            .offset(x: open ? 0 : (leading ? -12 : 12))
                            .clipped()
                    }
                }
            }
            .overlay {
                Rectangle().fill(palette.separator)
                    .frame(width: 1)
                    .padding(.vertical, SplitRow.Metrics.separatorInset)
                    .opacity(open ? 1 : 0)
            }
        }
        .padding(.leading, CGFloat(depth) * CraMetrics.indent)
    }

    private func cell(_ item: SidebarItem) -> some View {
        HStack(spacing: 8) {
            FaviconView(key: item.tab?.faviconKey, palette: palette)
                .frame(width: CraMetrics.favicon)
            Text(item.displayTitle)
                .font(.system(size: 14))
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 2)
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .frame(maxHeight: .infinity)
    }

    private var folder: some View {
        HStack(spacing: 11) {
            ZStack {
                Image(systemName: "folder.fill").foregroundStyle(palette.folderFill)
                Image(systemName: "folder").foregroundStyle(palette.folderTint)
            }
            .font(.system(size: 15, weight: .regular))
            .frame(width: CraMetrics.favicon)
            .scaleEffect(open ? 1 : 0.4)
            .opacity(open ? 1 : 0)
            Text("New Folder")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(palette.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 4)
            ZStack {
                stackedIcon(target)
                    .rotationEffect(.degrees(open ? -6 : 0))
                    .offset(x: open ? -5 : 0)
                stackedIcon(dragged)
                    .rotationEffect(.degrees(open ? 7 : 0))
                    .offset(x: open ? 6 : 22, y: open ? 0 : -8)
                    .opacity(open ? 1 : 0)
            }
            .padding(.trailing, 14)
        }
        .padding(.leading, 8 + CGFloat(depth) * CraMetrics.indent)
        .padding(.trailing, 6)
    }

    private func stackedIcon(_ item: SidebarItem) -> some View {
        FaviconView(key: item.tab?.faviconKey, palette: palette, size: 14)
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(palette.isDark ? Color(white: 0.22) : .white)
                    .shadow(color: .black.opacity(0.15), radius: 1.5, y: 0.5)
            )
    }
}
