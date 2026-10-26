import AppKit
import AppKit
import SwiftUI

extension Color {
    init(hex: String) {
        let c = HexColor.components(hex) ?? (0.5, 0.5, 0.5)
        self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: 1)
    }
}

extension NSColor {
    convenience init(hex: String) {
        let c = HexColor.components(hex) ?? (0.5, 0.5, 0.5)
        self.init(srgbRed: c.r, green: c.g, blue: c.b, alpha: 1)
    }
}

/// Colors derived from a space theme, the way Arc derives a
/// semanticColorPalette from the window theme.
struct SpacePalette {
    let isDark: Bool
    let gradientColors: [Color]
    let textPrimary: Color
    let textSecondary: Color
    let textTertiary: Color
    let hoverFill: Color
    let selectedFill: Color
    let separator: Color
    let pillFill: Color
    let toolbarFill: Color
    let folderTint: Color
    /// Arc 1.170: folder glyphs are a cream fill (theme colour pulled 80% to white) with an outline in the
    /// toolbar colour. Dark themes use a light outline over a faint white fill instead.
    let folderFill: Color
    /// Selected row in the command bar (Arc tints it with the space color).
    let commandHighlight: Color
    let noise: Double
    /// Opacity of the gradient over the blurred desktop at the top and bottom
    /// stops (1 when not vibrant). Arc's light themes get more opaque downwards.
    let gradientAlpha: Double
    let gradientAlphaBottom: Double
    let vibrant: Bool

    var gradient: LinearGradient {
        LinearGradient(colors: gradientColors, startPoint: .top, endPoint: .bottom)
    }

    /// Outline and fill for a folder glyph; nil (Auto) is the theme's pair.
    func folderColors(_ style: FolderIconStyle?) -> (tint: Color, fill: Color) {
        switch style {
        case nil: return (folderTint, folderFill)
        case .white?: return (.white.opacity(0.92), .white.opacity(0.22))
        case .black?: return (.black.opacity(0.8), .black.opacity(0.12))
        }
    }
}

extension SpaceTheme {
    static func blend(_ a: String, _ b: String, _ t: Double) -> Color {
        let x = HexColor.components(a) ?? (0.5, 0.5, 0.5), y = HexColor.components(b) ?? (0.5, 0.5, 0.5)
        let k = max(0, min(1, t))
        return Color(.sRGB, red: x.r + (y.r - x.r) * k, green: x.g + (y.g - x.g) * k, blue: x.b + (y.b - x.b) * k, opacity: 1)
    }

    private static func mix(_ hex: String, towardWhite: Bool, amount: Double) -> Color {
        let c = HexColor.components(hex) ?? (0.5, 0.5, 0.5)
        let target = towardWhite ? 1.0 : 0.0
        let a = max(0, min(1, amount))
        return Color(.sRGB, red: c.r + (target - c.r) * a, green: c.g + (target - c.g) * a, blue: c.b + (target - c.b) * a, opacity: 1)
    }

    /// Arc's toolbar band: the first theme colour pushed to a dark, fully
    /// saturated shade on light themes (Victor: #72601D) and a muted,
    /// slightly darker one on dark themes (JYSK: #0E0B16).
    static func hsb(_ r: Double, _ g: Double, _ b: Double) -> (h: Double, s: Double, v: Double) {
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
        var h = 0.0
        if d > 0.00001 {
            if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
            else if mx == g { h = (b - r) / d + 2 }
            else { h = (r - g) / d + 4 }
            h /= 6
            if h < 0 { h += 1 }
        }
        return (h, mx > 0 ? d / mx : 0, mx)
    }

