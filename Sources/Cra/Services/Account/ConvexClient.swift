import Foundation

/// Which Convex deployment Cra talks to. Prod by default; set CRA_CONVEX_URL /
/// CRA_CONVEX_SITE_URL to point at dev (helpful-stoat-265).
enum ConvexConfig {
    static let prodURL = URL(string: "https://artful-albatross-857.eu-west-1.convex.cloud")!
    static let prodSiteURL = URL(string: "https://artful-albatross-857.eu-west-1.convex.site")!
    static let devURL = URL(string: "https://helpful-stoat-265.eu-west-1.convex.cloud")!
    static let devSiteURL = URL(string: "https://helpful-stoat-265.eu-west-1.convex.site")!

    static var url: URL {
        if let s = ProcessInfo.processInfo.environment["CRA_CONVEX_URL"], let u = URL(string: s) { return u }
        return ProcessInfo.processInfo.environment["CRA_CONVEX_DEV"] == "1" ? devURL : prodURL
    }
    static var siteURL: URL {
        if let s = ProcessInfo.processInfo.environment["CRA_CONVEX_SITE_URL"], let u = URL(string: s) { return u }
        return ProcessInfo.processInfo.environment["CRA_CONVEX_DEV"] == "1" ? devSiteURL : prodSiteURL
    }
}

struct ConvexError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Minimal Convex HTTP client: /api/query, /api/mutation, /api/action.
struct ConvexClient {
    var baseURL: URL = ConvexConfig.url
    private let session = URLSession(configuration: .ephemeral)

    func query(_ path: String, _ args: [String: Any] = [:]) async throws -> Any? { try await call("query", path, args) }
    func mutation(_ path: String, _ args: [String: Any] = [:]) async throws -> Any? { try await call("mutation", path, args) }
    func action(_ path: String, _ args: [String: Any] = [:]) async throws -> Any? { try await call("action", path, args) }

    private func call(_ kind: String, _ path: String, _ args: [String: Any]) async throws -> Any? {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/\(kind)"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("cra-macos-0.1", forHTTPHeaderField: "Convex-Client")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["path": path, "args": args, "format": "json"])
        req.timeoutInterval = 20
        let (data, response) = try await session.data(for: req)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConvexError(message: "Unexpected response from the server.")
        }
        if json["status"] as? String == "success" {
            let v = json["value"]
            return v is NSNull ? nil : v
        }
        let raw = json["errorMessage"] as? String ?? "Request failed"
        // Convex wraps thrown errors: "[CONVEX M(auth:login)] [Request ID: …] Server Error\nUncaught Error: Invalid email…"
        let cleaned = raw.components(separatedBy: "Uncaught Error: ").last?.components(separatedBy: "\n").first ?? raw
        _ = response
        throw ConvexError(message: cleaned.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
