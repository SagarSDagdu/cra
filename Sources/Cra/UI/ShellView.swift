import AppKit
import SwiftUI

/// The window's content view: gradient background, sidebar (anchored,
/// hidden, or floating over the content on hover), a resize handle, and the
/// content card: Arc's toolbar strip on top, the Chromium view below. With no
/// tab selected there is no card, just the toolbar on the gradient.
final class ShellView: NSView {
    /// Behind-window blur for vibrant (Arc-style) themes.
    let vibrancy = NSVisualEffectView()
    /// Lifts the dark blur toward Arc's mid-grey base before the gradient goes on.
    let vibrancyLift = NSView()
    let backgroundHost: NSHostingView<SpaceBackground>
    let sidebarHost: NSHostingView<AnyView>
    let resizeHandle = ResizeHandleView()
    /// The rounded card. Holds the toolbar and the web container.
    let contentContainer = NSView()
    let toolbarHost: NSHostingView<AnyView>
    /// Where Chromium views live (card minus toolbar, minus the DevTools pane).
    let webContainer = NSView()
    /// DevTools dock on the right of the page, like Chrome's default.
    let devToolsHost = NSView()
    let devToolsDivider = NSView()
    let devToolsHandle = DevToolsResizeHandle()
    var devToolsVisible = false { didSet { needsLayout = true } }
    var devToolsWidth: CGFloat = 460 { didSet { needsLayout = true } }
    /// Reports the dock area (window coordinates) so the DevTools child window follows it.
    var onDevToolsFrame: ((NSRect) -> Void)?
    /// Set while the sidebar/card frames are being animated; layout() then leaves them alone.
    private var animatingFrames = false
    /// While the sidebar animates, Chromium views are kept at their final size
    /// (Arc reflows the page once, not every frame).
    private var frozenWebBounds: NSRect?
    let placeholderHost: NSHostingView<AnyView>
    let statusHost: NSHostingView<AnyView>
    let toastHost: NSHostingView<AnyView>
    let findHost: NSHostingView<AnyView>

    var sidebarWidth: CGFloat = CraMetrics.sidebarDefaultWidth { didSet { needsLayout = true } }
    var sidebarVisible = true { didSet { needsLayout = true } }
    var floatingSidebar = false { didSet { needsLayout = true } }
    var contentFullscreen = false { didSet { needsLayout = true } }
    var showToolbar = true { didSet { needsLayout = true } }
    var hasTab = false { didSet { needsLayout = true } }
    var onEdgeHover: ((Bool) -> Void)?
    var windowActive = true {
        didSet { refreshLift() }
    }

    /// Dark vibrant themes keep the earlier calibration (underWindowBackground + 15% lift).
    var vibrantDark = false { didSet { refreshLift() } }

    func refreshLift() {
        let t = CraTuning.shared
        let lift = vibrantDark ? (windowActive ? 0.15 : 0.93) : (windowActive ? t.liftActive : t.liftInactive)
        vibrancyLift.layer?.backgroundColor = NSColor(white: 1, alpha: lift).cgColor
        vibrancy.material = vibrantDark ? .underWindowBackground : t.material
        vibrancy.state = (t.forceActiveBlur || windowActive) ? .active : .inactive
        vibrancy.appearance = NSAppearance(named: t.darkBlur ? .darkAqua : .aqua)
    }
    var statusVisible = false
    var findVisible = false
    var toastCount = 0
    private var trackingArea: NSTrackingArea?

