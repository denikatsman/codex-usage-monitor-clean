import XCTest
@testable import UsageCore

final class RequestEvidenceTests: XCTestCase {
    private final class Fixture {
        let root: URL
        let db: HistoryDatabase
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("request-evidence-" + UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            db = try HistoryDatabase(url: root.appendingPathComponent("owned.sqlite"))
            try RequestEvidence.create(in: db)
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        func source(_ name: String = "logs_2.sqlite") throws -> HistoryDatabase {
            let source = try HistoryDatabase(url: root.appendingPathComponent(name))
            try source.run("CREATE TABLE IF NOT EXISTS logs(id INTEGER PRIMARY KEY,ts INTEGER NOT NULL,ts_nanos INTEGER NOT NULL,target TEXT NOT NULL,feedback_log_body TEXT,thread_id TEXT,module_path TEXT DEFAULT 'codex_core::session::turn',file TEXT DEFAULT 'core/src/session/turn.rs')")
            try source.run("CREATE INDEX IF NOT EXISTS logs_thread ON logs(thread_id,ts)")
            return source
        }
        func append(_ id: Int, at: Int, thread: String = "thread", turn: String = "turn", model: String = "model", effort: String = "High", tier: Any? = "priority", name: String = "logs_2.sqlite") throws {
            var tags: [String: Any] = ["private_message": "DO_NOT_PERSIST_THIS_MESSAGE"]
            if let tier { tags["service_tier"] = tier }
            let json = String(decoding: try JSONSerialization.data(withJSONObject: tags, options: [.sortedKeys]), as: UTF8.self)
            let body = "turn{turn.id=\(turn)}:run_sampling_request{turn_id=\(turn)}:try_run_sampling_request{turn_id=\(turn)}: model=\"\(model)\" effort=Some(\(effort)) tags_json=\(json) trailing_fields=ignored"
            try source(name).run("INSERT INTO logs(id,ts,ts_nanos,target,feedback_log_body,thread_id) VALUES (?,?,0,'feedback_tags',?,?)", [String(id),String(at),body,thread])
        }
        func collect(account: String = "account", threads: Set<String> = ["thread"]) throws {
            try RequestEvidence.collect(into: db, codexHome: root, account: account, threads: threads, since: Date(timeIntervalSince1970: 0))
        }
        func resolve(account: String = "account", thread: String = "thread", turn: String = "turn", start: Double? = 0, end: Double = 100) throws -> RequestAttribution {
            try RequestEvidence.resolve(in: db, account: account, threadID: thread, turnID: turn, startAt: start.map(Date.init(timeIntervalSince1970:)), endAt: Date(timeIntervalSince1970: end))
        }
    }

    func testTierValuesAndPrivacyWhitelist() throws {
        let f = try Fixture()
        let cases: [(Any?, String?)] = [("priority","priority"),("default","default"),("unset","unset"),("fast","priority"),("standard","default"),("ultrafast","ultrafast"),("future-tier","future-tier"),(NSNull(),nil),(nil,nil)]
        for (index, item) in cases.enumerated() {
            try f.append(index + 1, at: 10, turn: "turn-\(index)", tier: item.0)
        }
        try f.collect()
        for (index,item) in cases.enumerated() {
            let result = try f.resolve(turn: "turn-\(index)", start: 10)
            XCTAssertEqual(result.tier, item.1)
            XCTAssertEqual(result.model,"model"); XCTAssertEqual(result.effort,"high")
            XCTAssertEqual(result.references.count,1)
            if item.1 == nil || item.1 == "future-tier" { XCTAssertFalse(result.issues.isEmpty) }
            else { XCTAssertTrue(result.issues.isEmpty, result.issues.joined(separator: ",")) }
        }
        let records = try f.db.query("SELECT * FROM request_evidence_v1")
        XCTAssertFalse(records.description.contains("DO_NOT_PERSIST_THIS_MESSAGE"))
        XCTAssertEqual(records.first { $0["turn"] == "turn-3" }?["raw_tier"],"fast")
        XCTAssertEqual(records.first { $0["turn"] == "turn-7" }?["raw_tier"],nil)
    }

