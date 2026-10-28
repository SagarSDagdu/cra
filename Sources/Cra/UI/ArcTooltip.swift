import AppKit
import SwiftUI

/// Arc's hover tips for small controls (ArcTooltip, PresentationBehavior.onMouseIdle).
/// Measured on Arc 1.170's sidebar row buttons (27 Oct 2026, 1x screen recordings): the tip
/// shows once the pointer has rested ~1.6 s, at once when moving from another tip, pops in
/// without a fade, fades out in ~60 ms, and hangs off the bottom-trailing corner of a 16 pt
/// box around the glyph. Clicking the control dismisses it.
@MainActor
final class ArcTooltipController {
    static let shared = ArcTooltipController()

    static let idleDelay: TimeInterval = 1.6
    /// Moving onto another control this soon after a tip closed shows its tip right away.
    static let warmWindow: TimeInterval = 0.5

    private var panel: LittleTooltipPanel?
    private weak var shownFor: (any ArcTooltipTarget)?
    private weak var pendingFor: (any ArcTooltipTarget)?
    private var timer: Timer?
    private var lastHiddenAt = Date.distantPast
    private var clickMonitor: Any?
    private var flagsMonitor: Any?
    /// Anchors under the pointer; a row and its close button both track it, and the
    /// innermost (smallest) one owns the tip (Arc: TooltipController.enteredViewStack).
    private var hovered: [WeakAnchor] = []

    private struct WeakAnchor { weak var view: (any ArcTooltipTarget)? }

    private init() {
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] e in
            self?.dismiss()
            return e
        }
        // Modifier keys keep the tip up (Arc: allowedModifierKeys); ⌥ swaps in the option text.
        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            if let self, let v = self.shownFor, v.optionText != nil { self.show(for: v) }
            return e
        }
    }

    func mouseMoved(in view: any ArcTooltipTarget) {
        if !hovered.contains(where: { $0.view === view }) { hovered.append(WeakAnchor(view: view)) }
        let mouse = NSEvent.mouseLocation
        hovered.removeAll { a in
            guard let v = a.view, v.hostWindow != nil else { return true }
            return !v.screenFrame.contains(mouse)
        }
        guard let target = hovered.compactMap(\.view).min(by: { $0.screenFrame.width * $0.screenFrame.height < $1.screenFrame.width * $1.screenFrame.height }),
              !target.text.isEmpty else {
            if shownFor != nil { hide() }
            cancelPending()
            return
        }
        if shownFor === target { return }
        startTip(for: target)
    }

    private func startTip(for view: any ArcTooltipTarget) {
        if panel != nil || Date().timeIntervalSince(lastHiddenAt) < Self.warmWindow {
            show(for: view)
            return
        }
        // On mouse idle: every move restarts the wait.
        pendingFor = view
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: Self.idleDelay, repeats: false) { [weak self, weak view] _ in
            Task { @MainActor in
                guard let self, let view, self.pendingFor === view else { return }
                self.show(for: view)
            }
        }
    }

    func mouseExited(_ view: any ArcTooltipTarget) {
        hovered.removeAll { $0.view === view || $0.view == nil }
        if pendingFor === view { cancelPending() }
        if shownFor === view { hide() }
        // Leaving a close button for the rest of its row hands the tip back to the row.
        if let outer = hovered.last?.view, outer.hostWindow != nil { mouseMoved(in: outer) }
    }

    /// A click or key press: the next tip waits for the pointer to rest again, so a row that
    /// slides under the pointer after the click doesn't pop its tip.
    func dismiss() {
        cancelPending()
        hide()
        lastHiddenAt = .distantPast
    }

    private func cancelPending() {
        timer?.invalidate()
        timer = nil
        pendingFor = nil
    }

    private func show(for view: any ArcTooltipTarget) {
        cancelPending()
        guard let window = view.hostWindow, !view.text.isEmpty else { return }
        removePanel()
        let p = LittleTooltipPanel()
        let option = NSEvent.modifierFlags.contains(.option) ? view.optionText : nil
        let host = NSHostingView(rootView: ArcTooltipLabel(text: option ?? view.text, keys: option == nil ? view.keys : [],
                                                           subtitle: option == nil ? view.subtitle : nil))
        let size = host.fittingSize
        host.setFrameSize(size)
        p.contentView = host
        // Buttons: off the bottom-trailing corner of a 16 pt box around the glyph.
        // Rows: Arc's .cursor anchor, 13 pt right of and 14 pt below the pointer.
        let r = view.screenFrame
        let mouse = NSEvent.mouseLocation
        let anchor = view.followsCursor ? NSPoint(x: mouse.x + 13, y: mouse.y - 14) : NSPoint(x: r.midX + 8, y: r.midY - 7)
        var origin = NSPoint(x: anchor.x, y: anchor.y - size.height)
        if let screen = window.screen?.visibleFrame {
            origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - size.width - 4)
            if origin.y < screen.minY + 4 { origin.y = (view.followsCursor ? mouse.y : r.midY) + 7 }
        }
        p.setFrame(NSRect(origin: origin, size: size), display: true)
        window.addChildWindow(p, ordered: .above)
        p.orderFront(nil)
        panel = p
        shownFor = view
        view.onShow?()
    }

    private func hide() {
        guard let p = panel else { return }
        panel = nil
        shownFor = nil
        lastHiddenAt = Date()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.06
            p.animator().alphaValue = 0
        }, completionHandler: {
            p.parent?.removeChildWindow(p)
            p.orderOut(nil)
        })
    }

    private func removePanel() {
        guard let p = panel else { return }
        panel = nil
        shownFor = nil
        p.parent?.removeChildWindow(p)
        p.orderOut(nil)
    }
}

