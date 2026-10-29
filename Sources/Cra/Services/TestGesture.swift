import AppKit

/// Scripted sidebar scrolls for background test instances (cra://debug?scroll=…): the scroll view
/// under a point of the window moves a step every frame, as under a trackpad's momentum, while
/// the pointer and the front app stay put.
@MainActor
enum TestGesture {
    static func scroll(by dy: CGFloat, steps: Int, at point: NSPoint, in window: NSWindow, interval: TimeInterval = 1.0 / 120) {
        guard let root = window.contentView?.superview,
              let sv = root.hitTest(point)?.enclosingScrollView else { NSLog("Cra TestGesture: no scroll view"); return }
        for i in 1...max(1, steps) {
            DispatchQueue.main.asyncAfter(deadline: .now() + interval * Double(i)) {
                let clip = sv.contentView
                var origin = clip.bounds.origin
                origin.y += dy * (sv.documentView?.isFlipped ?? true ? 1 : -1)
                clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
                sv.reflectScrolledClipView(clip)
            }
        }
    }
}
