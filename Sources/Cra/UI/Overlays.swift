import AppKit
import Observation

struct DownloadToast: Identifiable, Equatable {
    let id: UInt32
    var name: String
    var percent: Int
    var state: Int
    var path: String
    var totalBytes: Int64 = -1
    /// When Chromium last reported on it (see MainWindowController.checkStalledDownloads).
    var updated = Date()
}

/// Overlay state shown on top of the web content: link status, find bar,
/// download toasts.
@MainActor
@Observable
final class OverlayState {
    var status = ""
    var findVisible = false
    var findQuery = ""
    var findFocusToken = 0
    /// Find in page results ("2/7" in the bar); nil until the page answers.
    var findMatchCount: Int?
    var findActiveMatch = 0
    var toasts: [DownloadToast] = []
}

/// The link under the pointer, bottom left over the page. AppKit: it changes on every link the
/// pointer crosses.
final class StatusBubbleView: NSView {
    private let overlay: OverlayState
    private let bubble = NSVisualEffectView()
    private let label = NSTextField.sidebarLabel(size: 11)

    init(overlay: OverlayState) {
        self.overlay = overlay
        super.init(frame: .zero)
        bubble.material = .popover
        bubble.blendingMode = .withinWindow
        bubble.state = .active
        bubble.wantsLayer = true
        bubble.layer?.cornerRadius = 6
        bubble.layer?.cornerCurve = .continuous
        bubble.layer?.masksToBounds = true
        bubble.layer?.borderWidth = 1
        label.lineBreakMode = .byTruncatingMiddle
        label.textColor = .labelColor
        // SwiftUI's .thinMaterial is lighter than any AppKit material: the popover material at
        // about four fifths matches it over Cra's pages; the text stays on top at full strength.
        bubble.alphaValue = 0.81
        addSubview(bubble)
        addSubview(label)
        observe()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private func observe() {
        let text = withObservationTracking { overlay.status } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        label.stringValue = text
        bubble.isHidden = text.isEmpty
        label.isHidden = text.isEmpty
        needsLayout = true
    }

    override func layout() {
        super.layout()
        bubble.layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.1).cgColor
        let s = label.attributedStringValue.size()
        let w = min(ceil(s.width) + 16, max(0, bounds.width - 12))
        let h = ceil(s.height) + 8
        bubble.frame = NSRect(x: 6, y: 6, width: w, height: h)
        label.frame = NSRect(x: 6 + 8 - SidebarText.inset, y: 6 + (h - ceil(s.height)) / 2, width: w - 16 + 2 * SidebarText.inset, height: ceil(s.height))
    }
}

/// Find in page, top trailing over the page: glyph, field, "2/7", previous, next, close.
final class FindBarView: NSView, NSTextFieldDelegate {
    private let overlay: OverlayState
    private let onFind: (String, Bool) -> Void   // query, forward
    private let onClose: () -> Void
    private let card = MaterialCardView(radius: 10)
    private let glyph = NSImageView()
    private let field = NSTextField()
    private let count = NSTextField.sidebarLabel(size: 11)
    private var buttons: [ClosureButton] = []
    private var lastQuery = ""
    private var lastFocusToken = 0
    private var wasVisible = false

    init(overlay: OverlayState, onFind: @escaping (String, Bool) -> Void, onClose: @escaping () -> Void) {
        self.overlay = overlay
        self.onFind = onFind
        self.onClose = onClose
        super.init(frame: .zero)
        addSubview(card)
        glyph.image = SidebarSymbols.image("magnifyingglass", size: 13)
        glyph.contentTintColor = .secondaryLabelColor
        glyph.imageScaling = .scaleNone
        addSubview(glyph)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.placeholderString = "Find in page"
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = self
        addSubview(field)
        count.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        count.textColor = .secondaryLabelColor
        addSubview(count)
        for (symbol, run) in [("chevron.up", { [weak self] in self.map { $0.onFind($0.overlay.findQuery, false) } }),
                              ("chevron.down", { [weak self] in self.map { $0.onFind($0.overlay.findQuery, true) } }),
                              ("xmark", { [weak self] in self?.onClose() })] as [(String, () -> Void)] {
            let b = ClosureButton(symbol: symbol, size: 13, onPress: run)
            buttons.append(b)
            addSubview(b)
        }
        observe()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func observe() {
        let (visible, query, matches, active, token) = withObservationTracking {
            (overlay.findVisible, overlay.findQuery, overlay.findMatchCount, overlay.findActiveMatch, overlay.findFocusToken)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        for v in subviews { v.isHidden = !visible }
        if field.stringValue != query { field.stringValue = query }
        // Like SwiftUI's .onChange on the query: every change, typed or set, searches.
        if visible, query != lastQuery { onFind(query, true) }
        lastQuery = query
        if let matches, !query.isEmpty {
            count.stringValue = "\(matches == 0 ? 0 : active)/\(matches)"
            count.isHidden = !visible
        } else {
            count.stringValue = ""
            count.isHidden = true
        }
        if visible, !wasVisible || token != lastFocusToken { window?.makeFirstResponder(field) }
        wasVisible = visible
        lastFocusToken = token
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if overlay.findVisible { window?.makeFirstResponder(field) }
    }

    func controlTextDidChange(_ obj: Notification) {
        overlay.findQuery = field.stringValue
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onFind(overlay.findQuery, !(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false))
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            onClose()
            return true
        default:
            return false
        }
    }

    override func layout() {
        super.layout()
        card.frame = bounds
        let h = bounds.height
        // padding 10, glyph, 6, field (flexible), 6, count, 6, ▲, 6, ▼, 6, ✕, padding 10.
        var x = bounds.width - 10
        for b in buttons.reversed() {
            let s = b.image?.size ?? .zero
            b.frame = NSRect(x: x - s.width, y: (h - s.height) / 2, width: s.width, height: s.height)
            x -= s.width + 6
        }
        if !count.isHidden {
            let w = ceil(count.attributedStringValue.size().width)
            count.frame = NSRect(x: x - w - SidebarText.inset, y: (h - 14) / 2, width: w + 2 * SidebarText.inset, height: 14)
            x -= w + 6
        }
        let gw = glyph.image?.size.width ?? 14
        glyph.frame = NSRect(x: 10, y: 0, width: gw, height: h)
        let fx = 10 + gw + 6
        let fh = ceil(field.intrinsicContentSize.height)
        field.frame = NSRect(x: fx - SidebarText.inset, y: (h - fh) / 2, width: max(0, x - fx + 2 * SidebarText.inset), height: fh)
    }
}

/// The find bar's own window, just the bar's size, over the page windows. The
/// page-sized overlay panel can't take key and would swallow every click on the page.
final class FindBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: CraMetrics.findBarSize),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
    }
}

