import XCTest
@testable import UsageCore

/// A bounded replay guards against accidentally restoring a per-interval full
/// activity scan. All records are synthetic and the SQLite file is disposable.
final class AnalysisPerformanceTests: XCTestCase {
    func testBoundedSnapshotAtLargeBacklog() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("usage-analysis-perf-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let db=try HistoryDatabase(url:root.appendingPathComponent("fixture.sqlite"))
        try AnalysisStore.create(in:db)
        let now=Date(), start=now.addingTimeInterval(-500001).timeIntervalSince1970
        try db.run("""
            WITH RECURSIVE sequence(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM sequence WHERE n<50000)
            INSERT INTO analysis_meter_v1 SELECT 'm-'||n,'account','epoch','codex-primary','Weekly','Pro',10080,?,(n/20)%101,?+n*10 FROM sequence
            """,[String(now.addingTimeInterval(86400).timeIntervalSince1970),String(start)])
        try db.run("""
            WITH RECURSIVE sequence(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM sequence WHERE n<100000)
            INSERT INTO analysis_activity_v1 SELECT 'a-'||n,'account','epoch','thread','Synthetic task','/fixture',NULL,NULL,'turn-'||(n/10),'model','high','Unknown',?+n*5,?+n*5,100,50,0,10,5,1,0,NULL,'[]' FROM sequence
            """,[String(start),String(start)])
        // Explicit validated metadata keeps this performance fixture on the pure,
        // eligible path while preserved raw records deliberately retain Unknown tier.
        try db.run("""
            INSERT INTO analysis_attribution_v2
            SELECT id,'model','high','default',turn,'["synthetic-validated-fixture"]','[]',?,?,2
            FROM analysis_activity_v1
            """,[String(now.timeIntervalSince1970),String(now.addingTimeInterval(86400).timeIntervalSince1970)])
        let begin=Date()
        let snapshot=try AnalysisStore.snapshot(db,account:"account",now:now)
        let elapsed=Date().timeIntervalSince(begin)
        print("ANALYSIS_PERF snapshot meters=50000 activity=100000 elapsed_seconds=\(elapsed)")
        XCTAssertLessThan(elapsed,10,"Bounded replay regressed; inspect query decoding and interval lookups.")
        XCTAssertEqual(snapshot.intervals.count,200)
        XCTAssertEqual(snapshot.openIntervals.count,1)
        XCTAssertFalse(snapshot.calibration.isEmpty)
        XCTAssertTrue(snapshot.issues.isEmpty)
        // At the cap, the first retained interval is excluded as a baseline;
        // complete recent intervals remain usable instead of pausing forever.
        try db.run("INSERT INTO analysis_activity_v1 SELECT 'over-cap',account,epoch,thread,title,project,parent,agent,turn,model,effort,speed,at,captured,input,cached,cache_write,output,reasoning,turns,tools,duration,issues FROM analysis_activity_v1 LIMIT 1")
        let truncatedBegin=Date()
        let truncated=try AnalysisStore.snapshot(db,account:"account",now:now)
        print("ANALYSIS_PERF truncated_snapshot elapsed_seconds=\(Date().timeIntervalSince(truncatedBegin))")
        XCTAssertFalse(truncated.calibration.isEmpty)
        XCTAssertTrue(truncated.issues.contains { $0.contains("100,000") })
        XCTAssertEqual(truncated.intervals.count,200)
        try db.run("DELETE FROM analysis_activity_v1 WHERE id='over-cap' OR CAST(substr(id,3) AS INTEGER)>10000")
        try db.run("DELETE FROM analysis_meter_v1 WHERE CAST(substr(id,3) AS INTEGER)>5000")
        let typicalBegin=Date()
        let typical=try AnalysisStore.snapshot(db,account:"account",now:now)
        print("ANALYSIS_PERF typical_snapshot meters=5000 activity=10000 elapsed_seconds=\(Date().timeIntervalSince(typicalBegin))")
        XCTAssertFalse(typical.calibration.isEmpty)
    }
    func testPureEngineAtLargeBacklog() {
        let now=Date(), origin=now.addingTimeInterval(-500001)
        for count in [10000,100000] {
            let meters=(1...(count/2)).map { n in
                MeterObservation(id:"m-\(n)",account:"account",epoch:"epoch",meterID:"codex-primary",title:"Weekly",plan:"Pro",windowMinutes:10080,resetAt:now.addingTimeInterval(86400),used:Double((n/20)%101),observedAt:origin.addingTimeInterval(Double(n*10)))
            }
            var t=TokenMetrics(); t.input=100; t.cached=50; t.output=10; t.reasoning=5
            let activity=(1...count).map { n in
                ActivityObservation(id:"a-\(n)",account:"account",epoch:"epoch",threadID:"thread",title:"Task",turnID:"turn-\(n/10)",model:"model",effort:"high",speed:"default",sourceAt:origin.addingTimeInterval(Double(n*5)),capturedAt:origin.addingTimeInterval(Double(n*5)),tokens:t)
            }
            let begin=Date()
            let result=UsageAnalysis.build(meters:meters,activity:activity,now:now)
            let elapsed=Date().timeIntervalSince(begin)
            print("ANALYSIS_PERF pure_engine meters=\(count/2) activity=\(count) elapsed_seconds=\(elapsed)")
            XCTAssertLessThan(elapsed,10)
            XCTAssertEqual(result.intervals.count,200)
            XCTAssertFalse(result.calibration.isEmpty)
        }
    }

}
