import SwiftUI

/// Dia's Privacy pane: a "Content blocking" card of switch rows with coloured glyphs
/// (Block ads / Block cookie banners / Block trackers) and a "Data" card. Cra ships one
/// ad-and-tracker domain list, so it has one switch and no usage-data row.
struct PrivacyPane: View {
    @Environment(SidebarStore.self) private var store

    var body: some View {
        @Bindable var store = store
        SettingsCardPane {
            SettingsHeader("Content blocking")
            SettingsCard {
                SettingsCardRow {
                    HStack(spacing: 5.5) {
                        SettingsGlyph(symbol: "hand.raised.fill", color: Color(nsColor: .systemRed))
                        Text("Block ads and trackers").font(.system(size: 13))
                    }
                } trailing: {
                    Toggle("Block ads and trackers", isOn: $store.settings.blockAdsAndTrackers)
                        .toggleStyle(.switch).labelsHidden()
                }
            }
            SettingsFootnote("Requests to known ad and tracker domains are cancelled unless they are first-party to the page.")
        }
    }
}