/// What a tip belongs to: an AppKit control's anchor view, or a SwiftUI view's hover.
@MainActor
protocol ArcTooltipTarget: AnyObject {
    var text: String { get }
    var keys: [String] { get }
    var followsCursor: Bool { get }
    var subtitle: String? { get }
    var optionText: String? { get }
    var onShow: (() -> Void)? { get }
    var screenFrame: NSRect { get }
    var hostWindow: NSWindow? { get }
}

/// Tracks the pointer over an AppKit control without taking its clicks.
final class ArcTooltipAnchorView: NSView, ArcTooltipTarget {
    var text = ""
    var keys: [String] = []
    var followsCursor = false
    /// A second, dimmer line (Arc's SidebarCellTooltipView subtitle, e.g. "Double-click to rename").
    var subtitle: String?
    /// Shown instead while ⌥ is held (the split close button un-splits on ⌥-click).
    var optionText: String?
    var onShow: (() -> Void)?

    var screenFrame: NSRect { window?.convertToScreen(convert(bounds, to: nil)) ?? .zero }
    var hostWindow: NSWindow? { window }

    /// For AppKit controls: an anchor filling `control`.
    static func attach(to control: NSView, help: String) -> ArcTooltipAnchorView {
        let a = ArcTooltipAnchorView(frame: control.bounds)
        a.autoresizingMask = [.width, .height]
        (a.text, a.keys) = ArcTooltipLabel.split(help)
        control.addSubview(a)
        return a
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        // activeAlways: the key window is usually a Chromium page window, not the sidebar's.
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { MainActor.assumeIsolated { ArcTooltipController.shared.mouseMoved(in: self) } }
    override func mouseMoved(with event: NSEvent) { MainActor.assumeIsolated { ArcTooltipController.shared.mouseMoved(in: self) } }
    override func mouseExited(with event: NSEvent) { MainActor.assumeIsolated { ArcTooltipController.shared.mouseExited(self) } }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        // Row buttons vanish when the row loses hover; their tip goes with them.
        if newWindow == nil { MainActor.assumeIsolated { ArcTooltipController.shared.mouseExited(self) } }
        super.viewWillMove(toWindow: newWindow)
    }
}

/// A SwiftUI view's tip, fed by its hover. No AppKit view per tip: the sidebar has hundreds of
/// rows and buttons across its spaces, and an anchor view in each one had SwiftUI move every
/// one of them, AppKit redo their tracking areas and rebuild its key view loop on every frame
/// of a space swipe or sidebar scroll.
@MainActor
private final class ArcTooltipSource: ArcTooltipTarget {
    var text = ""
    var keys: [String] = []
    var followsCursor = false
    var subtitle: String?
    var optionText: String?
    var onShow: (() -> Void)?
    var size = CGSize.zero
    /// The view's frame on screen, worked out from the last hover: the pointer's screen
    /// position and its position in the view.
    private(set) var screenFrame = NSRect.zero
    private(set) weak var hostWindow: NSWindow?

    /// Called on every pointer move. The window under the pointer is a window server query,
    /// so it is looked up once per visit (`entered`), not per move.
    func hovered(at local: CGPoint, entered: Bool) {
        let mouse = NSEvent.mouseLocation
        // SwiftUI's local y grows downwards, the screen's upwards.
        screenFrame = NSRect(x: mouse.x - local.x, y: mouse.y + local.y - size.height, width: size.width, height: size.height)
        if entered || hostWindow == nil {
            hostWindow = NSApp.window(withWindowNumber: NSWindow.windowNumber(at: mouse, belowWindowWithWindowNumber: 0))
        }
    }

