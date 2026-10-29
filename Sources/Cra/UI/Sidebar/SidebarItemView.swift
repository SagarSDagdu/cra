import SwiftUI

enum SidebarSection { case favorites, pinned, today }

struct FaviconView: View {
    let key: String?
    let palette: SpacePalette
    var size: CGFloat = CraMetrics.favicon
    /// Whether the icon sits on a dark fill; defaults to the sidebar's.
    var onDark: Bool?
    @Environment(FaviconCache.self) private var favicons

    var body: some View {
        if let img = favicons.image(forKey: key) {
            // One-color glyphs (GitHub) flip to white on dark fills and black on light ones.
            let dark = onDark ?? palette.isDark
            let flip = favicons.glyphIsDark(forKey: key) == dark
            Image(nsImage: img)
                .resizable()
                .renderingMode(flip ? .template : .original)
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(dark ? Color.white.opacity(0.92) : Color.black.opacity(0.85))
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        } else {
            Image(systemName: "globe")
                .font(.system(size: size * 0.8, weight: .regular))
                .foregroundStyle(palette.textTertiary)
                .frame(width: size, height: size)
        }
    }
}
