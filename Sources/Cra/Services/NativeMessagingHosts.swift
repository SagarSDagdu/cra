import Foundation

/// Extensions that talk to a desktop app (1Password, Bitwarden, Claude, Notion…)
/// find it through a native messaging host manifest. Apps install those into the
/// browsers they know, never into Cra's profile, so Chromium logs "Can't find
/// manifest for native messaging host" and the extension stays disconnected.
/// Before Chromium starts, Cra links every manifest the other browsers have into
/// its own NativeMessagingHosts folder. Links, not copies: an app that rewrites
/// its manifest on update is picked up without Cra noticing.
enum NativeMessagingHosts {
    static func link(into profileRoot: URL) {
        let fm = FileManager.default
        let dest = profileRoot.appendingPathComponent("NativeMessagingHosts", isDirectory: true)
        try? fm.createDirectory(at: dest, withIntermediateDirectories: true)

        // Rebuilt every launch, so hosts that were uninstalled go away. Plain
        // files are someone's own manifests and stay.
        for name in (try? fm.contentsOfDirectory(atPath: dest.path)) ?? [] {
            let url = dest.appendingPathComponent(name)
            if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
                try? fm.removeItem(at: url)
            }
        }

        // First source wins: Chrome is where every app installs, the rest fill gaps.
        for dir in sources {
            for name in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(".json") {
                let link = dest.appendingPathComponent(name)
                if (try? link.checkResourceIsReachable()) == true { continue }
                try? fm.createSymbolicLink(at: link, withDestinationURL: dir.appendingPathComponent(name))
            }
        }
    }

    private static var sources: [URL] {
        let browsers = ImportSource.allCases.filter { [.chromium, .arc, .dia].contains($0.kind) }
        let user = (browsers.filter { $0.id == "chrome" } + browsers.filter { $0.id != "chrome" }).map { $0.dataDir.appendingPathComponent("NativeMessagingHosts", isDirectory: true) }
        // System-wide installs (all users), per browser.
        let system = [
            "/Library/Google/Chrome/NativeMessagingHosts",
            "/Library/Application Support/Chromium/NativeMessagingHosts",
            "/Library/Microsoft/Edge/NativeMessagingHosts",
            "/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts",
        ].map { URL(fileURLWithPath: $0, isDirectory: true) }
        return user + system
    }
}
