import XCTest
@testable import UsageCore

final class SubscriptionTests: XCTestCase {
    private func auth(account: String = "fixture-account", tokenAccount: String = "fixture-account",
                      until: String? = "2030-01-15T12:34:56Z", mode: String = "chatgpt") throws -> Data {
        var claims: [String: Any] = ["chatgpt_account_id": tokenAccount,
                                    "chatgpt_subscription_last_checked": "2030-01-02T03:04:05.125Z"]
        claims["chatgpt_subscription_active_until"] = until
        let payload = try JSONSerialization.data(withJSONObject: ["https://api.openai.com/auth": claims])
            .base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return try JSONSerialization.data(withJSONObject: ["auth_mode": mode,
            "tokens": ["account_id": account, "id_token": "fixture.\(payload).fixture"]])
    }

    func testCachedSubscriptionDatePreservesSecondsAndCorrectRenewalTimeZone() throws {
        let value = try XCTUnwrap(SubscriptionMetadata.decode(auth(), accountID: "fixture-account"))
        let expected = try XCTUnwrap(ISO8601DateFormatter().date(from: "2030-01-15T12:34:56Z"))
        XCTAssertEqual(value.date, expected)
        XCTAssertEqual(value.lastChecked?.timeIntervalSince1970 ?? 0, 1893553445.125, accuracy: 0.001)
        let label = UsageFormatting.resetDate(value.date, timeZone: TimeZone(identifier: "Europe/Zurich")!)
        XCTAssertTrue(label.contains("15 Jan 2030 · 13:34:56"), label)
        XCTAssertFalse(value.isAwaitingUpdate(at: expected.addingTimeInterval(-1)))
        XCTAssertTrue(value.isAwaitingUpdate(at: expected))
        XCTAssertEqual(UsageFormatting.countdown(to: value.date, from: expected.addingTimeInterval(1)), "00h 00m 00s")
        // A cached past date remains past; there is no invented monthly rollover.
        XCTAssertEqual(SubscriptionMetadata.decode(try auth(), accountID: "fixture-account")?.date, expected)
    }

    func testRejectsMissingDatesMalformedFilesAndOtherAccounts() throws {
        XCTAssertNil(SubscriptionMetadata.decode(try auth(until: nil), accountID: "fixture-account"))
        for until in ["2030-99-99T99:99:99Z", "garbage", ""] {
            XCTAssertNil(SubscriptionMetadata.decode(try auth(until: until), accountID: "fixture-account"))
        }
        XCTAssertNil(SubscriptionMetadata.decode(try auth(), accountID: nil))
        XCTAssertNil(SubscriptionMetadata.decode(try auth(), accountID: "other"))
        XCTAssertNil(SubscriptionMetadata.decode(try auth(tokenAccount: "other"), accountID: "fixture-account"))
        XCTAssertNil(SubscriptionMetadata.decode(try auth(mode: "apikey"), accountID: "fixture-account"))
        for text in ["{}", "not json", #"{"tokens":{"account_id":"fixture-account","id_token":"bad.token"}}"#] {
            XCTAssertNil(SubscriptionMetadata.decode(Data(text.utf8), accountID: "fixture-account"))
        }
    }

    func testReadsActiveCodexHomeWithoutChangingFileAndReloadsRemovedMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("subscription-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let custom = root.appendingPathComponent("custom")
        try FileManager.default.createDirectory(at: custom, withIntermediateDirectories: true)
        let file = custom.appendingPathComponent("auth.json")
        let original = try auth()
        try original.write(to: file)
        XCTAssertNotNil(SubscriptionMetadata.read(accountID: "fixture-account", environment: ["CODEX_HOME": custom.path], homeDirectory: root))
        XCTAssertNotNil(SubscriptionMetadata.read(accountID: "fixture-account", environment: ["CODEX_HOME": "custom"], homeDirectory: root))
        XCTAssertNil(SubscriptionMetadata.read(accountID: "fixture-account", environment: [:], homeDirectory: root))
        XCTAssertEqual(try Data(contentsOf: file), original)
        try auth(until: nil).write(to: file)
        XCTAssertNil(SubscriptionMetadata.read(accountID: "fixture-account", environment: ["CODEX_HOME": custom.path], homeDirectory: root))
        try Data(repeating: 65, count: 1_048_577).write(to: file)
        XCTAssertNil(SubscriptionMetadata.read(accountID: "fixture-account", environment: ["CODEX_HOME": custom.path], homeDirectory: root))
    }
}
