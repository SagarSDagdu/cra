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
}

extension SpaceTheme {
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
            textPrimary: dark ? .white.opacity(0.92) : .black.opacity(0.9),
            textSecondary: dark ? .white.opacity(0.6) : .black.opacity(0.58),
            textTertiary: dark ? .white.opacity(0.38) : .black.opacity(0.38),
            hoverFill: dark ? .white.opacity(0.07) : .white.opacity(0.38),
            selectedFill: dark ? .white.opacity(0.13) : .white.opacity(0.74),
            separator: dark ? .white.opacity(0.12) : .black.opacity(0.09),
            pillFill: dark ? .white.opacity(0.08) : .black.opacity(0.07),
            // Arc: the toolbar is the first theme color at ~46% (dark) / lightened a touch (dark themes).
            toolbarFill: SpaceTheme.toolbarColor(self.accent ?? base[0], dark: dark),
            folderTint: dark ? Color(hex: "#6B9CFF") : Color(hex: "#3B7CF6"),
            commandHighlight: dark ? accent.opacity(0.55) : SpaceTheme.mix(base[0], towardWhite: false, amount: 0.45).opacity(0.75),
            noise: noise,
            // Calibrated against Arc's rendering of a 0.25-intensity vibrant theme.
            // Fitted to Arc's Victor theme (intensity 0.25) over white and black
            // backdrops: light vibrant themes run 0.45 → 0.59 over a HUD blur
            // (which passes ~55% of the backdrop and adds ~30/255 grey).
            gradientAlpha: vibrant ? (dark ? max(0.35, min(0.9, intensity * 2.2)) : min(0.95, intensity * 1.8)) : 1,
            gradientAlphaBottom: vibrant ? (dark ? max(0.35, min(0.9, intensity * 2.2)) : min(0.95, intensity * 2.33)) : 1,
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
    var body: some View {
        let scale = palette.vibrant ? CraTuning.shared.gradientAlphaScale : 1
        let n = palette.gradientColors.count
        let stops = palette.gradientColors.enumerated().map { i, c -> Gradient.Stop in
            let t = n > 1 ? Double(i) / Double(n - 1) : 0
            let a = (palette.gradientAlpha + (palette.gradientAlphaBottom - palette.gradientAlpha) * t) * scale
            return Gradient.Stop(color: c.opacity(min(1, a)), location: t)
        }
        ZStack {
            LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
            NoiseOverlay(amount: palette.noise, isDark: palette.isDark)
        }
        .ignoresSafeArea()
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
    static let contentInset: CGFloat = 9
    static let contentCornerRadius: CGFloat = 10
    static let toolbarHeight: CGFloat = 40
    /// Traffic lights, sidebar toggle and nav buttons share this centre line.
    static let titleRowCenter: CGFloat = 24
    static let titleAreaHeight: CGFloat = 44
    static let commandBarWidth: CGFloat = 766
}
