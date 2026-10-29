import SwiftUI
import UniformTypeIdentifiers

/// Tile backgrounds offered in a favorite's "Tile Color" menu.
enum TileColor {
    static let presets: [(name: String, hex: String)] = [
        ("White", "#FFFFFF"), ("Light Gray", "#D9D9DE"), ("Graphite", "#48484A"), ("Black", "#000000"),
        ("Red", "#FF453A"), ("Orange", "#FF9F0A"), ("Yellow", "#FFD60A"), ("Green", "#30D158"),
        ("Teal", "#40C8E0"), ("Blue", "#0A84FF"), ("Purple", "#BF5AF2"), ("Pink", "#FF375F"),
    ]

    /// A 12pt dot for the menu; Default is drawn hollow.
    static func swatch(_ hex: String?) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            let path = NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5))
            if let hex { NSColor(hex: hex).setFill(); path.fill() }
            NSColor.secondaryLabelColor.setStroke()
            path.lineWidth = 1
            path.stroke()
            return true
        }
    }
}

/// Routes the shared color panel to whichever favorite asked for it last.
@MainActor
final class TileColorPanel: NSObject {
    static let shared = TileColorPanel()
    private var onChange: ((String) -> Void)?

    func show(_ hex: String?, onChange: @escaping (String) -> Void) {
        let panel = NSColorPanel.shared
        // Detach first so seeding the color doesn't recolor the previous tile.
        panel.setTarget(nil)
        panel.setAction(nil)
        panel.showsAlpha = false
        panel.isContinuous = true
        if let hex { panel.color = NSColor(hex: hex) }
        self.onChange = onChange
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        panel.orderFront(nil)
    }

    @objc private func changed(_ panel: NSColorPanel) {
        guard let c = panel.color.usingColorSpace(.sRGB) else { return }
        onChange?(String(format: "#%02X%02X%02X", Int((c.redComponent * 255).rounded()),
                         Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded())))
    }
}
