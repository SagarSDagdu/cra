import AppKit

/// Dia's "back to the open tab" pill (TabList.TabOverflowIndicatorView, its geometry from
/// TabOverflowGeometryTracker): while the selected tab's row is scrolled out of the list, a
/// dark capsule with its favicon and an arrow pointing at it sits 7 pt inside the list edge
/// the tab is past. A click scrolls the tab to the middle of the list.
///
/// Measured on a Dia capture (2x): a 51 × 28 pt capsule, fill #1F1C1C, a 0.5 pt light inner
/// edge (~10 % white) inside a 0.5 pt dark outer edge (~45 % black), no larger shadow;
/// 10.5 pt in, the 16 pt favicon, 7 pt, a thin 9 pt arrow in #ADACAC, 10.5 pt out. A split
/// shows its tabs' favicons as a small facepile (Dia's `facepile`).
@MainActor
final class SidebarJumpPill: NSView {
    enum Edge { case top, bottom }

    static let inset: CGFloat = 7
    private static let height: CGFloat = 28
    private static let padding: CGFloat = 10.5
    private static let icon: CGFloat = 16
    /// Each further favicon of a split overlaps the one before by this much.
    private static let overlap: CGFloat = 5
    private static let fill = NSColor(srgbRed: 0x1F / 255, green: 0x1C / 255, blue: 0x1C / 255, alpha: 1)
    private static let fillHover = NSColor(srgbRed: 0x2A / 255, green: 0x27 / 255, blue: 0x27 / 255, alpha: 1)

    var onClick: () -> Void = {}
    private(set) var edge: Edge?
    private let body = NSView()
    private let innerEdge = CAShapeLayer()
    private var icons: [SidebarFaviconView] = []
    private let arrow = NSImageView()
    /// What the favicons show: their keys and whether each image had loaded.
    private var shownIcons: [String] = []
    private var hovering = false { didSet { if hovering != oldValue { refreshFill() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        isHidden = true
        body.wantsLayer = true
        if let l = body.layer {
            l.cornerRadius = Self.height / 2
            l.cornerCurve = .continuous
            l.borderWidth = 0.5
            l.borderColor = NSColor.black.withAlphaComponent(0.45).cgColor
            innerEdge.fillColor = nil
            innerEdge.strokeColor = NSColor.white.withAlphaComponent(0.1).cgColor
            innerEdge.lineWidth = 0.5
            l.addSublayer(innerEdge)
        }
        addSubview(body)
        arrow.imageScaling = .scaleNone
        arrow.contentTintColor = NSColor(srgbRed: 0xAD / 255, green: 0xAC / 255, blue: 0xAC / 255, alpha: 1)
        body.addSubview(arrow)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Scroll to the open tab")
        refreshFill()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// The pill's size for these many favicons.
    static func size(icons n: Int) -> NSSize {
        let iconsW = icon + CGFloat(max(0, n - 1)) * (icon - overlap)
        return NSSize(width: ceil(padding + iconsW + 7 + 7 + padding), height: height)
    }

    /// Shows the pill at `edge` with these favicons, or hides it (nil).
    func show(edge newEdge: Edge?, icons items: [(image: NSImage?, flip: Bool, key: String?)], animated: Bool) {
        if let newEdge {
            if Self.signature(items) != shownIcons { setIcons(items) }
            arrow.image = SidebarSymbols.image(newEdge == .top ? "arrow.up" : "arrow.down", size: 10.5, weight: .light)
        }
        guard newEdge != edge else { return }
        let appearing = edge == nil
        edge = newEdge
        needsLayout = true
        if let newEdge {
            isHidden = false
            alphaValue = 1
            guard animated, appearing, let layer = body.layer else { return }
            // In from the edge it points at: fade in while sliding 4 pt, sprung.
            layoutSubtreeIfNeeded()
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.18
            layer.add(fade, forKey: "fade")
            let move = CASpringAnimation(perceptualDuration: 0.32, bounce: 0.2)
            move.keyPath = "sublayerTransform"
            move.fromValue = CATransform3DMakeTranslation(0, newEdge == .top ? -4 : 4, 0)
            move.toValue = CATransform3DIdentity
            move.duration = move.settlingDuration
            self.layer?.add(move, forKey: "rise")
        } else if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().alphaValue = 0
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.edge == nil else { return }
                    self.isHidden = true
                    self.hovering = false
                }
            }
        } else {
            isHidden = true
            hovering = false
        }
    }

    private func setIcons(_ items: [(image: NSImage?, flip: Bool, key: String?)]) {
        icons.forEach { $0.removeFromSuperview() }
        // Mono glyphs flip to white on the dark pill.
        var dark = SidebarColors()
        dark.isDark = true
        dark.textTertiary = NSColor.white.withAlphaComponent(0.5)
        icons = items.prefix(3).map { item in
            let v = SidebarFaviconView(size: Self.icon)
            v.show(item.image, flip: item.flip, colors: dark)
            body.addSubview(v)
            return v
        }
        shownIcons = Self.signature(items)
        let size = Self.size(icons: icons.count)
        setFrameSize(size)
        needsLayout = true
    }

    private static func signature(_ items: [(image: NSImage?, flip: Bool, key: String?)]) -> [String] {
        items.map { "\($0.key ?? "-")|\($0.image.map { ObjectIdentifier($0).hashValue } ?? 0)|\($0.flip)" }
    }

    private func refreshFill() {
        body.layer?.backgroundColor = (hovering ? Self.fillHover : Self.fill).cgColor
        for v in icons.dropFirst() {
            v.layer?.borderColor = (hovering ? Self.fillHover : Self.fill).cgColor
        }
    }

    override func layout() {
        super.layout()
        body.frame = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let r = body.bounds.insetBy(dx: 0.75, dy: 0.75)
        innerEdge.path = CGPath(roundedRect: r, cornerWidth: r.height / 2, cornerHeight: r.height / 2, transform: nil)
        CATransaction.commit()
        var x = Self.padding
        for (i, v) in icons.enumerated() {
            v.frame = NSRect(x: x, y: (bounds.height - Self.icon) / 2, width: Self.icon, height: Self.icon)
            if i > 0 {
                v.layer?.borderWidth = 1.5
                v.layer?.borderColor = (hovering ? Self.fillHover : Self.fill).cgColor
            }
            x += Self.icon - Self.overlap
        }
        let arrowX = Self.padding + (Self.icon + CGFloat(max(0, icons.count - 1)) * (Self.icon - Self.overlap)) + 7
        arrow.frame = NSRect(x: arrowX, y: 0, width: 7, height: bounds.height)
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas where t.owner === self { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func hitTest(_ point: NSPoint) -> NSView? { edge == nil || isHidden ? nil : super.hitTest(point).map { _ in self } }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick() }
    }
}
