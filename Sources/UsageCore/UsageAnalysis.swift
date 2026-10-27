import Foundation

public struct MeterObservation: Sendable {
    public let id: String, account: String, epoch: String, meterID: String, title: String, plan: String
    public let windowMinutes: Int?
    public let resetAt: Date?
    public let used: Double
    public let observedAt: Date
    public init(id: String, account: String, epoch: String, meterID: String, title: String, plan: String = "Unknown", windowMinutes: Int? = nil, resetAt: Date? = nil, used: Double, observedAt: Date) {
        self.id=id; self.account=account; self.epoch=epoch; self.meterID=meterID; self.title=title; self.plan=plan; self.windowMinutes=windowMinutes; self.resetAt=resetAt; self.used=used; self.observedAt=observedAt
    }
}

public struct ActivityObservation: Sendable {
    public let id: String, account: String, epoch: String, threadID: String, title: String, project: String
    public let parentThreadID: String?, agentPath: String?, turnID: String?
    public let model: String, effort: String, speed: String
    public let sourceAt: Date, capturedAt: Date
    public let tokens: TokenMetrics
    public let completedTurns: Int, toolCalls: Int
    public let turnDurationSeconds: Double?
    public let issues: [String]
    public let provenance: [String]
    public init(id: String, account: String, epoch: String, threadID: String, title: String, project: String = "Unknown", parentThreadID: String? = nil, agentPath: String? = nil, turnID: String? = nil, model: String = "Unknown", effort: String = "Unknown", speed: String = "Unknown", sourceAt: Date, capturedAt: Date, tokens: TokenMetrics, completedTurns: Int = 0, toolCalls: Int = 0, turnDurationSeconds: Double? = nil, issues: [String] = [], provenance: [String] = []) {
        self.id=id; self.account=account; self.epoch=epoch; self.threadID=threadID; self.title=title; self.project=project; self.parentThreadID=parentThreadID; self.agentPath=agentPath; self.turnID=turnID; self.model=model; self.effort=effort; self.speed=UsageTier.canonical(speed); self.sourceAt=sourceAt; self.capturedAt=capturedAt; self.tokens=tokens; self.completedTurns=completedTurns; self.toolCalls=toolCalls; self.turnDurationSeconds=turnDurationSeconds; self.issues=issues; self.provenance=provenance
    }
}

public struct ActivitySegment: Identifiable, Sendable {
    public let id: String, threadID: String, title: String, project: String
    public let parentThreadID: String?, agentPath: String?, turnID: String?
    public let model: String, effort: String, speed: String
    public var tokens: TokenMetrics
    public var completedTurns: Int, toolCalls: Int
    public var firstAt: Date, lastAt: Date
    public var turnDurationSeconds: Double?
    public var issues: [String]
    public var provenance: [String]
    public init(id: String, threadID: String, title: String, project: String = "Unknown", parentThreadID: String? = nil, agentPath: String? = nil, turnID: String? = nil, model: String = "Unknown", effort: String = "Unknown", speed: String = "Unknown", tokens: TokenMetrics, completedTurns: Int = 0, toolCalls: Int = 0, firstAt: Date, lastAt: Date, turnDurationSeconds: Double? = nil, issues: [String] = [], provenance: [String] = []) {
        self.id=id; self.threadID=threadID; self.title=title; self.project=project; self.parentThreadID=parentThreadID; self.agentPath=agentPath; self.turnID=turnID; self.model=model; self.effort=effort; self.speed=UsageTier.canonical(speed); self.tokens=tokens; self.completedTurns=completedTurns; self.toolCalls=toolCalls; self.firstAt=firstAt; self.lastAt=lastAt; self.turnDurationSeconds=turnDurationSeconds; self.issues=issues; self.provenance=provenance
    }
}