/// Download toasts, bottom trailing over the page, newest at the bottom.
final class ToastStackView: NSView {
    private let overlay: OverlayState
    private let onDismiss: (UInt32) -> Void
    private var rows: [UInt32: ToastRowView] = [:]
    private var order: [UInt32] = []

    static let rowSize = NSSize(width: 300, height: 52)

    init(overlay: OverlayState, onDismiss: @escaping (UInt32) -> Void) {
        self.overlay = overlay
        self.onDismiss = onDismiss
        super.init(frame: .zero)
        observe()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func observe() {
        let toasts = withObservationTracking { overlay.toasts } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        let ids = Set(toasts.map(\.id))
        for (id, r) in rows where !ids.contains(id) { r.removeFromSuperview(); rows[id] = nil }
        for t in toasts {
            let r = rows[t.id] ?? {
                let r = ToastRowView { [weak self] in self?.onDismiss(t.id) }
                rows[t.id] = r
                addSubview(r)
                return r
            }()
            r.show(t)
        }
        order = toasts.map(\.id)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // VStack(spacing: 6) inside padding 10, pinned bottom trailing.
        var y: CGFloat = 10
        for id in order.reversed() {
            guard let r = rows[id] else { continue }
            r.frame = NSRect(x: bounds.width - 10 - Self.rowSize.width, y: y, width: Self.rowSize.width, height: Self.rowSize.height)
            y += Self.rowSize.height + 6
        }
    }
}

private final class ToastRowView: NSView {
    private let card = MaterialCardView(radius: 10)
    private let icon = NSImageView()
    private let name = NSTextField.sidebarLabel(size: 12, weight: .medium)
    private let detail = NSTextField.sidebarLabel(size: 11)
    private let progress = NSProgressIndicator()
    private let show = ClosureButton(title: "Show", controlSize: .small) {}
    private let close: ClosureButton
    private var path = ""

    init(onDismiss: @escaping () -> Void) {
        // Hides the toast only; the download carries on (the Library still has it).
        close = ClosureButton(symbol: "xmark", size: 9, weight: .semibold, tint: .secondaryLabelColor, onPress: onDismiss)
        super.init(frame: .zero)
        addSubview(card)
        icon.imageScaling = .scaleNone
        addSubview(icon)
        addSubview(name)
        detail.textColor = .secondaryLabelColor
        addSubview(detail)
        progress.style = .bar
        progress.controlSize = .small
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = 100
        addSubview(progress)
        show.onPress = { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: self.path)])
        }
        addSubview(show)
        addSubview(close)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(_ t: DownloadToast) {
        path = t.path
        icon.image = SidebarSymbols.image(t.state == 1 ? "checkmark.circle.fill" : (t.state == 0 ? "arrow.down.circle" : "exclamationmark.circle"), size: 13)
        icon.contentTintColor = t.state == 1 ? .systemGreen : .secondaryLabelColor
        name.stringValue = t.name
        progress.isHidden = t.state != 0
        progress.doubleValue = Double(max(0, t.percent))
        detail.isHidden = t.state == 0
        detail.stringValue = t.state == 1 ? "Downloaded" : (t.state == 2 ? "Cancelled" : "Failed")
        show.isHidden = t.state != 1
        needsLayout = true
    }

    override func layout() {
        super.layout()
        card.frame = bounds
        let h = bounds.height
        // padding 10: icon, 10, name over status (flexible), 10, Show, 10, ✕ 16×16, padding 10.
        var x = bounds.width - 10 - 16
        close.frame = NSRect(x: x, y: (h - 16) / 2, width: 16, height: 16)
        if !show.isHidden {
            let s = show.fittingSize
            x -= 10 + s.width
            show.frame = NSRect(x: x, y: (h - s.height) / 2, width: s.width, height: s.height)
        }
        let iw = icon.image?.size.width ?? 15
        icon.frame = NSRect(x: 10, y: 0, width: iw, height: h)
        let tx = 10 + iw + 10, tw = max(0, x - 10 - tx)
        name.frame = NSRect(x: tx - SidebarText.inset, y: h / 2 + 1, width: tw + 2 * SidebarText.inset, height: 15)
        detail.frame = NSRect(x: tx - SidebarText.inset, y: h / 2 - 15, width: tw + 2 * SidebarText.inset, height: 14)
        progress.frame = NSRect(x: tx, y: h / 2 - 11, width: tw, height: 6)
    }
}
