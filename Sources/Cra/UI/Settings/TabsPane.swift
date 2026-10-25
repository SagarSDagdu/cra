import SwiftUI

/// Dia's Tabs pane is a two-column form: "General:" checkboxes, "Tab Groups:" checkboxes and
/// "Tab Cleanup:" with a checkbox that enables a duration popup. Cra keeps the groups it has
/// behaviour for.
struct TabsPane: View {
    @Environment(SidebarStore.self) private var store

    var body: some View {
        @Bindable var store = store
        SettingsFormPane {
            SettingsFormRow(label: "General:") {
                SettingsCheckbox(title: "Add new tabs to the top", isOn: $store.settings.newTabsAtTop)
                SettingsCheckbox(title: "Haptic feedback when reordering tabs", isOn: $store.settings.hapticFeedbackOnReorder)
                SettingsCheckbox(title: "Show toolbar above the page", isOn: $store.settings.showToolbar)
                SettingsCheckbox(title: "Enable Picture in Picture when you leave a video tab", isOn: $store.settings.autoPictureInPicture)
                SettingsCheckbox(title: "Links from other apps open in a Little Window", isOn: $store.settings.openExternalLinksInLittleWindow)
            }
            SettingsFormRow(label: "Tab Cleanup:") {
                HStack(spacing: 6) {
                    SettingsCheckbox(title: "Archive tabs I haven’t used in:", isOn: $store.settings.autoArchiveEnabled)
                    Picker("", selection: $store.settings.autoArchive) {
                        ForEach(AutoArchiveThreshold.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .disabled(!store.settings.autoArchiveEnabled)
                }
            }
        }
    }
}
