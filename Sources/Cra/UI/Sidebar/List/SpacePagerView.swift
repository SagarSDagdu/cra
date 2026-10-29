import AppKit
import SwiftUI

/// Dia's paging container in AppKit: every space's column (favorites, header, tab list) sits
/// side by side on a strip, the strip follows a swipe 1:1, then a spring settles it on a page.
/// The page index places the strip by frame; the rest of the travel is a translation of the
/// pager's sublayers, which Core Animation moves on its own. A swipe or a settle never lays out,
/// diffs or redraws a row.
@MainActor
final class SpacePagerView: NSView {
    private let store: SidebarStore
    private let ui: SidebarUIState
    private let actions: SidebarActions
    private let favicons: FaviconCache
    private let strip = NSView()
    private var columns: [UUID: NSView] = [:]
    /// The page the strip's frame was placed at, and the width it was placed with.
    private var placedIndex = 0
    private var placedWidth: CGFloat = 0
    private var placedSwipe: CGFloat = 0
    /// The translation (points) the model layer holds; the presentation may still be springing.
    private var offset: CGFloat = 0
    /// Release speed for the next settle, relative to the distance left (Dia's spring).
    private var pendingVelocity: Double = 0
    private var ownSettle: Int?
    private static let settleKey = "settle"

    init(store: SidebarStore, ui: SidebarUIState, actions: SidebarActions, favicons: FaviconCache) {
        self.store = store
        self.ui = ui
        self.actions = actions
        self.favicons = favicons
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        strip.wantsLayer = true
        addSubview(strip)
        ui.observeSpaceSwipe { [weak self] in self?.swipeChanged() }
        observeSpaces()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    // The strip takes no clicks or hovers under the fingers, nor while the Library covers it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        ui.spaceSwipe != 0 || ui.libraryPage != nil ? nil : super.hitTest(point)
    }

    private func observeSpaces() {
        withObservationTracking {
            _ = store.pagedSpaces(window: ui.windowID).map(\.id)
            _ = store.focusedSpaceID(window: ui.windowID)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeSpaces() }
        }
        needsLayout = true
    }

    private func swipeChanged() {
        let swipe = ui.spaceSwipe
        if swipe == 0 {
            pendingVelocity = ui.spaceSettleVelocity
            needsLayout = true
            return
        }
        if placedSwipe == 0 { SpaceListView.endHover(for: ui) }
        // Under the fingers the strip follows at once, without a layout pass.
        layer?.removeAnimation(forKey: Self.settleKey)
        setOffset(-swipe * placedWidth)
        placedSwipe = swipe
    }

    private func column(for id: UUID) -> NSView {
        if let c = columns[id] { return c }
        let host = SpaceColumnView(spaceID: id, store: store, ui: ui, actions: actions, favicons: favicons)
        columns[id] = host
        strip.addSubview(host)
        return host
    }

    override func layout() {
        super.layout()
        let width = bounds.width, height = bounds.height
        let ids = store.pagedSpaces(window: ui.windowID).map(\.id)
        let index = ids.firstIndex(of: store.focusedSpaceID(window: ui.windowID)) ?? 0
        for (id, c) in columns where !ids.contains(id) {
            c.removeFromSuperview()
            columns[id] = nil
        }
        // Where the strip shows now, in pages (mid-spring if one runs).
        let shown = presentedPosition()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        strip.frame = NSRect(x: -CGFloat(index) * width, y: 0, width: CGFloat(max(1, ids.count)) * width, height: height)
        for (i, id) in ids.enumerated() {
            let f = NSRect(x: CGFloat(i) * width, y: 0, width: width, height: height)
            let c = column(for: id)
            if c.frame != f { c.frame = f }
        }
        CATransaction.commit()

        let swipe = ui.spaceSwipe
        defer {
            placedIndex = index
            placedWidth = width
            placedSwipe = swipe
        }
        if swipe != 0 {
            // Fingers on the trackpad: follow them exactly.
            layer?.removeAnimation(forKey: Self.settleKey)
            setOffset(-swipe * width)
        } else if index != placedIndex || placedSwipe != 0, let shown, abs(shown - CGFloat(index)) > 0.002, width > 0 {
            settle(from: -(shown - CGFloat(index)) * width)
        } else if layer?.animation(forKey: Self.settleKey) == nil {
            setOffset(0)
        }
    }

    private func presentedPosition() -> CGFloat? {
        guard placedWidth > 0 else { return nil }
        let tx = (layer?.presentation()?.value(forKeyPath: "sublayerTransform.translation.x") as? CGFloat) ?? offset
        return CGFloat(placedIndex) - tx / placedWidth
    }

    private func setOffset(_ x: CGFloat) {
        offset = x
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.sublayerTransform = CATransform3DMakeTranslation(x, 0, 0)
        CATransaction.commit()
    }

    /// Dia settles pages with a zero-bounce spring that picks up the release speed.
    private func settle(from x: CGFloat) {
        let spring = CASpringAnimation(perceptualDuration: 0.4, bounce: 0)
        spring.keyPath = "sublayerTransform.translation.x"
        spring.fromValue = x
        spring.toValue = 0
        spring.initialVelocity = pendingVelocity
        spring.duration = spring.settlingDuration
        pendingVelocity = 0
        let generation = ui.beginSpaceSettle()
        ownSettle = generation
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self else { return }
            if self.ownSettle == generation { self.ui.endSpaceSettle(generation) }
            SpaceListView.refreshHover(for: self.ui)
        }
        setOffset(0)
        layer?.add(spring, forKey: Self.settleKey)
        CATransaction.commit()
    }
}