    func testSpanIncludesPriorSettingsAndDetectsEveryDimensionChanging() throws {
        let f = try Fixture()
        try f.append(1,at:10,tier:"priority")
        try f.append(2,at:20,tier:"default")
        try f.append(3,at:30,model:"other-model",effort:"Max",tier:"default")
        try f.append(4,at:40,turn:"different-turn",model:"irrelevant",tier:"priority")
        try f.collect()
        let sparse = try f.resolve(start:12,end:19)
        XCTAssertEqual(sparse.tier,"priority"); XCTAssertTrue(sparse.issues.isEmpty)
        let tierChange = try f.resolve(start:12,end:20)
        XCTAssertNil(tierChange.tier); XCTAssertEqual(tierChange.model,"model")
        XCTAssertTrue(tierChange.issues.contains { $0.contains("service tier changed") })
        let allChanged = try f.resolve(start:12,end:100)
        XCTAssertNil(allChanged.model); XCTAssertNil(allChanged.effort); XCTAssertNil(allChanged.tier)
        XCTAssertEqual(allChanged.references.count,3)
        let noPrefix = try f.resolve(start:5,end:15)
        XCTAssertTrue(noPrefix.issues.contains { $0.contains("beginning") })
        let noStart = try f.resolve(start:nil)
        XCTAssertTrue(noStart.issues.contains { $0.contains("start unavailable") })
        let absent = try f.resolve(turn:"absent")
        XCTAssertNil(absent.model); XCTAssertTrue(absent.references.isEmpty)
    }

    func testThreadAndAccountIsolationNewThreadBackfillAndRepeatedCollection() throws {
        let f = try Fixture()
        try f.append(1,at:10,thread:"one",model:"model-one")
        try f.append(2,at:11,thread:"two",model:"model-two")
        try f.collect(threads:["one"])
        try f.collect(account:"other-account",threads:["two"])
        XCTAssertNil(try f.resolve(thread:"two").model)
        XCTAssertNil(try f.resolve(account:"other-account",thread:"one").model)
        try f.collect(threads:["one","two"])
        try f.collect(threads:["one","two"])
        XCTAssertEqual(try f.resolve(thread:"two",start:12).model,"model-two")
        XCTAssertEqual(try f.db.query("SELECT * FROM request_evidence_v1").count,3)
    }

    func testRotationAndInPlaceIDResetKeepImmutableEvidence() throws {
        let f = try Fixture()
        try f.append(10,at:10)
        try f.collect()
        let first = try f.resolve(start:10).references
        try f.source().run("DELETE FROM logs")
        try f.append(1,at:20,tier:"default")
        try f.collect()
        let reset = try f.resolve(start:10)
        XCTAssertEqual(reset.references.count,2)
        XCTAssertTrue(Set(first).isSubset(of:Set(reset.references)))
        try FileManager.default.moveItem(at:f.root.appendingPathComponent("logs_2.sqlite"),to:f.root.appendingPathComponent("old.sqlite"))
        try f.append(1,at:30,tier:"unset")
        try f.collect()
        XCTAssertEqual(try f.resolve(start:10).references.count,3)
        XCTAssertEqual(try f.resolve(start:30).tier,"unset")
    }

    func testReusedCursorIDWithHigherMaximumIsDetected() throws {
        let f = try Fixture()
        try f.append(1,at:10)
        try f.collect()
        try f.source().run("DELETE FROM logs")
        try f.append(1,at:20,tier:"default")
        try f.append(2,at:30,tier:"default")
        try f.collect()
        XCTAssertEqual(try f.resolve(start:10).references.count,3)
        XCTAssertEqual(try f.resolve(start:20).tier,"default")
    }