    init(frame: NSRect, background: SpaceBackground, sidebar: AnyView, toolbar: AnyView, placeholder: AnyView, status: AnyView, toasts: AnyView, find: AnyView) {
        backgroundHost = NSHostingView(rootView: background)
        sidebarHost = NSHostingView(rootView: sidebar)
        toolbarHost = NSHostingView(rootView: toolbar)
        placeholderHost = NSHostingView(rootView: placeholder)
        statusHost = NSHostingView(rootView: status)
        toastHost = NSHostingView(rootView: toasts)
        findHost = NSHostingView(rootView: find)
        super.init(frame: frame)
        wantsLayer = true

        vibrancy.blendingMode = .behindWindow
        vibrancy.material = .underWindowBackground
        vibrancy.state = .active
        vibrancy.isHidden = true
        addSubview(vibrancy)
        vibrancyLift.wantsLayer = true
        vibrancyLift.layer?.backgroundColor = NSColor(white: 1, alpha: 0.15).cgColor
        vibrancyLift.isHidden = true
        addSubview(vibrancyLift)
        addSubview(backgroundHost)
        contentContainer.wantsLayer = true
        contentContainer.layer?.cornerRadius = CraMetrics.contentCornerRadius
        contentContainer.layer?.cornerCurve = .continuous
        contentContainer.layer?.masksToBounds = true
        contentContainer.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(contentContainer)
        toolbarHost.sizingOptions = []
        contentContainer.addSubview(toolbarHost)
        webContainer.wantsLayer = true
        webContainer.autoresizesSubviews = false
        contentContainer.addSubview(webContainer)
        devToolsHost.wantsLayer = true
        devToolsHost.layer?.backgroundColor = NSColor.white.cgColor
        devToolsHost.isHidden = true
        contentContainer.addSubview(devToolsHost)
        devToolsDivider.wantsLayer = true
        devToolsDivider.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.12).cgColor
        devToolsDivider.isHidden = true
        contentContainer.addSubview(devToolsDivider)
        devToolsHandle.isHidden = true
        devToolsHandle.onDrag = { [weak self] dx in
            guard let self else { return }
            self.devToolsWidth = min(max(320, self.devToolsWidth - dx), self.contentContainer.bounds.width * 0.7)
            self.layoutSubtreeIfNeeded()
        }
        contentContainer.addSubview(devToolsHandle)
        webContainer.addSubview(placeholderHost)
        for h in [statusHost, toastHost, findHost] {
            h.sizingOptions = []
            h.isHidden = true
            webContainer.addSubview(h)
        }
        sidebarHost.sizingOptions = []
        sidebarHost.wantsLayer = true
        sidebarHost.layer?.cornerCurve = .continuous
        addSubview(sidebarHost)
        addSubview(resizeHandle)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingArea { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        trackingArea = t
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let p = convert(event.locationInWindow, from: nil)
        let overTitleRow = (sidebarVisible || floatingSidebar) && !contentFullscreen
            && p.x < sidebarWidth && p.y > bounds.height - CraMetrics.titleAreaHeight
        (window as? CraWindow)?.trafficLightsRevealed = overTitleRow
        guard !sidebarVisible, !contentFullscreen else { return }
        if !floatingSidebar, p.x <= 2 {
            onEdgeHover?(true)
        } else if floatingSidebar, p.x > sidebarWidth + 24 {
            onEdgeHover?(false)
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        (window as? CraWindow)?.trafficLightsRevealed = false
        if floatingSidebar { onEdgeHover?(false) }
    }

    struct Frames {
        var sidebar: NSRect
        var handle: NSRect
        var content: NSRect
        var cornerRadius: CGFloat
        var sidebarCorner: CGFloat
    }

    func frames(sidebarVisible: Bool, floating: Bool, fullscreen: Bool, width: CGFloat) -> Frames {
        let b = bounds
        if fullscreen {
            return Frames(sidebar: NSRect(x: -width, y: 0, width: width, height: b.height),
                          handle: .zero, content: b, cornerRadius: 0, sidebarCorner: 0)
        }
        if sidebarVisible {
            let inset = CraMetrics.contentInset
            let content = NSRect(x: width, y: inset, width: max(0, b.width - width - inset), height: max(0, b.height - 2 * inset))
            return Frames(sidebar: NSRect(x: 0, y: 0, width: width, height: b.height),
                          handle: NSRect(x: width - 4, y: 0, width: 8, height: b.height),
                          content: content, cornerRadius: CraMetrics.contentCornerRadius, sidebarCorner: 0)
        }
        if floating {
            let m: CGFloat = 8
            return Frames(sidebar: NSRect(x: m, y: m, width: width, height: b.height - 2 * m),
                          handle: .zero, content: NSRect(x: 0, y: 0, width: b.width, height: b.height), cornerRadius: 0, sidebarCorner: 12)
        }
        return Frames(sidebar: NSRect(x: -width - 20, y: 0, width: width, height: b.height),
                      handle: .zero, content: b, cornerRadius: 0, sidebarCorner: 0)
    }

    override func layout() {
        super.layout()
        vibrancy.frame = bounds
        vibrancyLift.frame = bounds
        backgroundHost.frame = bounds
        if animatingFrames { layoutContentChildren(); return }
        let f = frames(sidebarVisible: sidebarVisible, floating: floatingSidebar, fullscreen: contentFullscreen, width: sidebarWidth)
        apply(f)
    }

    func apply(_ f: Frames) {
        sidebarHost.frame = f.sidebar
        resizeHandle.frame = f.handle
        resizeHandle.isHidden = f.handle.isEmpty
        contentContainer.frame = f.content
        contentContainer.layer?.cornerRadius = f.cornerRadius
        sidebarHost.layer?.cornerRadius = f.sidebarCorner
        if f.sidebarCorner > 0 {
            sidebarHost.shadow = NSShadow()
            sidebarHost.shadow?.shadowBlurRadius = 24
            sidebarHost.shadow?.shadowOffset = NSSize(width: 0, height: -6)
            sidebarHost.shadow?.shadowColor = NSColor.black.withAlphaComponent(0.3)
        } else {
            sidebarHost.shadow = nil
        }
        layoutContentChildren()
    }

    func layoutContentChildren() {
        let cb = contentContainer.bounds
        let toolbarH: CGFloat = (showToolbar && !contentFullscreen) ? CraMetrics.toolbarHeight : 0
        toolbarHost.isHidden = toolbarH == 0
        toolbarHost.frame = NSRect(x: 0, y: cb.height - toolbarH, width: cb.width, height: toolbarH)
        let bodyH = max(0, cb.height - toolbarH)
        let showDev = devToolsVisible && cb.width > 640
        let devW: CGFloat = showDev ? min(max(320, devToolsWidth), cb.width * 0.7) : 0
        webContainer.frame = NSRect(x: 0, y: 0, width: cb.width - devW, height: bodyH)
        devToolsHost.isHidden = !showDev
        devToolsDivider.isHidden = !showDev
        devToolsHandle.isHidden = !showDev
        devToolsHost.frame = NSRect(x: cb.width - devW, y: 0, width: devW, height: bodyH)
        devToolsDivider.frame = NSRect(x: cb.width - devW, y: 0, width: 1, height: bodyH)
        devToolsHandle.frame = NSRect(x: cb.width - devW - 3, y: 0, width: 7, height: bodyH)
        for sub in devToolsHost.subviews { sub.frame = devToolsHost.bounds }
        if showDev { onDevToolsFrame?(contentContainer.convert(devToolsHost.frame, to: nil)) }
        // The white page card only exists while a tab is showing.
        contentContainer.layer?.backgroundColor = NSColor.clear.cgColor
        webContainer.layer?.backgroundColor = (hasTab ? NSColor.white : NSColor.clear).cgColor
        let wb = webContainer.bounds
        // Chromium views are added after the overlays; keep overlays on top.
        for h in [statusHost, toastHost, findHost] where webContainer.subviews.last !== h {
            webContainer.addSubview(h, positioned: .above, relativeTo: nil)
        }
        placeholderHost.frame = wb
        let chromiumBounds = frozenWebBounds ?? wb
        for sub in webContainer.subviews where sub !== placeholderHost && sub !== statusHost && sub !== toastHost && sub !== findHost {
            if sub.frame != chromiumBounds { sub.frame = chromiumBounds }
        }
        statusHost.isHidden = !statusVisible
        statusHost.frame = NSRect(x: 0, y: 0, width: min(540, wb.width), height: 34)
        toastHost.isHidden = toastCount == 0
        toastHost.frame = NSRect(x: wb.width - 330, y: 0, width: 330, height: CGFloat(toastCount) * 76 + 20)
        findHost.isHidden = !findVisible
        findHost.frame = NSRect(x: wb.width - 360, y: wb.height - 60, width: 360, height: 60)
    }

    /// Animate between sidebar states by interpolating frames.
    func animateSidebar(visible: Bool, floating: Bool, fullscreen: Bool, width: CGFloat, duration: TimeInterval = 0.22) {
        let target = frames(sidebarVisible: visible, floating: floating, fullscreen: fullscreen, width: width)
        // Size the page for its destination once, up front; the card then just slides over it.
        let toolbarH: CGFloat = (showToolbar && !fullscreen) ? CraMetrics.toolbarHeight : 0
        let devW: CGFloat = devToolsVisible && target.content.width > 640 ? min(max(320, devToolsWidth), target.content.width * 0.7) : 0
        frozenWebBounds = NSRect(x: 0, y: 0, width: target.content.width - devW, height: max(0, target.content.height - toolbarH))
        layoutContentChildren()
        animatingFrames = true
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = duration
            // Fast start, soft landing: feels immediate without a visible snap.
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.85, 0.25, 1)
            ctx.allowsImplicitAnimation = true
            sidebarHost.animator().frame = target.sidebar
            contentContainer.animator().frame = target.content
            contentContainer.layer?.cornerRadius = target.cornerRadius
        } completionHandler: { [weak self] in
            guard let self else { return }
            self.animatingFrames = false
            self.frozenWebBounds = nil
            self.sidebarVisible = visible
            self.floatingSidebar = floating
            self.contentFullscreen = fullscreen
            self.needsLayout = true
            self.layoutSubtreeIfNeeded()
        }
    }
}

/// Thin vertical strip between sidebar and content that drags the width.
final class ResizeHandleView: NSView {
    var onDrag: ((CGFloat) -> Void)?
    var onEnd: (() -> Void)?
    private var lastX: CGFloat = 0

    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func mouseDown(with event: NSEvent) { lastX = event.locationInWindow.x }
    override func mouseDragged(with event: NSEvent) {
        let x = event.locationInWindow.x
        onDrag?(x - lastX)
        lastX = x
    }
    override func mouseUp(with event: NSEvent) { onEnd?() }
}


/// Thin vertical grab area on the DevTools divider.
final class DevToolsResizeHandle: NSView {
    var onDrag: ((CGFloat) -> Void)?
    override func resetCursorRects() { addCursorRect(bounds, cursor: .resizeLeftRight) }
    override func mouseDragged(with event: NSEvent) { onDrag?(event.deltaX) }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(convert(point, from: superview)) ? self : nil }
}