public struct UsageInterval: Identifiable, Sendable {
    public let id: String, meterID: String, title: String, plan: String, epoch: String, account: String
    public let windowMinutes: Int?
    public let resetAt: Date?
    public let startAt: Date, endAt: Date?, previousObservationAt: Date
    public let fromUsed: Double, toUsed: Double?
    public let isBaseline: Bool
    public let segments: [ActivitySegment]
    public let issues: [String]
    public let isCalibrationEligible: Bool
    public let totals: TokenMetrics
    public let durationSeconds: Double
    public var points: Double? { toUsed.map { $0 - fromUsed } }
    public init(id: String, meterID: String, title: String, account: String = "", plan: String = "Unknown", windowMinutes: Int? = nil, resetAt: Date? = nil, epoch: String, startAt: Date, endAt: Date? = nil, previousObservationAt: Date, fromUsed: Double, toUsed: Double? = nil, isBaseline: Bool, segments: [ActivitySegment] = [], issues: [String] = [], isCalibrationEligible: Bool = false, totals: TokenMetrics = TokenMetrics(), durationSeconds: Double) {
        self.id=id; self.account=account; self.meterID=meterID; self.title=title; self.plan=plan; self.windowMinutes=windowMinutes; self.resetAt=resetAt; self.epoch=epoch; self.startAt=startAt; self.endAt=endAt; self.previousObservationAt=previousObservationAt; self.fromUsed=fromUsed; self.toUsed=toUsed; self.isBaseline=isBaseline; self.segments=segments; self.issues=issues; self.isCalibrationEligible=isCalibrationEligible; self.totals=totals; self.durationSeconds=durationSeconds
    }
}

public struct CalibrationSummary: Identifiable, Sendable {
    public let id: String, meterID: String, title: String, plan: String, model: String, effort: String, speed: String
    public let windowMinutes: Int?
    public let sampleCount: Int
    public let totalPoints: Double, medianTokensPerPoint: Double, lowerTokensPerPoint: Double, upperTokensPerPoint: Double
    public let inputPerPoint: Double, cachedPerPoint: Double, cacheWritePerPoint: Double, outputPerPoint: Double, reasoningPerPoint: Double
    public var isEarlyData: Bool { sampleCount < 5 }
    public init(id: String, meterID: String, title: String, plan: String, model: String, effort: String, speed: String, windowMinutes: Int? = nil, sampleCount: Int, totalPoints: Double, medianTokensPerPoint: Double, lowerTokensPerPoint: Double, upperTokensPerPoint: Double, inputPerPoint: Double, cachedPerPoint: Double, outputPerPoint: Double, reasoningPerPoint: Double, cacheWritePerPoint: Double = 0) {
        self.id=id; self.meterID=meterID; self.title=title; self.plan=plan; self.model=model; self.effort=effort; self.speed=speed; self.windowMinutes=windowMinutes; self.sampleCount=sampleCount; self.totalPoints=totalPoints; self.medianTokensPerPoint=medianTokensPerPoint; self.lowerTokensPerPoint=lowerTokensPerPoint; self.upperTokensPerPoint=upperTokensPerPoint; self.inputPerPoint=inputPerPoint; self.cachedPerPoint=cachedPerPoint; self.cacheWritePerPoint=cacheWritePerPoint; self.outputPerPoint=outputPerPoint; self.reasoningPerPoint=reasoningPerPoint
    }
}

public struct AnalysisSnapshot: Sendable {
    public let intervals: [UsageInterval], openIntervals: [UsageInterval]
    public let calibration: [CalibrationSummary]
    public let issues: [String]
    public let generatedAt: Date
    public let note: String
    public init(intervals: [UsageInterval] = [], openIntervals: [UsageInterval] = [], calibration: [CalibrationSummary] = [], issues: [String] = [], generatedAt: Date = Date(), note: String = "Observed local activity; allowance changes are delayed and rounded. This is not exact billing attribution.") {
        self.intervals=intervals; self.openIntervals=openIntervals; self.calibration=calibration; self.issues=issues; self.generatedAt=generatedAt; self.note=note
    }
}

