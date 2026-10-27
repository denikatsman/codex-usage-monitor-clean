import XCTest
@testable import UsageCore

final class AttributionEnricherTests: XCTestCase {
    private final class Fixture {
        let root: URL, file: URL, db: HistoryDatabase
        let start=Date(timeIntervalSince1970:1_900_000_000)
        let generation=UUID().uuidString
        var threads: [[String:String]] { [["id":"child","rollout_path":file.path,"created_at_ms":String(start.timeIntervalSince1970*1000)]] }
        init() throws {
            root=FileManager.default.temporaryDirectory.appendingPathComponent("attribution-"+UUID().uuidString)
            let sessions=root.appendingPathComponent("sessions")
            try FileManager.default.createDirectory(at:sessions,withIntermediateDirectories:true)
            file=sessions.appendingPathComponent("child.jsonl")
            try Data().write(to:file)
            db=try HistoryDatabase(url:root.appendingPathComponent("analysis.sqlite"))
            try AnalysisStore.create(in:db); try RequestEvidence.create(in:db); try AttributionStore.create(in:db)
            _ = try append(type:"session_meta",payload:["id":"child","parent_thread_id":"parent"],seconds:0)
        }
        deinit { try? FileManager.default.removeItem(at:root) }
        @discardableResult func append(type: String="event_msg",payload: [String:Any],seconds: Double) throws -> UInt64 {
            let handle=try FileHandle(forWritingTo:file); defer { try? handle.close() }
            let offset=try handle.seekToEnd()
            let formatter=ISO8601DateFormatter(); formatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
            var data=try JSONSerialization.data(withJSONObject:["type":type,"timestamp":formatter.string(from:start.addingTimeInterval(seconds)),"payload":payload]); data.append(10)
            try handle.write(contentsOf:data); return offset
        }
        func context(_ seconds: Double, effort: String="high",model: String="m",turn: String="own") throws {
            try append(type:"turn_context",payload:["model":model,"effort":effort,"turn_id":turn],seconds:seconds)
        }
        func counter(_ seconds: Double,_ input: Int) throws -> UInt64 {
            try append(payload:["type":"token_count","info":["total_token_usage":["input_tokens":input,"cached_input_tokens":input/2,"cache_write_input_tokens":input/4,"output_tokens":input/10,"reasoning_output_tokens":input/20]]],seconds:seconds)
        }
        func activity(_ offset: UInt64,seconds: Double=5,account: String="a",input: Int64=100,storedTurn: String="parent-turn") throws -> String {
            let id="epoch"+file.path+":"+generation+":"+String(offset)
            var t=TokenMetrics(); t.input=input; t.cached=input/2; t.cacheWrite=input/4; t.output=input/10; t.reasoning=input/20
            try AnalysisStore.activity(db,.init(id:id,account:account,epoch:"epoch",threadID:"child",title:"Child",turnID:storedTurn,model:"wrong-old-model",effort:"ultra",sourceAt:start.addingTimeInterval(seconds),capturedAt:start.addingTimeInterval(6),tokens:t))
            return id
        }
        func request(model: String="m",effort: String="high",tier: String="default",seconds: Double=1) throws {
            try db.run("INSERT INTO request_evidence_v1 VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",["a","fixture","0","1","child","own",String(start.addingTimeInterval(seconds).timeIntervalSince1970),model,effort,tier,tier,"[]"])
            // The synthetic request source was retained continuously over the
            // measured counter span; a lone settings sample is not coverage.
            try db.run("INSERT INTO request_evidence_coverage_v1 VALUES (?,?,?,?,?)",["a","fixture","child",String(start.addingTimeInterval(seconds).timeIntervalSince1970),String(start.addingTimeInterval(5).timeIntervalSince1970)])
        }
        func enrich(force: Bool=false,seconds: Double=10) throws -> Int { try AttributionEnricher(codexHome:root).enrich(db,account:"a",threads:threads,force:force,at:start.addingTimeInterval(seconds)) }
    }
    func testOwnChildContextAndRequestOverlayPreserveAllNumericRows() throws {
        let f=try Fixture()
        try f.context(-1,effort:"ultra",turn:"parent-turn")
        try f.context(0)
        _ = try f.counter(1,100)
        let offset=try f.counter(5,200)
        let id=try f.activity(offset)
        try f.request()
        try f.db.run("INSERT INTO analysis_meter_v1 VALUES (?,?,?,?,?,?,?,?,?,?)",["meter","a","epoch","codex-primary","Weekly","Pro","10080",nil,"41",String(f.start.timeIntervalSince1970)])
        let before=try f.db.query("SELECT * FROM analysis_activity_v1")
        let metersBefore=try f.db.query("SELECT * FROM analysis_meter_v1")
        XCTAssertEqual(try f.enrich(),1)
        XCTAssertEqual(before,try f.db.query("SELECT * FROM analysis_activity_v1"))
        XCTAssertEqual(metersBefore,try f.db.query("SELECT * FROM analysis_meter_v1"))
        let overlay=try XCTUnwrap(f.db.query("SELECT * FROM analysis_attribution_v2 WHERE activity_id=?",[id]).first)
        XCTAssertEqual(overlay["model"],"m"); XCTAssertEqual(overlay["effort"],"high")
        XCTAssertEqual(overlay["speed"],"default"); XCTAssertEqual(overlay["turn_id"],"own")
        XCTAssertEqual(overlay["issues"],"[]")
        XCTAssertTrue(overlay["provenance"]?.contains("turn_context") == true)
        XCTAssertEqual(try f.enrich(seconds:11),0)
    }
    func testOldContextBeyondTailAndLateRequestCanRecoverUnknownTier() throws {
        let f=try Fixture(); try f.context(0)
        _ = try f.counter(1,100)
        try f.append(type:"response_item",payload:["type":"message","content":String(repeating:"x",count:700000)],seconds:2)
        let offset=try f.counter(5,200); _ = try f.activity(offset)
        XCTAssertEqual(try f.enrich(),1)
        var overlay=try XCTUnwrap(f.db.query("SELECT * FROM analysis_attribution_v2").first)
        XCTAssertEqual(overlay["effort"],"high"); XCTAssertEqual(overlay["speed"],"Unknown")
        try f.request()
        XCTAssertEqual(try f.enrich(seconds:71),1)
        overlay=try XCTUnwrap(f.db.query("SELECT * FROM analysis_attribution_v2").first)
        XCTAssertEqual(overlay["speed"],"default"); XCTAssertEqual(overlay["issues"],"[]")
    }
    func testMixedConfigurationCounterSpanCannotUseLastConfiguration() throws {
        let f=try Fixture(); try f.context(0)
        _ = try f.counter(1,100)
        try f.context(2,effort:"ultra",model:"other")
        let offset=try f.counter(5,200); _ = try f.activity(offset)
        try f.request(model:"other",effort:"ultra")
        _ = try f.enrich()
        let row=try XCTUnwrap(f.db.query("SELECT * FROM analysis_attribution_v2").first)
        XCTAssertEqual(row["model"],"Unknown"); XCTAssertEqual(row["effort"],"Unknown")
        XCTAssertTrue(row["issues"]?.contains("Counter span crosses") == true)
    }
    func testCounterMismatchWrongAccountAndReplacementHeaderAreRejected() throws {
        let f=try Fixture(); try f.context(0); _ = try f.counter(1,100)
        let offset=try f.counter(5,200); _ = try f.activity(offset,input:999)
        XCTAssertEqual(try AttributionEnricher(codexHome:f.root).enrich(f.db,account:"other",threads:f.threads),0)
        _ = try f.enrich()
        var row=try XCTUnwrap(f.db.query("SELECT * FROM analysis_attribution_v2").first)
        XCTAssertEqual(row["model"],"Unknown"); XCTAssertTrue(row["issues"]?.contains("counter delta") == true)
        var bytes=try String(contentsOf:f.file,encoding:.utf8)
        bytes=bytes.replacingOccurrences(of:"\"child\"",with:"\"other\"")
        try Data(bytes.utf8).write(to:f.file)
        _ = try f.enrich(force:true,seconds:11)
        row=try XCTUnwrap(f.db.query("SELECT * FROM analysis_attribution_v2").first)
        XCTAssertTrue(row["issues"]?.contains("session identity") == true)
    }
    func testCoverageRowsHaveExplicitUnavailableOverlay() throws {
        let f=try Fixture()
        try AnalysisStore.activity(f.db,.init(id:"epoch:coverage",account:"a",epoch:"epoch",threadID:"child",title:"Coverage",sourceAt:f.start,capturedAt:f.start,tokens:.init(),issues:["Original coverage warning"]))
        _ = try f.enrich()
        let row=try XCTUnwrap(f.db.query("SELECT * FROM analysis_attribution_v2").first)
        XCTAssertEqual(row["model"],"Unknown"); XCTAssertTrue(row["issues"]?.contains("no rollout byte offset") == true)
        XCTAssertEqual(try f.db.query("SELECT issues FROM analysis_activity_v1").first?["issues"],"[\"Original coverage warning\"]")
    }
    func testCancellationDoesNotWriteOverlays() async throws {
        let f=try Fixture(); try f.context(0); _ = try f.counter(1,100)
        let offset=try f.counter(5,200); _ = try f.activity(offset)
        var continuation: AsyncStream<Void>.Continuation!
        let stream=AsyncStream<Void> { continuation=$0 }
        let task=Task {
            for await _ in stream { }
            try Task.checkCancellation()
            return try f.enrich()
        }
        task.cancel(); continuation.finish()
        do { _ = try await task.value; XCTFail("Cancelled enrichment ran") }
        catch is CancellationError { }
        XCTAssertTrue(try f.db.query("SELECT * FROM analysis_attribution_v2").isEmpty)
    }

}
