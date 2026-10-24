import SwiftUI

/// Arc's command bar: a wide translucent panel, input row with the top
/// match's favicon, single-line rows "Title — url", the selected row tinted
/// with the space color, "Switch to Tab" + arrow for open tabs.
struct CommandBarView: View {
    let controller: CommandBarController
    @Environment(FaviconCache.self) private var favicons
    @Environment(\.colorScheme) private var scheme

    static let rowHeight: CGFloat = 50
    static let fieldHeight: CGFloat = 60
    static func height(forRows n: Int) -> CGFloat { fieldHeight + (n == 0 ? 0 : CGFloat(n) * rowHeight + CGFloat(n - 1) * 2 + 20) }

    private var dark: Bool { scheme == .dark }
    @State private var shown = false

    /// Arc pops the bar in with a short fade and a hint of scale; driven by the
    /// controller's open state so it replays on every open.
    var body: some View {
        content
            .opacity(shown ? 1 : 0)
            .scaleEffect(shown ? 1 : 0.985, anchor: .top)
            .onChange(of: controller.isOpen, initial: true) { _, open in
                withAnimation(open ? .easeOut(duration: 0.12) : .easeIn(duration: 0.08)) { shown = open }
            }
    }

    private var content: some View {
        let items = controller.result.items
        return VStack(spacing: 0) {
            HStack(spacing: 14) {
                leadingIcon.frame(width: 22, height: 22)
                CommandTextField(controller: controller)
                    .frame(height: 30)
                if controller.query.isEmpty {
                    Image(systemName: "info.circle")
                        .font(.system(size: 16, weight: .regular))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 22)
            .frame(height: Self.fieldHeight)

            if !items.isEmpty {
                Rectangle().fill(Color.primary.opacity(0.08)).frame(height: 1).padding(.horizontal, 16)
                VStack(spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, s in
                        SuggestionRow(suggestion: s, selected: idx == controller.selectedIndex,
                                      highlight: controller.highlight, focusedSpaceID: controller.focusedSpaceID,
                                      spaceName: controller.spaceName, queryEmpty: controller.query.isEmpty, dark: dark)
                            .onHover { if $0 { controller.selectedIndex = idx } }
                            .onTapGesture { controller.commit(s) }
                    }
                }
                .padding(10)
            }
        }
        .frame(width: controller.panelWidth)
        .background(dark ? AnyShapeStyle(Color.black.opacity(0.74)) : AnyShapeStyle(Color.white.opacity(0.7)))
        .background(.ultraThinMaterial)
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: controller.attached ? 10 : 14, bottomLeadingRadius: 14,
                                          bottomTrailingRadius: 14, topTrailingRadius: controller.attached ? 10 : 14, style: .continuous))
        .overlay(UnevenRoundedRectangle(topLeadingRadius: controller.attached ? 10 : 14, bottomLeadingRadius: 14,
                                        bottomTrailingRadius: 14, topTrailingRadius: controller.attached ? 10 : 14, style: .continuous)
            .strokeBorder(Color.primary.opacity(dark ? 0.12 : 0.08)))
    }

    @ViewBuilder private var leadingIcon: some View {
        if let s = controller.result.items.first, let key = s.faviconKey, s.id != "typed", let img = favicons.image(forKey: key),
           controller.result.inlineCompletion != nil || controller.mode == .editURL {
            Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .frame(width: 20, height: 20).clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        } else {
            Image(systemName: controller.mode == .editURL ? "info.circle" : "magnifyingglass")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}

struct SuggestionRow: View {
    let suggestion: Suggestion
    let selected: Bool
    let highlight: Color
    let focusedSpaceID: UUID?
    let spaceName: (UUID) -> String
    let queryEmpty: Bool
    let dark: Bool
    @Environment(FaviconCache.self) private var favicons

    private var isTab: Bool { suggestion.tabID != nil }
    private var otherSpace: String? {
        guard isTab, let sid = suggestion.spaceID, sid != focusedSpaceID else { return nil }
        return spaceName(sid)
    }

    var body: some View {
        HStack(spacing: 14) {
            icon.frame(width: 26, height: 26)
            (Text(suggestion.title).font(.system(size: 15, weight: .semibold)).foregroundStyle(.primary)
             + Text(detailText).font(.system(size: 15)).foregroundStyle(.secondary))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            if isTab {
                Text(otherSpace ?? (queryEmpty ? "" : "Switch to Tab"))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                Image(systemName: "arrow.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.primary.opacity(0.8))
                    .frame(width: 22, height: 22)
                    .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color.primary.opacity(0.1)))
            } else if let t = suggestion.trailing {
                Text(t).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: CommandBarView.rowHeight)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? highlight : .clear))
        .contentShape(Rectangle())
    }

    private var detailText: String {
        switch suggestion.kind {
        case .switchToTab, .search, .command, .switchSpace, .moveToSpace, .moveToFolder: return ""
        case .archived: return suggestion.subtitle.isEmpty ? "" : " — \(suggestion.subtitle)"
        default:
            guard let url = suggestion.url else { return "" }
            let human = SuggestionEngine.humanURL(url)
            return human.lowercased() == suggestion.title.lowercased() ? "" : " — \(human)"
        }
    }

    @ViewBuilder private var icon: some View {
        if let key = suggestion.faviconKey, let img = favicons.image(forKey: key) {
            Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 18)
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(dark ? Color.white.opacity(0.14) : Color.black.opacity(0.06)))
        } else if case .switchSpace = suggestion.kind, let t = suggestion.trailing {
            Text(t).font(.system(size: 16))
        } else {
            Image(systemName: suggestion.symbol ?? "globe")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }
}
