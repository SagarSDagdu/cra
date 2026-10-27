import AppKit
import Observation
import SwiftUI

struct DownloadToast: Identifiable, Equatable {
    let id: UInt32
    var name: String
    var percent: Int
    var state: Int
    var path: String
    var totalBytes: Int64 = -1
    /// When Chromium last reported on it (see MainWindowController.checkStalledDownloads).
    var updated = Date()
}

/// Overlay state shown on top of the web content: link status, find bar,
/// download toasts.
@MainActor
@Observable
final class OverlayState {
    var status = ""
    var findVisible = false
    var findQuery = ""
    var findFocusToken = 0
    /// Find in page results ("2/7" in the bar); nil until the page answers.
    var findMatchCount: Int?
    var findActiveMatch = 0
    var toasts: [DownloadToast] = []
}

struct StatusBubble: View {
    let overlay: OverlayState
    var body: some View {
        if !overlay.status.isEmpty {
            Text(overlay.status)
                .font(.system(size: 11))
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.1)))
                .padding(6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }
}

struct FindBar: View {
    let overlay: OverlayState
    let onFind: (String, Bool) -> Void   // query, forward
    let onClose: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        if overlay.findVisible {
            @Bindable var overlay = overlay
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find in page", text: $overlay.findQuery)
                    .textFieldStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .focused($focused)
                    .onSubmit { onFind(overlay.findQuery, !(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false)) }
                    .onChange(of: overlay.findQuery) { _, q in onFind(q, true) }
                    .onExitCommand { onClose() }
                if !overlay.findQuery.isEmpty, let count = overlay.findMatchCount {
                    Text("\(count == 0 ? 0 : overlay.findActiveMatch)/\(count)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
                Button { onFind(overlay.findQuery, false) } label: { Image(systemName: "chevron.up") }.buttonStyle(.plain)
                Button { onFind(overlay.findQuery, true) } label: { Image(systemName: "chevron.down") }.buttonStyle(.plain)
                Button { onClose() } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1)))
            .onAppear { focused = true }
            .onChange(of: overlay.findFocusToken) { _, _ in focused = true }
        }
    }
}

/// The find bar's own window, just the bar's size, over the page windows. The
/// page-sized overlay panel can't take key and would swallow every click on the page.
final class FindBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: CraMetrics.findBarSize),
                   styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
    }
}

struct ToastStack: View {
    let overlay: OverlayState
    let onDismiss: (UInt32) -> Void
    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            ForEach(overlay.toasts) { t in
                HStack(spacing: 10) {
                    Image(systemName: t.state == 1 ? "checkmark.circle.fill" : (t.state == 0 ? "arrow.down.circle" : "exclamationmark.circle"))
                        .foregroundStyle(t.state == 1 ? .green : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        if t.state == 0 {
                            ProgressView(value: Double(max(0, t.percent)), total: 100).controlSize(.small)
                        } else {
                            Text(t.state == 1 ? "Downloaded" : (t.state == 2 ? "Cancelled" : "Failed")).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    if t.state == 1 {
                        Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: t.path)]) }
                            .controlSize(.small)
                    }
                    // Hides the toast only; the download carries on (the Library still has it).
                    Button { onDismiss(t.id) } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                            .frame(width: 16, height: 16).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(10)
                .frame(width: 300)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1)))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }
}

/// Arc shows a faint, slightly lighter card over the gradient when no tab is selected.
struct EmptyContentView: View {
    let space: Space
    var body: some View {
        // Fill under the titlebar too: the safe-area edge otherwise cuts through the toolbar.
        (space.theme.palette.isDark ? Color.white.opacity(0.04) : Color.black.opacity(0.03))
            .ignoresSafeArea()
    }
}
