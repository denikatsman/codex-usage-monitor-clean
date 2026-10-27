import XCTest
@testable import UsageCore

/// Synthetic, temporary rollouts exercise collection without reading real chats.
final class AnalysisRecorderTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let source: URL
        let store: URL
        let start: Date
        init() throws {
            start = Date().addingTimeInterval(-120)
            root = FileManager.default.temporaryDirectory.appendingPathComponent("usage-analysis-recorder-" + UUID().uuidString)
            let sessions = root.appendingPathComponent("sessions")
            try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
            source = sessions.appendingPathComponent("fixture.jsonl")
            store = root.appendingPathComponent("history.sqlite")
            try Data().write(to: source)
            let db = try HistoryDatabase(url: root.appendingPathComponent("state_5.sqlite"))
            try db.run("CREATE TABLE threads(id,title,model,rollout_path,creator_account_id,created_at,created_at_ms,updated_at)")
            let created = start.addingTimeInterval(1).timeIntervalSince1970
            try db.run("INSERT INTO threads VALUES(?,?,?,?,?,?,?,?)", ["child", "Synthetic task", "misleading-index-model", source.path, "account-a", String(Int64(ceil(created))), String(created * 1000), String(Date().timeIntervalSince1970)])
            try append(["id": "child"], type: "session_meta", at: 1)
        }
        func recorder() -> HistoryRecorder { HistoryRecorder(storeURL: store, codexHome: root, startedAt: start) }
        func clean() { try? FileManager.default.removeItem(at: root) }
        func append(_ payload: [String: Any], type: String = "event_msg", at offset: Double) throws {
            let date = ISO8601DateFormatter(); date.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var data = try JSONSerialization.data(withJSONObject: ["type": type, "timestamp": date.string(from: start.addingTimeInterval(offset)), "payload": payload])
            data.append(10)
            let file = try FileHandle(forWritingTo: source); defer { try? file.close() }
            try file.seekToEnd(); try file.write(contentsOf: data)
        }
        func token(_ input: Int, output: Int = 0, cached: Int = 0, write: Int = 0, reasoning: Int = 0, at: Double, misleadingUsed: Int = 90) throws {
            try append(["type": "token_count", "info": ["total_token_usage": ["input_tokens": input, "cached_input_tokens": cached, "cache_write_input_tokens": write, "output_tokens": output, "reasoning_output_tokens": reasoning]], "rate_limits": ["primary": ["used_percent": misleadingUsed, "window_minutes": 10080, "resets_at": start.addingTimeInterval(86400).timeIntervalSince1970]]], at: at)
        }
        func response(_ used: Int, account: String = "account-a") throws -> UsageResponse {
            try JSONDecoder().decode(UsageResponse.self, from: JSONSerialization.data(withJSONObject: ["accountId": account, "rateLimits": ["planType": "pro", "primary": ["usedPercent": used, "windowDurationMins": 10080, "resetsAt": start.addingTimeInterval(86400).timeIntervalSince1970]]]))
        }
        func rows(_ sql: String) throws -> [[String: String]] { try HistoryDatabase(url: store, readOnly: true).query(sql) }
    }

    func testAnalysisUsesAccountMeterOnlyAndDeduplicatesCumulativeCounters() async throws {
        let f = try Fixture(); defer { f.clean() }
        let recorder = f.recorder()
        _ = try await recorder.record(f.response(10), at: f.start)
        try f.append(["model": "model-a", "effort": "high", "turn_id": "turn-a"], type: "turn_context", at: 2)
        try f.token(100, output: 20, at: 3)
        try f.token(100, output: 20, at: 4, misleadingUsed: 95)
        try f.token(150, output: 30, cached: 25, write: 7, reasoning: 4, at: 5, misleadingUsed: 99)
        _ = try await recorder.scan(at: f.start.addingTimeInterval(6))
        let snapshot = try await recorder.record(f.response(11), at: f.start.addingTimeInterval(7))
        let interval = try XCTUnwrap(snapshot.analysis.intervals.first)
        XCTAssertEqual(interval.points, 1)
        XCTAssertEqual(interval.totals.input, 50)
        XCTAssertEqual(interval.totals.output, 10)
        XCTAssertEqual(interval.totals.cached, 25)
        XCTAssertEqual(interval.totals.cacheWrite, 7)
        XCTAssertEqual(interval.totals.reasoning, 4)
        XCTAssertEqual(try f.rows("SELECT * FROM analysis_meter_v1").count, 2)
        let count = try f.rows("SELECT * FROM analysis_activity_v1").count
        let unchanged = try await recorder.scan(at: f.start.addingTimeInterval(8))
        XCTAssertNil(unchanged)
        XCTAssertEqual(try f.rows("SELECT * FROM analysis_activity_v1").count, count)
    }

    func testNewThreadCreatedWithinStartSecondUsesMillisecondPrecision() async throws {
        let f = try Fixture(); defer { f.clean() }
        let recorder = f.recorder()
        let floorSecond = floor(f.start.timeIntervalSince1970)
        let created = (f.start.timeIntervalSince1970 + floorSecond + 1) / 2
        let index = try HistoryDatabase(url: f.root.appendingPathComponent("state_5.sqlite"))
        try index.run("UPDATE threads SET created_at=?,created_at_ms=?", [String(Int64(floorSecond)), String(created * 1000)])
        _ = try await recorder.record(f.response(10), at: f.start)
        try f.token(100, at: 2)
        try f.token(140, at: 3)
        _ = try await recorder.scan(at: f.start.addingTimeInterval(4))
        let snapshot = try await recorder.record(f.response(11), at: f.start.addingTimeInterval(5))
        XCTAssertEqual(snapshot.analysis.intervals.first?.totals.input, 40)
    }

    func testCounterRestartRebaselinesAndRetainsCoverageWarning() async throws {
        let f = try Fixture(); defer { f.clean() }
        let recorder = f.recorder()
        _ = try await recorder.record(f.response(10), at: f.start)
        try f.token(100, at: 2)
        try f.token(140, at: 3)
        try f.token(10, at: 4)
        try f.token(25, at: 5)
        _ = try await recorder.scan(at: f.start.addingTimeInterval(6))
        let snapshot = try await recorder.record(f.response(11), at: f.start.addingTimeInterval(7))
        let interval = try XCTUnwrap(snapshot.analysis.intervals.first)
        XCTAssertEqual(interval.totals.input, 55)
        XCTAssertTrue(interval.issues.contains { $0.contains("counter restarted") })
        XCTAssertFalse(interval.isCalibrationEligible)
    }

    func testContextSwitchMetadataAndDurationArePreservedWithAmbiguity() async throws {
        let f = try Fixture(); defer { f.clean() }
        let recorder = f.recorder()
        _ = try await recorder.record(f.response(10), at: f.start)
        try f.append(["id": "child", "cwd": "/fixture/project", "parent_thread_id": "parent", "source": ["subagent": ["thread_spawn": ["agent_path": "/root/child", "parent_thread_id": "parent"]]]], type: "session_meta", at: 2)
        try f.append(["model": "model-a", "effort": "low", "turn_id": "turn-a", "cwd": "/fixture/project"], type: "turn_context", at: 3)
        try f.token(100, at: 4)
        try f.token(120, at: 5)
        try f.append(["model": "model-b", "effort": "high", "speed": "fast", "turn_id": "turn-b"], type: "turn_context", at: 6)
        try f.token(150, at: 7)
        try f.append(["type": "task_complete", "turn_id": "turn-b", "duration_ms": 12500], at: 8)
        _ = try await recorder.scan(at: f.start.addingTimeInterval(9))
        let snapshot = try await recorder.record(f.response(11), at: f.start.addingTimeInterval(10))
        let interval = try XCTUnwrap(snapshot.analysis.intervals.first)
        let first = try XCTUnwrap(interval.segments.first { $0.model == "model-a" })
        let mixed = try XCTUnwrap(interval.segments.first { $0.tokens.input == 30 })
        let completion = try XCTUnwrap(interval.segments.first { $0.completedTurns == 1 })
        XCTAssertEqual(first.effort, "low"); XCTAssertEqual(first.tokens.input, 20)
        XCTAssertEqual(mixed.model, "Unknown"); XCTAssertEqual(mixed.effort, "Unknown")
        XCTAssertEqual(mixed.turnID, "turn-b")
        XCTAssertEqual(mixed.project, "/fixture/project")
        XCTAssertEqual(mixed.parentThreadID, "parent"); XCTAssertEqual(mixed.agentPath, "/root/child")
        XCTAssertEqual(completion.model, "model-b"); XCTAssertEqual(completion.effort, "high")
        XCTAssertEqual(completion.completedTurns, 1); XCTAssertEqual(completion.turnDurationSeconds, 12.5)
        XCTAssertTrue(mixed.issues.contains { $0.contains("configuration change") })
        // The overlay corrects display attribution without rewriting recorded context.
        let original = try XCTUnwrap(f.rows("SELECT * FROM analysis_activity_v1 WHERE input=30").first)
        XCTAssertEqual(original["model"], "model-b"); XCTAssertEqual(original["effort"], "high")
        XCTAssertEqual(original["speed"], "priority")
        XCTAssertFalse(interval.isCalibrationEligible)
    }

    func testInheritedParentRecordsOnlyEstablishChildCounterBaseline() async throws {
        let f = try Fixture(); defer { f.clean() }
        let recorder = f.recorder()
        _ = try await recorder.record(f.response(10), at: f.start)
        try f.append(["model": "model-a", "effort": "high", "turn_id": "inherited"], type: "turn_context", at: -20)
        try f.token(100, at: -10)
        try f.append(["type": "task_complete", "duration_ms": 90000], at: 0)
        try f.append(["model": "model-a", "effort": "high", "turn_id": "child-turn"], type: "turn_context", at: 2)
        try f.token(140, at: 3)
        _ = try await recorder.scan(at: f.start.addingTimeInterval(4))
        let snapshot = try await recorder.record(f.response(11), at: f.start.addingTimeInterval(5))
        let interval = try XCTUnwrap(snapshot.analysis.intervals.first)
        XCTAssertEqual(interval.totals.input, 40)
        XCTAssertEqual(interval.segments.reduce(0) { $0 + $1.completedTurns }, 0)
        XCTAssertEqual(interval.segments.map(\.turnID), ["child-turn"])
    }

    func testSavedAnalysisSeparatesAccountsAndRecordingEpochsAcrossRestart() async throws {
        let f = try Fixture(); defer { f.clean() }
        let first = f.recorder()
        _ = try await first.record(f.response(10), at: f.start)
        _ = try await first.record(f.response(11), at: f.start.addingTimeInterval(5))
        let resumed = HistoryRecorder(storeURL: f.store, codexHome: f.root, startedAt: f.start.addingTimeInterval(10))
        _ = try await resumed.record(f.response(40), at: f.start.addingTimeInterval(10))
        let saved = try await resumed.record(f.response(41), at: f.start.addingTimeInterval(15))
        XCTAssertEqual(saved.analysis.intervals.count, 2)
        XCTAssertEqual(Set(saved.analysis.intervals.map(\.epoch)).count, 2)
        XCTAssertTrue(saved.analysis.intervals.allSatisfy { $0.points == 1 })
        let other = try await resumed.record(f.response(80, account: "account-b"), at: f.start.addingTimeInterval(20))
        XCTAssertTrue(other.analysis.intervals.isEmpty)
        let reader = HistoryRecorder(storeURL: f.store, codexHome: f.root, readOnly: true)
        let reloaded = try await reader.loadSaved(accountId: "account-a")
        XCTAssertEqual(reloaded.analysis.intervals.count, 2)
        XCTAssertEqual(Set(reloaded.analysis.intervals.map(\.id)), Set(saved.analysis.intervals.map(\.id)))
        let unknown = try await reader.loadSaved(accountId: "unknown")
        XCTAssertTrue(unknown.analysis.intervals.isEmpty)
    }

    func testMissingIndexPersistsCoverageWarningInAffectedInterval() async throws {
        let f = try Fixture(); defer { f.clean() }
        let recorder = f.recorder()
        _ = try await recorder.record(f.response(10), at: f.start)
        try FileManager.default.removeItem(at: f.root.appendingPathComponent("state_5.sqlite"))
        _ = try await recorder.scan(at: f.start.addingTimeInterval(2))
        let snapshot = try await recorder.record(f.response(11), at: f.start.addingTimeInterval(3))
        let interval = try XCTUnwrap(snapshot.analysis.intervals.first)
        XCTAssertTrue(interval.issues.contains { $0.contains("index unavailable") })
        XCTAssertFalse(interval.isCalibrationEligible)
        XCTAssertFalse(try f.rows("SELECT issues FROM analysis_activity_v1").isEmpty)
    }

    func testMalformedSourceRecordBlocksCalibrationWithoutLosingValidDelta() async throws {
        let f = try Fixture(); defer { f.clean() }
        let recorder = f.recorder()
        _ = try await recorder.record(f.response(10), at: f.start)
        try f.append(["model": "model-a", "effort": "high", "turn_id": "turn-a"], type: "turn_context", at: 2)
        try f.token(100, at: 2)
        try f.token(120, at: 3)
        _ = try await recorder.scan(at: f.start.addingTimeInterval(4))
        _ = try await recorder.record(f.response(11), at: f.start.addingTimeInterval(5))
        let handle = try FileHandle(forWritingTo: f.source)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("{invalid json}\n".utf8)); try handle.close()
        try f.token(140, at: 7)
        _ = try await recorder.scan(at: f.start.addingTimeInterval(8))
        let snapshot = try await recorder.record(f.response(12), at: f.start.addingTimeInterval(9))
        let interval = try XCTUnwrap(snapshot.analysis.intervals.first)
        XCTAssertFalse(interval.isBaseline)
        XCTAssertEqual(interval.totals.input, 20)
        XCTAssertTrue(interval.issues.contains { $0.localizedCaseInsensitiveContains("unreadable") })
        XCTAssertFalse(interval.isCalibrationEligible)
    }

    func testPausedSavedViewFreezesOpenDurationAtLastCaptureEvenYearsLater() async throws {
        let f = try Fixture(); defer { f.clean() }
        let past = Date(timeIntervalSince1970: 1_600_000_000)
        let recorder = HistoryRecorder(storeURL: f.store, codexHome: f.root, startedAt: past)
        _ = try await recorder.record(f.response(10), at: past)
        _ = try await recorder.record(f.response(10), at: past.addingTimeInterval(30))
        _ = try await recorder.record(f.response(11), at: past.addingTimeInterval(60))
        _ = try await recorder.record(f.response(11), at: past.addingTimeInterval(90))
        let reader = HistoryRecorder(storeURL: f.store, codexHome: f.root, readOnly: true)
        let snapshot = try await reader.loadSaved(accountId: "account-a")
        XCTAssertEqual(snapshot.analysis.intervals.count, 1, "Paused analysis retains the last recorded fortnight rather than discarding old history relative to today.")
        let open = try XCTUnwrap(snapshot.analysis.openIntervals.first)
        XCTAssertEqual(open.durationSeconds, 30)
        XCTAssertEqual(snapshot.analysis.generatedAt, past.addingTimeInterval(90))
        XCTAssertFalse(open.issues.contains { $0.contains("older than 90 seconds") })
        let reloaded = try await reader.loadSaved(accountId: "account-a")
        XCTAssertEqual(reloaded.analysis.openIntervals.first?.durationSeconds, 30)
        XCTAssertEqual(reloaded.analysis.generatedAt, snapshot.analysis.generatedAt)
        let db = try HistoryDatabase(url: f.store)
        let epoch = try XCTUnwrap(db.query("SELECT epoch FROM analysis_meter_v1 LIMIT 1").first?["epoch"])
        try AnalysisStore.activity(db, ActivityObservation(id: "late-captured", account: HistoryRecorder.accountKey("account-a"), epoch: epoch,
            threadID: "synthetic", title: "Synthetic late capture", sourceAt: past.addingTimeInterval(80),
            capturedAt: past.addingTimeInterval(100), tokens: .init()))
        let late = try await reader.loadSaved(accountId: "account-a")
        XCTAssertEqual(late.analysis.generatedAt, past.addingTimeInterval(100))
        XCTAssertEqual(late.analysis.openIntervals.first?.durationSeconds, 40)
    }

    func testHistoricalMetadataOverlayRecoversDisplayWithoutRewritingOriginalUnknownRows() async throws {
        let f = try Fixture(); defer { f.clean() }
        let recorder = f.recorder()
        _ = try await recorder.record(f.response(10), at: f.start)
        try f.append(["model": "model-a", "effort": "high", "turn_id": "own-turn"], type: "turn_context", at: 2)
        try f.token(100, at: 3)
        let offset = try XCTUnwrap((FileManager.default.attributesOfItem(atPath: f.source.path)[.size] as? NSNumber)?.uint64Value)
        try f.token(140, at: 5)
        let db = try HistoryDatabase(url: f.store)
        let epoch = try XCTUnwrap(db.query("SELECT epoch FROM analysis_meter_v1 LIMIT 1").first?["epoch"])
        let account = HistoryRecorder.accountKey("account-a")
        var tokens = TokenMetrics(); tokens.input = 40
        let id = epoch + f.source.path + ":" + UUID().uuidString + ":" + String(offset)
        try AnalysisStore.activity(db, .init(id: id, account: account, epoch: epoch, threadID: "child", title: "Historical task",
            sourceAt: f.start.addingTimeInterval(5), capturedAt: f.start.addingTimeInterval(6), tokens: tokens))
        _ = try await recorder.record(f.response(11), at: f.start.addingTimeInterval(7))
        try db.run("INSERT INTO request_evidence_v1 VALUES (?,?,?,?,?,?,?,?,?,?,?,?)", [account, "synthetic-capture", "0", "1", "child", "own-turn", String(f.start.addingTimeInterval(2.5).timeIntervalSince1970), "model-a", "high", "default", "default", "[]"])
        try db.run("INSERT INTO request_evidence_coverage_v1 VALUES (?,?,?,?,?)", [account, "synthetic-capture", "child", String(f.start.addingTimeInterval(2).timeIntervalSince1970), String(f.start.addingTimeInterval(6).timeIntervalSince1970)])
        let original = try db.query("SELECT * FROM analysis_activity_v1")
        let meters = try db.query("SELECT * FROM analysis_meter_v1")
        XCTAssertEqual(original.first?["model"], "Unknown")
        XCTAssertEqual(original.first?["effort"], "Unknown")
        XCTAssertEqual(original.first?["speed"], "Unknown")
        let recovered = try await recorder.recoverSaved()
        XCTAssertEqual(recovered["modelAndEffortRecovered"], 1)
        XCTAssertEqual(try db.query("SELECT * FROM analysis_activity_v1"), original)
        XCTAssertEqual(try db.query("SELECT * FROM analysis_meter_v1"), meters)
        let reader = HistoryRecorder(storeURL: f.store, codexHome: f.root, readOnly: true)
        let snapshot = try await reader.loadSaved(accountId: "account-a")
        let segment = try XCTUnwrap(snapshot.analysis.intervals.first?.segments.first)
        XCTAssertEqual(segment.tokens.input, 40)
        XCTAssertEqual(segment.model, "model-a"); XCTAssertEqual(segment.effort, "high")
        XCTAssertEqual(segment.speed, "default"); XCTAssertEqual(segment.turnID, "own-turn")
        XCTAssertTrue(segment.provenance.contains { $0.contains("turn_context") })
        XCTAssertTrue(segment.issues.isEmpty, "Recovered segment issues: \(segment.issues)")
    }

    func testAtomicSameSizeAndLargerReplacementRebaselineWithoutRecountingPrefix() async throws {
        for larger in [false, true] {
            let f = try Fixture(); defer { f.clean() }
            let recorder = f.recorder()
            _ = try await recorder.record(f.response(10), at: f.start)
            try f.append(["model": "model-a", "effort": "high", "turn_id": "own"], type: "turn_context", at: 2)
            try f.token(100, at: 3); try f.token(120, at: 4)
            _ = try await recorder.scan(at: f.start.addingTimeInterval(5))
            let originalRows = try f.rows("SELECT * FROM analysis_activity_v1 ORDER BY id")
            XCTAssertEqual(originalRows.compactMap { $0["input"].flatMap(Int.init) }.reduce(0, +), 20)
            let before = try String(contentsOf: f.source, encoding: .utf8)
            XCTAssertTrue(before.contains("\"input_tokens\":120"))
            let replacement = before.replacingOccurrences(of: "\"input_tokens\":100", with: "\"input_tokens\":900")
                .replacingOccurrences(of: "\"input_tokens\":120", with: "\"input_tokens\":920")
            XCTAssertEqual(replacement.utf8.count, before.utf8.count)
            try Data(replacement.utf8).write(to: f.source, options: .atomic)
            if larger { try f.append(["type": "message", "content": "Synthetic padding to make replacement larger"], type: "response_item", at: 5.5) }
            let newSize = try FileManager.default.attributesOfItem(atPath: f.source.path)[.size] as? NSNumber
            XCTAssertEqual(newSize?.intValue == before.utf8.count, !larger)
            _ = try await recorder.scan(at: f.start.addingTimeInterval(6))
            try f.token(950, at: 7)
            _ = try await recorder.scan(at: f.start.addingTimeInterval(8))
            let rows = try f.rows("SELECT * FROM analysis_activity_v1 ORDER BY id")
            for original in originalRows {
                XCTAssertEqual(rows.first { $0["id"] == original["id"] }, original, "Replacement must preserve original evidence.")
            }
            XCTAssertEqual(rows.compactMap { $0["input"].flatMap(Int.init) }.reduce(0, +), 50, "Only 20 original + 30 new tokens are recorded; replacement prefix is a baseline.")
            XCTAssertTrue(rows.contains { $0["issues"]?.contains("Source file restarted") == true })
        }
    }

    func testReadOnlyLegacyHistoryDoesNotCreateAnalysisTables() async throws {
        let f = try Fixture(); defer { f.clean() }
        let db = try HistoryDatabase(url: f.store)
        try db.run("CREATE TABLE observations (id TEXT PRIMARY KEY,account,bucket,title,at,used,reset,captured,epoch)")
        try db.run("CREATE TABLE activity (id TEXT PRIMARY KEY,account,thread,title,model,at,input,cached,output,reasoning,turns,tools,raw)")
        let before = try db.query("SELECT name,sql FROM sqlite_master ORDER BY name")
        let reader = HistoryRecorder(storeURL: f.store, codexHome: f.root, readOnly: true)
        let snapshot = try await reader.loadSaved(accountId: "account-a")
        XCTAssertTrue(snapshot.analysis.intervals.isEmpty)
        XCTAssertTrue(snapshot.analysis.openIntervals.isEmpty)
        XCTAssertEqual(try db.query("SELECT name,sql FROM sqlite_master ORDER BY name"), before)
        XCTAssertTrue(try db.query("SELECT name FROM sqlite_master WHERE name LIKE 'analysis_%'").isEmpty)
    }
}
