import AppKit
import ObjectiveC

/// Chromium puts a page into fullscreen by making the page's own window FullScreenPrimary
/// and calling -toggleFullScreen: on it (NativeWidgetNSWindowFullscreenController). Cra
/// docks that window as a child of the browser window, so macOS gave it a fullscreen
/// Space of its own next to the browser window's: every video fullscreen left another
/// empty desktop in Mission Control. For child windows the toggle never reaches AppKit.
/// Chromium gets the will/did enter and exit callbacks AppKit would send, and the parent
/// window goes fullscreen instead (didChangeFullscreen in the window controllers).
@MainActor
enum ChromiumChildFullscreen {
    private static let fullscreen = NSHashTable<NSWindow>.weakObjects()
    private static var patchedClasses = Set<ObjectIdentifier>()

    static func attach(_ window: NSWindow) {
        let cls: AnyClass = type(of: window)
        let id = ObjectIdentifier(cls)
        guard !patchedClasses.contains(id) else { return }
        patchedClasses.insert(id)
        let sel = #selector(NSWindow.toggleFullScreen(_:))
        guard let method = class_getInstanceMethod(cls, sel), let types = method_getTypeEncoding(method) else { return }
        let original = unsafeBitCast(method_getImplementation(method), to: ToggleIMP.self)
        let block: @convention(block) (NSWindow, AnyObject?) -> Void = { w, sender in
            MainActor.assumeIsolated {
                // ⌃⌘F and the View menu reach the key window, which is the page: that means the browser window.
                if let parent = w.parent, sender != nil { return parent.toggleFullScreen(sender) }
                // A page that went fullscreen docked and was undocked since still exits the same way.
                guard w.parent != nil || fullscreen.contains(w) else { return original(w, sel, sender) }
                playTransition(w)
            }
        }
        let imp = imp_implementationWithBlock(block)
        if !class_addMethod(cls, sel, imp, types) { method_setImplementation(method, imp) }
    }

    private typealias ToggleIMP = @convention(c) (NSWindow, Selector, AnyObject?) -> Void

    /// AppKit calls the will-callback inside -toggleFullScreen: and the did-callback once
    /// the animation ends; Chromium's state machine expects that order.
    private static func playTransition(_ w: NSWindow) {
        let entering = !fullscreen.contains(w)
        if entering { fullscreen.add(w) } else { fullscreen.remove(w) }
        send(entering ? "windowWillEnterFullScreen:" : "windowWillExitFullScreen:", entering ? NSWindow.willEnterFullScreenNotification : NSWindow.willExitFullScreenNotification, to: w)
        DispatchQueue.main.async {
            send(entering ? "windowDidEnterFullScreen:" : "windowDidExitFullScreen:", entering ? NSWindow.didEnterFullScreenNotification : NSWindow.didExitFullScreenNotification, to: w)
        }
    }

    private static func send(_ name: String, _ notification: Notification.Name, to w: NSWindow) {
        let sel = NSSelectorFromString(name)
        guard let delegate = w.delegate as? NSObject, delegate.responds(to: sel) else { return }
        delegate.perform(sel, with: Notification(name: notification, object: w))
    }
}
