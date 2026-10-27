import AppKit
import SwiftUI

/// Arc 1.170's tab switcher, measured on a 1× display (27 Oct 2026, see
/// docs/arc-reverse-engineering.md "Tab switcher").
enum TabSwitcherMetrics {
    static let maxItems = 5
    /// ⌃Tab to panel: Arc showed it 0.18–0.26 s after the key; a 0.13 s tap never showed it.
    static let showDelay: TimeInterval = 0.15
    static let card = CGSize(width: 180, height: 158)
    static let thumbnail = CGSize(width: 158, height: 105)
    static let thumbnailOrigin = CGPoint(x: 11.5, y: 12)
    static let cardSpacing: CGFloat = 2
    static let paddingH: CGFloat = 16.5
    static let paddingV: CGFloat = 16
    static let cornerRadius: CGFloat = 26
    static let cardCornerRadius: CGFloat = 8
    static let thumbnailCornerRadius: CGFloat = 6.5
    static let favicon: CGFloat = 16
    /// Room around the panel for its shadow (the window is this much larger on each side).
    static let shadowMargin: CGFloat = 40

    static func panelSize(count: Int) -> CGSize {
        let n = CGFloat(max(count, 1))
        return CGSize(width: paddingH * 2 + n * card.width + (n - 1) * cardSpacing, height: paddingV * 2 + card.height)
    }

    static func windowSize(count: Int) -> CGSize {
        let p = panelSize(count: count)
        return CGSize(width: p.width + shadowMargin * 2, height: p.height + shadowMargin * 2)
    }
}

struct TabSwitcherView: View {
    let switcher: TabSwitcher
    private typealias M = TabSwitcherMetrics

    var body: some View {
        let dark = switcher.isDark
        let shape = RoundedRectangle(cornerRadius: M.cornerRadius, style: .continuous)
        HStack(spacing: M.cardSpacing) {
            ForEach(Array(switcher.items.enumerated()), id: \.element.id) { i, item in
                card(item, selected: i == switcher.selectedIndex, dark: dark)
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        if case .active = phase { switcher.hover(i) }
                    }
                    .onTapGesture { switcher.click(i) }
            }
        }
        .padding(.horizontal, M.paddingH)
        .padding(.vertical, M.paddingV)
        // Arc: #1C1B1A inside a near-black outer line and a 23% white inner line.
        .background(shape.fill(dark ? Color(red: 28 / 255, green: 27 / 255, blue: 26 / 255) : Color(white: 0.97)))
        .overlay(shape.inset(by: 1).strokeBorder(dark ? Color.white.opacity(0.23) : Color.white.opacity(0.8), lineWidth: 1))
        .overlay(shape.strokeBorder(dark ? Color.black.opacity(0.92) : Color.black.opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(dark ? 0.3 : 0.18), radius: 24, y: 10)
        .padding(M.shadowMargin)
        .environment(\.colorScheme, dark ? .dark : .light)
    }

    private func card(_ item: TabSwitcher.Item, selected: Bool, dark: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            thumbnail(item, dark: dark)
                .frame(width: M.thumbnail.width, height: M.thumbnail.height)
                .clipShape(RoundedRectangle(cornerRadius: M.thumbnailCornerRadius, style: .continuous))
                .shadow(color: .black.opacity(dark ? 0.4 : 0.15), radius: 7, y: 3)
                .padding(.leading, M.thumbnailOrigin.x)
                .padding(.top, M.thumbnailOrigin.y)
            HStack(spacing: 8) {
                favicon(item, dark: dark)
                Text(item.title)
                    // Arc's titles measure as SF 14 medium (ink width and cap height match).
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(dark ? Color.white : Color.black.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.leading, 13.5)
            .padding(.trailing, 10.5)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .frame(width: M.card.width, height: M.card.height, alignment: .topLeading)
        .background {
            if selected { RoundedRectangle(cornerRadius: M.cardCornerRadius, style: .continuous).fill(switcher.highlight) }
        }
    }

    @ViewBuilder
    private func thumbnail(_ item: TabSwitcher.Item, dark: Bool) -> some View {
        if let image = item.snapshot {
            Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
        } else {
            // A tab never seen since launch: Arc shows an empty #1C1C1C card.
            Rectangle().fill(dark ? Color(white: 28 / 255) : Color(white: 0.9))
        }
    }

    @ViewBuilder
    private func favicon(_ item: TabSwitcher.Item, dark: Bool) -> some View {
        if let palette = switcher.palette, item.iconKey != nil {
            FaviconIconOrPlaceholder(key: item.iconKey, palette: palette, dark: dark)
        } else {
            FaviconPlaceholder(dark: dark)
        }
    }
}

/// Arc's switcher draws a missing favicon as a faint rounded square, not a globe.
private struct FaviconIconOrPlaceholder: View {
    let key: String?
    let palette: SpacePalette
    let dark: Bool
    @Environment(FaviconCache.self) private var favicons

