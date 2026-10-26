import AppKit
import SwiftUI

/// NSTextField wrapper with Chrome/Arc-style inline completion: the
/// completed suffix is inserted selected, so typing replaces it and
/// Backspace removes it without re-completing.
struct CommandTextField: NSViewRepresentable {
    let controller: CommandBarController

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(string: controller.fieldText)
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 20, weight: .regular)
        field.placeholderString = controller.placeholder
        field.delegate = context.coordinator
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        context.coordinator.field = field
        DispatchQueue.main.async {
            field.window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        field.placeholderString = controller.placeholder
        let coord = context.coordinator
        if coord.appliedVersion != controller.fieldTextVersion {
            coord.appliedVersion = controller.fieldTextVersion
            coord.suppressChange = true
            field.stringValue = controller.fieldText
            coord.lastTyped = controller.fieldText
            coord.suppressChange = false
            DispatchQueue.main.async {
                field.window?.makeFirstResponder(field)
                field.currentEditor()?.selectAll(nil)
            }
        }
        if coord.appliedPreview != controller.previewVersion {
            coord.appliedPreview = controller.previewVersion
            coord.showPreview(controller.previewText)
        }
        if controller.previewText != nil {
            // Arrowed onto a row; the field shows that row, not a completion.
        } else if let c = controller.result.inlineCompletion, controller.allowCompletion, coord.pendingCompletion != c {
            coord.applyCompletion(c)
        } else if controller.result.inlineCompletion == nil {
            coord.pendingCompletion = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        let controller: CommandBarController
        weak var field: NSTextField?
        var appliedVersion = 0
        var appliedPreview = 0
        var lastTyped = ""
        var suppressChange = false
        var pendingCompletion: String?

        init(controller: CommandBarController) { self.controller = controller }

        func applyCompletion(_ completion: String) {
            guard let field, let editor = field.currentEditor() else { return }
            let typed = lastTyped
            guard completion.lowercased().hasPrefix(typed.lowercased()), completion.count > typed.count else { return }
            let remainder = String(completion.dropFirst(typed.count))
            pendingCompletion = completion
            suppressChange = true
            field.stringValue = typed + remainder
            editor.selectedRange = NSRange(location: (typed as NSString).length, length: (remainder as NSString).length)
            suppressChange = false
        }

        /// Show the arrowed-to row's text, or restore what was typed.
        func showPreview(_ text: String?) {
            guard let field else { return }
            let shown = text ?? controller.query
            suppressChange = true
            field.stringValue = shown
            lastTyped = shown
            pendingCompletion = nil
            field.currentEditor()?.selectedRange = NSRange(location: (shown as NSString).length, length: 0)
            suppressChange = false
        }

        func controlTextDidChange(_ obj: Notification) {
            guard !suppressChange, let field else { return }
            let text = field.stringValue
            let deleting = text.count < lastTyped.count || (pendingCompletion != nil && text == lastTyped)
            lastTyped = text
            pendingCompletion = nil
            controller.update(query: text, allowCompletion: !deleting)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.moveDown(_:)):
                controller.moveSelection(by: 1); return true
            case #selector(NSResponder.moveUp(_:)):
                controller.moveSelection(by: -1); return true
            case #selector(NSResponder.insertNewline(_:)):
                let cmd = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
                // If a completion suffix is selected, Enter means "go there".
                if pendingCompletion != nil, textView.selectedRange.length > 0 {
                    lastTyped = textView.string
                    controller.update(query: textView.string, allowCompletion: false)
                }
                controller.commit(forceNewTab: cmd)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                controller.close(); return true
            case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.moveRight(_:)), #selector(NSResponder.moveToEndOfLine(_:)):
                if pendingCompletion != nil, textView.selectedRange.length > 0 {
                    let text = textView.string
                    textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
                    lastTyped = text
                    pendingCompletion = nil
                    controller.update(query: text, allowCompletion: false)
                    return true
                }
                return selector == #selector(NSResponder.insertTab(_:))
            case #selector(NSResponder.deleteBackward(_:)):
                if pendingCompletion != nil, textView.selectedRange.length > 0 {
                    // Remove the suggestion, keep what was typed.
                    let typed = lastTyped
                    pendingCompletion = nil
                    suppressChange = true
                    textView.string = typed
                    textView.setSelectedRange(NSRange(location: (typed as NSString).length, length: 0))
                    suppressChange = false
                    controller.update(query: typed, allowCompletion: false)
                    return true
                }
                return false
            default:
                return false
            }
        }
    }
}
