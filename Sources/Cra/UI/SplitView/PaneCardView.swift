import AppKit
import SwiftUI

/// One content pane: Arc's rounded card with its toolbar strip on top and the
/// page below (ARCUI.SplitViewContentPaneView + Arc.WindowContentViewController).
/// A pane without a page (Arc's "Search or Enter URL…" pane) is a translucent
/// tinted card with nothing but the toolbar.
final class PaneCardView: NSView {
    let tabID: UUID
    let toolbarHost: NSHostingView<AnyView>
    /// Where the Chromium view lives (or where the page window is positioned).
    let webArea = NSView()
    /// Hairline under the toolbar when the pane has no page (Arc draws it on the tinted card).
    private let hairline = NSView()
    var showToolbar = true { didSet { needsLayout = true } }
    var toolbarHeight: CGFloat = CraMetrics.toolbarHeight { didSet { needsLayout = true } }
    var cornerRadius: CGFloat = CraMetrics.contentCornerRadius { didSet { layer?.cornerRadius = cornerRadius } }
    /// White page card, or Arc's tinted translucent empty pane.
    var hasPage = true { didSet { refreshBackground() } }
    var isDark = false { didSet { refreshBackground() } }
    /// The page's own background ("#RRGGBB"; white until it reports one). The page window trails
    /// the card by a frame or more while the window is resized quickly; in that gap the
    /// page area must look like the page, not like a white card.
    var pageColor: String? { didSet { refreshBackground() } }
    /// The no-tab stand-in: toolbar on the gradient, no card at all.
    var transparent = false { didSet { refreshBackground() } }
    /// While a pane is being dragged open/closed its page keeps its last size.
    var frozenWebBounds: NSRect?

    init(tabID: UUID, toolbar: AnyView) {
        self.tabID = tabID
        toolbarHost = NSHostingView(rootView: toolbar)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        toolbarHost.sizingOptions = []
        webArea.wantsLayer = true
        webArea.autoresizesSubviews = false
        hairline.wantsLayer = true
        hairline.isHidden = true
        addSubview(webArea)
        addSubview(hairline)
        addSubview(toolbarHost)
        refreshBackground()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func refreshBackground() {
        // Measured on Arc 1.170 (Victor theme, 2x): the empty pane is the
        // gradient plus about +9/+11/+12 per channel, i.e. a white veil at ~0.2.
        layer?.backgroundColor = transparent ? NSColor.clear.cgColor : (hasPage ? NSColor.white.cgColor : NSColor(white: 1, alpha: isDark ? 0.08 : 0.2).cgColor)
        let page = pageColor.map { NSColor(Color(hex: $0)) } ?? .white
        webArea.layer?.backgroundColor = (hasPage && !transparent ? page : NSColor.clear).cgColor
        hairline.isHidden = hasPage || transparent || !showToolbar
        hairline.layer?.backgroundColor = NSColor(white: isDark ? 1 : 0, alpha: 0.08).cgColor
    }

    override func layout() {
        super.layout()
        let b = bounds
        let th: CGFloat = showToolbar ? toolbarHeight : 0
        toolbarHost.isHidden = th == 0
        toolbarHost.frame = NSRect(x: 0, y: b.height - th, width: b.width, height: th)
        hairline.frame = NSRect(x: 0, y: b.height - th - 1, width: b.width, height: 1)
        hairline.isHidden = hasPage || transparent || th == 0
        webArea.frame = NSRect(x: 0, y: 0, width: b.width, height: max(0, b.height - th))
        let wb = frozenWebBounds ?? webArea.bounds
        for sub in webArea.subviews where sub.frame != wb { sub.frame = wb }
    }
}
