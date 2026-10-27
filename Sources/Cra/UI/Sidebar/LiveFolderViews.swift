import AppKit
import SwiftUI

// The parts of a folder row that differ for a live folder (Arc's GitHub "Pull Requests" folder):
// the GitHub glyph, a refresh button, the folder menu with its filters, and a line inside the
// folder when it has nothing to show or GitHub can't be read.

/// GitHub's mark (Primer Octicons mark-github, MIT) for the live folder and its tabs (Arc: the
/// GithubFavicon asset and customInfo.iconType "github"). github.com's own favicon is no stand-in:
/// Cra caches favicons per host and GitHub swaps in a red ✕ while a pull request's checks fail.
enum GitHubMark {
    static let image: NSImage = {
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 16 16" width="16" height="16"><path d="M8 0c4.42 0 8 3.58 8 8a8.013 8.013 0 0 1-5.45 7.59c-.4.08-.55-.17-.55-.38 0-.27.01-1.13.01-2.2 0-.75-.25-1.23-.54-1.48 1.78-.2 3.65-.88 3.65-3.95 0-.88-.31-1.59-.82-2.15.08-.2.36-1.02-.08-2.12 0 0-.67-.22-2.2.82-.64-.18-1.32-.27-2-.27-.68 0-1.36.09-2 .27-1.53-1.03-2.2-.82-2.2-.82-.44 1.1-.16 1.92-.08 2.12-.51.56-.82 1.28-.82 2.15 0 3.06 1.86 3.75 3.64 3.95-.23.2-.44.55-.51 1.07-.46.21-1.61.55-2.33-.66-.15-.24-.6-.83-1.23-.82-.67.01-.27.38.01.53.34.19.73.9.82 1.13.16.45.68 1.31 2.69.94 0 .67.01 1.3.01 1.49 0 .21-.15.45-.55.38A7.995 7.995 0 0 1 0 8c0-4.42 3.58-8 8-8Z"/></svg>"#
        let img = NSImage(data: Data(svg.utf8)) ?? NSImage()
        img.isTemplate = true
        return img
    }()
}

/// The mark on its own: a live folder's tabs (Arc draws GithubFavicon for them).
struct GitHubMarkIcon: View {
    let palette: SpacePalette
    var size: CGFloat = CraMetrics.favicon
    var color: Color?
    var body: some View {
        Image(nsImage: GitHubMark.image)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .foregroundStyle(color ?? (palette.isDark ? Color.white.opacity(0.92) : Color.black.opacity(0.85)))
            .frame(width: size, height: size)
    }
}

/// Arc's live folder glyph: the folder it draws for any folder, with GitHub's mark on its
/// front in the outline colour (seen in Arc 1.170, 27 Oct 2026).
struct LiveFolderIcon: View {
    let palette: SpacePalette
    let style: FolderIconStyle?
    let expanded: Bool
    var body: some View {
        let glyph = palette.folderColors(style)
        ZStack {
            if !expanded {
                Image(systemName: "folder.fill").foregroundStyle(glyph.fill)
            }
            Image(systemName: "folder").foregroundStyle(glyph.tint)
            GitHubMarkIcon(palette: palette, size: 7, color: glyph.tint)
                .offset(y: 1.5)
        }
        .font(.system(size: 15, weight: .regular))
    }
}

/// Trailing refresh button. It spins while a refresh runs; a failed refresh leaves a warning
/// in its place until the next one works.
struct LiveFolderAccessory: View {
    let item: SidebarItem
    let palette: SpacePalette
    let hover: Bool
    private var manager: LiveFolderManager { .shared }

    var body: some View {
        let live = item.liveFolder
        let busy = manager.refreshing.contains(item.id)
        if busy {
            ProgressView().controlSize(.mini).frame(width: 26, height: 26)
        } else if let error = live?.lastError {
            // Arc keeps the warning on hover too; here a click tries again.
            SidebarIconButton(symbol: "exclamationmark.triangle", palette: palette, help: "\(LiveFolderText.status(error)). Click to try again.",
                              size: 26, iconSize: 13, weight: .regular) {
                manager.refresh(item.id)
            }
        } else if hover {
            SidebarIconButton(symbol: "arrow.clockwise", palette: palette, help: LiveFolderText.refreshHelp(live),
                              size: 26, iconSize: 12) {
                manager.refresh(item.id)
            }
        }
    }
}

/// A line inside the open folder when there are no pull requests to show, or GitHub can't be
/// read (Arc's live folder cells: "Sign back in to GitHub.", "Login with SSO to unlock this folder").
struct LiveFolderStatusRow: View {
    let item: SidebarItem
    let depth: Int
    let palette: SpacePalette
    @Environment(SidebarStore.self) private var store
    @Environment(\.sidebarActions) private var actions
    @State private var hover = false

    private var message: (text: String, url: String?)? {
        guard let live = item.liveFolder, item.children.isEmpty else { return nil }
        switch live.lastError {
        case .notSignedIn?: return ("Sign back in to GitHub.", "https://github.com/login")
        case .some: return ("We’re having trouble connecting to GitHub; click here to see your Pull Requests.", "https://github.com/pulls")
        case nil:
            if let org = live.ssoOrganizations.first { return ("Login with SSO to unlock this folder", "https://github.com/orgs/\(org)/sso") }
            if live.lastFetch == nil { return nil }
            return ("Pull requests from you and your team will show up here automatically", nil)
        }
    }