public enum UsageAnalysis {
    private static func key(_ values: [String]) -> String { values.map { "\($0.utf8.count):\($0)" }.joined() }
    private static func add(_ a: TokenMetrics, _ b: TokenMetrics) -> TokenMetrics {
        var t = TokenMetrics(); t.input=a.input+b.input; t.cached=a.cached+b.cached; t.cacheWrite=a.cacheWrite+b.cacheWrite; t.output=a.output+b.output; t.reasoning=a.reasoning+b.reasoning; return t
    }
    private static func unique(_ values: [String]) -> [String] { Array(Set(values)).sorted() }
    private static func unknown(_ value: String) -> Bool { value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || value.lowercased() == "unknown" }
    private static func segments(_ rows: [ActivityObservation]) -> [ActivitySegment] {
        var result: [String: ActivitySegment] = [:]
        for a in rows.sorted(by: { ($0.sourceAt, $0.id) < ($1.sourceAt, $1.id) }) {
            let k=key([a.threadID,a.turnID ?? "",a.model,a.effort,a.speed,a.project,a.parentThreadID ?? "",a.agentPath ?? ""])
            if var s=result[k] {
                s.tokens=add(s.tokens,a.tokens); s.completedTurns += a.completedTurns; s.toolCalls += a.toolCalls; s.lastAt=max(s.lastAt,a.sourceAt)
                if let d=a.turnDurationSeconds, d.isFinite, d >= 0 { s.turnDurationSeconds=max(s.turnDurationSeconds ?? 0,d) }
                s.issues=unique(s.issues+a.issues); s.provenance=unique(s.provenance+a.provenance); result[k]=s
            } else {
                result[k]=ActivitySegment(id:k,threadID:a.threadID,title:a.title,project:a.project,parentThreadID:a.parentThreadID,agentPath:a.agentPath,turnID:a.turnID,model:a.model,effort:a.effort,speed:a.speed,tokens:a.tokens,completedTurns:a.completedTurns,toolCalls:a.toolCalls,firstAt:a.sourceAt,lastAt:a.sourceAt,turnDurationSeconds:a.turnDurationSeconds,issues:a.issues,provenance:unique(a.provenance))
            }
        }
        return result.values.sorted { ($0.firstAt,$0.id) < ($1.firstAt,$1.id) }
    }
    public static func build(meters: [MeterObservation], activity: [ActivityObservation], now: Date, issues: [String] = []) -> AnalysisSnapshot {
        // IDs identify source records. Re-reading a source is never new activity.
        var seenActivity=Set<String>()
        let deduped=activity.filter { seenActivity.insert(key([$0.account,$0.epoch,$0.id])).inserted }
        var seenMeters=Set<String>()
        let activityByEpoch=Dictionary(grouping:deduped.filter { $0.capturedAt<=now }) { key([$0.account,$0.epoch]) }
            .mapValues { $0.sorted { ($0.sourceAt,$0.id) < ($1.sourceAt,$1.id) } }
        func upperBound(_ rows: [ActivityObservation], _ date: Date) -> Int {
            var lower=0, upper=rows.count
            while lower<upper { let middle=lower+(upper-lower)/2; if rows[middle].sourceAt<=date { lower=middle+1 } else { upper=middle } }
            return lower
        }
        let observations=meters.filter { $0.used.isFinite && (0...100).contains($0.used) && $0.observedAt <= now && seenMeters.insert(key([$0.account,$0.epoch,$0.id])).inserted }
        let groups=Dictionary(grouping: observations) { key([$0.account,$0.epoch,$0.meterID,$0.plan,String($0.windowMinutes ?? -1)]) }
        let latestByMeter=Dictionary(grouping: observations) { key([$0.account,$0.meterID]) }
            .mapValues { values in values.max { ($0.observedAt,$0.id) < ($1.observedAt,$1.id) }! }
        var closed=[UsageInterval](), open=[UsageInterval]()
        for (_, values) in groups.sorted(by: { $0.key < $1.key }) {
            let sorted=values.sorted { ($0.observedAt,$0.id) < ($1.observedAt,$1.id) }
            guard var anchor=sorted.first else { continue }
            var previous=anchor, baseline=true, gaps=[String]()
            func interval(end: MeterObservation?, extra: [String] = []) -> UsageInterval {
                let upper=end?.observedAt ?? now
                let candidates=activityByEpoch[key([anchor.account,anchor.epoch])] ?? []
                let lower=upperBound(candidates,anchor.observedAt), endIndex=upperBound(candidates,upper)
                let rows=Array(candidates[lower..<endIndex])
                let parts=segments(rows)
                var warnings=issues+gaps+extra+parts.flatMap(\.issues)
                if let reset=anchor.resetAt, reset<=upper { warnings.append("Awaiting a meter observation for the new allowance window.") }
                let configs=Set(parts.filter { $0.tokens.total>0 }.map { key([$0.model,$0.effort,$0.speed]) })
                if configs.count>1 { warnings.append("Mixed configurations; per-model allowance attribution is unavailable.") }
                if parts.contains(where: { $0.tokens.total>0 && (unknown($0.model) || unknown($0.effort)) }) { warnings.append("Configuration metadata is incomplete.") }
                if parts.contains(where: { $0.tokens.total>0 && !UsageTier.isComparable($0.speed) }) { warnings.append("Service tier is unresolved or unsupported; this interval is excluded from calibration. Recorded activity remains available.") }
                let threadIDs=Set(parts.map(\.threadID))
                if parts.contains(where: { $0.parentThreadID.map(threadIDs.contains) ?? false }) { warnings.append("Parent and child activity overlap; counter scope is uncertain.") }
                if rows.isEmpty { warnings.append("No local activity captured in this interval.") }
                let totals=parts.reduce(TokenMetrics()) { add($0,$1.tokens) }
                if totals.cached>totals.input || totals.reasoning>totals.output { warnings.append("Token subcategory counters exceed their totals.") }
                let points=end.map { $0.used-anchor.used }
                let eligible=end != nil && !baseline && warnings.isEmpty && configs.count==1 && totals.total>0 && (points ?? 0)>0
                return UsageInterval(id:key([anchor.account,anchor.epoch,anchor.meterID,anchor.id,end?.id ?? "open"]),meterID:anchor.meterID,title:anchor.title,account:anchor.account,plan:anchor.plan,windowMinutes:anchor.windowMinutes,resetAt:anchor.resetAt,epoch:anchor.epoch,startAt:anchor.observedAt,endAt:end?.observedAt,previousObservationAt:previous.observedAt,fromUsed:anchor.used,toUsed:end?.used,isBaseline:baseline,segments:parts,issues:unique(warnings),isCalibrationEligible:eligible,totals:totals,durationSeconds:max(0,upper.timeIntervalSince(anchor.observedAt)))
            }
            for row in sorted.dropFirst() {
                let resetChanged: Bool
                switch (previous.resetAt,row.resetAt) {
                case (.none,.none): resetChanged=false
                case (.some(let a),.some(let b)): resetChanged=abs(a.timeIntervalSince(b))>120
                default: resetChanged=true
                }
                if row.used<previous.used || resetChanged {
                    anchor=row; previous=row; baseline=true; gaps=[]; continue
                }
                if row.observedAt.timeIntervalSince(previous.observedAt)>90 { gaps.append("Observation gap exceeds 90 seconds; activity coverage may be incomplete.") }
                if row.used-anchor.used >= 0.999999 {
                    closed.append(interval(end:row)); anchor=row; baseline=false; gaps=[]
                }
                previous=row
            }
            if now.timeIntervalSince(previous.observedAt)>90 { gaps.append("Latest meter observation is older than 90 seconds.") }
            if latestByMeter[key([anchor.account,anchor.meterID])]?.id == previous.id {
                open.append(interval(end:nil))
            }
        }
        closed.sort { ($0.endAt ?? .distantPast,$0.id) > ($1.endAt ?? .distantPast,$1.id) }
        let retained=Array(closed.prefix(200))
        let calibrationGroups=Dictionary(grouping:closed.filter(\.isCalibrationEligible)) { i in
            let s=i.segments.first(where: { $0.tokens.total>0 })!
            return key([i.account,i.meterID,i.plan,String(i.windowMinutes ?? -1),s.model,s.effort,s.speed])
        }
        let calibration=calibrationGroups.map { k, intervals -> CalibrationSummary in
            let first=intervals[0], config=first.segments.first(where: { $0.tokens.total>0 })!
            let points=intervals.reduce(0) { $0+($1.points ?? 0) }
            let rates=intervals.map { Double($0.totals.total)/$0.points! }.sorted()
            func percentile(_ p: Double) -> Double { let position=Double(rates.count-1)*p; let lower=Int(position); let upper=min(lower+1,rates.count-1); return rates[lower]+(rates[upper]-rates[lower])*(position-Double(lower)) }
            let t=intervals.reduce(TokenMetrics()) { add($0,$1.totals) }
            return CalibrationSummary(id:k,meterID:first.meterID,title:first.title,plan:first.plan,model:config.model,effort:config.effort,speed:config.speed,windowMinutes:first.windowMinutes,sampleCount:intervals.count,totalPoints:points,medianTokensPerPoint:percentile(0.5),lowerTokensPerPoint:percentile(0.1),upperTokensPerPoint:percentile(0.9),inputPerPoint:Double(t.input)/points,cachedPerPoint:Double(t.cached)/points,outputPerPoint:Double(t.output)/points,reasoningPerPoint:Double(t.reasoning)/points,cacheWritePerPoint:Double(t.cacheWrite)/points)
        }.sorted { $0.id<$1.id }
        return AnalysisSnapshot(intervals:retained,openIntervals:open.sorted { $0.id<$1.id },calibration:calibration,issues:unique(issues),generatedAt:now)
    }
}
