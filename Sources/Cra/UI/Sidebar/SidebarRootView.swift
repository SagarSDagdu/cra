import SwiftUI

struct SidebarIconButton: View {
    let symbol: String
    let palette: SpacePalette
    var help: String = ""
    /// Tooltip while ⌥ is held, for buttons that do something else on ⌥-click.
    var optionHelp: String? = nil
    var enabled: Bool = true
    var size: CGFloat = 28
    var height: CGFloat? = nil
    var iconSize: CGFloat = 13
    var weight: Font.Weight = .medium
    /// Header buttons follow the app's active state (nil: the plain sidebar tone).
    var active: Bool? = nil
    let action: () -> Void
    @State private var hover = false

    /// Arc 1.170 draws these glyphs at roughly 26% black (sidebar toggle, library, +) while the
    /// app is in the background. With the app active its header glyphs darken to ~59% black;
    /// disabled ones stay at ~24% (light theme, 26 Oct; the dark theme was not measured).
    private var tint: Color {
        if palette.isDark { return enabled ? Color.white.opacity(0.55) : palette.textTertiary.opacity(0.55) }
        guard let active else { return enabled ? Color.black.opacity(0.26) : palette.textTertiary.opacity(0.55) }
        return Color.black.opacity(enabled && active ? 0.59 : 0.24)
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: iconSize, weight: weight))
                .foregroundStyle(tint)
                .frame(width: size, height: height ?? min(size, 28))
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hover && enabled ? palette.hoverFill : .clear))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hover = $0 }
        .arcTooltip(help, optionHelp: optionHelp)
    }
}
