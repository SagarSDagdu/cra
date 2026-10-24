import AppKit
import SwiftUI

/// Click-to-record shortcut field for the Settings window.
struct ShortcutRecorder: View {
    let action: KeyAction
    @Environment(KeyBindingRegistry.self) private var bindings
    @State private var recording = false
    @State private var monitor: Any?

    private var conflict: String? {
        guard let s = action.primary else { return nil }
        return bindings.actions.first { $0.id != action.id && $0.shortcuts.contains(s) }?.name
    }

    var body: some View {
        HStack(spacing: 6) {
            if let c = conflict {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help("Also used by \(c)")
            }
            Button {
                recording ? stop() : start()
            } label: {
                Text(recording ? "Press keys…" : (action.shortcuts.isEmpty ? "None" : action.shortcuts.map(\.display).joined(separator: "  ")))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(recording ? Color.accentColor : .secondary)
                    .frame(minWidth: 84)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(recording ? Color.accentColor : Color.clear))
            }
            .buttonStyle(.plain)
            .help("Click, then press the new shortcut. Esc cancels, ⌫ removes it.")
        }
        .onDisappear { stop() }
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            handle(e)
            return nil
        }
    }

    private func stop() {
        recording = false
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
    }

    private func handle(_ e: NSEvent) {
        if e.keyCode == 53 { stop(); return }                               // esc
        if e.keyCode == 51 || e.keyCode == 117 { bindings.setShortcuts([], for: action.id); stop(); return }  // ⌫ / ⌦
        guard let s = Shortcut.from(event: e) else { return }
        bindings.setShortcuts([s], for: action.id)
        stop()
    }
}
