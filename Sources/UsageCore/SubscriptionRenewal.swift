import Foundation

/// Cached subscription entitlement metadata, distinct from quota resets and billing confirmation.
public struct SubscriptionRenewal: Equatable, Sendable {
    public let date: Date
    public let lastChecked: Date?

    public init(date: Date, lastChecked: Date? = nil) {
        self.date = date
        self.lastChecked = lastChecked
    }

    public func isAwaitingUpdate(at now: Date) -> Bool { now >= date }
}

public enum SubscriptionMetadata {
    /// Reads only selected claims from the existing sign-in file; never refreshes, logs or stores tokens.
    public static func read(accountID: String?, environment: [String: String] = ProcessInfo.processInfo.environment,
                            homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> SubscriptionRenewal? {
        guard let accountID, !accountID.isEmpty else { return nil }
        let home: URL
        if let path = environment["CODEX_HOME"], !path.isEmpty {
            let expanded = (path as NSString).expandingTildeInPath
            home = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded, isDirectory: true)
                : homeDirectory.appendingPathComponent(expanded, isDirectory: true)
        } else { home = homeDirectory.appendingPathComponent(".codex", isDirectory: true) }
        guard let file = try? FileHandle(forReadingFrom: home.appendingPathComponent("auth.json")) else { return nil }
        defer { try? file.close() }
        // Bound the read; a malformed local file must not consume unbounded memory.
        guard let data = try? file.read(upToCount: 1_048_577), data.count <= 1_048_576 else { return nil }
        return decode(data, accountID: accountID)
    }

    public static func decode(_ authData: Data, accountID: String?) -> SubscriptionRenewal? {
        guard let accountID, !accountID.isEmpty, authData.count <= 1_048_576,
              let auth = try? JSONDecoder().decode(AuthMetadata.self, from: authData),
              auth.authMode == nil || auth.authMode == "chatgpt",
              auth.tokens.accountID == accountID else { return nil }
        let parts = auth.tokens.idToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONDecoder().decode(Claims.self, from: data),
              claims.auth.accountID == accountID,
              let date = parseDate(claims.auth.activeUntil) else { return nil }
        return SubscriptionRenewal(date: date, lastChecked: parseDate(claims.auth.lastChecked))
    }

    private static func parseDate(_ text: String?) -> Date? {
        guard let text else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }

    private struct AuthMetadata: Decodable {
        let authMode: String?
        let tokens: Tokens
        enum CodingKeys: String, CodingKey { case authMode = "auth_mode", tokens }
    }
    private struct Tokens: Decodable {
        let idToken: String
        let accountID: String
        enum CodingKeys: String, CodingKey { case idToken = "id_token", accountID = "account_id" }
    }
    private struct Claims: Decodable {
        let auth: Entitlement
        enum CodingKeys: String, CodingKey { case auth = "https://api.openai.com/auth" }
    }
    private struct Entitlement: Decodable {
        let accountID: String
        let activeUntil: String?
        let lastChecked: String?
        enum CodingKeys: String, CodingKey {
            case accountID = "chatgpt_account_id"
            case activeUntil = "chatgpt_subscription_active_until"
            case lastChecked = "chatgpt_subscription_last_checked"
        }
    }
}