    static func rgb(h: Double, s: Double, v: Double) -> (Double, Double, Double) {
        let i = floor(h * 6), f = h * 6 - i
        let p = v * (1 - s), q = v * (1 - f * s), t = v * (1 - (1 - f) * s)
        switch Int(i) % 6 {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }

    /// Light: 46% brightness, saturation +0.10 (Victor #F8D558 → #725F1D, Arc #72601D).
    /// Dark: 60% saturation, 80% brightness (JYSK #010220 → #0A0B19, Arc #0E0B16).
    /// Arc's light-theme ink: the first theme colour pushed to ~13% brightness
    /// (Victor #F8D558 → ≈#201A0C; Arc's row titles sample 32/26/0).
    static func inkColor(_ hex: String) -> Color {
        let c = HexColor.components(hex) ?? (0.5, 0.5, 0.5)
        var (h, s, v) = hsb(c.r, c.g, c.b)
        s = min(1, s + 0.10); v *= 0.135
        let o = rgb(h: h, s: s, v: v)
        return Color(.sRGB, red: o.0, green: o.1, blue: o.2, opacity: 1)
    }

    static func toolbarColor(_ hex: String, dark: Bool) -> Color {
        let c = HexColor.components(hex) ?? (0.5, 0.5, 0.5)
        var (h, s, v) = hsb(c.r, c.g, c.b)
        if dark { s *= 0.6; v *= 0.8 } else { s = min(1, s + 0.10); v *= 0.46 }
        let o = rgb(h: h, s: s, v: v)
        return Color(.sRGB, red: o.0, green: o.1, blue: o.2, opacity: 1)
    }

    var palette: SpacePalette {
        let dark = isDark
        let base = colors.isEmpty ? ["#DDDDDD"] : colors
        // Vibrant (Arc): raw colors at `intensity` opacity over the blur.
        // Opaque: intensity 1 = the raw colors; lower pulls toward white/black.
        let pull = vibrant ? 0 : (1 - intensity) * (dark ? 0.35 : 0.6)
        var stops = base.map { SpaceTheme.mix($0, towardWhite: !dark, amount: pull) }
        if stops.count == 1 { stops.append(SpaceTheme.mix(base[0], towardWhite: !dark, amount: pull + 0.15)) }

        let accent = SpaceTheme.mix(base[0], towardWhite: dark, amount: dark ? 0.25 : -0.0)
        return SpacePalette(
            isDark: dark,
            gradientColors: stops,
            textPrimary: dark ? .white.opacity(0.92) : SpaceTheme.inkColor(self.accent ?? base[0]),
            textSecondary: dark ? .white.opacity(0.6) : .black.opacity(0.5),
            textTertiary: dark ? .white.opacity(0.38) : .black.opacity(0.38),
            // Arc 1.170 live: a hovered row darkens ~4.5% (220/210/171 → 210/200/163), it does not lighten.
            hoverFill: dark ? .white.opacity(0.07) : .black.opacity(0.045),
            selectedFill: dark ? .white.opacity(0.13) : .white.opacity(0.74),
            separator: dark ? .white.opacity(0.12) : .black.opacity(0.09),
            pillFill: dark ? .white.opacity(0.08) : .black.opacity(0.045),
            // Arc: the toolbar is the first theme color at ~46% (dark) / lightened a touch (dark themes).
            toolbarFill: SpaceTheme.toolbarColor(self.accent ?? base[0], dark: dark),
            // Dark themes: the toolbar shade vanished on the dark sidebar, so the outline is light ink there.
            folderTint: dark ? .white.opacity(0.85) : SpaceTheme.toolbarColor(self.accent ?? base[0], dark: dark),
            folderFill: dark ? .white.opacity(0.14) : SpaceTheme.mix(base[0], towardWhite: true, amount: 0.8),
            commandHighlight: dark ? accent.opacity(0.55) : SpaceTheme.mix(base[0], towardWhite: false, amount: 0.45).opacity(0.75),
            noise: noise,
            // Calibrated against Arc's rendering of a 0.25-intensity vibrant theme.
            // Fitted to Arc's Victor theme (intensity 0.25) over white and black
            // backdrops: light vibrant themes run 0.45 → 0.59 over a HUD blur
            // (which passes ~55% of the backdrop and adds ~30/255 grey).
            // Re-fitted 25 Oct against Arc 1.170 over solid white/black backdrops (same
            // screen, same window frame): Arc's sidebar = c + k·backdrop with k 0.32 → 0.23
            // and c 123/116/83 → 159/129/95 (Victor theme). The dark HUD material (own tint
            // 27, passes 52 %) could not reach both, so light vibrant themes now blur through
            // an untinted CABackdropLayer with a 0.19 dim and a 0.16→0.18 lift (ShellView);
            // opacity 0.43 top / 0.59 bottom then matches Arc within ±5 over white and black.
            gradientAlpha: vibrant ? (dark ? max(0.35, min(0.9, intensity * 2.2)) : min(0.95, intensity * 1.70)) : 1,
            gradientAlphaBottom: vibrant ? (dark ? max(0.35, min(0.9, intensity * 2.2)) : min(0.95, intensity * 2.35)) : 1,
            vibrant: vibrant
        )
    }
}

extension Color {
    /// Mix toward another color in sRGB (amount 0...1).
    func blendedToward(_ other: Color, _ amount: Double) -> Color {
        guard amount > 0 else { return self }
        let a = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        let b = NSColor(other).usingColorSpace(.sRGB) ?? .gray
        let t = max(0, min(1, amount))
        return Color(.sRGB, red: Double(a.redComponent + (b.redComponent - a.redComponent) * t),
                     green: Double(a.greenComponent + (b.greenComponent - a.greenComponent) * t),
                     blue: Double(a.blueComponent + (b.blueComponent - a.blueComponent) * t), opacity: 1)
    }
}

/// A tiny tiled grain texture, like Arc's "grain" overlay modifier.
enum NoiseTexture {
    static let image: NSImage = {
        let size = 96
        let img = NSImage(size: NSSize(width: size, height: size))
        img.lockFocus()
        var rng = SystemRandomNumberGenerator()
        for y in 0..<size {
            for x in 0..<size {
                let v = Double.random(in: 0...1, using: &rng)
                NSColor(white: v, alpha: 1).setFill()
                NSRect(x: x, y: y, width: 1, height: 1).fill()
            }
        }
        img.unlockFocus()
        return img
    }()
}

struct NoiseOverlay: View {
    let amount: Double
    let isDark: Bool
    var body: some View {
        Image(nsImage: NoiseTexture.image)
            .resizable(resizingMode: .tile)
            .opacity(amount * (isDark ? 0.1 : 0.09))
            .blendMode(isDark ? .screen : .multiply)
            .allowsHitTesting(false)
    }
}

struct SpaceBackground: View {
    let palette: SpacePalette
    /// The main window passes the store so the tint follows a space swipe.
    var pager: SpacePager?

