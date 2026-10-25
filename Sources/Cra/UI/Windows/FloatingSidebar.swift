import AppKit
import SwiftUI

/// Arc's floating sidebar: with the sidebar hidden, touching the window's left
/// edge slides the sidebar in over the page; it leaves when the pointer does.
///
/// Pages are separate Chromium child windows stacked above the shell, so a
/// sidebar drawn inside the shell would be covered and the shell never sees the
/// pointer over a page. The sidebar therefore moves into its own child panel
/// (above the page windows) while it floats, and a pointer monitor that sees
/// events in every window of the app decides when it comes and goes.
@MainActor
final class FloatingSidebarController {
    unowned let shell: ShellView
    unowned let window: NSWindow
    /// Whether the anchored sidebar is hidden right now (floating only makes sense then).
    var sidebarHidden: () -> Bool = { false }
    var palette: () -> SpacePalette
    /// Called after the panel is attached so the overlay panel can be re-ordered above it.
    var didAttachPanel: (() -> Void)?

    private(set) var isShown = false
    private var panel: FloatingSidebarPanel?
    private let blur = NSVisualEffectView()
    private let lift = NSView()
    private var gradientHost: NSHostingView<SpaceBackground>?

    enum Metrics {
        static let edge: CGFloat = 2
        static let leaveSlack: CGFloat = 24
        static let cornerRadius: CGFloat = 12
        static let margin: CGFloat = 8
        static let duration: TimeInterval = 0.085
    }

    init(shell: ShellView, window: NSWindow, palette: @escaping () -> SpacePalette) {
        self.shell = shell
        self.window = window
        self.palette = palette
    }

    deinit {
        poll?.invalidate()
    }

    private var poll: Timer?

    /// No window of ours reliably receives mouse-moved events here: the key window
    /// is usually a Chromium page window, and the shell's tracking areas only run in
    /// the key window. So the pointer is sampled on a timer while the app is active.
    func install() {
        guard poll == nil else { return }
        poll = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pointerMoved() }
        }
        poll?.tolerance = 0.01
    }

    private func pointerMoved() {
        guard NSApp.isActive, !shell.contentFullscreen, window.isVisible else { return }
        guard isShown || sidebarHidden() else { return }
        let screenPoint = NSEvent.mouseLocation
        let inWindow = window.frame.contains(screenPoint)
        let p = window.convertPoint(fromScreen: screenPoint)
        if !isShown {
            guard sidebarHidden(), inWindow, p.x <= Metrics.edge else { return }
            show()
        } else if !inWindow || p.x > shell.sidebarWidth + Metrics.margin + Metrics.leaveSlack {
            hide(animated: true)
        }
    }

    /// The sidebar's floating frame on screen, from the shell's layout.
    private var targetFrame: NSRect {
        let f = shell.frames(sidebarVisible: false, floating: true, fullscreen: false, width: shell.sidebarWidth).sidebar
        return window.convertToScreen(shell.convert(f, to: nil))
    }

    private func makePanel() -> FloatingSidebarPanel {
        let p = FloatingSidebarPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 600),
                                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isMovable = false
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        let content = NSView(frame: p.contentRect(forFrameRect: p.frame))
        content.wantsLayer = true
        content.layer?.cornerRadius = Metrics.cornerRadius
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        p.contentView = content
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]
        content.addSubview(blur)
        lift.wantsLayer = true
        lift.autoresizingMask = [.width, .height]
        content.addSubview(lift)
        let g = NSHostingView(rootView: SpaceBackground(palette: palette()))
        g.sizingOptions = []
        g.autoresizingMask = [.width, .height]
        content.addSubview(g)
        gradientHost = g
        return p
    }

    private func refreshBackdrop() {
        guard let content = panel?.contentView else { return }
        let pal = palette()
        let t = CraTuning.shared
        for v in [blur, lift, gradientHost as NSView?].compactMap({ $0 }) { v.frame = content.bounds }
        gradientHost?.rootView = SpaceBackground(palette: pal)
        blur.isHidden = !pal.vibrant
        lift.isHidden = !pal.vibrant
        blur.material = pal.isDark ? .underWindowBackground : t.material
        blur.appearance = NSAppearance(named: t.darkBlur ? .darkAqua : .aqua)
        lift.layer?.backgroundColor = NSColor(white: 1, alpha: pal.isDark ? 0.15 : t.liftActive).cgColor
    }

    func show() {
        guard !isShown, sidebarHidden() else { return }
        isShown = true
        let p = panel ?? makePanel()
        panel = p
        let target = targetFrame
        p.setFrame(target.offsetBy(dx: -target.width - 20, dy: 0), display: false)
        refreshBackdrop()
        let host = shell.sidebarHost
        host.removeFromSuperview()
        host.frame = p.contentView!.bounds
        host.autoresizingMask = [.width, .height]
        host.layer?.cornerRadius = 0
        p.contentView!.addSubview(host)
        shell.sidebarDetached = true
        shell.floatingSidebar = true
        if p.parent !== window { window.addChildWindow(p, ordered: .above) }
        didAttachPanel?()
        p.orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Metrics.duration
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.15, 0.7, 0.3, 1)
            p.animator().setFrame(target, display: true)
        }
    }

    func hide(animated: Bool) {
        guard isShown, let p = panel else { return }
        isShown = false
        let finish = { [weak self] in
            guard let self else { return }
            self.window.removeChildWindow(p)
            p.orderOut(nil)
            self.reattach(floating: false)
        }
        guard animated else { finish(); return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = Metrics.duration
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.15, 0.7, 0.3, 1)
            p.animator().setFrame(p.frame.offsetBy(dx: -p.frame.width - 20, dy: 0), display: true)
        } completionHandler: { finish() }
    }

    /// The sidebar is about to be anchored (⌘S while floating): put it back in the
    /// shell at its floating frame so the anchoring animation starts from there.
    func prepareForAnchoring() {
        guard isShown, let p = panel else { return }
        isShown = false
        window.removeChildWindow(p)
        p.orderOut(nil)
        reattach(floating: true)
    }

    private func reattach(floating: Bool) {
        let host = shell.sidebarHost
        host.removeFromSuperview()
        host.autoresizingMask = []
        shell.addSubview(host, positioned: .below, relativeTo: shell.resizeHandle)
        shell.sidebarDetached = false
        shell.floatingSidebar = floating
        shell.needsLayout = true
        shell.layoutSubtreeIfNeeded()
    }

    /// Window moved or resized while floating.
    func reposition() {
        guard isShown, let p = panel else { return }
        p.setFrame(targetFrame, display: true)
    }
}

final class FloatingSidebarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
