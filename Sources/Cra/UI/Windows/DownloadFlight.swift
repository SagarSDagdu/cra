import AppKit
import QuartzCore

/// Arc's download animation (DownloadsUI.DownloadToLibrary: a window over the browser
/// window, a "projectile" icon with g, vx0, vy0, apex and apexTime, and a "bin" at the
/// Library button). Measured on Arc 1.170 at 60 fps, 27 Oct 2026:
/// - the glyph launches from the pointer as the download starts, rises 90 pt to its apex,
///   then falls under g ≈ 2630 pt/s² at a constant horizontal speed onto the Library
///   button (about 1.1 s for a launch from the top of a 1084 pt window);
/// - it is a navy disc with a light ring and a down arrow, 32 pt at launch, 48 pt at the
///   apex, shrinking linearly to 10 pt on arrival; it fades in over the climb, and the
///   arrow turns from ↘ to ↓ during the first half of the flight;
/// - a faint blue glow surrounds it.
@MainActor
enum DownloadFlight {
    nonisolated static let gravity: CGFloat = 2630
    nonisolated static let apexHeight: CGFloat = 90
    private static let maxDiameter: CGFloat = 48
    private static var flights: [NSPanel] = []

    /// Flies the glyph from `from` to `to` (screen points) over `window`; returns the
    /// flight time.
    @discardableResult
    static func launch(over window: NSWindow, from: NSPoint, to: NSPoint) -> TimeInterval {
        let frame = window.frame
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        let view = FlippedView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        panel.contentView = view
        window.addChildWindow(panel, ordered: .above)

        // Top-left coordinates inside the panel, like Arc's window-sized view.
        func local(_ p: NSPoint) -> CGPoint { CGPoint(x: p.x - frame.minX, y: frame.maxY - p.y) }
        let path = Trajectory(start: local(from), end: local(to))

        let icon = CALayer()
        icon.bounds = CGRect(x: 0, y: 0, width: maxDiameter, height: maxDiameter)
        icon.contents = glyph
        icon.contentsScale = window.backingScaleFactor
        icon.shadowColor = NSColor(red: 0.1, green: 0.42, blue: 0.85, alpha: 1).cgColor
        icon.shadowOpacity = 0.55
        icon.shadowRadius = 9
        icon.shadowOffset = .zero
        icon.opacity = 0
        view.layer?.addSublayer(icon)

        let samples = 66
        var positions: [NSValue] = [], transforms: [NSValue] = [], opacities: [NSNumber] = [], times: [NSNumber] = []
        for i in 0...samples {
            let p = CGFloat(i) / CGFloat(samples)
            positions.append(NSValue(point: path.point(at: p * path.duration)))
            let apexP = path.apexTime / path.duration
            // Diameter: 32 → 48 at the apex → 10 on arrival.
            let d = p < apexP ? 32 + 16 * p / apexP : 48 - 38 * (p - apexP) / (1 - apexP)
            let turn = min(1, p / 0.5)
            let angle = -(1 - turn * turn * (3 - 2 * turn)) * (.pi / 4)  // ↘ (45°) eased to ↓
            var t = CATransform3DMakeScale(d / maxDiameter, d / maxDiameter, 1)
            t = CATransform3DRotate(t, angle, 0, 0, 1)
            transforms.append(NSValue(caTransform3D: t))
            opacities.append(NSNumber(value: Double(min(1, p / apexP))))
            times.append(NSNumber(value: Double(p)))
        }
        func track(_ key: String, _ values: [Any]) -> CAKeyframeAnimation {
            let a = CAKeyframeAnimation(keyPath: key)
            a.values = values
            a.keyTimes = times
            a.calculationMode = .linear
            return a
        }
        let group = CAAnimationGroup()
        group.animations = [track("position", positions), track("transform", transforms), track("opacity", opacities)]
        group.duration = path.duration
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false

        flights.append(panel)
        CATransaction.begin()
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                window.removeChildWindow(panel)
                panel.orderOut(nil)
                flights.removeAll { $0 === panel }
            }
        }
        icon.add(group, forKey: "flight")
        CATransaction.commit()
        return path.duration
    }

    /// Projectile from `start` to `end` in top-left coordinates: the apex 90 pt above the
    /// higher of the two, gravity pulling down, horizontal speed constant.
    struct Trajectory {
        let start: CGPoint, end: CGPoint
        let apexTime: CGFloat, duration: CGFloat, vx: CGFloat, vy: CGFloat

        init(start: CGPoint, end: CGPoint) {
            self.start = start
            self.end = end
            let apexY = min(start.y, end.y) - DownloadFlight.apexHeight
            let g = DownloadFlight.gravity
            apexTime = sqrt(2 * (start.y - apexY) / g)
            duration = apexTime + sqrt(2 * (end.y - apexY) / g)
            vy = -g * apexTime
            vx = (end.x - start.x) / duration
        }

        func point(at t: CGFloat) -> CGPoint {
            CGPoint(x: start.x + vx * t, y: start.y + vy * t + DownloadFlight.gravity * t * t / 2)
        }
    }

    /// The glyph at its largest: navy disc, light ring, down arrow.
    private static let glyph: NSImage = {
        let d = maxDiameter
        return NSImage(size: NSSize(width: d, height: d), flipped: false) { rect in
            let ring: CGFloat = 2.5
            let disc = NSBezierPath(ovalIn: rect.insetBy(dx: ring / 2, dy: ring / 2))
            NSColor(red: 4 / 255, green: 7 / 255, blue: 42 / 255, alpha: 1).setFill()
            disc.fill()
            NSColor(red: 239 / 255, green: 239 / 255, blue: 1, alpha: 1).setStroke()
            disc.lineWidth = ring
            disc.stroke()
            let config = NSImage.SymbolConfiguration(pointSize: d * 0.42, weight: .semibold)
                .applying(.init(paletteColors: [NSColor(red: 239 / 255, green: 239 / 255, blue: 1, alpha: 1)]))
            if let arrow = NSImage(systemSymbolName: "arrow.down", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let s = arrow.size
                arrow.draw(in: NSRect(x: (d - s.width) / 2, y: (d - s.height) / 2, width: s.width, height: s.height))
            }
            return true
        }
    }()
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
