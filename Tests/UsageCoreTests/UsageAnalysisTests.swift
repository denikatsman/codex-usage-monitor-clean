import XCTest
@testable import UsageCore

final class UsageAnalysisTests: XCTestCase {
    let start=Date(timeIntervalSince1970:1_900_000_000)
    func meter(_ seconds: Double, _ used: Double, epoch: String="e", account: String="a", meter: String="codex-primary", reset: Double=86400) -> MeterObservation {
        MeterObservation(id:"\(account)-\(epoch)-\(meter)-\(seconds)",account:account,epoch:epoch,meterID:meter,title:"Weekly",plan:"Pro",windowMinutes:10080,resetAt:start.addingTimeInterval(reset),used:used,observedAt:start.addingTimeInterval(seconds))
    }
    func activity(_ seconds: Double, input: Int64=100, epoch: String="e", account: String="a", thread: String="t", parent: String?=nil, model: String="m", effort: String="high", speed: String="standard", issues: [String]=[], provenance: [String]=[]) -> ActivityObservation {
        var t=TokenMetrics(); t.input=input; t.cached=input/2; t.cacheWrite=input/4; t.output=input/10; t.reasoning=input/20
        return ActivityObservation(id:"\(thread)-\(seconds)",account:account,epoch:epoch,threadID:thread,title:thread,parentThreadID:parent,turnID:"turn",model:model,effort:effort,speed:speed,sourceAt:start.addingTimeInterval(seconds),capturedAt:start.addingTimeInterval(seconds+1),tokens:t,completedTurns:1,issues:issues,provenance:provenance)
    }
    func testBaselineBoundaryDedupLateIngestionAndMultiPointJump() {
        let meters=[meter(0,10),meter(10,11),meter(20,13),meter(30,13)]
        let a=activity(10), b=activity(20,input:200), c=activity(25,input:300)
        let result=UsageAnalysis.build(meters:meters,activity:[a,a,b,c],now:start.addingTimeInterval(31))
        XCTAssertEqual(result.intervals.count,2)
        let completed=result.intervals[0]
        XCTAssertEqual(completed.points,2)
        XCTAssertEqual(completed.totals.total,220)
        XCTAssertFalse(completed.isBaseline)
        XCTAssertTrue(completed.isCalibrationEligible)
        XCTAssertTrue(result.intervals[1].isBaseline)
        XCTAssertFalse(result.intervals[1].isCalibrationEligible)
        XCTAssertEqual(result.openIntervals.first?.totals.total,330)
        XCTAssertEqual(result.calibration.first?.medianTokensPerPoint,110)
        XCTAssertEqual(result.calibration.first?.sampleCount,1)
        XCTAssertTrue(result.calibration.first?.isEarlyData == true)
        let late=activity(15,input:50)
        let updated=UsageAnalysis.build(meters:meters,activity:[a,b,c,late],now:start.addingTimeInterval(31))
        XCTAssertEqual(updated.intervals[0].id,completed.id)
        XCTAssertEqual(updated.intervals[0].totals.total,275)
    }
    func testMixedUnknownAndParentChildIntervalsCannotCalibrate() {
        let meters=[meter(0,0),meter(10,1),meter(20,2)]
        for samples in [
            [activity(12),activity(15,thread:"u",model:"other")],
            [activity(12,effort:"Unknown")],
            [activity(12),activity(15,thread:"child",parent:"t")],
            [activity(12,issues:["Counter span crosses a model change."])]
        ] {
            let result=UsageAnalysis.build(meters:meters,activity:samples,now:start.addingTimeInterval(21))
            XCTAssertFalse(result.intervals[0].isCalibrationEligible)
            XCTAssertFalse(result.intervals[0].issues.isEmpty)
            XCTAssertTrue(result.calibration.isEmpty)
            XCTAssertGreaterThan(result.intervals[0].totals.total,0)
        }
    }
    func testAccountEpochResetAndCorrectionIsolation() {
        let result=UsageAnalysis.build(meters:[meter(0,10),meter(10,11),meter(20,12),meter(30,0,reset:172800),meter(40,1,reset:172800),meter(50,0,reset:172800),meter(60,1,reset:172800),meter(70,99,epoch:"next"),meter(80,100,epoch:"next")],activity:[activity(15),activity(15,input:900,epoch:"other"),activity(15,input:900,account:"other"),activity(35),activity(55),activity(75,epoch:"next")],now:start.addingTimeInterval(81))
        XCTAssertEqual(result.intervals.count,5)
        XCTAssertEqual(result.openIntervals.count,1)
        XCTAssertEqual(result.openIntervals[0].epoch,"next")
        XCTAssertEqual(result.intervals.filter(\.isCalibrationEligible).count,1)
        XCTAssertEqual(result.calibration.first?.medianTokensPerPoint,110)
        XCTAssertEqual(result.intervals.first?.totals.total,110)
        XCTAssertTrue(result.intervals.first?.isBaseline == true)
    }
    func testGapAndStaleOpenMeterAreExplicitAndInputOrderDoesNotMatter() {
        let meters=[meter(120,2),meter(0,0),meter(10,1)]
        let result=UsageAnalysis.build(meters:meters,activity:[activity(115)],now:start.addingTimeInterval(240))
        XCTAssertFalse(result.intervals[0].isCalibrationEligible)
        XCTAssertTrue(result.intervals[0].issues.contains { $0.contains("gap") })
        XCTAssertTrue(result.openIntervals[0].issues.contains { $0.contains("older") })
        XCTAssertTrue(result.calibration.isEmpty)
    }
    func testEmpiricalQuantilesAndSubcategoryTotals() {
        let meters=(0...6).map { meter(Double($0*10),Double($0)) }
        let activity=(1...5).map { self.activity(Double($0*10+5),input:Int64($0*100)) }
        let result=UsageAnalysis.build(meters:meters,activity:activity,now:start.addingTimeInterval(61))
        let c=try! XCTUnwrap(result.calibration.first)
        XCTAssertEqual(c.sampleCount,5)
        XCTAssertFalse(c.isEarlyData)
        XCTAssertEqual(c.totalPoints,5)
        XCTAssertEqual(c.medianTokensPerPoint,330)
        XCTAssertEqual(c.lowerTokensPerPoint,154,accuracy:0.0001)
        XCTAssertEqual(c.upperTokensPerPoint,506,accuracy:0.0001)
        XCTAssertEqual(c.inputPerPoint,300)
        XCTAssertEqual(c.cachedPerPoint,150)
        XCTAssertEqual(c.cacheWritePerPoint,75)
        XCTAssertEqual(c.outputPerPoint,30)
        XCTAssertEqual(c.reasoningPerPoint,15)
    }
    func testDifferentAllowanceWindowsHaveSeparateCalibration() {
        let a=[meter(0,0),meter(10,1),meter(20,2)]
        let b=[meter(0,0,meter:"codex-secondary"),meter(10,1,meter:"codex-secondary"),meter(20,2,meter:"codex-secondary")]
        let result=UsageAnalysis.build(meters:a+b,activity:[activity(15)],now:start.addingTimeInterval(21))
        XCTAssertEqual(result.calibration.count,2)
        XCTAssertEqual(result.calibration.map(\.sampleCount),[1,1])
    }
    func testUnknownSpeedRemainsExplicitAndFutureCaptureIsNotCounted() {
        let meters=[meter(0,0),meter(10,1),meter(20,2)]
        let known=activity(15,speed:"Unknown")
        var t=TokenMetrics(); t.input=900
        let notYetCaptured=ActivityObservation(id:"late",account:"a",epoch:"e",threadID:"t",title:"t",model:"m",effort:"high",sourceAt:start.addingTimeInterval(16),capturedAt:start.addingTimeInterval(30),tokens:t)
        let result=UsageAnalysis.build(meters:meters,activity:[known,notYetCaptured],now:start.addingTimeInterval(21))
        XCTAssertTrue(result.calibration.isEmpty)
        XCTAssertEqual(result.intervals.first?.segments.first?.speed,"Unknown")
        XCTAssertEqual(result.intervals.first?.totals.total,110)
        XCTAssertFalse(result.intervals.first?.isCalibrationEligible == true)
    }

