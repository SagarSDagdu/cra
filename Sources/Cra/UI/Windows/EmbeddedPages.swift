import AppKit
import ObjectiveC

/// Experimental: Chromium's page view lives in the pane card instead of its own child window,
/// the way Arc and Dia host pages. One window and one Core Animation tree, so the page moves,
/// resizes and animates with the card, and clicks and keys reach it without making another
/// window key.
///
/// CEF 156 only makes Chrome-style browsers (extensions, Chrome's DevTools) inside its own
/// window, so that window stays: empty, click-through, never key, laid over the card as
/// before so Chromium's menus, popups and layout still have the right screen position. Its
/// page view (WebContentsViewCocoa) moves into the card's web area.
///
/// On with `defaults write dk.kildahl.cra embedPages -bool YES` or CRA_EMBED_PAGES=1.
enum EmbeddedPages {
    static let isEnabled = ProcessInfo.processInfo.environment["CRA_EMBED_PAGES"] == "1"
        || UserDefaults.standard.bool(forKey: "embedPages")

    /// Chrome windows whose page moved out: they must never become key or main, or keys
    /// would go to a window with nothing in it (Chromium activates its window on focus).
    private static let hosts = NSHashTable<NSWindow>.weakObjects()
    private static var patched = false

    static func markHost(_ window: NSWindow) {
        patch(window)
        hosts.add(window)
        // Its views moved out and it is clear and borderless, so it shows nothing. It keeps
        // alpha 1: Chrome pops page context menus up from it, and an alpha 0 window gets none.
        window.ignoresMouseEvents = true
    }

    /// The page went back into its window (DevTools docked in it).
    static func unmarkHost(_ window: NSWindow) {
        guard hosts.contains(window) else { return }
        hosts.remove(window)
        window.ignoresMouseEvents = false
    }

    static func isHost(_ window: NSWindow?) -> Bool { window.map { hosts.contains($0) } ?? false }

    /// What moves, by Chrome window, wherever the views are now (any window's card, or none
    /// while the tab is hidden), so a tab moving to another Cra window still finds its page.
    /// Chromium draws the page with the window's compositor, whose layers live in
    /// ViewsCompositorSuperview; WebContentsViewCocoa on top of it only takes input. Both move,
    /// in that order.
    private static let pages = NSMapTable<NSWindow, NSArray>.weakToStrongObjects()

    static func pageViews(of window: NSWindow) -> [NSView]? {
        if let views = pages.object(forKey: window) as? [NSView] { return views }
        guard let cv = window.contentView, let page = webContentsView(in: cv),
              let compositor = find("ViewsCompositorSuperview", in: cv) else { return nil }
        let views = [compositor, page]
        pages.setObject(views as NSArray, forKey: window)
        return views
    }

    static func webContentsView(in root: NSView) -> NSView? { find("WebContentsViewCocoa", in: root) }
    static func renderView(in root: NSView) -> NSView? { find("RenderWidgetHostViewCocoa", in: root) }

    private static func find(_ className: String, in root: NSView) -> NSView? {
        if NSStringFromClass(type(of: root)) == className { return root }
        for v in root.subviews { if let found = find(className, in: v) { return found } }
        return nil
    }

    private typealias BoolIMP = @convention(c) (AnyObject, Selector) -> Bool

    private static func patch(_ window: NSWindow) {
        guard !patched else { return }
        patched = true
        let cls: AnyClass = type(of: window)
        for name in ["canBecomeKeyWindow", "canBecomeMainWindow"] {
            let sel = NSSelectorFromString(name)
            guard let method = class_getInstanceMethod(cls, sel) else { continue }
            let original = unsafeBitCast(method_getImplementation(method), to: BoolIMP.self)
            let block: @convention(block) (AnyObject) -> Bool = { obj in
                if let w = obj as? NSWindow, MainActor.assumeIsolated({ hosts.contains(w) }) { return false }
                return original(obj, sel)
            }
            method_setImplementation(method, imp_implementationWithBlock(block))
        }
    }
}
