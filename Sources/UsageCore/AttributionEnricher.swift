import Foundation

enum AttributionStore {
    static func create(in db: HistoryDatabase) throws {
        try db.run("""
            CREATE TABLE IF NOT EXISTS analysis_attribution_v2 (
              activity_id TEXT PRIMARY KEY,model TEXT NOT NULL,effort TEXT NOT NULL,speed TEXT NOT NULL,
              turn_id TEXT,provenance TEXT NOT NULL,issues TEXT NOT NULL,checked_at REAL NOT NULL,
              retry_after REAL NOT NULL,version INTEGER NOT NULL)
            """)
    }
}

/// Metadata overlays only. Original counters, activity timestamps and meter records
/// remain immutable; source reads never execute or persist message contents.
final class AttributionEnricher {
    private let home: URL
    private let contexts: TurnContextResolver
    private let fractional: ISO8601DateFormatter = {
        let f=ISO8601DateFormatter(); f.formatOptions=[.withInternetDateTime,.withFractionalSeconds]; return f
    }()
    private let whole=ISO8601DateFormatter()
    private let chunk=256*1024
    init(codexHome: URL) { home=codexHome; contexts=TurnContextResolver(codexHome:codexHome) }

    func enrich(_ db: HistoryDatabase, account: String, threads: [[String:String]], limit: Int = 200, force: Bool = false, at: Date = Date()) throws -> Int {
        try Task.checkCancellation()
        let owned=Dictionary(threads.compactMap { row -> (String,[String:String])? in row["id"].map { ($0,row) } },uniquingKeysWith:{ first,_ in first })
        let rows=try db.query("""
            SELECT a.* FROM analysis_activity_v1 a LEFT JOIN analysis_attribution_v2 v ON v.activity_id=a.id
            WHERE a.account=? AND (?='1' OR v.activity_id IS NULL OR v.version<2 OR v.retry_after<=?)
            ORDER BY (v.activity_id IS NULL) DESC,a.at DESC,a.id LIMIT ?
            """,[account,force ? "1":"0",String(at.timeIntervalSince1970),String(max(0,min(limit,1000)))])
        try db.run("SAVEPOINT attribution_enrichment")
        do {
            for row in rows {
                try Task.checkCancellation()
                let result: Overlay
                do { result=try resolve(db,account:account,row:row,thread:owned[row["thread"] ?? ""]) }
                catch is CancellationError { throw CancellationError() }
                catch { result=Overlay(issues:["Local attribution source could not be read; retry is required."]) }
                let complete=result.model != "Unknown" && result.effort != "Unknown" && result.speed != "Unknown"
                let sourceAt=row["at"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
                let recent=sourceAt.map { at.timeIntervalSince($0)<120 } ?? false
                let delay: TimeInterval
                if result.issues.contains(where:{ $0.contains("catching up") }) { delay=60 }
                else if complete { delay=recent ? 30:86400 }
                else { delay=(result.model=="Unknown" || result.effort=="Unknown") ? 300:60 }
                let values: [String?]=[row["id"],result.model,result.effort,result.speed,result.turn,
                    try json(result.references),try json(result.issues),String(at.timeIntervalSince1970),String(at.addingTimeInterval(delay).timeIntervalSince1970),"2"]
                // The account guard protects against a caller passing stale/unowned IDs.
                try db.run("""
                    INSERT INTO analysis_attribution_v2(activity_id,model,effort,speed,turn_id,provenance,issues,checked_at,retry_after,version)
                    SELECT ?,?,?,?,?,?,?,?,?,? WHERE EXISTS(SELECT 1 FROM analysis_activity_v1 WHERE id=? AND account=?)
                    ON CONFLICT(activity_id) DO UPDATE SET model=excluded.model,effort=excluded.effort,speed=excluded.speed,
                    turn_id=excluded.turn_id,provenance=excluded.provenance,issues=excluded.issues,
                    checked_at=excluded.checked_at,retry_after=excluded.retry_after,version=excluded.version
                    WHERE model IS NOT excluded.model OR effort IS NOT excluded.effort OR speed IS NOT excluded.speed
                    OR turn_id IS NOT excluded.turn_id OR provenance IS NOT excluded.provenance OR issues IS NOT excluded.issues
                    OR checked_at IS NOT excluded.checked_at OR retry_after IS NOT excluded.retry_after OR version IS NOT excluded.version
                    """,Array(values.prefix(10))+[row["id"],account])
            }
            try db.run("RELEASE SAVEPOINT attribution_enrichment")
            return rows.count
        } catch {
            try? db.run("ROLLBACK TO SAVEPOINT attribution_enrichment",cancellable:false)
            try? db.run("RELEASE SAVEPOINT attribution_enrichment",cancellable:false)
            throw error
        }
    }
    private struct Overlay {
        var model="Unknown", effort="Unknown", speed="Unknown"
        var turn: String?
        var references=[String](), issues=[String]()
    }
    private func json(_ values: [String]) throws -> String { String(decoding:try JSONEncoder().encode(Array(Set(values)).sorted()),as:UTF8.self) }
    private func date(_ event: [String:Any]) -> Date? { (event["timestamp"] as? String).flatMap { fractional.date(from:$0) ?? whole.date(from:$0) } }
    private func source(_ id: String) -> (String,UInt64)? {
        guard let last=id.lastIndex(of:":"),let offset=UInt64(id[id.index(after:last)...]) else { return nil }
        let prefix=id[..<last]
        guard let colon=prefix.lastIndex(of:":"), UUID(uuidString:String(prefix[prefix.index(after:colon)...])) != nil,
              let slash=prefix[..<colon].firstIndex(of:"/") else { return nil }
        return (String(prefix[slash..<colon]),offset)
    }
    private func allowed(_ path: String) -> Bool {
        let resolved=URL(fileURLWithPath:path).standardizedFileURL.resolvingSymlinksInPath().path
        return ["sessions","archived_sessions"].contains { resolved.hasPrefix(home.appendingPathComponent($0).resolvingSymlinksInPath().path+"/") }
    }
    private func event(_ file: FileHandle, at offset: UInt64) throws -> [String:Any]? {
        if offset>0 {
            try file.seek(toOffset:offset-1)
            guard try file.read(upToCount:1)==Data([10]) else { return nil }
        }
        try file.seek(toOffset:offset)
        var data=Data()
        while data.count<=4*1024*1024 {
            try Task.checkCancellation()
            let bytes=try file.read(upToCount:64*1024) ?? Data()
            if let newline=bytes.firstIndex(of:10) { data.append(bytes[..<newline]); break }
            guard !bytes.isEmpty else { break }
            data.append(bytes)
        }
        guard data.count<=4*1024*1024 else { return nil }
        return (try? JSONSerialization.jsonObject(with:data)) as? [String:Any]
    }
    private struct Counter { let offset: UInt64; let at: Date; let tokens: TokenMetrics; let turn: String? }
    private func priorCounter(_ file: FileHandle, before offset: UInt64) throws -> Counter? {
        var end=offset, pending=Data()
        while end>0 {
            try Task.checkCancellation()
            let begin=end>UInt64(chunk) ? end-UInt64(chunk):0
            try file.seek(toOffset:begin)
            var bytes=try file.read(upToCount:Int(end-begin)) ?? Data()
            guard bytes.count==Int(end-begin) else { return nil }
            bytes.append(pending)
            let lines=bytes.split(separator:10,omittingEmptySubsequences:false)
            var position=begin, records=[(UInt64,Data.SubSequence)]()
            for (index,line) in lines.enumerated() {
                if begin==0 || index>0 { records.append((position,line)) }
                position += UInt64(line.count+1)
            }
            for (position,line) in records.reversed() {
                try Task.checkCancellation()
                guard line.count<=4*1024*1024,line.range(of:Data("\"token_count\"".utf8)) != nil,
                      let e=(try? JSONSerialization.jsonObject(with:Data(line))) as? [String:Any],e["type"] as? String=="event_msg",
                      let p=e["payload"] as? [String:Any],p["type"] as? String=="token_count",
                      let info=p["info"] as? [String:Any],let total=info["total_token_usage"] as? [String:Any],let at=date(e) else { continue }
                return Counter(offset:position,at:at,tokens:TokenMetrics(total),turn:p["turn_id"] as? String)
            }
            pending=begin>0 ? Data(lines.first ?? Data.SubSequence()):Data()
            // A source record can be arbitrarily long; bounded memory still permits
            // looking farther back after dropping that unreadable record.
            if pending.count>4*1024*1024 { pending=Data() }
            end=begin
        }
        return nil
    }
    private func resolve(_ db: HistoryDatabase, account: String, row: [String:String], thread: [String:String]?) throws -> Overlay {
        guard let id=row["id"],let threadID=row["thread"],let thread else { return Overlay(issues:["Thread is not present in the current account-owned index."]) }
        guard let (path,offset)=source(id) else { return Overlay(issues:["Coverage or baseline record has no rollout byte offset; configuration is unavailable."]) }
        guard allowed(path) else { return Overlay(issues:["Activity source is outside the allowed Codex rollout directories."]) }
        guard let sourceAt=row["at"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:)) else { return Overlay(issues:["Stored activity timestamp is unavailable."]) }
        let file=try FileHandle(forReadingFrom:URL(fileURLWithPath:path)); defer { try? file.close() }
        let before=try FileManager.default.attributesOfItem(atPath:path)
        guard let header=try event(file,at:0),header["type"] as? String=="session_meta",
              let metadata=header["payload"] as? [String:Any],metadata["id"] as? String==threadID else {
            return Overlay(issues:["Rollout session identity does not match this activity's thread."])
        }
        guard let e=try event(file,at:offset),let p=e["payload"] as? [String:Any],let stamp=date(e),abs(stamp.timeIntervalSince(sourceAt))<0.001 else { return Overlay(issues:["Rollout byte offset or timestamp no longer matches the recorded activity."]) }
        let created=thread["created_at_ms"].flatMap(Double.init).map { Date(timeIntervalSince1970:$0/1000) }
            ?? thread["created_at"].flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
        // Stored turn metadata in old rows may have been inherited. Source records
        // and chronological own-context resolution take precedence.
        let explicit=p["turn_id"] as? String
        let context=try contexts.resolve(path:path,threadID:threadID,eventOffset:offset,eventAt:stamp,explicitTurnID:explicit,createdAt:created)
        var result=Overlay(model:context.model ?? "Unknown",effort:context.effort ?? "Unknown",turn:context.turnID,references:context.references,issues:[])
        var stored=TokenMetrics(); stored.input=Int64(row["input"] ?? "0") ?? 0; stored.cached=Int64(row["cached"] ?? "0") ?? 0
        stored.cacheWrite=Int64(row["cache_write"] ?? "0") ?? 0; stored.output=Int64(row["output"] ?? "0") ?? 0; stored.reasoning=Int64(row["reasoning"] ?? "0") ?? 0
        var start: Date?
        if stored.total>0 || stored.cacheWrite>0 || stored.cached>0 || stored.reasoning>0 {
            guard e["type"] as? String=="event_msg",p["type"] as? String=="token_count",
                  let info=p["info"] as? [String:Any],let total=info["total_token_usage"] as? [String:Any],
                  let prior=try priorCounter(file,before:offset),let delta=TokenMetrics(total).delta(from:prior.tokens),delta==stored else {
                return Overlay(issues:["Source cumulative counter delta does not match the preserved activity; attribution is unavailable."])
            }
            start=prior.at
            result.references.append("counter-span:\(path):\(prior.offset)..\(offset)")
            let earlier=try contexts.resolve(path:path,threadID:threadID,eventOffset:prior.offset,eventAt:prior.at,explicitTurnID:prior.turn,createdAt:created)
            if let model=earlier.model,let endModel=context.model,let effort=earlier.effort,let endEffort=context.effort {
                if model != endModel || effort != endEffort {
                    result.model="Unknown"; result.effort="Unknown"
                    result.issues.append("Counter span crosses a configuration change; per-configuration token attribution is unavailable.")
                }
            } else { result.issues.append("Configuration at the beginning of the counter span is unavailable.") }
            result.references += earlier.references
        }
        if let turn=result.turn {
            let request=try RequestEvidence.resolve(in:db,account:account,threadID:threadID,turnID:turn,startAt:start,endAt:stamp)
            result.references += request.references
            result.issues += request.issues.filter { issue in
                start != nil || issue != "Counter span start unavailable; settings describe retained same-turn sampling evidence."
            }
            if !result.issues.contains(where: { $0.contains("Counter span crosses") }) {
                if let model=request.model {
                    if let chosen=context.model,chosen != model { result.model="Unknown"; result.issues.append("Sampling model conflicts with chosen turn configuration.") }
                    else { result.model=model }
                }
                if let effort=request.effort {
                    if let chosen=context.effort,chosen != effort { result.effort="Unknown"; result.issues.append("Sampling reasoning effort conflicts with chosen turn configuration.") }
                    else { result.effort=effort }
                }
            }
            if request.model != nil,request.effort != nil,request.issues.isEmpty {
                result.issues.removeAll { $0 == "Configuration at the beginning of the counter span is unavailable." }
            }
            result.speed=request.tier ?? "Unknown"
            if request.issues.contains(where:{ $0.contains("Sampling model changed") }) { result.model="Unknown" }
            if request.issues.contains(where:{ $0.contains("Sampling reasoning effort changed") }) { result.effort="Unknown" }
        } else { result.issues.append("Own turn identity unavailable; sampling settings could not be matched.") }
        if result.model=="Unknown" || result.effort=="Unknown" { result.issues += context.issues }
        if result.speed=="Unknown" { result.issues.append("Service tier is unknown; no matching retained sampling evidence established it.") }
        let after=try FileManager.default.attributesOfItem(atPath:path)
        for key in [FileAttributeKey.systemFileNumber,.systemNumber,.creationDate] {
            if String(describing:before[key]) != String(describing:after[key]) { return Overlay(issues:["Rollout source changed during attribution; retry is required."]) }
        }
        let beforeSize=(before[.size] as? NSNumber)?.uint64Value ?? 0
        let afterSize=(after[.size] as? NSNumber)?.uint64Value ?? 0
        if afterSize<beforeSize { return Overlay(issues:["Rollout source was truncated during attribution; retry is required."]) }
        if String(describing:before[.modificationDate]) != String(describing:after[.modificationDate]) {
            // Normal append-only activity must not repeatedly invalidate old evidence.
            // Recheck the source line and own-context anchors before accepting growth.
            guard afterSize>beforeSize,let current=try event(file,at:offset),NSDictionary(dictionary:current).isEqual(to:e),
                  let currentHeader=try event(file,at:0),NSDictionary(dictionary:currentHeader).isEqual(to:header) else {
                return Overlay(issues:["Rollout source anchors changed during attribution; retry is required."])
            }
            let checked=try contexts.resolve(path:path,threadID:threadID,eventOffset:offset,eventAt:stamp,explicitTurnID:explicit,createdAt:created)
            guard checked.model==context.model,checked.effort==context.effort,checked.turnID==context.turnID,
                  checked.contextOffset==context.contextOffset else {
                return Overlay(issues:["Rollout context anchors changed during attribution; retry is required."])
            }
        }
        result.references=Array(Set(result.references)).sorted(); result.issues=Array(Set(result.issues)).sorted()
        return result
    }
}