    var body: some View {
        if let pager {
            let spaces = pager.store.orderedSpaces
            let index = spaces.firstIndex { $0.id == pager.store.focusedSpaceID } ?? 0
            PagedSpaceBackground(palettes: spaces.map(\.theme.palette), position: Double(index) + Double(pager.ui.spaceSwipe))
                .animation(pager.ui.spaceSettleAnimation, value: pager.store.focusedSpaceID)
        } else {
            gradient
        }
    }

    private var gradient: some View {
        let scale = palette.vibrant ? CraTuning.shared.gradientAlphaScale : 1
        let n = palette.gradientColors.count
        let stops = palette.gradientColors.enumerated().map { i, c -> Gradient.Stop in
            let t = n > 1 ? Double(i) / Double(n - 1) : 0
            let top = palette.gradientAlpha * (palette.vibrant ? CraTuning.shared.gradientAlphaTopScale : 1)
            let bottom = palette.gradientAlphaBottom * (palette.vibrant ? CraTuning.shared.gradientAlphaBottomScale : 1)
            let a = (top + (bottom - top) * t) * scale
            return Gradient.Stop(color: c.opacity(min(1, a)), location: t)
        }
        return ZStack {
            LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
            NoiseOverlay(amount: palette.noise, isDark: palette.isDark)
        }
        .ignoresSafeArea()
    }