    var body: some View {
        if favicons.image(forKey: key) != nil {
            FaviconView(key: key, palette: palette, size: TabSwitcherMetrics.favicon, onDark: dark)
        } else {
            FaviconPlaceholder(dark: dark)
        }
    }
}

private struct FaviconPlaceholder: View {
    let dark: Bool
    var body: some View {
        RoundedRectangle(cornerRadius: 4.5, style: .continuous)
            .fill(dark ? Color.white.opacity(0.14) : Color.black.opacity(0.1))
            .frame(width: TabSwitcherMetrics.favicon, height: TabSwitcherMetrics.favicon)
    }
}

extension SpaceTheme {
    /// The selected card: Arc's semantic "hover" colour. In Arc's own data (JYSK and Victor
    /// spaces) the dark one sits at OKLab lightness ≈ 0.60 in the theme's hue, close to the
    /// most saturated colour sRGB has there, at 48% opacity; the light one is opaque at ≈ 0.885.
    func switcherHighlight(dark: Bool) -> Color {
        let hex = accent ?? colors.first ?? "#808080"
        let c = HexColor.components(hex) ?? (0.5, 0.5, 0.5)
        let lab = OKLab.from(r: c.r, g: c.g, b: c.b)
        let chroma = (lab.a * lab.a + lab.b * lab.b).squareRoot()
        let hue = atan2(lab.b, lab.a)
        let L = dark ? 0.60 : 0.885
        // Greys stay grey; anything with a clear hue gets Arc's near-full saturation.
        let target = OKLab.maxChroma(L: L, hue: hue) * (dark ? 0.87 : 0.5) * min(1, chroma / 0.03)
        let rgb = OKLab.toRGB(L: L, a: target * cos(hue), b: target * sin(hue))
        return Color(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b, opacity: dark ? 0.48 : 1)
    }
}

/// Björn Ottosson's OKLab, for colours that keep the same perceived lightness across hues.
enum OKLab {
    static func from(r: Double, g: Double, b: Double) -> (L: Double, a: Double, b: Double) {
        func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        let (lr, lg, lb) = (lin(r), lin(g), lin(b))
        let l = cbrt(0.4122214708 * lr + 0.5363325363 * lg + 0.0514459929 * lb)
        let m = cbrt(0.2119034982 * lr + 0.6806995451 * lg + 0.1073969566 * lb)
        let s = cbrt(0.0883024619 * lr + 0.2817188376 * lg + 0.6299787005 * lb)
        return (0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    /// Linear-light sRGB before clamping, so callers can tell whether it is in gamut.
    static func toLinear(L: Double, a: Double, b: Double) -> (r: Double, g: Double, b: Double) {
        let l = pow(L + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(L - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(L - 0.0894841775 * a - 1.2914855480 * b, 3)
        return (4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
    }

    static func toRGB(L: Double, a: Double, b: Double) -> (r: Double, g: Double, b: Double) {
        func enc(_ c: Double) -> Double {
            let x = max(0, min(1, c))
            return x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1 / 2.4) - 0.055
        }
        let v = toLinear(L: L, a: a, b: b)
        return (enc(v.r), enc(v.g), enc(v.b))
    }

    /// The largest chroma at this lightness and hue that sRGB can show.
    static func maxChroma(L: Double, hue: Double) -> Double {
        var lo = 0.0, hi = 0.4
        for _ in 0..<24 {
            let mid = (lo + hi) / 2
            let v = toLinear(L: L, a: mid * cos(hue), b: mid * sin(hue))
            if [v.r, v.g, v.b].allSatisfy({ $0 >= 0 && $0 <= 1 }) { lo = mid } else { hi = mid }
        }
        return lo
    }
}