    func testBoundedBacklogIsExplicitAndEventuallyCompletes() throws {
        let f = try Fixture()
        let source = try f.source()
        let body = #"run_sampling_request{turn_id=turn}: model="model" effort=Some(High) tags_json={"service_tier":"unset"}"#
        try source.run("WITH RECURSIVE n(x) AS (VALUES(1) UNION ALL SELECT x+1 FROM n WHERE x<1002) INSERT INTO logs(id,ts,ts_nanos,target,feedback_log_body,thread_id) SELECT x,x,0,'feedback_tags',?,'thread' FROM n",[body])
        try f.collect()
        XCTAssertEqual(try f.db.query("SELECT * FROM request_evidence_v1").count,1000)
        XCTAssertTrue(try f.resolve(start:1,end:2000).issues.contains { $0.contains("catching up") })
        try f.collect()
        XCTAssertEqual(try f.db.query("SELECT * FROM request_evidence_v1").count,1002)
        XCTAssertFalse(try f.resolve(start:1,end:2000).issues.contains { $0.contains("catching up") })
    }

    func testFailedCollectionRollsBackEvidenceAndCursorTogether() throws {
        let f = try Fixture()
        try f.append(1,at:10)
        try f.append(2,at:20)
        try f.db.run("CREATE TRIGGER fail_evidence BEFORE INSERT ON request_evidence_v1 WHEN NEW.log_id=2 BEGIN SELECT RAISE(ABORT,'fixture failure'); END")
        XCTAssertThrowsError(try f.collect())
        XCTAssertTrue(try f.db.query("SELECT * FROM request_evidence_v1").isEmpty)
        XCTAssertTrue(try f.db.query("SELECT * FROM request_evidence_cursor_v1").isEmpty)
        try f.db.run("DROP TRIGGER fail_evidence")
        try f.collect()
        XCTAssertEqual(try f.resolve(start:10).references.count,2)
    }

    func testCancelledCollectionDoesNotAdvanceCursor() async throws {
        let f = try Fixture()
        try f.append(1,at:10)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try f.collect()
        }
        do { try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
        XCTAssertTrue(try f.db.query("SELECT * FROM request_evidence_v1").isEmpty)
        XCTAssertTrue(try f.db.query("SELECT * FROM request_evidence_cursor_v1").isEmpty)
    }

    func testExplicitCaptureImportIsScopedDeduplicatedAndKeepsProvenance() throws {
        let f = try Fixture()
        let capture = f.root.appendingPathComponent("capture.json")
        let records: [[String: Any]] = [
            ["log_id": 1,"ts": 10,"ts_nanos": 5,"thread": "thread","turn": "turn","model": "model","effort": "High","service_tier_present": true,"service_tier": "fast","unselected_message": "DO_NOT_PERSIST_THIS_MESSAGE"],
            ["log_id": 2,"ts": 20,"ts_nanos": 0,"thread": "other","turn": "turn","model": "other-model","effort": "Max","service_tier_present": true,"service_tier": "unset"]
        ]
        try JSONSerialization.data(withJSONObject: ["requests": records,"query_start": 0,"query_end": 100]).write(to: capture)
        try RequestEvidence.importCapture(capture,into:f.db,account:"account",threads:["thread"])
        try RequestEvidence.importCapture(capture,into:f.db,account:"account",threads:["thread"])
        let result = try f.resolve(start:11,end:90)
        XCTAssertEqual(result.tier,"priority"); XCTAssertEqual(result.effort,"high")
        XCTAssertTrue(result.issues.isEmpty)
        XCTAssertTrue(result.references.first?.hasPrefix("sampling:audit-capture:") == true)
        XCTAssertNil(try f.resolve(thread:"other").model)
        XCTAssertNil(try f.resolve(account:"other-account").model)
        let stored = try f.db.query("SELECT * FROM request_evidence_v1")
        XCTAssertEqual(stored.count,1); XCTAssertEqual(stored.first?["raw_tier"],"fast")
        XCTAssertFalse(stored.description.contains("DO_NOT_PERSIST_THIS_MESSAGE"))
        XCTAssertTrue(try f.resolve(start:11,end:110).issues.contains { $0.contains("complete counter span") })
        // A current read of the same thread's live logs supplies coverage beyond
        // the older capture without treating the last request time as its end.
        try f.append(3,at:90,tier:"fast")
        try f.collect()
        XCTAssertFalse(try f.resolve(start:90,end:110).issues.contains { $0.contains("complete counter span") })
    }

