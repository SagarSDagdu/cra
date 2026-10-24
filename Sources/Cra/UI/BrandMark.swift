import SwiftUI

/// The Cra "segments" mark from brand/cra-segments.svg, rendered at build time
/// into resources/brand (WebKit, so the multiply blends survive).
struct BrandMark: View {
    var size: CGFloat = 48
    var mono = false

    private static let colour: NSImage? = load("cra-mark@2x")
    private static let monoImage: NSImage? = load("cra-mark-mono")

    private static func load(_ name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "brand") else { return nil }
        return NSImage(contentsOf: url)
    }

    var body: some View {
        if let img = mono ? BrandMark.monoImage : BrandMark.colour {
            Image(nsImage: img)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .accessibilityLabel("Cra")
        }
    }
}
