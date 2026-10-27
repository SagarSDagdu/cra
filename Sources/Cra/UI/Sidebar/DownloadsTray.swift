import AppKit
import SwiftUI

/// Arc's downloads list: hovering the Library button lists the recent downloads over the
/// bottom of the sidebar, newest at the bottom, and the tab list behind them fades out.
/// Measured on Arc 1.170 (window captures at 60 fps, 27 Oct 2026): rows 56 pt apart, a
/// 40 pt thumbnail with 6 pt corners 8 pt in, the name at x 61 (14 pt, white 82 %) and
/// "54 seconds ago" under it (12 pt, white 50 %); the last row ends 2 pt below the list
/// area. The tab list is hidden from 3 pt above the first row and fades back in over the
/// 170 pt above that. It opens 0.2 s into the hover, rows rising 5 pt and fading in bottom
/// first 25 ms apart; it closes 0.07 s after the pointer leaves.
enum DownloadsTrayMetrics {
    static let rowPitch: CGFloat = 56
    static let thumbnail: CGFloat = 40
    static let fade: CGFloat = 170
    static func listHeight(rows: Int) -> CGFloat { rows == 0 ? 0 : CGFloat(rows) * rowPitch - (rowPitch - thumbnail) }
}

extension SidebarUIState {
    func downloadsHoverChanged() {
        downloadsListWork?.cancel()
        let open = (libraryHovered || downloadsListHovered) && !DownloadHistory.shared.recent.isEmpty
        guard open != downloadsListOpen else { return }
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.downloadsListOpen = open } }
        downloadsListWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (open ? 0.2 : 0.07), execute: work)
    }
}

struct DownloadsTray: View {
    let palette: SpacePalette
    @Environment(SidebarUIState.self) private var ui
    private var history: DownloadHistory { .shared }

    var body: some View {
        let entries = history.recent
        let open = ui.downloadsListOpen
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: DownloadsTrayMetrics.rowPitch - DownloadsTrayMetrics.thumbnail) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { i, entry in
                    let fromBottom = Double(entries.count - 1 - i)
                    DownloadsTrayRow(entry: entry, palette: palette, now: context.date)
                        .opacity(open ? 1 : 0)
                        .offset(y: open ? 0 : 5)
                        .animation(open ? .easeOut(duration: 0.12).delay(fromBottom * 0.025)
                                        : .easeIn(duration: 0.05).delay(fromBottom * 0.015), value: open)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .allowsHitTesting(open)
        .onHover { ui.downloadsListHovered = $0; ui.downloadsHoverChanged() }
        .offset(y: 2)
    }
}

private struct DownloadsTrayRow: View {
    let entry: DownloadHistory.Entry
    let palette: SpacePalette
    let now: Date
    private var ink: Color { palette.isDark ? .white : .black }

    var body: some View {
        Button { NSWorkspace.shared.open(URL(fileURLWithPath: entry.path)) } label: {
            HStack(spacing: 13) {
                Group {
                    if let image = DownloadHistory.shared.thumbnail(for: entry.path) {
                        Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color.white.opacity(0.9)
                    }
                }
                .frame(width: DownloadsTrayMetrics.thumbnail, height: DownloadsTrayMetrics.thumbnail)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                VStack(alignment: .leading, spacing: -1) {
                    Text((entry.path as NSString).lastPathComponent)
                        .font(.system(size: 14))
                        .foregroundStyle(ink.opacity(0.82))
                        .lineLimit(1).truncationMode(.middle)
                    Text(Self.age.localizedString(for: min(entry.date, now), relativeTo: now))
                        .font(.system(size: 12))
                        .foregroundStyle(ink.opacity(0.5))
                }
                .padding(.top, 1)
            }
            .padding(.leading, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onDrag { NSItemProvider(contentsOf: URL(fileURLWithPath: entry.path)) ?? NSItemProvider() }
    }

    /// "54 seconds ago", "6 minutes ago".
    private static let age: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()
}

/// Hides the tab list under the downloads list and fades it back in above it. One
/// gradient sized by a GeometryReader: fixed-height layers here raised the sidebar's
/// minimum height and the window grew to fit them.
struct DownloadsTrayMask: View {
    let rows: Int
    let open: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(open ? 0 : 1)
            GeometryReader { g in
                let h = max(g.size.height, 1)
                let clearTop = max(0, h - DownloadsTrayMetrics.listHeight(rows: rows) - 1)
                let fadeTop = max(0, clearTop - DownloadsTrayMetrics.fade)
                LinearGradient(stops: [.init(color: .black, location: fadeTop / h),
                                       .init(color: .clear, location: clearTop / h),
                                       .init(color: .clear, location: 1)],
                               startPoint: .top, endPoint: .bottom)
            }
            .opacity(open ? 1 : 0)
        }
        .animation(open ? .easeOut(duration: 0.18) : .easeOut(duration: 0.13).delay(0.08), value: open)
    }
}
