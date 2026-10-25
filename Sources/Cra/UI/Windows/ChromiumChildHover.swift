import AppKit
import ObjectiveC

/// Chromium drops mouse moves in a window that is neither main nor key
/// (-[RenderWidgetHostViewCocoa shouldIgnoreMouseEvent:]). Cra docks the page and DevTools
/// as separate child windows of the main window, so only the focused one got hover: no
/// page highlight from the Elements tree while the page had focus, no hover states on the
/// page while DevTools had it. Chrome keeps both in one window. For windows registered
/// here a mouse move counts as foreground while focus is anywhere in their parent window.
@MainActor
enum ChromiumChildHover {
    private static let docked = NSHashTable<NSWindow>.weakObjects()
    private static var patched = false

    static func setDocked(_ isDocked: Bool, for window: NSWindow) {
        patch()
        if isDocked { docked.add(window) } else { docked.remove(window) }
    }

    private static func isForeground(_ view: NSView) -> Bool {
        guard NSApp.isActive, let w = view.window, docked.contains(w), let parent = w.parent else { return false }
        return parent.isKeyWindow || parent.isMainWindow || NSApp.keyWindow?.parent === parent
    }

    private typealias IgnoreIMP = @convention(c) (AnyObject, Selector, NSEvent) -> Bool
    private typealias BoolIMP = @convention(c) (AnyObject, Selector) -> Bool

    private static func patch() {
        guard !patched else { return }
        patched = true
        let sel = NSSelectorFromString("shouldIgnoreMouseEvent:")
        guard let cls = NSClassFromString("RenderWidgetHostViewCocoa"),
              let method = class_getInstanceMethod(cls, sel) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: IgnoreIMP.self)
        let block: @convention(block) (AnyObject, NSEvent) -> Bool = { obj, event in
            guard event.type == .mouseMoved, let view = obj as? NSView,
                  MainActor.assumeIsolated({ isForeground(view) }) else { return original(obj, sel, event) }
            return isCovered(view, at: event.locationInWindow, renderClass: cls)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }

    /// The rest of Chromium's check: ignore the move when the pointer is over a non-web
    /// view or over another render widget in the same window.
    private static func isCovered(_ view: NSView, at point: NSPoint, renderClass: AnyClass) -> Bool {
        let nonWeb = NSSelectorFromString("nonWebContentView")
        var hit = view.window?.contentView?.hitTest(point)
        while let v = hit {
            if let m = class_getInstanceMethod(type(of: v), nonWeb),
               unsafeBitCast(method_getImplementation(m), to: BoolIMP.self)(v, nonWeb) { return true }
            if v.isKind(of: renderClass), v !== view { return true }
            hit = v.superview
        }
        return false
    }
}
