import Foundation

/// Additive, versioned telemetry tables. Older history is retained but never used
/// for calibration because it mixed account reads with delayed rollout meters.
enum AnalysisStore {
    static func create(in db: HistoryDatabase) throws {
        try db.run("CREATE TABLE IF NOT EXISTS analysis_meter_v1 (id TEXT PRIMARY KEY,account TEXT NOT NULL,epoch TEXT NOT NULL,meter TEXT NOT NULL,title TEXT NOT NULL,plan TEXT NOT NULL,minutes INTEGER,reset REAL,used REAL NOT NULL,at REAL NOT NULL)")
        try db.run("CREATE INDEX IF NOT EXISTS analysis_meter_time ON analysis_meter_v1(account,at)")
        try db.run("CREATE TABLE IF NOT EXISTS analysis_activity_v1 (id TEXT PRIMARY KEY,account TEXT NOT NULL,epoch TEXT NOT NULL,thread TEXT NOT NULL,title TEXT NOT NULL,project TEXT NOT NULL,parent TEXT,agent TEXT,turn TEXT,model TEXT NOT NULL,effort TEXT NOT NULL,speed TEXT NOT NULL,at REAL NOT NULL,captured REAL NOT NULL,input INTEGER NOT NULL,cached INTEGER NOT NULL,cache_write INTEGER NOT NULL,output INTEGER NOT NULL,reasoning INTEGER NOT NULL,turns INTEGER NOT NULL,tools INTEGER NOT NULL,duration REAL,issues TEXT NOT NULL)")
        try db.run("CREATE INDEX IF NOT EXISTS analysis_activity_time ON analysis_activity_v1(account,at)")
        try AttributionStore.create(in: db)
        try RequestEvidence.create(in: db)
    }
    static func meter(_ db: HistoryDatabase, account: String, epoch: String, row: UsageRow, plan: String, date: Date) throws {
        guard let used = row.window.usedPercent, used.isFinite, (0...100).contains(used) else { return }
        try db.run("INSERT INTO analysis_meter_v1 VALUES (?,?,?,?,?,?,?,?,?,?)", [UUID().uuidString, account, epoch, row.id, row.title, plan, row.window.windowDurationMins.map(String.init), row.window.resetDate.map { String($0.timeIntervalSince1970) }, String(used), String(date.timeIntervalSince1970)])
    }
    static func activity(_ db: HistoryDatabase, _ a: ActivityObservation) throws {
        let issues = String(decoding: try JSONEncoder().encode(a.issues), as: UTF8.self)
        try db.run("INSERT OR IGNORE INTO analysis_activity_v1 VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", [a.id,a.account,a.epoch,a.threadID,a.title,a.project,a.parentThreadID,a.agentPath,a.turnID,a.model,a.effort,a.speed,String(a.sourceAt.timeIntervalSince1970),String(a.capturedAt.timeIntervalSince1970),String(a.tokens.input),String(a.tokens.cached),String(a.tokens.cacheWrite),String(a.tokens.output),String(a.tokens.reasoning),String(a.completedTurns),String(a.toolCalls),a.turnDurationSeconds.flatMap { $0.isFinite && $0 >= 0 ? String($0) : nil },issues])
    }
    static func snapshot(_ db: HistoryDatabase, account: String, now: Date = Date(), paused: Bool = false, coverageIssues: [String] = []) throws -> AnalysisSnapshot {
        guard !(try db.query("SELECT name FROM sqlite_master WHERE type='table' AND name='analysis_meter_v1'")).isEmpty else { return .init() }
        var asOf = now
        if paused {
            let last = try db.query("SELECT MAX(at) AS at FROM (SELECT MAX(at) AS at FROM analysis_meter_v1 WHERE account=? UNION ALL SELECT MAX(captured) AS at FROM analysis_activity_v1 WHERE account=?)", [account,account]).first?["at"].flatMap(Double.init)
            if let last { asOf = min(now, Date(timeIntervalSince1970: last)) }
        }
        // Persist all data, but bound interactive work. When the limit cuts through
        // activity, move the analysis start forward; the first remaining interval
        // is an excluded baseline. Never calibrate a partly retained interval.
        let cutoff = asOf.addingTimeInterval(-14 * 86400).timeIntervalSince1970
        let meterRows = try db.query("SELECT * FROM analysis_meter_v1 WHERE account=? AND at>=? ORDER BY at DESC LIMIT 100001", [account,String(cutoff)])
        let hasAttribution = !(try db.query("SELECT name FROM sqlite_master WHERE type='table' AND name='analysis_attribution_v2'")).isEmpty
        let activityRows: [[String:String]]
        if hasAttribution {
            activityRows = try db.query("""
                SELECT a.*,v.model AS verified_model,v.effort AS verified_effort,v.speed AS verified_speed,
                       v.turn_id AS verified_turn,v.provenance AS attribution_provenance,v.issues AS attribution_issues
                FROM analysis_activity_v1 a LEFT JOIN analysis_attribution_v2 v ON a.id=v.activity_id
                WHERE a.account=? AND a.at>=? ORDER BY a.at DESC LIMIT 100001
                """,[account,String(cutoff)])
        } else { activityRows = try db.query("SELECT * FROM analysis_activity_v1 WHERE account=? AND at>=? ORDER BY at DESC LIMIT 100001",[account,String(cutoff)]) }
        let limited = meterRows.count > 100000 || activityRows.count > 100000
        let retainedStart = activityRows.count > 100000
            ? max(cutoff, Double(activityRows[99999]["at"] ?? "") ?? cutoff) : cutoff
        let meters = meterRows.prefix(100000).compactMap { r -> MeterObservation? in
            guard let at = r["at"].flatMap(Double.init), at >= retainedStart, let used = r["used"].flatMap(Double.init) else { return nil }
            return .init(id:r["id"]!,account:account,epoch:r["epoch"]!,meterID:r["meter"]!,title:r["title"]!,plan:r["plan"]!,windowMinutes:r["minutes"].flatMap(Int.init),resetAt:r["reset"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:)),used:used,observedAt:Date(timeIntervalSince1970:at))
        }
        let activity = activityRows.prefix(100000).compactMap { r -> ActivityObservation? in
            guard let at = r["at"].flatMap(Double.init), let captured = r["captured"].flatMap(Double.init) else { return nil }
            var t=TokenMetrics(); t.input=Int64(r["input"] ?? "0") ?? 0; t.cached=Int64(r["cached"] ?? "0") ?? 0
            t.cacheWrite=Int64(r["cache_write"] ?? "0") ?? 0; t.output=Int64(r["output"] ?? "0") ?? 0; t.reasoning=Int64(r["reasoning"] ?? "0") ?? 0
            func strings(_ key: String) -> [String] { r[key].flatMap { $0.data(using:.utf8) }.flatMap { try? JSONDecoder().decode([String].self,from:$0) } ?? [] }
            var warnings = strings("issues")
            if r["verified_model"] != nil {
                // The overlay checks both counter endpoints and replaces this older
                // cursor-change heuristic with evidence-based attribution warnings.
                warnings.removeAll { $0 == "Counter span crosses a configuration change; attribution may include earlier work." }
            }
            if t.total > 0 || t.cacheWrite > 0 {
                warnings += r["attribution_issues"] == nil ? ["Metadata verification is pending."] : strings("attribution_issues")
            }
            return .init(id:r["id"]!,account:account,epoch:r["epoch"]!,threadID:r["thread"]!,title:r["title"]!,project:r["project"]!,parentThreadID:r["parent"],agentPath:r["agent"],turnID:r["verified_turn"],model:r["verified_model"] ?? "Unknown",effort:r["verified_effort"] ?? "Unknown",speed:r["verified_speed"] ?? "Unknown",sourceAt:Date(timeIntervalSince1970:at),capturedAt:Date(timeIntervalSince1970:captured),tokens:t,completedTurns:Int(r["turns"] ?? "0") ?? 0,toolCalls:Int(r["tools"] ?? "0") ?? 0,turnDurationSeconds:r["duration"].flatMap(Double.init),issues:warnings,provenance:strings("attribution_provenance"))
        }
        let result = UsageAnalysis.build(meters:meters,activity:activity,now:asOf,issues:coverageIssues)
        guard limited else { return result }
        return AnalysisSnapshot(intervals: result.intervals, openIntervals: result.openIntervals, calibration: result.calibration,
            issues: result.issues + ["Analysis reached its 100,000-record bound. Only fully retained recent intervals contribute to calibration; older records remain on disk."],
            generatedAt: result.generatedAt, note: result.note)
    }
}
