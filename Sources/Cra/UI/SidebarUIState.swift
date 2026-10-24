import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// Transient sidebar UI state shared between AppKit and SwiftUI.
@MainActor
@Observable
final class SidebarUIState {
    var renamingID: UUID?
    var draggingID: UUID?
    var hoveredTabID: UUID?
    /// Loading progress per tab (0...1), fed by the browser manager.
    var progress: [UUID: Double] = [:]
    var loadedTabIDs: Set<UUID> = []
    var canGoBack = false
    var canGoForward = false
    var isLoading = false
    var isCompact = false
    /// Page theme colour of the visible tab ("#RRGGBB" or "").
    var pageThemeColor = ""
    /// Tab chosen from the keyboard; Arc draws its yellow/black dashed ring
    /// around it until the mouse picks another tab.
    var keyboardFocusID: UUID?
}

/// Things the sidebar needs AppKit to do.
@MainActor
final class SidebarActions {
    var openCommandBar: (CommandBarMode) -> Void = { _ in }
    var closeTab: (UUID) -> Void = { _ in }
    var goBack: () -> Void = {}
    var goForward: () -> Void = {}
    var reload: () -> Void = {}
    var editSpace: (Space?) -> Void = { _ in }
    var toggleSidebar: () -> Void = {}
    var showArchive: () -> Void = {}
    var resetPinnedTab: (UUID) -> Void = { _ in }
    var openURL: (String) -> Void = { _ in }
    var performAction: (String) -> Void = { _ in }
}

private struct SidebarActionsKey: EnvironmentKey {
    @MainActor static var defaultValue: SidebarActions { SidebarActions() }
}

extension EnvironmentValues {
    var sidebarActions: SidebarActions {
        get { self[SidebarActionsKey.self] }
        set { self[SidebarActionsKey.self] = newValue }
    }
}

extension UTType {
    static let craSidebarItem = UTType(exportedAs: "dk.kildahl.cra.sidebar-item")
}

struct SidebarDragItem: Codable, Transferable {
    let id: UUID
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .craSidebarItem)
    }
}