    func testMalformedCaptureRejectsBeforeAnyPartialWrite() throws {
        let f = try Fixture()
        let capture = f.root.appendingPathComponent("malformed.json")
        let good: [String: Any] = ["log_id": 1,"ts": 10,"ts_nanos": 0,"thread": "thread","turn": "turn","model": "model","effort": "High","service_tier_present": true,"service_tier": "unset"]
        var bad = good; bad["log_id"] = 2; bad["turn"] = ""
        try JSONSerialization.data(withJSONObject:["requests":[good,bad],"query_start":0,"query_end":100]).write(to:capture)
        XCTAssertThrowsError(try RequestEvidence.importCapture(capture,into:f.db,account:"account",threads:["thread"]))
        XCTAssertTrue(try f.db.query("SELECT * FROM request_evidence_v1").isEmpty)
        XCTAssertTrue(try f.db.query("SELECT * FROM request_evidence_coverage_v1").isEmpty)
        bad = good; bad["ts"] = "not-a-number"
        try JSONSerialization.data(withJSONObject:["requests":[good,bad]]).write(to:capture)
        XCTAssertThrowsError(try RequestEvidence.importCapture(capture,into:f.db,account:"account",threads:["thread"]))
        XCTAssertTrue(try f.db.query("SELECT * FROM request_evidence_v1").isEmpty)
        bad = good; bad["service_tier_present"] = false
        try JSONSerialization.data(withJSONObject:["requests":[bad]]).write(to:capture)
        XCTAssertThrowsError(try RequestEvidence.importCapture(capture,into:f.db,account:"account",threads:["thread"]))
    }

    func testCopiedLogsCoverageStopsAtExplicitCaptureTime() throws {
        let f = try Fixture()
        try f.append(1,at:10)
        try f.append(2,at:40)
        try RequestEvidence.collect(into:f.db,codexHome:f.root,account:"account",threads:["thread"],since:Date(timeIntervalSince1970:0),through:Date(timeIntervalSince1970:50))
        // A request at 40 supports token reporting through the capture at 50.
        XCTAssertFalse(try f.resolve(start:10,end:49).issues.contains { $0.contains("complete counter span") })
        XCTAssertTrue(try f.resolve(start:10,end:51).issues.contains { $0.contains("complete counter span") })
        XCTAssertEqual(try f.db.query("SELECT end_at FROM request_evidence_coverage_v1").first?["end_at"].flatMap(Double.init),50)
        // A subsequent genuinely live collection can extend the old capture.
        try f.collect()
        XCTAssertFalse(try f.resolve(start:10,end:51).issues.contains { $0.contains("complete counter span") })
    }

    func testMalformedSamplingPersistsGapWhileUnrelatedFeedbackIsIgnored() throws {
        let f = try Fixture()
        try f.append(1,at:10)
        let source = try f.source()
        try source.run("INSERT INTO logs(id,ts,ts_nanos,target,feedback_log_body,thread_id) VALUES (2,15,0,'feedback_tags',?,'thread')",["unrelated feedback DO_NOT_PERSIST_THIS_MESSAGE"])
        try source.run("INSERT INTO logs(id,ts,ts_nanos,target,feedback_log_body,thread_id) VALUES (3,20,0,'feedback_tags',?,'thread')",["run_sampling_request{unrecognized_format=true} DO_NOT_PERSIST_THIS_MESSAGE"])
        try f.append(4,at:40)
        try f.collect()
        try f.collect()
        let gaps = try f.db.query("SELECT * FROM request_evidence_gap_v1")
        XCTAssertEqual(gaps.count,1); XCTAssertEqual(gaps.first?["log_id"],"3")
        XCTAssertFalse(gaps.description.contains("DO_NOT_PERSIST_THIS_MESSAGE"))
        XCTAssertEqual(try f.db.query("SELECT * FROM request_evidence_v1").count,2)
        let crossing = try f.resolve(start:10,end:30)
        XCTAssertTrue(crossing.issues.contains { $0.contains("could not be parsed") })
        XCTAssertTrue(crossing.references.contains { $0.hasPrefix("sampling-gap:") })
        // A malformed change before the counter's start also invalidates the
        // settings inherited from its earlier valid sample.
        XCTAssertTrue(try f.resolve(start:30,end:35).issues.contains { $0.contains("could not be parsed") })
        XCTAssertFalse(try f.resolve(start:40,end:50).issues.contains { $0.contains("could not be parsed") })
        XCTAssertFalse(try f.resolve(account:"other",start:10,end:30).issues.contains { $0.contains("could not be parsed") })
        XCTAssertFalse(try f.resolve(thread:"other",start:10,end:30).issues.contains { $0.contains("could not be parsed") })
        // The coverage warning survives removal of the original log message.
        try source.run("DELETE FROM logs WHERE id=3")
        try f.collect()
        XCTAssertTrue(try f.resolve(start:10,end:30).issues.contains { $0.contains("could not be parsed") })
    }

