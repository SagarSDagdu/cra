import AppKit
import Foundation
import Observation
import Security

struct AccountUser: Codable, Equatable {
    var userId: String
    var email: String
    var name: String?
    var firstName: String?
    var lastName: String?
    var profileImageUrl: String?
    var isAdmin: Bool
    var emailVerified: Bool
    var authProvider: String

    init?(json: Any?) {
        guard let d = json as? [String: Any], let id = d["userId"] as? String, let email = d["email"] as? String else { return nil }
        userId = id
        self.email = email
        name = d["name"] as? String
        firstName = d["firstName"] as? String
        lastName = d["lastName"] as? String
        profileImageUrl = d["profileImageUrl"] as? String
        isAdmin = d["isAdmin"] as? Bool ?? false
        emailVerified = d["emailVerified"] as? Bool ?? false
        authProvider = d["authProvider"] as? String ?? "email"
    }
}

/// Sign-in state, session token in the Keychain, settings sync and sidebar
/// backups. Mirrors GhostWriter's useAuth: validate the stored session on
/// launch, keep local state in sync with the server.
@MainActor
@Observable
final class AccountStore {
    private(set) var user: AccountUser?
    private(set) var isBusy = false
    var lastError: String?
    private(set) var googleConfigured = false
    private(set) var backups: [(device: String, tabCount: Int, updatedAt: Date)] = []
    private(set) var lastBackupAt: Date?

    @ObservationIgnored private let client = ConvexClient()
    @ObservationIgnored private var token: String? {
        didSet { if let t = token { Keychain.set(t) } else { Keychain.delete() } }
    }
    @ObservationIgnored private let userFile = JSONStore<AccountUser?>("account.json")
    @ObservationIgnored private var settingsPushTask: Task<Void, Never>?

    static let deviceID: String = {
        let key = "cra.deviceID"
        if let v = UserDefaults.standard.string(forKey: key) { return v }
        let v = (Host.current().localizedName ?? "Mac") + "-" + String(UUID().uuidString.prefix(6))
        UserDefaults.standard.set(v, forKey: key)
        return v
    }()

    var isSignedIn: Bool { user != nil }

    init() {
        token = Keychain.get()
        if token != nil { user = userFile.load(or: { nil }) }
    }

    // MARK: Session

    func restore() async {
        guard let token else { return }
        do {
            let v = try await client.mutation("auth:touch", ["token": token])
            if let u = AccountUser(json: v) {
                user = u
                userFile.save(u)
            } else {
                // Session gone on the server.
                await clearLocal()
            }
        } catch {
            // Keep the cached user; transient failures should not log out (GhostWriter grace period).
        }
        await refreshGoogleConfig()
    }

    func refreshGoogleConfig() async {
        if let cfg = try? await client.query("auth:googleConfig") as? [String: Any] {
            googleConfigured = cfg["configured"] as? Bool ?? false
        }
    }

    func signIn(email: String, password: String) async {
        await run {
            let v = try await self.client.mutation("auth:login", ["email": email, "password": password, "device": Self.deviceID])
            try self.adopt(v)
        }
    }

    func signUp(email: String, password: String, name: String) async {
        await run {
            let v = try await self.client.mutation("auth:signUp", ["email": email, "password": password, "name": name, "device": Self.deviceID])
            try self.adopt(v)
        }
    }

    func signOut() async {
        if let token { _ = try? await client.mutation("auth:logout", ["token": token]) }
        await clearLocal()
    }

    private func clearLocal() async {
        token = nil
        user = nil
        backups = []
        try? FileManager.default.removeItem(at: AppPaths.file("account.json"))
    }

    private func adopt(_ value: Any?) throws {
        guard let d = value as? [String: Any], let t = d["token"] as? String, let u = AccountUser(json: d["user"]) else {
            throw ConvexError(message: "Unexpected sign-in response.")
        }
        token = t
        user = u
        userFile.save(u)
    }

    private func run(_ body: @escaping () async throws -> Void) async {
        isBusy = true
        lastError = nil
        do { try await body() } catch { lastError = error.localizedDescription }
        isBusy = false
    }

    // MARK: Google

    /// Builds the Google consent URL. The Convex /google-callback route finishes
    /// the flow and deep-links back with cra://auth-callback?data=…
    func googleSignInURL() async -> URL? {
        guard let cfg = try? await client.query("auth:googleConfig") as? [String: Any], let clientId = cfg["clientId"] as? String else { return nil }
        let redirect = ConvexConfig.siteURL.appendingPathComponent("google-callback").absoluteString
        var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        comps.queryItems = [
            .init(name: "client_id", value: clientId),
            .init(name: "redirect_uri", value: redirect),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: "openid email profile"),
            .init(name: "access_type", value: "offline"),
            .init(name: "prompt", value: "select_account"),
            .init(name: "state", value: Self.deviceID),
        ]
        return comps.url
    }

    /// cra://auth-callback?data=<base64 json {token,user}>
    func handleAuthCallback(_ url: URL) -> Bool {
        guard url.host == "auth-callback",
              let data = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "data" })?.value,
              let raw = Data(base64Encoded: data.removingPercentEncoding ?? data),
              let json = try? JSONSerialization.jsonObject(with: raw) else { return false }
        do { try adopt(json); return true } catch { lastError = error.localizedDescription; return false }
    }

    // MARK: Sync

    func pushSettings(_ settings: AppSettings) {
        guard let token, let data = try? JSONEncoder().encode(settings),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return }
        settingsPushTask?.cancel()
        settingsPushTask = Task { [client] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            _ = try? await client.mutation("settings:set", ["token": token, "settings": obj])
        }
    }

    func pullSettings() async -> AppSettings? {
        guard let token, let v = try? await client.query("settings:get", ["token": token]) as? [String: Any],
              let s = v["settings"], let data = try? JSONSerialization.data(withJSONObject: s) else { return nil }
        return try? JSONDecoder().decode(AppSettings.self, from: data)
    }

    func backupSidebar(_ document: SidebarDocument, tabCount: Int) async {
        guard let token else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        guard let data = try? enc.encode(document), let obj = try? JSONSerialization.jsonObject(with: data) else { return }
        if (try? await client.mutation("settings:backupSidebar", ["token": token, "device": Self.deviceID, "document": obj, "tabCount": tabCount])) != nil {
            lastBackupAt = Date()
        }
        await refreshBackups()
    }

    func refreshBackups() async {
        guard let token, let rows = try? await client.query("settings:listBackups", ["token": token]) as? [[String: Any]] else { return }
        backups = rows.compactMap { r in
            guard let d = r["device"] as? String else { return nil }
            return (d, r["tabCount"] as? Int ?? 0, Date(timeIntervalSince1970: (r["updatedAt"] as? Double ?? 0) / 1000))
        }
    }

    func fetchBackup(device: String) async -> SidebarDocument? {
        guard let token, let v = try? await client.query("settings:getBackup", ["token": token, "device": device]) as? [String: Any],
              let doc = v["document"], let data = try? JSONSerialization.data(withJSONObject: doc) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(SidebarDocument.self, from: data)
    }
}

/// Session token storage.
enum Keychain {
    private static let service = "dk.kildahl.cra"
    private static let account = "session"

    static func get() -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func set(_ value: String) {
        delete()
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecValueData as String: Data(value.utf8),
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete() {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}
