import SwiftUI

/// Import spaces, pinned tabs, folders, favorites, archive and settings from
/// Arc or Dia. Shown from Settings and on first launch when either exists.
struct ImportView: View {
    let onDone: () -> Void
    @Environment(SidebarStore.self) private var store
    @Environment(FaviconCache.self) private var favicons
    @State private var source = ArcImporter.isAvailable ? "Arc" : "Dia"
    @State private var plan: ImportPlan?
    @State private var error: String?
    @State private var includeArchive = true
    @State private var includeSettings = true
    @State private var result: SidebarStore.ImportResult?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import").font(.system(size: 17, weight: .semibold))
            Picker("From", selection: $source) {
                if ArcImporter.isAvailable { Text("Arc").tag("Arc") }
                if DiaImporter.isAvailable { Text("Dia").tag("Dia") }
            }
            .pickerStyle(.segmented)
            .onChange(of: source) { _, _ in load() }

            if let plan {
                VStack(alignment: .leading, spacing: 6) {
                    Label("\(plan.spaces.count) spaces: \(plan.spaces.map { "\($0.emoji) \($0.title)" }.joined(separator: ", "))", systemImage: "square.grid.2x2")
                    Label("\(plan.tabCount) tabs, \(plan.folderCount) folders, \(plan.favorites.count) favorites", systemImage: "pin")
                    Label("\(plan.archive.count) archived tabs", systemImage: "archivebox")
                    if plan.settings.autoArchive != nil || plan.settings.sidebarWidth != nil {
                        Label("Settings: auto-archive \(plan.settings.autoArchive?.label ?? "–"), sidebar width \(Int(plan.settings.sidebarWidth ?? 0))", systemImage: "gear")
                    }
                }
                .font(.system(size: 13))
                Toggle("Include archived tabs", isOn: $includeArchive)
                Toggle("Include settings", isOn: $includeSettings)
                Text("Spaces with the same name are merged. Tabs already in a section are skipped.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else if let error {
                Text(error).foregroundStyle(.red)
            } else {
                ProgressView().controlSize(.small)
            }

            if let result {
                Text("Imported \(result.spaces) new spaces, \(result.tabs) tabs, \(result.folders) folders and \(result.archived) archived tabs.")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(.green)
            }

            HStack {
                Button(result == nil ? "Not Now" : "Done") { onDone() }.keyboardShortcut(.cancelAction)
                Spacer()
                if result == nil {
                    Button("Import") {
                        guard let plan else { return }
                        working = true
                        result = store.apply(plan, includeArchive: includeArchive, includeSettings: includeSettings)
                        favicons.reset()
                        working = false
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan == nil || working)
                }
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { load() }
    }

    private func load() {
        plan = nil
        error = nil
        result = nil
        do {
            plan = try (source == "Arc" ? ArcImporter.plan() : DiaImporter.plan())
        } catch {
            self.error = error.localizedDescription
        }
    }
}
