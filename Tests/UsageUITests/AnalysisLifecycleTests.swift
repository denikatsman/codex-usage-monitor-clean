import XCTest
@testable import UsageCore
@testable import CodexUsageMonitor

final class AnalysisLifecycleTests: XCTestCase {
    @MainActor
    func testHiddenAnalysisKeepsCaptureAndLoadsOnOpenThenStopsCleanly() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("analysis-lifecycle-" + UUID().uuidString)
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = sessions.appendingPathComponent("fixture.jsonl")
        let store = root.appendingPathComponent("history.sqlite")
        try Data().write(to: source)
        let model = HistoryModel(storeURL: store, codexHome: root)
        model.setEnabled(true)
        let start = Date()
        let index = try HistoryDatabase(url: root.appendingPathComponent("state_5.sqlite"))
        try index.run("CREATE TABLE threads(id,title,model,rollout_path,creator_account_id,created_at,created_at_ms,updated_at)")
        try index.run("INSERT INTO threads VALUES(?,?,?,?,?,?,?,?)", ["fixture-chat", "Synthetic hidden activity", "fixture-model", source.path, "fixture-account", String(Int64(ceil(start.timeIntervalSince1970))), String(start.timeIntervalSince1970 * 1000), String(start.timeIntervalSince1970)])
        func rows(_ table: String) -> Int {
            guard FileManager.default.fileExists(atPath: store.path),
                  let db = try? HistoryDatabase(url: store, readOnly: true),
                  let values = try? db.query("SELECT COUNT(*) AS n FROM \(table)") else { return 0 }
            return Int(values.first?["n"] ?? "0") ?? 0
        }
        model.receive(try response(10), at: start)
        try await eventually { rows("analysis_meter_v1") == 1 }
        XCTAssertFalse(model.analysisVisible)
        XCTAssertTrue(model.analysis.openIntervals.isEmpty)
        // This synthetic chat begins after collection starts, so its two counters are incremental records.
        let created = Date().timeIntervalSince1970
        try index.run("UPDATE threads SET created_at=?,created_at_ms=?", [String(Int64(ceil(created))), String(created * 1000)])
        try await Task.sleep(nanoseconds: 5_100_000_000) // Advance the real capture deadline; future synthetic capture timestamps are intentionally excluded.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let entries: [[String: Any]] = [
            ["type": "turn_context", "payload": ["model": "fixture-model", "effort": "high", "turn_id": "fixture-turn"]],
            ["type": "event_msg", "payload": ["type": "token_count", "info": ["total_token_usage": ["input_tokens": 100, "output_tokens": 10]]]],
            ["type": "event_msg", "payload": ["type": "token_count", "info": ["total_token_usage": ["input_tokens": 140, "output_tokens": 15]]]]
        ]
        var data = Data()
        for entry in entries {
            var line = entry
            line["timestamp"] = formatter.string(from: Date())
            data.append(try JSONSerialization.data(withJSONObject: line)); data.append(10)
        }
        try data.write(to: source)
        // Collection proceeds on its own cadence while the window remains hidden.
        model.tick(Date())
        try await eventually {
            model.tick(Date())
            return rows("analysis_activity_v1") >= 1
        }
        XCTAssertTrue(model.analysis.intervals.isEmpty)
        XCTAssertTrue(model.analysis.openIntervals.isEmpty)
        model.setAnalysisVisible(true)
        try await eventually { !model.analysis.openIntervals.isEmpty }
        XCTAssertEqual(model.analysis.openIntervals.first?.totals.total, 45)
        model.setAnalysisVisible(false)
        model.setAnalysisVisible(true) // A canceled display must not publish after the replacement.
        model.setAnalysisVisible(false)
        await model.stopAndWait()
        XCTAssertFalse(model.enabled)
        XCTAssertFalse(model.analysisVisible)
        let count = rows("analysis_activity_v1")
        model.tick(Date().addingTimeInterval(30))
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(rows("analysis_activity_v1"), count)
        model.receive(try response(30, account: "different-account"), at: Date())
        XCTAssertTrue(model.analysis.openIntervals.isEmpty)
        XCTAssertTrue(model.analysis.intervals.isEmpty)
        XCTAssertTrue(model.drops.isEmpty)
        await model.stopAndWait()
    }

    @MainActor
    func testRecordingPollingCadenceDoesNotDependOnAnalysisVisibility() throws {
        let usage = UsageModel(initial: try response(10))
        defer { usage.stop() }
        XCTAssertEqual(usage.refreshInterval, 60)
        usage.historyRecording = true
        XCTAssertEqual(usage.refreshInterval, 15)
        usage.historyRecording = false
        XCTAssertEqual(usage.refreshInterval, 60)
        let credits = try JSONDecoder().decode(UsageResponse.self, from: Data(#"{"accountId":"fixture-account","ordinaryUsageAllowed":false,"rateLimits":{"credits":{"hasCredits":true,"unlimited":false,"balance":"100"},"primary":{"usedPercent":100}}}"#.utf8))
        let creditUsage = UsageModel(initial: credits)
        defer { creditUsage.stop() }
        XCTAssertEqual(creditUsage.refreshInterval, 10)
        creditUsage.historyRecording = true
        XCTAssertEqual(creditUsage.refreshInterval, 10)
    }

    private func response(_ used: Int, account: String = "fixture-account") throws -> UsageResponse {
        try JSONDecoder().decode(UsageResponse.self, from: JSONSerialization.data(withJSONObject: ["accountId": account, "rateLimits": ["planType": "pro", "primary": ["usedPercent": used, "windowDurationMins": 10080]]]))
    }
    @MainActor
    private func eventually(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for the synthetic collector", file: file, line: line)
    }
}