    /// Gradient stops as drawn: each colour carries the palette's top-to-bottom alpha.
    static func stops(_ palette: SpacePalette) -> [(color: NSColor, location: Double)] {
        let scale = palette.vibrant ? CraTuning.shared.gradientAlphaScale : 1
        let n = palette.gradientColors.count
        return palette.gradientColors.enumerated().map { i, c in
            let t = n > 1 ? Double(i) / Double(n - 1) : 0
            let top = palette.gradientAlpha * (palette.vibrant ? CraTuning.shared.gradientAlphaTopScale : 1)
            let bottom = palette.gradientAlphaBottom * (palette.vibrant ? CraTuning.shared.gradientAlphaBottomScale : 1)
            let a = min(1, (top + (bottom - top) * t) * scale)
            let rgb = NSColor(c).usingColorSpace(.sRGB) ?? .gray
            return (rgb.withAlphaComponent(rgb.alphaComponent * a), t)
        }
    }
}

struct SpacePager {
    let store: SidebarStore
    let ui: SidebarUIState
}

/// The window tint while paging between spaces: the two neighbouring spaces'
/// gradients mixed colour by colour at the fractional page position (Dia blends
/// its space tint with the paging progress). Animatable, so the settle spring
/// drives it frame by frame.
struct PagedSpaceBackground: View, Animatable {
    let palettes: [SpacePalette]
    var position: Double

    var animatableData: Double {
        get { position }
        set { position = newValue }
    }

    var body: some View {
        let last = max(0, palettes.count - 1)
        let p = min(max(position, 0), Double(last))
        let lo = Int(p.rounded(.down)), hi = min(last, lo + 1)
        let f = p - Double(lo)
        let a = palettes[lo], b = palettes[hi]
        let samples = 5
        let stops = (0..<samples).map { k -> Gradient.Stop in
            let t = Double(k) / Double(samples - 1)
            return Gradient.Stop(color: Color(nsColor: Self.mix(Self.color(a, at: t), Self.color(b, at: t), f)), location: t)
        }
        ZStack {
            LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
            NoiseOverlay(amount: a.noise + (b.noise - a.noise) * f, isDark: f < 0.5 ? a.isDark : b.isDark)
        }
        .ignoresSafeArea()
    }

    private static func color(_ palette: SpacePalette, at t: Double) -> NSColor {
        let stops = SpaceBackground.stops(palette)
        guard let first = stops.first else { return .clear }
        guard stops.count > 1 else { return first.color }
        for (s, e) in zip(stops, stops.dropFirst()) where t <= e.location {
            return mix(s.color, e.color, (t - s.location) / max(0.0001, e.location - s.location))
        }
        return stops[stops.count - 1].color
    }

    private static func mix(_ x: NSColor, _ y: NSColor, _ f: Double) -> NSColor {
        let x = x.usingColorSpace(.sRGB) ?? x, y = y.usingColorSpace(.sRGB) ?? y
        let g = CGFloat(f)
        return NSColor(srgbRed: x.redComponent + (y.redComponent - x.redComponent) * g,
                       green: x.greenComponent + (y.greenComponent - x.greenComponent) * g,
                       blue: x.blueComponent + (y.blueComponent - x.blueComponent) * g,
                       alpha: x.alphaComponent + (y.alphaComponent - x.alphaComponent) * g)
    }
}

/// Layout constants measured from Arc 1.168 at 2x (see docs).
enum CraMetrics {
    static let sidebarMinWidth: CGFloat = 220
    static let sidebarMaxWidth: CGFloat = 520
    static let sidebarDefaultWidth: CGFloat = 328
    static let rowHeight: CGFloat = 40
    static let rowSpacing: CGFloat = 1
    static let rowCorner: CGFloat = 10
    static let favicon: CGFloat = 16
    static let indent: CGFloat = 18
    static let contentInset: CGFloat = 10
    static let contentCornerRadius: CGFloat = 6
    static let toolbarHeight: CGFloat = 32
    /// Traffic lights, sidebar toggle and nav buttons share this centre line.
    static let titleRowCenter: CGFloat = 24
    static let titleAreaHeight: CGFloat = 44
    static let commandBarWidth: CGFloat = 766
    static let findBarSize = NSSize(width: 300, height: 38)
    /// Gap between the find bar and the page's top and trailing edges.
    static let findBarInset: CGFloat = 10
}