    func testActualNestedAuthEmissionIsNotASettingsChangeOrMetadataGap() throws {
        let f = try Fixture()
        let source = try f.source()
        // Redacted structure of real log 152499810 (core/src/session/turn.rs:2630)
        // and 152499815 (feedback/src/lib.rs:167), 10.193 ms apart. The latter
        // inherits sampling scopes but emits auth metadata, not model settings.
        let scope = #"session_loop{thread_id=thread}:submission_dispatch{otel.name="op.dispatch.turn_input" submission.id="turn" codex.op="turn_input"}:codex.turn_input{conversation.id=thread turn.id="turn"}:turn{otel.name="session_task.turn" thread.id=thread turn.id=turn model=gpt-6-astra codex.turn.reasoning_effort=ultra}:session_task.run:run_turn:run_sampling_request{turn_id=turn model=gpt-6-astra cwd=/fixture}:try_run_sampling_request{turn_id=turn model=gpt-6-astra}:"#
        let settings = scope + #" model="gpt-6-astra" approval_policy=Never sandbox_policy=DangerFullAccess effort=Some(Ultra) auth_mode=Some(Chatgpt) tags_json={"service_tier":"unset"}"#
        let auth = scope + #"model_client.stream_responses_websocket{model=gpt-6-astra wire_api=Responses transport=websocket turn.has_metadata_header=true websocket.warmup=false api.path=responses}:responses_websocket.stream_request{transport="websocket" api.path=responses}: auth_header_attached=true auth_header_name="REDACTED_HEADER" auth_mode="chatgpt" auth_request_id="" auth_error="""#
        try source.run("INSERT INTO logs(id,ts,ts_nanos,target,feedback_log_body,thread_id) VALUES (1,10,0,'feedback_tags',?,'thread')",[settings])
        try source.run("INSERT INTO logs VALUES (2,10,10193000,'feedback_tags',?,'thread','codex_feedback','feedback/src/lib.rs')",[auth])
        try f.collect()
        let result = try f.resolve(start:10,end:11)
        XCTAssertEqual(result.model,"gpt-6-astra"); XCTAssertEqual(result.effort,"ultra"); XCTAssertEqual(result.tier,"unset")
        XCTAssertTrue(result.issues.isEmpty,result.issues.joined(separator:","))
        XCTAssertEqual(result.references.count,1)
        XCTAssertTrue(try f.db.query("SELECT * FROM request_evidence_gap_v1").isEmpty)
        XCTAssertFalse(try f.db.query("SELECT * FROM request_evidence_v1").description.contains("REDACTED_HEADER"))

        // A genuine settings emission missing its tier remains incomplete; it
        // must not disappear merely because nearby full settings are available.
        let missing = scope + #" model="gpt-6-astra" effort=Some(Ultra) tags_json={}"#
        try source.run("INSERT INTO logs(id,ts,ts_nanos,target,feedback_log_body,thread_id) VALUES (3,20,0,'feedback_tags',?,'thread')",[missing])
        try f.collect()
        let incomplete = try f.resolve(start:10,end:21)
        XCTAssertEqual(incomplete.tier,"unset")
        XCTAssertTrue(incomplete.issues.contains { $0.contains("tier metadata is missing") })
        XCTAssertFalse(incomplete.issues.contains { $0.contains("service tier changed") })

        let null = scope + #" model="gpt-6-astra" effort=Some(Ultra) tags_json={"service_tier":null}"#
        try source.run("INSERT INTO logs(id,ts,ts_nanos,target,feedback_log_body,thread_id) VALUES (4,25,0,'feedback_tags',?,'thread')",[null])
        try f.collect()
        XCTAssertTrue(try f.resolve(start:10,end:26).issues.contains { $0.contains("explicitly null") })
        XCTAssertFalse(try f.resolve(start:10,end:26).issues.contains { $0.contains("service tier changed") })

        let changed = scope + #" model="gpt-6-astra" effort=Some(Ultra) tags_json={"service_tier":"priority"}"#
        try source.run("INSERT INTO logs(id,ts,ts_nanos,target,feedback_log_body,thread_id) VALUES (5,30,0,'feedback_tags',?,'thread')",[changed])
        try f.collect()
        let mixed = try f.resolve(start:10,end:31)
        XCTAssertNil(mixed.tier)
        XCTAssertTrue(mixed.issues.contains { $0.contains("service tier changed") })
    }

