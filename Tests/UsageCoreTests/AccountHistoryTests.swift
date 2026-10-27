import XCTest
@testable import UsageCore

final class AccountHistoryTests: XCTestCase {
    private let time = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970) - 120)
    private func response(_ used: Double, balance: String = "1000", account: String = "fixture-account", ordinary: Bool = true, reset: Double = 1900086400) throws -> UsageResponse {
        let data: [String: Any] = ["accountId": account, "ordinaryUsageAllowed": ordinary,
            "rateLimits": ["primary": ["usedPercent": used, "windowDurationMins": 10080, "resetsAt": reset],
                           "credits": ["hasCredits": true, "unlimited": false, "balance": balance]]]
        return try JSONDecoder().decode(UsageResponse.self, from: JSONSerialization.data(withJSONObject: data))
    }

    func testCreditsUseExactDecimalsAndOnlyAnimateObservedExhaustedDeductions() throws {
        var tracker = CreditDebitTracker()
        XCTAssertNil(tracker.observe(try response(100, ordinary: false), at: time))
        let debit = tracker.observe(try response(100, balance: "899.75", ordinary: false), at: time)
        XCTAssertEqual(debit?.amount, Decimal(string: "100.25"))
        XCTAssertNil(tracker.observe(try response(100, balance: "899.75", ordinary: false), at: time))
        XCTAssertNil(tracker.observe(try response(100, balance: "1100", ordinary: false), at: time))
        XCTAssertNil(tracker.observe(try response(20, balance: "1000"), at: time))
        XCTAssertNil(tracker.observe(try response(100, balance: "900", account: "other", ordinary: false), at: time))
        let unavailable = try JSONDecoder().decode(UsageResponse.self, from: Data(#"{"accountId":"other"}"#.utf8))
        XCTAssertNil(tracker.observe(unavailable, at: time))
        XCTAssertNil(tracker.observe(try response(100, balance: "800", account: "other", ordinary: false), at: time))
        var anonymous = CreditDebitTracker()
        XCTAssertNil(anonymous.observe(try response(100, account: "", ordinary: false), at: time))
        XCTAssertNil(anonymous.observe(try response(100, balance: "900", account: "", ordinary: false), at: time))
    }

    func testResetExpirySupportsTimestampsDateOnlyMissingAndExpiredRecords() throws {
        let time = Date(timeIntervalSince1970: 1900000000) // Keep this explicit date-only expiry fixture fixed.
        let value = try JSONDecoder().decode(UsageResponse.self, from: Data(#"{"rateLimitResetCredits":{"availableCount":4,"credits":[{"id":"a","status":"available","expiresAt":1900000200},{"id":"b","status":"available","expiresAt":"2030-04-01"},{"id":"c","status":"available","expiresAt":1800000000},{"id":"d","status":"available"},{"id":"e","status":"used","expiresAt":1900000300}]}}"#.utf8))
        let available = try XCTUnwrap(value.rateLimitResetCredits).available(at: time)
        XCTAssertEqual(Set(available.map(\.id)), ["a", "b", "d"])
        XCTAssertEqual(available.first?.expiry.date, time.addingTimeInterval(200))
        XCTAssertTrue(available.first { $0.id == "b" }!.expiry.label.contains("time unavailable"))
        XCTAssertEqual(available.first { $0.id == "d" }!.expiry.label, "Expiry unavailable")
    }

    func testNumericCreditsAndUnavailableBalancesAreNotGuessed() throws {
        let numeric = try JSONDecoder().decode(UsageResponse.self, from: Data(#"{"rateLimits":{"credits":{"balance":12.5}}}"#.utf8))
        XCTAssertEqual(numeric.credits?.amount, Decimal(string: "12.5"))
        let missing = try JSONDecoder().decode(UsageResponse.self, from: Data(#"{"rateLimits":{"credits":{"hasCredits":true}}}"#.utf8))
        XCTAssertNil(missing.credits?.amount)
    }

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("usage-monitor-test-history-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testMultiPointDropsCorrectionsResetWindowsAndAccountIsolation() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let recorder = HistoryRecorder(storeURL: root.appendingPathComponent("history.sqlite"), codexHome: root)
        _ = try await recorder.record(response(10), at: time)
        _ = try await recorder.record(response(10), at: time.addingTimeInterval(1))
        var snapshot = try await recorder.record(response(13), at: time.addingTimeInterval(2))
        XCTAssertEqual(snapshot.analysis.intervals.count, 1)
        XCTAssertEqual(snapshot.analysis.intervals.first?.points, 3)
        XCTAssertEqual(snapshot.analysis.intervals.first?.previousObservationAt, time.addingTimeInterval(1))
        _ = try await recorder.record(response(0, reset: 1900186400), at: time.addingTimeInterval(3))
        snapshot = try await recorder.record(response(1, reset: 1900186401), at: time.addingTimeInterval(4))
        XCTAssertEqual(snapshot.analysis.intervals.count, 2) // A one-second server timestamp adjustment is not a reset.
        snapshot = try await recorder.record(response(80, account: "other"), at: time.addingTimeInterval(5))
        XCTAssertTrue(snapshot.analysis.intervals.isEmpty)
        snapshot = try await recorder.record(response(81, account: "other"), at: time.addingTimeInterval(6))
        XCTAssertEqual(snapshot.analysis.intervals.count, 1)
        let unknown = try JSONDecoder().decode(UsageResponse.self, from: Data(#"{"rateLimits":{"primary":{"usedPercent":99}}}"#.utf8))
        snapshot = try await recorder.record(unknown, at: time)
        XCTAssertTrue(snapshot.analysis.intervals.isEmpty)
        XCTAssertTrue(snapshot.note.contains("identity unavailable"))
    }

    func testPauseAndRestartKeepSavedHistoryWithoutJoiningTheDisabledInterval() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("history.sqlite")
        let first = HistoryRecorder(storeURL: store, codexHome: root)
        _ = try await first.record(response(10), at: time)
        _ = try await first.record(response(11), at: time.addingTimeInterval(1))
        let resumed = HistoryRecorder(storeURL: store, codexHome: root)
        var snapshot = try await resumed.record(response(30), at: time.addingTimeInterval(20))
        XCTAssertEqual(snapshot.analysis.intervals.count, 1)
        snapshot = try await resumed.record(response(31), at: time.addingTimeInterval(21))
        XCTAssertEqual(snapshot.analysis.intervals.count, 2)
        XCTAssertEqual(snapshot.analysis.intervals.first?.points, 1)
        let reader = HistoryRecorder(storeURL: store, codexHome: root, readOnly: true)
        let saved = try await reader.loadSaved(accountId: "fixture-account")
        XCTAssertEqual(saved.analysis.intervals.count, 2)
        let other = try await reader.loadSaved(accountId: "other")
        XCTAssertTrue(other.analysis.intervals.isEmpty)
    }

    func testIncrementalLocalActivityDeduplicatesAndNeverCopiesChatMessages() async throws {
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let sources = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let file = sources.appendingPathComponent("fixture.jsonl")
        try Data().write(to: file)
        let index = try HistoryDatabase(url: root.appendingPathComponent("state_5.sqlite"))
        try index.run("CREATE TABLE threads(id,title,model,rollout_path,creator_account_id,created_at,updated_at)")
        try index.run("INSERT INTO threads VALUES(?,?,?,?,?,?,?)", ["fixture-chat", "Example chat", "fixture-model", file.path, "fixture-account", String(Int64(ceil(time.timeIntervalSince1970 + 1))), String(time.timeIntervalSince1970 + 100)])
        let recorder = HistoryRecorder(storeURL: root.appendingPathComponent("history.sqlite"), codexHome: root, startedAt: time)
        _ = try await recorder.record(response(10), at: time)
        func append(_ payload: [String: Any], type: String = "event_msg", seconds: Double) throws {
            let stamp = ISO8601DateFormatter().string(from: time.addingTimeInterval(seconds))
            var data = try JSONSerialization.data(withJSONObject: ["type": type, "timestamp": stamp, "payload": payload]); data.append(10)
            let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: data)
        }
        func token(_ input: Int, used: Int) -> [String: Any] {
            ["type": "token_count", "info": ["total_token_usage": ["input_tokens": input, "cached_input_tokens": input / 2, "output_tokens": input / 10, "reasoning_output_tokens": input / 20]],
             "rate_limits": ["primary": ["used_percent": used, "window_minutes": 10080, "resets_at": 1900086400]]]
        }
        try append(["type": "task_complete"], seconds: 0) // A fork's inherited parent turn is not new work.
        try append(token(100, used: 10), seconds: 1)
        _ = try await recorder.scan(at: time.addingTimeInterval(2))
        try append(token(100, used: 10), seconds: 2) // Repeated counters are not new work.
        try append(["type": "task_complete"], seconds: 3)
        try append(["type": "function_call", "arguments": "SHOULD_NOT_BE_STORED"], type: "response_item", seconds: 3)
        try append(["type": "message", "content": "SHOULD_NOT_BE_STORED"], type: "response_item", seconds: 3)
        try append(token(140, used: 11), seconds: 4)
        _ = try await recorder.scan(at: time.addingTimeInterval(5))
        let result = try await recorder.record(response(11), at: time.addingTimeInterval(6))
        let drop = try XCTUnwrap(result.analysis.intervals.first)
        let chat = try XCTUnwrap(drop.segments.first)
        XCTAssertEqual(chat.tokens.input, 40)
        XCTAssertEqual(chat.tokens.cached, 20)
        XCTAssertEqual(chat.tokens.output, 4)
        XCTAssertEqual(chat.tokens.reasoning, 2)
        XCTAssertEqual(chat.tokens.total, 44)
        XCTAssertEqual(chat.completedTurns, 1); XCTAssertEqual(chat.toolCalls, 1)
        let repeatScan = try await recorder.scan(at: time.addingTimeInterval(6.5))
        XCTAssertNil(repeatScan)
        let db = try HistoryDatabase(url: root.appendingPathComponent("history.sqlite"), readOnly: true)
        XCTAssertTrue(try db.query("SELECT raw FROM activity").isEmpty)
        let columns = try db.query("PRAGMA table_info(analysis_activity_v1)").compactMap { $0["name"] }
        XCTAssertFalse(columns.contains("raw"))
        let stored = try db.query("SELECT * FROM analysis_activity_v1").description
        XCTAssertFalse(stored.contains("SHOULD_NOT_BE_STORED"))
        try append(token(10, used: 11), seconds: 7) // Counter restart: establish a new baseline.
        try append(token(20, used: 12), seconds: 8)
        _ = try await recorder.scan(at: time.addingTimeInterval(9))
        let afterReset = try await recorder.record(response(12), at: time.addingTimeInterval(10))
        XCTAssertEqual(afterReset.analysis.intervals.first?.totals.total, 11)
        XCTAssertTrue(afterReset.note.contains("counter restarted"))
    }
}
