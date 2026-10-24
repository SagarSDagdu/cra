import SwiftUI
import CraCEF

struct SettingsView: View {
    @Environment(SidebarStore.self) private var store
    @Environment(KeyBindingRegistry.self) private var bindings
    @Environment(AccountStore.self) private var account
    @State private var extensions = ExtensionStore()
    @State private var extensionError: String?
    let onImport: () -> Void
    var onOpenURL: (String) -> Void = { _ in }
    let onAccount: () -> Void

    var body: some View {
        @Bindable var store = store
        Form {
            Section("Account") {
                if let u = account.user {
                    LabeledContent("Signed in as", value: u.name.map { "\($0) · \(u.email)" } ?? u.email)
                    Button("Manage Account…") { onAccount() }
                } else {
                    Text("Sign in to sync settings and back up your sidebar.").foregroundStyle(.secondary)
                    Button("Sign In…") { onAccount() }
                }
            }
            Section("Tabs") {
                Picker("Archive today tabs after", selection: $store.settings.autoArchive) {
                    ForEach(AutoArchiveThreshold.allCases) { Text($0.label).tag($0) }
                }
                Toggle("New tabs open at the top of Today", isOn: $store.settings.newTabsAtTop)
                Toggle("Show toolbar above the page (⇧⌘D)", isOn: $store.settings.showToolbar)
                Toggle("Enable Picture in Picture when you leave a video tab", isOn: $store.settings.autoPictureInPicture)
                Toggle("Links from other apps open in a Little Window", isOn: $store.settings.openExternalLinksInLittleWindow)
                Toggle("Chrome engine for pages (extensions, Chrome DevTools) — restart Cra to apply", isOn: $store.settings.chromeEngine)
            }
            Section("Search") {
                Picker("Search engine", selection: $store.settings.searchEngine) {
                    ForEach(SearchEngine.allCases) { Text($0.label).tag($0) }
                }
            }
            Section("Import") {
                Text(ArcImporter.isAvailable || DiaImporter.isAvailable
                     ? "Bring spaces, pinned tabs, folders, favorites and the archive over from \([ArcImporter.isAvailable ? "Arc" : nil, DiaImporter.isAvailable ? "Dia" : nil].compactMap { $0 }.joined(separator: " or "))."
                     : "No Arc or Dia data found on this Mac.")
                    .foregroundStyle(.secondary)
                Button("Import…") { onImport() }.disabled(!(ArcImporter.isAvailable || DiaImporter.isAvailable))
            }
            Section {
                if extensions.entries.isEmpty {
                    Text("No extensions installed. Add an unpacked extension folder (the kind Chrome's \"Load unpacked\" takes).")
                        .foregroundStyle(.secondary)
                }
                ForEach(extensions.entries) { e in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(e.name) \(e.version)").font(.system(size: 13, weight: .medium))
                            if !e.description.isEmpty { Text(e.description).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2) }
                        }
                        Spacer()
                        Button("Remove") { extensions.remove(e) }.buttonStyle(.link).font(.system(size: 11))
                    }
                }
                HStack {
                    Button("Add Unpacked Extension…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        panel.prompt = "Add"
                        panel.message = "Choose an unpacked extension folder (it holds manifest.json)."
                        if panel.runModal() == .OK, let url = panel.url {
                            do { try extensions.add(folder: url); extensionError = nil } catch { extensionError = error.localizedDescription }
                        }
                    }
                    Button("Open Chrome's Extension Manager") { onOpenURL("chrome://extensions") }
                        .disabled(!store.settings.chromeEngine)
                    Spacer()
                }
                if let err = extensionError { Text(err).font(.system(size: 11)).foregroundStyle(.red) }
                Text(store.settings.chromeEngine
                     ? (extensions.needsRestart ? "Restart Cra to apply the change." : "Extensions load when Cra starts.")
                     : "Extensions need the Chrome engine (Tabs section).")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } header: {
                Text("Extensions")
            }
            Section {
                ForEach(bindings.actions) { a in
                    HStack(spacing: 8) {
                        Text(a.name)
                        Spacer()
                        ShortcutRecorder(action: a)
                        Button("Reset") { bindings.resetShortcuts(for: a.id) }
                            .buttonStyle(.link).font(.system(size: 11))
                            .opacity(bindings.isOverridden(a.id) ? 1 : 0)
                            .disabled(!bindings.isOverridden(a.id))
                    }
                }
                HStack {
                    Text("Click a shortcut, then press the new keys. Esc cancels, ⌫ removes it.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset All to Arc Defaults") { bindings.resetOverrides() }
                }
            } header: {
                Text("Shortcuts")
            }
            Section("About") {
                HStack(spacing: 12) {
                    BrandMark(size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Cra").font(.system(size: 16, weight: .semibold))
                        Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
                LabeledContent("Chromium", value: CraCEFRuntime.chromiumVersion())
                LabeledContent("CEF", value: CraCEFRuntime.cefVersion())
                LabeledContent("Backend", value: ConvexConfig.url.host ?? "")
                LabeledContent("Data", value: AppPaths.supportDir.path)
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 640)
    }
}
