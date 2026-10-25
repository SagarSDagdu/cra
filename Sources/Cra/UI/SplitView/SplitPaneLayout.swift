import AppKit

/// Pure layout for Arc-style split panes, after ARCUI.SplitViewControllerLayout:
/// each pane gets `widthFactor × (container − gaps)` along the main axis,
/// clamped to a minimum, with the dragger handles living in the gaps.
struct SplitPaneLayout {
    struct Pane: Equatable {
        let id: UUID
        var factor: CGFloat
    }

    struct Result: Equatable {
        /// Card frame per pane, in the container's coordinates.
        var frames: [UUID: NSRect] = [:]
        /// Gap rects between consecutive panes (the dragger handle lives here), in pane order.
        var gaps: [NSRect] = []
        /// Factors after clamping to the minimum size; sum to 1.
        var factors: [UUID: CGFloat] = [:]
    }

    enum Constants {
        /// Gap between two pane cards; measured on Arc 1.170 at 2x: 20 px.
        static let gap: CGFloat = 10
        /// Smallest pane along the main axis.
        static let minimumPaneLength: CGFloat = 200
        /// The handle reacts a little outside the visible gap (Arc: draggerHandleHitTargetOutset).
        static let handleHitOutset: CGFloat = 4
        /// Add/remove pane transition. Arc lays the new pane out within a single
        /// frame (window recording at 27 fps, 24 Oct 2026); 0 = no transition.
        static let transitionDuration: TimeInterval = 0
        static let transitionTiming = CAMediaTimingFunction(controlPoints: 0.2, 0.85, 0.25, 1)
    }

    var panes: [Pane]
    var orientation: SplitOrientation
    var containerSize: CGSize
    var backingScaleFactor: CGFloat = 2
    var gap: CGFloat = Constants.gap
    var minimumPaneLength: CGFloat = Constants.minimumPaneLength

    /// Equal shares for panes without a stored factor; the stored ones keep
    /// their share of what is left (Arc stores only the dragged factors).
    static func normalizedFactors(ids: [UUID], stored: [UUID: Double]) -> [UUID: CGFloat] {
        guard !ids.isEmpty else { return [:] }
        let known = ids.filter { stored[$0] != nil }
        let knownSum = known.reduce(0.0) { $0 + (stored[$1] ?? 0) }
        var out: [UUID: CGFloat] = [:]
        if known.count == ids.count, knownSum > 0 {
            for id in ids { out[id] = CGFloat(stored[id]! / knownSum) }
            return out
        }
        let unknown = ids.count - known.count
        let remaining = max(0, 1 - min(knownSum, 1))
        for id in ids {
            if let f = stored[id] { out[id] = CGFloat(min(f, 1)) }
            else { out[id] = CGFloat(remaining / Double(unknown)) }
        }
        let sum = out.values.reduce(0, +)
        if sum > 0 { for id in ids { out[id]! /= sum } }
        return out
    }

    func compute() -> Result {
        var result = Result()
        let n = panes.count
        guard n > 0 else { return result }
        let horizontal = orientation == .horizontal
        let total = (horizontal ? containerSize.width : containerSize.height) - gap * CGFloat(n - 1)
        let cross = horizontal ? containerSize.height : containerSize.width
        let scale = max(1, backingScaleFactor)
        func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }

        // Clamp to the minimum, redistributing from the larger panes.
        var factors = panes.map { max(0, $0.factor) }
        let fsum = factors.reduce(0, +)
        if fsum <= 0 { factors = Array(repeating: 1 / CGFloat(n), count: n) } else { factors = factors.map { $0 / fsum } }
        var lengths = factors.map { $0 * total }
        let minLen = min(minimumPaneLength, total / CGFloat(n))
        for _ in 0..<n {
            var deficit: CGFloat = 0
            var flexible: [Int] = []
            for i in 0..<n {
                if lengths[i] < minLen { deficit += minLen - lengths[i]; lengths[i] = minLen } else { flexible.append(i) }
            }
            guard deficit > 0, !flexible.isEmpty else { break }
            let flexSum = flexible.reduce(0) { $0 + lengths[$1] - minLen }
            for i in flexible {
                let share = flexSum > 0 ? (lengths[i] - minLen) / flexSum : 1 / CGFloat(flexible.count)
                lengths[i] -= deficit * share
            }
        }

        var cursor: CGFloat = 0
        for (i, pane) in panes.enumerated() {
            let start = snap(cursor)
            let end = i == n - 1 ? (horizontal ? containerSize.width : containerSize.height) : snap(cursor + lengths[i])
            let frame: NSRect
            if horizontal {
                frame = NSRect(x: start, y: 0, width: max(0, end - start), height: cross)
            } else {
                // AppKit's y grows upward: the first pane sits at the top.
                frame = NSRect(x: 0, y: containerSize.height - end, width: cross, height: max(0, end - start))
            }
            result.frames[pane.id] = frame
            result.factors[pane.id] = total > 0 ? lengths[i] / total : 0
            if i < n - 1 {
                let gapStart = end
                let gapEnd = snap(cursor + lengths[i] + gap)
                if horizontal {
                    result.gaps.append(NSRect(x: gapStart, y: 0, width: gapEnd - gapStart, height: cross))
                } else {
                    result.gaps.append(NSRect(x: 0, y: containerSize.height - gapEnd, width: cross, height: gapEnd - gapStart))
                }
            }
            cursor += lengths[i] + gap
        }
        return result
    }

    /// Move the divider after pane `index` by `delta` points along the main
    /// axis, respecting minimum sizes; returns the new factors. Snaps to the
    /// centre when two panes would end up within `snapDistance` of equal.
    func dragging(dividerAfter index: Int, by delta: CGFloat, snapDistance: CGFloat = 6) -> (factors: [UUID: CGFloat], snapped: Bool) {
        let n = panes.count
        guard index >= 0, index + 1 < n else { return (Dictionary(uniqueKeysWithValues: panes.map { ($0.id, $0.factor) }), false) }
        let horizontal = orientation == .horizontal
        let total = (horizontal ? containerSize.width : containerSize.height) - gap * CGFloat(n - 1)
        guard total > 0 else { return (Dictionary(uniqueKeysWithValues: panes.map { ($0.id, $0.factor) }), false) }
        var lengths = panes.map { $0.factor * total }
        let minLen = min(minimumPaneLength, total / CGFloat(n))
        var d = delta
        if lengths[index] + d < minLen { d = minLen - lengths[index] }
        if lengths[index + 1] - d < minLen { d = lengths[index + 1] - minLen }
        lengths[index] += d
        lengths[index + 1] -= d
        var snapped = false
        if n == 2 {
            let mid = total / 2
            if abs(lengths[0] - mid) < snapDistance { lengths = [mid, mid]; snapped = true }
        } else {
            let pairSum = lengths[index] + lengths[index + 1]
            if abs(lengths[index] - pairSum / 2) < snapDistance { lengths[index] = pairSum / 2; lengths[index + 1] = pairSum / 2; snapped = true }
        }
        var out: [UUID: CGFloat] = [:]
        for (i, p) in panes.enumerated() { out[p.id] = lengths[i] / total }
        return (out, snapped)
    }
}