    /// Between the pointer arriving and leaving.
    var isHovered = false
}

private struct ArcTooltipModifier: ViewModifier {
    let text: String
    let keys: [String]
    let followsCursor: Bool
    let subtitle: String?
    let optionText: String?
    let onShow: (() -> Void)?
    @State private var source = ArcTooltipSource()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGSize.self) { $0.size } action: { source.size = $0 }
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let location):
                    source.text = text
                    source.keys = keys
                    source.followsCursor = followsCursor
                    source.subtitle = subtitle
                    source.optionText = optionText
                    source.onShow = onShow
                    source.hovered(at: location, entered: !source.isHovered)
                    source.isHovered = true
                    ArcTooltipController.shared.mouseMoved(in: source)
                case .ended:
                    source.isHovered = false
                    ArcTooltipController.shared.mouseExited(source)
                }
            }
            // Row buttons vanish when the row loses hover; their tip goes with them.
            .onDisappear { ArcTooltipController.shared.mouseExited(source) }
    }
}

extension View {
    /// Arc-style tooltip. A trailing shortcut in parentheses, "Close Tab (⌘W)", becomes key caps.
    /// `followsCursor` places it by the pointer (Arc's sidebar rows and tiles) instead of the control.
    func arcTooltip(_ help: String, followsCursor: Bool = false, subtitle: String? = nil,
                    optionHelp: String? = nil, onShow: (() -> Void)? = nil) -> some View {
        let (text, keys) = ArcTooltipLabel.split(help)
        return modifier(ArcTooltipModifier(text: text, keys: keys, followsCursor: followsCursor, subtitle: subtitle,
                                           optionText: optionHelp, onShow: onShow))
    }
}

/// The tip itself: 28 pt navy capsule, 12 pt medium text, 18 pt key caps with a darker
/// bottom edge (Arc sidebar, 1x captures; Little Arc's larger tip is LittleTooltip).
struct ArcTooltipLabel: View {
    let text: String
    let keys: [String]
    var subtitle: String? = nil

    static let capEdge = Color(red: 119 / 255, green: 122 / 255, blue: 211 / 255)
    static let maxTextWidth: CGFloat = 280

    static func width(of text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]).width
    }

    private var wraps: Bool { Self.width(of: text) > Self.maxTextWidth }

    var body: some View {
        let multiline = wraps || subtitle != nil
        HStack(spacing: 7) {
            VStack(alignment: .leading, spacing: 1) {
                // Long titles wrap at a fixed width (ArcTooltipConfiguration.maxWidth; Arc's value is unknown).
                if wraps {
                    Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(LittlePalette.tooltipText)
                        .lineLimit(3)
                        .frame(width: Self.maxTextWidth, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(text).font(.system(size: 12, weight: .medium)).foregroundStyle(LittlePalette.tooltipText)
                }
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(LittlePalette.tooltipText.opacity(0.6))
                }
            }
            if !keys.isEmpty {
                HStack(spacing: 3) {
                    ForEach(Array(keys.enumerated()), id: \.offset) { _, k in
                        ZStack(alignment: .top) {
                            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Self.capEdge)
                            Text(k)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(LittlePalette.tooltipCapGlyph)
                                .frame(width: 18, height: 16)
                                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(LittlePalette.tooltipCap))
                        }
                        .frame(width: 18, height: 18)
                    }
                }
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, keys.isEmpty ? 10 : 8)
        .padding(.vertical, multiline ? 6 : 0)
        .frame(minHeight: 28)
        // No border: unlike Little Arc's tip, the sidebar one goes straight from fill to backdrop.
        // Two or more lines get a rounded rectangle (Cra's choice; Arc's multi-line tip wasn't observed).
        .background(RoundedRectangle(cornerRadius: multiline ? 10 : 14, style: .circular).fill(LittlePalette.tooltip))
        .fixedSize()
    }

    /// "Copy URL (⇧⌘C)" → ("Copy URL", ["⇧", "⌘", "C"]).
    static func split(_ help: String) -> (String, [String]) {
        guard help.hasSuffix(")"), let open = help.range(of: " (", options: .backwards) else { return (help, []) }
        let shortcut = String(help[open.upperBound..<help.index(before: help.endIndex)])
        let modifiers: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]
        guard let first = shortcut.first, modifiers.contains(first), shortcut.count <= 6 else { return (help, []) }
        var caps = shortcut.prefix { modifiers.contains($0) }.map(String.init)
        let key = shortcut.drop { modifiers.contains($0) }
        if !key.isEmpty { caps.append(String(key)) }
        return (String(help[..<open.lowerBound]), caps)
    }
}
