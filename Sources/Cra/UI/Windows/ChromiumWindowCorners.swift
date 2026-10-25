import AppKit
import ObjectiveC

/// Chromium's page and DevTools windows use a frame view derived from NSThemeFrame, so
/// macOS clips them to its window corner radius (about 18 pt on macOS 26) even when they
/// are borderless. Docked inside Cra's card they must be square; the card's own rounded
/// bottom corners come from the content layer's mask. This overrides the frame view's
/// corner queries for windows registered here only; every other window keeps the system
/// behaviour.
@MainActor
enum ChromiumWindowCorners {
    private static let squared = NSHashTable<NSWindow>.weakObjects()
    private static var patchedClasses = Set<ObjectIdentifier>()

    static func setSquare(_ square: Bool, for window: NSWindow) {
        guard let frameView = window.contentView?.superview else { return }
        patch(type(of: frameView))
        let changed = squared.contains(window) != square
        if square { squared.add(window) } else { squared.remove(window) }
        guard changed else { return }
        let refresh = NSSelectorFromString("_cornerMaskChanged")
        if window.responds(to: refresh) { window.perform(refresh) }
        frameView.needsDisplay = true
        window.invalidateShadow()
    }

    static func isSquare(_ view: AnyObject) -> Bool {
        guard let v = view as? NSView, let w = v.window else { return false }
        return squared.contains(w)
    }

    private static func patch(_ cls: AnyClass) {
        let id = ObjectIdentifier(cls)
        guard !patchedClasses.contains(id) else { return }
        patchedClasses.insert(id)
        overrideBool(cls, "_shouldRoundCornersForSurface", squareValue: false)
        overrideBool(cls, "topCornerRounded", squareValue: false)
        overrideBool(cls, "bottomCornerRounded", squareValue: false)
        overrideFloat(cls, "_cornerRadius", squareValue: 0)
        overrideFloat(cls, "_getCachedWindowCornerRadius", squareValue: 0)
    }

    private typealias BoolIMP = @convention(c) (AnyObject, Selector) -> Bool
    private typealias FloatIMP = @convention(c) (AnyObject, Selector) -> CGFloat

    private static func overrideBool(_ cls: AnyClass, _ name: String, squareValue: Bool) {
        let sel = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(cls, sel), let types = method_getTypeEncoding(method) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: BoolIMP.self)
        let block: @convention(block) (AnyObject) -> Bool = { obj in
            MainActor.assumeIsolated { isSquare(obj) } ? squareValue : original(obj, sel)
        }
        let imp = imp_implementationWithBlock(block)
        // Add on the subclass when it only inherits the method, else replace its own.
        if !class_addMethod(cls, sel, imp, types) { method_setImplementation(method, imp) }
    }

    private static func overrideFloat(_ cls: AnyClass, _ name: String, squareValue: CGFloat) {
        let sel = NSSelectorFromString(name)
        guard let method = class_getInstanceMethod(cls, sel), let types = method_getTypeEncoding(method) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: FloatIMP.self)
        let block: @convention(block) (AnyObject) -> CGFloat = { obj in
            MainActor.assumeIsolated { isSquare(obj) } ? squareValue : original(obj, sel)
        }
        let imp = imp_implementationWithBlock(block)
        if !class_addMethod(cls, sel, imp, types) { method_setImplementation(method, imp) }
    }
}
