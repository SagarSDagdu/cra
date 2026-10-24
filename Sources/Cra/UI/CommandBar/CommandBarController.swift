import AppKit
import Observation
import SwiftUI

/// State + behaviour of the ⌘T / ⌘L bar. The panel and SwiftUI view read
/// from here; MainWindowController owns commits.
@MainActor
@Observable
final class CommandBarController {
    var isOpen = false
    var mode: CommandBarMode = .newTab
    var query = ""
    var result = SuggestionResult()
    var selectedIndex = 0
    /// Text pushed into the field from outside (prefill); bump version to apply.
    var fieldText = ""
    var fieldTextVersion = 0
    var allowCompletion = true
    /// Layout hints set by the window controller before opening.
    var panelWidth: CGFloat = CraMetrics.commandBarWidth
    var attached = false
    var highlight: Color = .accentColor.opacity(0.4)
    var focusedSpaceID: UUID?
    var spaceName: (UUID) -> String = { _ in "" }

    unowned let engine: SuggestionEngine
    unowned let store: SidebarStore
    var onCommit: (Suggestion?, String, CommandBarMode, Bool) -> Void = { _, _, _, _ in }
    var onClose: () -> Void = {}

    init(engine: SuggestionEngine, store: SidebarStore) {
        self.engine = engine
        self.store = store
    }

    var placeholder: String {
        switch mode {
        case .newTab: return "Search or enter URL…"
        case .editURL: return "Edit URL or search…"
        }
    }

    func open(mode: CommandBarMode, prefill: String?) {
        self.mode = mode
        query = prefill ?? ""
        fieldText = query
        fieldTextVersion += 1
        allowCompletion = false
        selectedIndex = 0
        result = engine.suggestions(for: query, mode: mode, currentTabID: store.selectedTabID)
        isOpen = true
    }

    /// Replace the typed text (scripting / tests).
    func setQuery(_ text: String) {
        fieldText = text
        fieldTextVersion += 1
        update(query: text, allowCompletion: true)
    }

    func update(query newQuery: String, allowCompletion: Bool) {
        query = newQuery
        self.allowCompletion = allowCompletion
        result = engine.suggestions(for: newQuery, mode: mode, currentTabID: store.selectedTabID)
        if !allowCompletion { result.inlineCompletion = nil }
        selectedIndex = 0
    }

    func moveSelection(by delta: Int) {
        guard !result.items.isEmpty else { return }
        let n = result.items.count
        selectedIndex = ((selectedIndex + delta) % n + n) % n
    }

    /// Accept the inline completion (Tab / →).
    func acceptCompletion() -> Bool {
        guard let c = result.inlineCompletion else { return false }
        fieldText = c
        fieldTextVersion += 1
        update(query: c, allowCompletion: false)
        return true
    }

    func commit(forceNewTab: Bool) {
        let selected = result.items.indices.contains(selectedIndex) ? result.items[selectedIndex] : nil
        var typed = query
        // Enter on the typed row with an inline completion goes to the completion.
        if selectedIndex == 0, let c = result.inlineCompletion, selected?.id == "typed" { typed = c }
        close()
        onCommit(selected, typed, mode, forceNewTab)
    }

    func commit(_ suggestion: Suggestion) {
        close()
        onCommit(suggestion, query, mode, false)
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        onClose()
    }
}

/// Borderless floating panel that can take keyboard focus.
final class CommandBarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 680, height: 60),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        animationBehavior = .utilityWindow
        collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
    }
}