    var body: some View {
        if let message {
            Text(message.text)
                .font(.system(size: 12))
                .foregroundStyle(message.url != nil && hover ? palette.textSecondary : palette.textTertiary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 8 + CGFloat(depth) * CraMetrics.indent + CraMetrics.favicon + 11)
                .padding(.trailing, 10)
                .padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: CraMetrics.rowCorner, style: .continuous)
                    .fill(message.url != nil && hover ? palette.hoverFill : .clear))
                .contentShape(Rectangle())
                .onHover { hover = $0 }
                .onTapGesture { if let url = message.url { actions.openURL(url) } }
        }
    }
}

/// The live folder's context menu (Arc: SidebarMenu+ListContextMenu liveFolderContextMenu).
struct LiveFolderMenu: View {
    let item: SidebarItem
    @Environment(SidebarStore.self) private var store
    @Environment(SidebarUIState.self) private var ui
    @Environment(\.sidebarActions) private var actions
    private var manager: LiveFolderManager { .shared }

    var body: some View {
        let live = item.liveFolder ?? LiveFolderData()
        Text(manager.refreshing.contains(item.id) ? "Updating…" : LiveFolderText.lastUpdate(live))
        Button("Refresh") { manager.refresh(item.id) }
        Divider()
        filterToggle("My Pull Requests", .authored, live)
        filterToggle("Review Requests", .reviewRequests, live)
        filterToggle("Team Review Requests", .teamReviewRequests, live)
        let repos = manager.repositories[item.id] ?? live.filter.hiddenRepositories
        if !repos.isEmpty {
            Menu("Repositories") {
                Text("This list is generated based on your currently active pull requests.")
                Divider()
                ForEach(repos, id: \.self) { repo in
                    Toggle(repo, isOn: Binding(
                        get: { !live.filter.hiddenRepositories.contains(repo) },
                        set: { on in
                            store.updateLiveFolder(item.id) { l in
                                l.filter.hiddenRepositories.removeAll { $0 == repo }
                                if !on { l.filter.hiddenRepositories.append(repo) }
                            }
                            manager.refresh(item.id, force: true)
                        }))
                }
            }
        }
        if !live.ssoOrganizations.isEmpty {
            Divider()
            Text("SSO ensures all of your organizations’ PRs appear")
            ForEach(live.ssoOrganizations, id: \.self) { org in
                Button("Sign In to \(org) with SSO…") { actions.openURL("https://github.com/orgs/\(org)/sso") }
            }
        }
        Divider()
        Button("Rename…") { ui.renamingID = item.id }
        Picker("Icon Color", selection: Binding(get: { item.folderIcon }, set: { store.setFolderIcon($0, for: item.id) })) {
            Text("Auto").tag(FolderIconStyle?.none)
            Text("White").tag(FolderIconStyle?.some(.white))
            Text("Black").tag(FolderIconStyle?.some(.black))
        }
        Button("Copy All Links as Markdown") {
            let lines = store.children(of: item.id).compactMap { c in c.tab.map { "- [\(c.displayTitle)](\($0.liveItemURL ?? $0.url))" } }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        }
        .disabled(item.children.isEmpty)
        Divider()
        Button("Delete Live Folder") { confirmDelete() }
    }

    private func filterToggle(_ title: String, _ attribute: GitHubLiveFilter.Attributes, _ live: LiveFolderData) -> some View {
        Toggle(title, isOn: Binding(
            get: { live.filter.attributes.contains(attribute) },
            set: { on in
                store.updateLiveFolder(item.id) { l in
                    if on { l.filter.attributes.insert(attribute) } else { l.filter.attributes.remove(attribute) }
                }
                manager.refresh(item.id, force: true)
            }))
    }

    /// Arc asks first ("Delete your %@ Live Folder?") and says how to get it back.
    private func confirmDelete() {
        let alert = NSAlert()
        alert.messageText = "Delete your \(item.title ?? "Pull Requests") Live Folder?"
        alert.informativeText = "You can add it again with New GitHub Live Folder in the sidebar’s menu or the command bar."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        let id = item.id
        let delete = { withAnimation(.snappy(duration: 0.22, extraBounce: 0)) { store.deleteFolder(id) } }
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window) { if $0 == .alertFirstButtonReturn { delete() } }
        } else if alert.runModal() == .alertFirstButtonReturn {
            delete()
        }
    }
}

enum LiveFolderText {
    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f
    }()

    static func lastUpdate(_ live: LiveFolderData) -> String {
        if let error = live.lastError { return status(error) }
        guard let last = live.lastFetch else { return "Not updated yet" }
        if Date().timeIntervalSince(last) < 60 { return "Updated just now" }
        return "Updated \(relative.localizedString(for: last, relativeTo: Date()))"
    }

    static func refreshHelp(_ live: LiveFolderData?) -> String {
        guard let live, live.lastFetch != nil else { return "Refresh" }
        return "Refresh · \(lastUpdate(live))"
    }

    static func status(_ error: LiveFolderError) -> String {
        switch error {
        case .notSignedIn: return "Not signed in to GitHub"
        case .rateLimited: return "GitHub rate limit exceeded"
        case .unexpectedPage: return "Failed to update: unexpected GitHub page"
        case .network: return "Failed to update: GitHub can’t be reached"
        }
    }
}
