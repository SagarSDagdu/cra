import AppKit

/// Arc's software-update sidebar banners (SidebarBanner `updateAvailable` and `updateSummary`),
/// above the space dock. Copy from Arc 1.170's strings: "An update is ready!" / "Click to
/// restart", "New Arc Version Available", and after the restart "Updated!" with "See What's
/// New". The banner never appeared on this Mac during the analysis, so its look follows
/// Cra's sidebar cards rather than a capture.
@MainActor
final class UpdateBannerView: NSView {
    private struct Content: Equatable {
        var symbol: String
        var title: String
        var subtitle: String
    }

    /// What the banner says, or nil when there is nothing to say.
    static var isShown: Bool { content != nil }

    private static var content: Content? {
        let u = SoftwareUpdater.shared
        if u.readyRelease != nil, !u.bannerDismissed {
            return Content(symbol: "arrow.down.circle.fill", title: "An update is ready!", subtitle: "Click to restart")
        }
        if let r = u.foundRelease, !u.bannerDismissed {
            return Content(symbol: "arrow.down.circle", title: "New Cra Version Available", subtitle: "Cra \(r.version)")
        }
        if u.updatedTo != nil {
            return Content(symbol: "heart.circle.fill", title: "Cra Updated!", subtitle: "See What's New")
        }
        return nil
    }

    private static func perform() {
        let u = SoftwareUpdater.shared
        if u.readyRelease != nil, !u.bannerDismissed { u.installAndRelaunch() }
        else if u.foundRelease != nil, !u.bannerDismissed { u.showFoundUpdate() }
        else if u.updatedTo != nil { u.openReleaseNotes() }
    }

    var colors = SidebarColors() { didSet { if colors != oldValue { refresh() } } }
    private let card = NSView()
    private let icon = NSImageView()
    private let title = NSTextField.sidebarLabel(size: 13, weight: .semibold)
    private let subtitle = NSTextField.sidebarLabel(size: 12)
    private let close = NSView()
    private let closeGlyph = NSImageView()
    private var shown: Content?
    private var hovering = false { didSet { if hovering != oldValue { refresh() } } }
    private var hoveringClose = false { didSet { if hoveringClose != oldValue { refresh() } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        card.wantsLayer = true
        card.layer?.cornerRadius = 10
        card.layer?.cornerCurve = .continuous
        // Hidden until there is something to say: the host is 0 pt tall then, and the card
        // would hang over the dock.
        card.isHidden = true
        addSubview(card)
        icon.imageScaling = .scaleNone
        card.addSubview(icon)
        card.addSubview(title)
        card.addSubview(subtitle)
        close.wantsLayer = true
        close.layer?.cornerRadius = 9
        closeGlyph.image = SidebarSymbols.image("xmark", size: 9, weight: .bold)
        closeGlyph.imageScaling = .scaleNone
        closeGlyph.frame = NSRect(x: 0, y: 0, width: 18, height: 18)
        close.addSubview(closeGlyph)
        _ = ArcTooltipAnchorView.attach(to: close, help: "Dismiss")
        close.isHidden = true
        card.addSubview(close)
        observe()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    private func observe() {
        let content = withObservationTracking { Self.content } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        guard content != shown else { return }
        let appearing = shown == nil && content != nil
        shown = content
        card.isHidden = content == nil
        guard let content else { return }
        icon.image = SidebarSymbols.image(content.symbol, size: 20)
        title.stringValue = content.title
        subtitle.stringValue = content.subtitle
        needsLayout = true
        // .transition(.move(edge: .bottom).combined(with: .opacity)), easeInOut 0.25.
        if appearing, let layer = card.layer {
            layoutSubtreeIfNeeded()
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            let move = CABasicAnimation(keyPath: "position.y")
            move.fromValue = layer.position.y - bounds.height
            move.toValue = layer.position.y
            let group = CAAnimationGroup()
            group.animations = [fade, move]
            group.duration = 0.25
            group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(group, forKey: "appear")
        }
    }

    private func refresh() {
        card.layer?.backgroundColor = (hovering ? colors.selectedFill : colors.hoverFill).cgColor
        icon.contentTintColor = colors.textPrimary
        title.textColor = colors.textPrimary
        subtitle.textColor = colors.textSecondary
        closeGlyph.contentTintColor = colors.textSecondary
        close.layer?.backgroundColor = (hoveringClose ? colors.hoverFill : .clear).cgColor
        close.isHidden = !hovering
    }

    override func layout() {
        super.layout()
        // .padding(.horizontal, 8), .padding(.top, 8), 52 tall.
        card.frame = NSRect(x: 8, y: 8, width: max(0, bounds.width - 16), height: 52)
        let h: CGFloat = 52
        let iw = icon.image?.size.width ?? 20
        icon.frame = NSRect(x: 12, y: 0, width: iw, height: h)
        let tx = 12 + iw + 10, tw = max(0, card.bounds.width - tx - 12)
        // VStack(spacing: 1): 16 + 1 + 15, centred.
        let top = (h - 32) / 2
        title.frame = NSRect(x: tx - SidebarText.inset, y: h - top - 16, width: tw + 2 * SidebarText.inset, height: 16)
        subtitle.frame = NSRect(x: tx - SidebarText.inset, y: h - top - 32, width: tw + 2 * SidebarText.inset, height: 15)
        close.frame = NSRect(x: card.bounds.width - 6 - 18, y: h - 6 - 18, width: 18, height: 18)
    }

    // MARK: Pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas where t.owner === self { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { track(event) }
    override func mouseMoved(with event: NSEvent) { track(event) }
    override func mouseExited(with event: NSEvent) { hovering = false; hoveringClose = false }

    private func track(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        hovering = shown != nil && card.frame.contains(p)
        hoveringClose = hovering && close.frame.contains(card.convert(p, from: self))
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard shown != nil, card.frame.contains(convert(point, from: superview)) else { return nil }
        return self
    }

    /// After an automatic update Cra restarts in the background; "See What's New" acts on the
    /// click that brings the window forward.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard card.frame.contains(p) else { return }
        if hovering, close.frame.contains(card.convert(p, from: self)) {
            SoftwareUpdater.shared.dismissBanner()
        } else {
            Self.perform()
        }
    }
}