    func testGlobalCoverageIssuesExcludeCalibrationAndExpiredOpenWindowWarns() {
        let meters=[meter(0,0,reset:25),meter(10,1,reset:25),meter(20,2,reset:25)]
        let samples=[activity(15)]
        let covered=UsageAnalysis.build(meters:meters,activity:samples,now:start.addingTimeInterval(30))
        XCTAssertTrue(covered.intervals[0].isCalibrationEligible)
        XCTAssertTrue(covered.openIntervals[0].issues.contains { $0.contains("new allowance window") })
        let incomplete=UsageAnalysis.build(meters:meters,activity:samples,now:start.addingTimeInterval(30),issues:["Activity query truncated; coverage is partial."])
        XCTAssertTrue(incomplete.calibration.isEmpty)
        XCTAssertFalse(incomplete.intervals[0].isCalibrationEligible)
        XCTAssertTrue(incomplete.intervals[0].issues.contains { $0.contains("truncated") })
    }

    func testTierCanonicalizationPreservesEvidenceDistinctions() {
        XCTAssertEqual(UsageTier.canonical("fast"), "priority")
        XCTAssertEqual(UsageTier.canonical(" Priority "), "priority")
        XCTAssertEqual(UsageTier.canonical("standard"), "default")
        XCTAssertEqual(UsageTier.canonical("unset"), "unset")
        XCTAssertEqual(UsageTier.canonical("ultrafast"), "ultrafast")
        XCTAssertEqual(UsageTier.canonical(nil), "Unknown")
        XCTAssertEqual(UsageTier.canonical("  "), "Unknown")
        XCTAssertEqual(UsageTier.canonical("experimentalTier"), "experimentalTier")
        XCTAssertEqual(UsageTier.label("fast"), "Fast (priority)")
        XCTAssertEqual(UsageTier.label("unset"), "Unset (logged)")
        for tier in ["Unknown", "unset", "Mixed", "experimentalTier"] {
            XCTAssertFalse(UsageTier.isComparable(tier))
            let result=UsageAnalysis.build(meters:[meter(0,0),meter(10,1),meter(20,2)],activity:[activity(15,speed:tier)],now:start.addingTimeInterval(21))
            XCTAssertTrue(result.calibration.isEmpty)
            XCTAssertFalse(result.intervals[0].isCalibrationEligible)
            XCTAssertEqual(result.intervals[0].totals.total,110)
            XCTAssertTrue(result.intervals[0].issues.contains { $0.contains("Service tier") })
        }
    }

    func testComparableTiersRemainSeparateAndEvidenceReferencesAggregate() {
        let result=UsageAnalysis.build(meters:[meter(0,0),meter(10,1),meter(20,2),meter(30,3),meter(40,4)],activity:[activity(12,speed:"fast",provenance:["request:turn-1:service_tier", "rollout:42"]),activity(15,speed:"priority",provenance:["request:turn-1:service_tier", "rollout:43"]),activity(25,speed:"standard"),activity(35,speed:"ultrafast")],now:start.addingTimeInterval(41))
        XCTAssertEqual(Set(result.calibration.map(\.speed)),Set(["priority","default","ultrafast"]))
        let priority=result.intervals.first { $0.segments.first?.speed == "priority" }
        XCTAssertEqual(priority?.segments.count,1)
        XCTAssertEqual(priority?.segments.first?.provenance,["request:turn-1:service_tier","rollout:42","rollout:43"])
        XCTAssertTrue(priority?.isCalibrationEligible == true)
    }

}
