import SwiftUI

/// Arc's software-update sidebar banners (SidebarBanner `updateAvailable` and `updateSummary`),
/// above the space dock. Copy from Arc 1.170's strings: "An update is ready!" / "Click to
/// restart", "New Arc Version Available", and after the restart "Updated!" with "See What's
/// New". The banner never appeared on this Mac during the analysis, so its look follows
/// Cra's sidebar cards rather than a capture.
struct UpdateBanner: View {
    let palette: SpacePalette
    @State private var hover = false
    @State private var hoverClose = false

    private struct Content {
        var symbol: String
        var title: String
        var subtitle: String
        var action: @MainActor () -> Void
    }

    @MainActor private var content: Content? {
        let u = SoftwareUpdater.shared
        if u.readyRelease != nil, !u.bannerDismissed {
            return Content(symbol: "arrow.down.circle.fill", title: "An update is ready!", subtitle: "Click to restart") { u.installAndRelaunch() }
        }
        if let r = u.foundRelease, !u.bannerDismissed {
            return Content(symbol: "arrow.down.circle", title: "New Cra Version Available", subtitle: "Cra \(r.version)") { u.showFoundUpdate() }
        }
        if u.updatedTo != nil {
            return Content(symbol: "heart.circle.fill", title: "Cra Updated!", subtitle: "See What's New") { u.openReleaseNotes() }
        }
        return nil
    }

    var body: some View {
        Group {
            if let c = content {
                HStack(spacing: 10) {
                    Image(systemName: c.symbol)
                        .font(.system(size: 20))
                        .foregroundStyle(palette.textPrimary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(c.title).font(.system(size: 13, weight: .semibold))
                        Text(c.subtitle).font(.system(size: 12)).foregroundStyle(palette.textSecondary)
                    }
                    .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .frame(height: 52)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(hover ? palette.selectedFill : palette.hoverFill))
                .overlay(alignment: .topTrailing) {
                    if hover {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(palette.textSecondary)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(hoverClose ? palette.hoverFill : .clear))
                            .contentShape(Circle())
                            .onHover { hoverClose = $0 }
                            .onTapGesture { SoftwareUpdater.shared.dismissBanner() }
                            .padding(6)
                            .help("Dismiss")
                    }
                }
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onHover { hover = $0 }
                .onTapGesture { c.action() }
                .padding(.top, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.25), value: content?.title)
    }
}