    func testSamplingOwnTurnAndFieldsCannotBindAncestorOrRootTurnSubstring() throws {
        let f = try Fixture()
        let source = try f.source()
        let explicit = #"turn{turn.id=ancestor model="ancestor-model" codex.turn.reasoning_effort=low effort=Some(Low)}:run_sampling_request{root_turn_id=ancestor turn_id=own model=own-frame-model}:try_run_sampling_request{root_turn_id=ancestor turn_id=own model=own-frame-model}: model="own-model" effort=Some(Max) tags_json={"service_tier":"priority"}"#
        let scoped = #"turn{turn.id=ancestor model="ancestor-model" codex.turn.reasoning_effort=low effort=Some(Low)}:turn{turn.id=own-two model=own-frame-model codex.turn.reasoning_effort=high}:run_sampling_request{root_turn_id=ancestor turn_id=own-two model=own-frame-model}:try_run_sampling_request{root_turn_id=ancestor turn_id=own-two model=own-frame-model}: tags_json={"service_tier":"unset"}"#
        let rootOnly = #"turn{turn.id=ancestor model="ancestor-model" codex.turn.reasoning_effort=low}:run_sampling_request{root_turn_id=ancestor model=unknown}: model="emitted-model" effort=Some(High) tags_json={"service_tier":"default"}"#
        for (index,body) in [explicit,scoped,rootOnly].enumerated() {
            try source.run("INSERT INTO logs(id,ts,ts_nanos,target,feedback_log_body,thread_id) VALUES (?,?,0,'feedback_tags',?,'thread')",[String(index+1),String(10+index*10),body])
        }
        try f.collect()
        let own = try f.resolve(turn:"own",start:10,end:11)
        XCTAssertEqual(own.model,"own-model"); XCTAssertEqual(own.effort,"max"); XCTAssertEqual(own.tier,"priority")
        XCTAssertTrue(own.issues.isEmpty)
        let ownTwo = try f.resolve(turn:"own-two",start:20,end:21)
        XCTAssertEqual(ownTwo.model,"own-frame-model"); XCTAssertEqual(ownTwo.effort,"high"); XCTAssertEqual(ownTwo.tier,"unset")
        XCTAssertTrue(ownTwo.issues.isEmpty)
        XCTAssertNil(try f.resolve(turn:"ancestor",start:10,end:21).model)
        XCTAssertEqual(try f.db.query("SELECT * FROM request_evidence_v1").count,2)
        XCTAssertEqual(try f.db.query("SELECT * FROM request_evidence_gap_v1").count,1)
    }
}
