import AppKit

/// Chrome plays a download-started animation when a download begins: a 64 pt round
/// download glyph that fades in over the page and flies to the toolbar's download button
/// (DownloadBubbleStartedAnimationViews, 500 ms). Cra keeps Chrome's toolbar hidden, so
/// the glyph flies to nothing, and Cra shows its own animation like Arc. Chrome has no
/// switch for it (only reduced motion), so its window is ordered out as soon as it
/// appears: a views popup parented to the page (a child window), created with
/// accept_events = false (ignores the mouse), sized 2 × kIconBackgroundRadius 32.
@MainActor
enum ChromeDownloadAnimation {
    private static let size = NSSize(width: 64, height: 64)
    /// Chrome posts the animation once the toolbar's download button has animated in.
    private static let watchDuration: TimeInterval = 2
    private static var watchUntil = Date.distantPast
    private static var timer: Timer?

    /// Call when a download starts.
    static func suppress() {
        watchUntil = Date().addingTimeInterval(watchDuration)
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
    }

    private static func tick() {
        for w in NSApp.windows where isAnimationWindow(w) && (w.isVisible || w.alphaValue > 0) {
            w.alphaValue = 0
            w.orderOut(nil)
        }
        if Date() >= watchUntil {
            timer?.invalidate()
            timer = nil
        }
    }

    private static func isAnimationWindow(_ w: NSWindow) -> Bool {
        w.parent != nil && w.ignoresMouseEvents && w.frame.size == size
            && NSStringFromClass(type(of: w)).contains("NativeWidgetMac")
    }
}
