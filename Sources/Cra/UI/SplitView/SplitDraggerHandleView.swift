import AppKit

/// The divider between two panes (Arc: SplitViewDraggerHandleView). Sits in the
/// gap, shows a pill while hovered or dragged, resizes with a pan and resets
/// to equal widths on a double-click.
final class SplitDraggerHandleView: NSView {
    var orientation: SplitOrientation = .horizontal { didSet { needsLayout = true; window?.invalidateCursorRects(for: self) } }
    /// Mouse moved by `delta` points along the main axis since the drag started.
    var onDrag: ((CGFloat) -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragEnded: (() -> Void)?
    var onDoubleClick: (() -> Void)?
    var hitOutset: CGFloat = SplitPaneLayout.Constants.handleHitOutset

    private let pill = NSView()
    private var tracking: NSTrackingArea?
    private var dragStart: NSPoint?
    private var dragging = false
    private(set) var hovered = false

    enum Style {
        /// Measured on Arc 1.170: a 4 pt wide pill, 10 pt shorter than the gap on each end is far too long;
        /// Arc shows a short centred capsule.
        static let pillThickness: CGFloat = 4
        static let pillLength: CGFloat = 36
        static let pillColor = NSColor(white: 0, alpha: 0.28)
        static let pillHighlightColor = NSColor(white: 0, alpha: 0.45)
        static let fade: TimeInterval = 0.12
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        pill.wantsLayer = true
        pill.layer?.backgroundColor = Style.pillColor.cgColor
        pill.layer?.cornerRadius = Style.pillThickness / 2
        pill.alphaValue = 0
        addSubview(pill)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let b = bounds
        if orientation == .horizontal {
            pill.frame = NSRect(x: (b.width - Style.pillThickness) / 2, y: (b.height - Style.pillLength) / 2, width: Style.pillThickness, height: Style.pillLength)
        } else {
            pill.frame = NSRect(x: (b.width - Style.pillLength) / 2, y: (b.height - Style.pillThickness) / 2, width: Style.pillLength, height: Style.pillThickness)
        }
    }

    /// The gap is narrow; accept hits a little outside it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        return bounds.insetBy(dx: -hitOutset, dy: -hitOutset).contains(p) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    /// The window is movable by its background; the handle must own its drags.
    override var mouseDownCanMoveWindow: Bool { false }

    private var resizeCursor: NSCursor { orientation == .horizontal ? .resizeLeftRight : .resizeUpDown }

    override func resetCursorRects() {
        addCursorRect(bounds.insetBy(dx: -hitOutset, dy: -hitOutset), cursor: resizeCursor)
    }

    /// The page window next to us is usually the key window, so track always
    /// and set the cursor ourselves.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds.insetBy(dx: -hitOutset, dy: -hitOutset), options: [.mouseEnteredAndExited, .cursorUpdate, .activeAlways], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func cursorUpdate(with event: NSEvent) { resizeCursor.set() }
    override func mouseEntered(with event: NSEvent) { hovered = true; refreshPill(); resizeCursor.set() }
    override func mouseExited(with event: NSEvent) { hovered = false; refreshPill(); if !dragging { NSCursor.arrow.set() } }

    /// Observed on Arc 1.170: hovering the gap shows nothing; the gap only
    /// changes the cursor. The pill is shown while dragging.
    private func refreshPill() {
        let visible = dragging
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Style.fade
            pill.animator().alphaValue = visible ? 1 : 0
        }
        pill.layer?.backgroundColor = (dragging ? Style.pillHighlightColor : Style.pillColor).cgColor
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { onDoubleClick?(); return }
        dragStart = convert(event.locationInWindow, from: nil)
        dragging = true
        refreshPill()
        onDragBegan?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let p = convert(event.locationInWindow, from: nil)
        // Vertical layouts stack downwards; AppKit's y grows upwards.
        let delta = orientation == .horizontal ? p.x - start.x : start.y - p.y
        onDrag?(delta)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragging else { return }
        dragging = false
        dragStart = nil
        refreshPill()
        onDragEnded?()
    }
}
