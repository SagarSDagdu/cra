import Foundation

// Live folders: folders that fill themselves from a service and empty as items close.
// Shape follows Arc's AutomaticLiveFolderData (StorableSidebar.json `list.automaticLiveFolderData`:
// dataSource github, filter.github {attributes, hiddenRepositories}, hiddenItems, lastFetch) and the
// cached LiveItem.github.pullRequest in StorableLiveData.json. Dia 1.54 keeps the same GitHub client
// (ARCClients/GitHubClient). Findings and what was verified: docs/live-folders.md.

/// What a live folder is filled from. Arc and Dia also have Bitbucket, Notion, Drive and calendar sources.
enum LiveFolderSource: String, Codable {
    case github
}

/// Which pull requests a GitHub live folder shows. Arc saves `attributes` as a bit mask (7 = all three).
struct GitHubLiveFilter: Codable, Equatable {
    struct Attributes: OptionSet, Codable, Hashable {
        let rawValue: Int
        /// author:@me
        static let authored = Attributes(rawValue: 1)
        /// user-review-requested:@me (asked of you by name)
        static let reviewRequests = Attributes(rawValue: 2)
        /// review-requested:@me, which also covers teams you are on (Arc: "Team Review Requests")
        static let teamReviewRequests = Attributes(rawValue: 4)
        static let all: Attributes = [.authored, .reviewRequests, .teamReviewRequests]
    }

    var attributes: Attributes = .all
    /// "owner/name" of repositories switched off in the folder's menu.
    var hiddenRepositories: [String] = []
}

enum LiveFolderError: String, Codable, Equatable {
    case notSignedIn, rateLimited, unexpectedPage, network
}

struct LiveFolderData: Codable, Equatable {
    var source: LiveFolderSource = .github
    var filter = GitHubLiveFilter()
    /// Items closed out of the folder; they don't come back (Arc: hiddenItems).
    var hiddenItems: [String] = []
    var lastFetch: Date?
    /// Why the last refresh failed; nil once one succeeds.
    var lastError: LiveFolderError?
    /// Organizations that want a SAML sign-in before their pull requests show up (Arc: needsSSO).
    var ssoOrganizations: [String] = []
    /// The enterprise whose single sign-on GitHub sent a tab to (Enterprise Managed Users sign in
    /// there, not at github.com/login): the folder's sign-in button goes there too.
    var enterprise: String?

    /// Where to sign in again.
    var signInURL: String {
        if let enterprise { return "https://github.com/enterprises/\(enterprise)/sso" }
        return "https://github.com/login?return_to=%2Fpulls"
    }

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decodeIfPresent(LiveFolderSource.self, forKey: .source) ?? .github
        filter = try c.decodeIfPresent(GitHubLiveFilter.self, forKey: .filter) ?? GitHubLiveFilter()
        hiddenItems = try c.decodeIfPresent([String].self, forKey: .hiddenItems) ?? []
        lastFetch = try c.decodeIfPresent(Date.self, forKey: .lastFetch)
        lastError = try? c.decodeIfPresent(LiveFolderError.self, forKey: .lastError)
        ssoOrganizations = try c.decodeIfPresent([String].self, forKey: .ssoOrganizations) ?? []
        enterprise = try c.decodeIfPresent(String.self, forKey: .enterprise)
    }
}

/// One pull request as the GitHub client reads it (Arc: LiveItem.Data.github.pullRequest).
struct LivePullRequest: Codable, Equatable, Identifiable {
    enum State: String, Codable { case open, draft, merged, closed }

    var owner: String
    var repo: String
    var number: Int
    var title: String
    var author: String?
    var state: State = .open
    var createdByMe = false
    var isAwaitingMyReview = false
    var createdAt: Date?
    var updatedAt: Date?

    var id: String { url }
    var url: String { "https://github.com/\(owner)/\(repo)/pull/\(number)" }
    var repository: String { "\(owner)/\(repo)" }
}
