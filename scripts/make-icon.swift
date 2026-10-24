// Renders the Cra app icon: the default space gradient with a reversed "C"
// (Arc reversed), and writes resources/AppIcon.icns via iconutil.
import Cocoa

func render(_ size: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let r = NSRect(x: 0, y: 0, width: size, height: size)
    let inset = size * 0.08
    let path = NSBezierPath(roundedRect: r.insetBy(dx: inset, dy: inset), xRadius: size * 0.2, yRadius: size * 0.2)
    let g = NSGradient(colors: [NSColor(hex: "#F8D558"), NSColor(hex: "#A4F554")])!
    g.draw(in: path, angle: -55)
    // Reversed C: an arc open to the left.
    let stroke = NSBezierPath()
    let c = NSPoint(x: size * 0.47, y: size * 0.5)
    stroke.appendArc(withCenter: c, radius: size * 0.24, startAngle: 130, endAngle: -130, clockwise: true)
    stroke.lineWidth = size * 0.13
    stroke.lineCapStyle = .round
    NSColor.white.withAlphaComponent(0.92).setStroke()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
    shadow.shadowBlurRadius = size * 0.03
    shadow.shadowOffset = NSSize(width: 0, height: -size * 0.015)
    shadow.set()
    stroke.stroke()
    img.unlockFocus()
    return img
}

extension NSColor {
    convenience init(hex: String) {
        var s = hex; s.removeFirst()
        let v = UInt32(s, radix: 16)!
        self.init(srgbRed: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
}

let out = CommandLine.arguments[1]
let set = out + "/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: set)
try! FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
for (name, px) in [("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64), ("icon_128x128", 128),
                   ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    let img = render(CGFloat(px))
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(set)/\(name).png"))
}
let task = Process()
task.launchPath = "/usr/bin/iconutil"
task.arguments = ["-c", "icns", set, "-o", out + "/AppIcon.icns"]
task.launch(); task.waitUntilExit()
try? FileManager.default.removeItem(atPath: set)
print("wrote \(out)/AppIcon.icns")
