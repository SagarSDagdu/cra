import AppKit
import Observation

/// Favicons keyed by host. Chromium hands us PNG bytes through the bridge;
/// we keep them in memory and on disk so the sidebar is populated on launch
/// before any tab has loaded (Arc: SidebarItemsFaviconCache).
@MainActor
@Observable
final class FaviconCache {
    private(set) var images: [String: NSImage] = [:]
    private var attemptedDiskLoad: Set<String> = []

    static func key(for urlString: String) -> String? {
        guard let host = URL(string: urlString)?.host, !host.isEmpty else { return nil }
        return host.lowercased()
    }

    func image(forKey key: String?) -> NSImage? {
        guard let key else { return nil }
        if let img = images[key] { return img }
        if !attemptedDiskLoad.contains(key) {
            attemptedDiskLoad.insert(key)
            let file = AppPaths.favicons.appendingPathComponent(Self.fileName(key))
            if let img = NSImage(contentsOf: file) {
                images[key] = img
                return img
            }
        }
        return nil
    }

    func image(for urlString: String) -> NSImage? { image(forKey: Self.key(for: urlString)) }

    private var dominant: [String: String] = [:]

    /// Average colour of the favicon's opaque pixels as "#RRGGBB" (Arc tints
    /// the toolbar with the favicon's dominant colour when a page has no
    /// theme-color).
    func dominantColor(forKey key: String?) -> String? {
        guard let key else { return nil }
        if let c = dominant[key] { return c.isEmpty ? nil : c }
        guard let img = image(forKey: key), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = 16, h = 16
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var r = 0, g = 0, b = 0, n = 0
        for i in stride(from: 0, to: buf.count, by: 4) where buf[i + 3] > 200 {
            r += Int(buf[i]); g += Int(buf[i + 1]); b += Int(buf[i + 2]); n += 1
        }
        guard n > 40 else { dominant[key] = ""; return nil }
        let hex = String(format: "#%02X%02X%02X", r / n, g / n, b / n)
        dominant[key] = hex
        return hex
    }

    /// Forget in-memory state so files added on disk (imports) are picked up.
    func reset() {
        images = [:]
        attemptedDiskLoad = []
        dominant = [:]
    }

    func store(_ image: NSImage, forKey key: String) {
        images[key] = image
        let file = AppPaths.favicons.appendingPathComponent(Self.fileName(key))
        DispatchQueue.global(qos: .utility).async {
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { return }
            try? png.write(to: file, options: .atomic)
        }
    }

    static func fileName(_ key: String) -> String {
        let safe = key.map { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" ? String($0) : "_" }.joined()
        return safe + ".png"
    }
}
