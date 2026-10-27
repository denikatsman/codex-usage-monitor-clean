import Foundation
import CryptoKit
import CoreFoundation

/// Local sampling settings, not a claim about billing or the server-served tier.
struct RequestAttribution {
    var model: String?
    var effort: String?
    var tier: String?
    var references: [String]
    var issues: [String]
}

enum RequestEvidence {
    private static let batchLimit = 10_000

    static func create(in db: HistoryDatabase) throws {
        try db.run("""
            CREATE TABLE IF NOT EXISTS request_evidence_v1 (
              account TEXT NOT NULL, source TEXT NOT NULL, generation INTEGER NOT NULL,
              log_id INTEGER NOT NULL, thread TEXT NOT NULL, turn TEXT NOT NULL,
              at REAL NOT NULL, model TEXT, effort TEXT, raw_tier TEXT, tier TEXT,
              issues TEXT NOT NULL,
              PRIMARY KEY(account,source,generation,log_id,thread))
            """)
        try db.run("CREATE INDEX IF NOT EXISTS request_evidence_turn_v1 ON request_evidence_v1(account,thread,turn,at)")
        try db.run("""
            CREATE TABLE IF NOT EXISTS request_evidence_cursor_v1 (
              account TEXT NOT NULL, source TEXT NOT NULL, thread TEXT NOT NULL,
              generation INTEGER NOT NULL, last_id INTEGER NOT NULL,
              anchor TEXT NOT NULL, catching_up INTEGER NOT NULL,
              PRIMARY KEY(account,source,thread))
            """)
        try db.run("""
            CREATE TABLE IF NOT EXISTS request_evidence_coverage_v1 (
              account TEXT NOT NULL, source TEXT NOT NULL, thread TEXT NOT NULL,
              start_at REAL NOT NULL, end_at REAL NOT NULL,
              PRIMARY KEY(account,source,thread,start_at))
            """)
        try db.run("""
            CREATE TABLE IF NOT EXISTS request_evidence_gap_v1 (
              account TEXT NOT NULL, source TEXT NOT NULL, generation INTEGER NOT NULL,
              log_id INTEGER NOT NULL, thread TEXT NOT NULL, at REAL NOT NULL,
              PRIMARY KEY(account,source,generation,log_id,thread))
            """)
        try db.run("CREATE INDEX IF NOT EXISTS request_evidence_gap_time_v1 ON request_evidence_gap_v1(account,thread,at)")
    }

    /// Import only a deliberately selected local capture. The app never discovers
    /// audit files automatically; the checksum identifies immutable source bytes.
    static func importCapture(_ url: URL, into db: HistoryDatabase, account: String,
                              threads: Set<String>) throws {
        try Task.checkCancellation()
        guard !account.isEmpty else { throw HistoryDatabase.Failure.database("Capture account is empty") }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 16 * 1024 * 1024 else { throw HistoryDatabase.Failure.database("Request capture exceeds 16 MiB") }
        // Bounded read also enforces the limit if the file grows after inspection.
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 16 * 1024 * 1024 + 1) ?? Data()
        guard data.count <= 16 * 1024 * 1024,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let records = object["requests"] as? [[String: Any]], records.count <= 100_000 else {
            throw HistoryDatabase.Failure.database("Invalid or oversized request capture")
        }
        struct Captured {
            let id: String, thread: String, at: Double
            let sample: Sample
        }
        var validated = [Captured]()
        for record in records {
            try Task.checkCancellation()
            guard let id = integer(record["log_id"]), id > 0,
                  let seconds = integer(record["ts"]),
                  let nanos = integer(record["ts_nanos"]), (0..<1_000_000_000).contains(nanos),
                  let thread = identifier(record["thread"]),
                  let turn = identifier(record["turn"]),
                  let present = record["service_tier_present"] as? NSNumber,
                  CFGetTypeID(present) == CFBooleanGetTypeID() else {
                throw HistoryDatabase.Failure.database("Malformed request capture metadata")
            }
            let at = Double(seconds) + Double(nanos) / 1_000_000_000
            guard at.isFinite else { throw HistoryDatabase.Failure.database("Invalid request capture timestamp") }
            var issues = [String]()
            func optionalText(_ key: String) throws -> String? {
                guard let value = record[key], !(value is NSNull) else { return nil }
                guard let text = value as? String, !text.isEmpty, text.utf8.count <= 512 else {
                    throw HistoryDatabase.Failure.database("Malformed request capture setting")
                }
                return text
            }
            let model = try optionalText("model"), effort = try optionalText("effort")?.lowercased()
            let rawTier = try optionalText("service_tier")
            guard present.boolValue || rawTier == nil else {
                throw HistoryDatabase.Failure.database("Inconsistent request capture tier presence")
            }
            if model == nil { issues.append("Sampling model metadata is missing.") }
            if effort == nil { issues.append("Sampling reasoning metadata is missing.") }
            let tier = rawTier.map { UsageTier.canonical($0) }
            if let tier, !["priority","default","unset","ultrafast"].contains(tier) {
                issues.append("Sampling service tier is unrecognized; its recorded value is preserved.")
            }
            if rawTier == nil {
                issues.append(present.boolValue ? "Sampling service tier was explicitly null." : "Sampling service tier metadata is missing.")
            }
            if threads.contains(thread) {
                validated.append(Captured(id: String(id), thread: thread, at: at,
                    sample: Sample(turn: turn, model: model, effort: effort, rawTier: rawTier, tier: tier, issues: issues)))
            }
        }
        let identity = "audit-capture:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        func bound(_ value: Any?) throws -> Double? {
            guard let value, !(value is NSNull) else { return nil }
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else {
                throw HistoryDatabase.Failure.database("Malformed request capture coverage")
            }
            return number.doubleValue
        }
        let retained = object["retained_range"] as? [String: Any]
        let beginning = try bound(object["query_start"])
        let retainedBeginning = try bound(retained?["first"])
        let end = try bound(object["query_end"] ?? object["captureAsOf"])
        let start = [beginning,retainedBeginning].compactMap { $0 }.max()
        if let start, let end, start > end {
            throw HistoryDatabase.Failure.database("Invalid request capture coverage range")
        }
        try db.run("SAVEPOINT request_evidence_import")
        do {
            for record in validated {
                let sample = record.sample
                let issues = String(decoding: try JSONEncoder().encode(sample.issues), as: UTF8.self)
                try db.run("INSERT OR IGNORE INTO request_evidence_v1 VALUES (?,?,?,?,?,?,?,?,?,?,?,?)", [account,identity,"0",record.id,record.thread,sample.turn,String(record.at),sample.model,sample.effort,sample.rawTier,sample.tier,issues])
            }
            if let start, let end {
                for thread in Set(validated.map(\.thread)) {
                    try recordCoverage(in: db, account: account, source: identity, thread: thread, start: start, end: end)
                }
            }
            try db.run("RELEASE SAVEPOINT request_evidence_import")
        } catch {
            try? db.run("ROLLBACK TO SAVEPOINT request_evidence_import", cancellable: false)
            try? db.run("RELEASE SAVEPOINT request_evidence_import", cancellable: false)
            throw error
        }
    }

    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue >= Double(Int64.min), number.doubleValue < Double(Int64.max) else { return nil }
        return number.int64Value
    }

    private static func identifier(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty, value.utf8.count <= 512,
              value.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else { return nil }
        return value
    }

    /// Only account-owned threads supplied by the caller enter the app's database.
    /// Cursors are per thread, so discovering another agent backfills its retained logs.
    static func collect(into db: HistoryDatabase, codexHome: URL, account: String,
                        threads: Set<String>, since: Date, through: Date? = nil) throws {
        try Task.checkCancellation()
        guard !threads.isEmpty else { return }
        let paths = try FileManager.default.contentsOfDirectory(at: codexHome, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.range(of: #"^logs_[0-9]+\.sqlite$"#, options: .regularExpression) != nil }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        try db.run("SAVEPOINT request_evidence_collect")
        do {
            // Removed/rotated sources cannot leave a permanent catching-up flag.
            try db.run("UPDATE request_evidence_cursor_v1 SET catching_up=0 WHERE account=?", [account])
            var remaining = batchLimit
            for path in paths {
                try Task.checkCancellation()
                let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
                let identity = [path.lastPathComponent,
                                String(describing: attributes[.systemNumber] ?? ""),
                                String(describing: attributes[.systemFileNumber] ?? ""),
                                String((attributes[.creationDate] as? Date)?.timeIntervalSince1970 ?? 0)].joined(separator: ":")
                let source = try HistoryDatabase(url: path, readOnly: true)
                let asOf = min(Date().timeIntervalSince1970, through?.timeIntervalSince1970 ?? .infinity)
                let maximum = Int64(try source.query("SELECT MAX(id) AS id FROM logs").first?["id"] ?? "0") ?? 0
                let retainedStart = try source.query("SELECT MIN(ts) AS first FROM logs").first?["first"].flatMap(Double.init)
                for thread in threads.sorted() {
                    let saved = try db.query("SELECT * FROM request_evidence_cursor_v1 WHERE account=? AND source=? AND thread=?", [account,identity,thread]).first
                    var generation = Int(saved?["generation"] ?? "0") ?? 0
                    var lastID = Int64(saved?["last_id"] ?? "0") ?? 0
                    var anchor = saved?["anchor"] ?? ""
                    // Detect a recreated/truncated database even when its inode survives.
                    let existing = lastID > 0 ? try source.query("SELECT id,ts,ts_nanos,thread_id FROM logs WHERE id=?", [String(lastID)]).first : nil
                    if maximum < lastID || (existing.map { fingerprint($0) != anchor } ?? false) {
                        generation += 1; lastID = 0; anchor = ""
                    }
                    let limit = min(1000, remaining)
                    let records = try source.query("""
                        SELECT id,ts,ts_nanos,thread_id,feedback_log_body,module_path,file FROM logs
                        WHERE thread_id=? AND id>? AND ts>=? AND target='feedback_tags'
                        ORDER BY id LIMIT ?
                        """, [thread,String(lastID),String(since.timeIntervalSince1970),String(limit + 1)])
                    let selected = records.prefix(limit)
                    for row in selected {
                        try Task.checkCancellation()
                        let body = row["feedback_log_body"] ?? ""
                        let at = (Double(row["ts"] ?? "0") ?? 0) + (Double(row["ts_nanos"] ?? "0") ?? 0) / 1_000_000_000
                        if isAuxiliaryFeedback(body, module: row["module_path"], file: row["file"]) {
                            // Transport/auth feedback inherits the sampling span
                            // names. It is not a new settings snapshot.
                        } else if let sample = parse(body) {
                            let issues = String(decoding: try JSONEncoder().encode(sample.issues), as: UTF8.self)
                            try db.run("INSERT OR IGNORE INTO request_evidence_v1 VALUES (?,?,?,?,?,?,?,?,?,?,?,?)", [account,identity,String(generation),row["id"],thread,sample.turn,String(at),sample.model,sample.effort,sample.rawTier,sample.tier,issues])
                        } else if body.contains("run_sampling_request") {
                            // Preserve a metadata gap even after its source row is
                            // pruned. No message text or guessed turn enters storage.
                            try db.run("INSERT OR IGNORE INTO request_evidence_gap_v1 VALUES (?,?,?,?,?,?)", [account,identity,String(generation),row["id"],thread,String(at)])
                        }
                        lastID = Int64(row["id"] ?? "0") ?? lastID
                        anchor = fingerprint(row)
                    }
                    remaining -= selected.count
                    try db.run("INSERT OR REPLACE INTO request_evidence_cursor_v1 VALUES (?,?,?,?,?,?,?)", [account,identity,thread,String(generation),String(lastID),anchor,records.count > limit ? "1" : "0"])
                    if records.count <= limit, let retainedStart {
                        try recordCoverage(in: db, account: account, source: identity, thread: thread,
                                           start: max(retainedStart, since.timeIntervalSince1970), end: asOf)
                    }
                }
            }
            try db.run("RELEASE SAVEPOINT request_evidence_collect")
        } catch {
            try? db.run("ROLLBACK TO SAVEPOINT request_evidence_collect", cancellable: false)
            try? db.run("RELEASE SAVEPOINT request_evidence_collect", cancellable: false)
            throw error
        }
    }

    /// Includes the settings active at the span's start and every observed same-turn
    /// sample through its end. A preceding sample is turn evidence, not a request ID.
    static func resolve(in db: HistoryDatabase, account: String, threadID: String,
                        turnID: String, startAt: Date?, endAt: Date) throws -> RequestAttribution {
        var rows: [[String: String]]
        var issues = [String]()
        let base = [account,threadID,turnID]
        if let startAt {
            rows = try db.query("SELECT * FROM request_evidence_v1 WHERE account=? AND thread=? AND turn=? AND at<=? ORDER BY at DESC,log_id DESC LIMIT 1", base + [String(startAt.timeIntervalSince1970)])
            if rows.isEmpty { issues.append("No retained sampling settings cover the beginning of this counter span.") }
            rows += try db.query("SELECT * FROM request_evidence_v1 WHERE account=? AND thread=? AND turn=? AND at>? AND at<=? ORDER BY at,log_id LIMIT 10001", base + [String(startAt.timeIntervalSince1970),String(endAt.timeIntervalSince1970)])
        } else {
            rows = try db.query("SELECT * FROM request_evidence_v1 WHERE account=? AND thread=? AND turn=? AND at<=? ORDER BY at,log_id LIMIT 10001", base + [String(endAt.timeIntervalSince1970)])
            issues.append("Counter span start unavailable; settings describe retained same-turn sampling evidence.")
        }
        if rows.count > batchLimit {
            return RequestAttribution(references: [], issues: ["Sampling evidence span exceeds 10,000 records; attribution is incomplete."])
        }
        if rows.isEmpty { issues.append("No retained sampling request evidence for this turn.") }
        if !rows.isEmpty, let startAt {
            let coverage = try db.query("SELECT start_at,end_at FROM request_evidence_coverage_v1 WHERE account=? AND thread=? AND end_at>=? AND start_at<=? ORDER BY start_at", [account,threadID,String(startAt.timeIntervalSince1970),String(endAt.timeIntervalSince1970)])
            var coveredThrough = startAt.timeIntervalSince1970
            for range in coverage {
                guard let lower = range["start_at"].flatMap(Double.init), let upper = range["end_at"].flatMap(Double.init) else { continue }
                if lower > coveredThrough { break }
                coveredThrough = max(coveredThrough, upper)
            }
            if coveredThrough < endAt.timeIntervalSince1970 {
                issues.append("Sampling log coverage does not include the complete counter span.")
            }
        }
        let pending = try db.query("SELECT 1 AS pending FROM request_evidence_cursor_v1 WHERE account=? AND thread=? AND catching_up=1 LIMIT 1", [account,threadID])
        if !pending.isEmpty { issues.append("Local sampling evidence is catching up; attribution may be incomplete.") }
        // An unparsed sample between the preceding known settings and this span
        // can invalidate the settings inherited at its start as well.
        let gapStart = min(startAt?.timeIntervalSince1970 ?? Date.distantPast.timeIntervalSince1970,
                           rows.first?["at"].flatMap(Double.init) ?? .infinity)
        let gaps = try db.query("SELECT source,generation,log_id FROM request_evidence_gap_v1 WHERE account=? AND thread=? AND at>=? AND at<=? ORDER BY at LIMIT 10001", [account,threadID,String(gapStart),String(endAt.timeIntervalSince1970)])
        if !gaps.isEmpty {
            issues.append("Sampling metadata could not be parsed within this counter span; attribution may be incomplete.")
        }
        for row in rows {
            if let raw = row["issues"], let data = raw.data(using: .utf8), let values = try? JSONDecoder().decode([String].self, from: data) { issues += values }
        }
        func value(_ column: String, label: String) -> String? {
            // Absence is incomplete evidence, not an observed setting change.
            // Per-row issues still prevent incomplete evidence from calibrating.
            let distinct = Set(rows.compactMap { $0[column] })
            if distinct.count > 1 { issues.append("Sampling \(label) changed within this counter span; per-setting token attribution is unavailable."); return nil }
            return distinct.first
        }
        let model = value("model", label: "model"), effort = value("effort", label: "reasoning effort"), tier = value("tier", label: "service tier")
        let references = rows.map { "sampling:\($0["source"] ?? ""):\($0["generation"] ?? "0"):\($0["log_id"] ?? "")" }
            + gaps.map { "sampling-gap:\($0["source"] ?? ""):\($0["generation"] ?? "0"):\($0["log_id"] ?? "")" }
        return RequestAttribution(model: model, effort: effort, tier: tier, references: Array(Set(references)).sorted(), issues: Array(Set(issues)).sorted())
    }

    private static func fingerprint(_ row: [String: String]) -> String {
        ["id","ts","ts_nanos","thread_id"].map { row[$0] ?? "" }.joined(separator: ":")
    }

    private static func recordCoverage(in db: HistoryDatabase, account: String, source: String,
                                       thread: String, start: Double, end: Double) throws {
        guard start.isFinite, end.isFinite, start <= end else { return }
        let arguments = [account,source,thread,String(end),String(start)]
        let overlap = try db.query("SELECT MIN(start_at) AS first,MAX(end_at) AS last FROM request_evidence_coverage_v1 WHERE account=? AND source=? AND thread=? AND start_at<=? AND end_at>=?", arguments).first
        let lower = min(start, overlap?["first"].flatMap(Double.init) ?? start)
        let upper = max(end, overlap?["last"].flatMap(Double.init) ?? end)
        try db.run("DELETE FROM request_evidence_coverage_v1 WHERE account=? AND source=? AND thread=? AND start_at<=? AND end_at>=?", arguments)
        try db.run("INSERT INTO request_evidence_coverage_v1 VALUES (?,?,?,?,?)", [account,source,thread,String(lower),String(upper)])
    }

    private struct Sample {
        var turn: String
        var model: String?
        var effort: String?
        var rawTier: String?
        var tier: String?
        var issues: [String]
    }

    private static func capture(_ pattern: String, in body: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)),
              let range = Range(match.range(at: 1), in: body) else { return nil }
        return String(body[range])
    }

    private static func parse(_ body: String) -> Sample? {
        guard let sampling = frames("try_run_sampling_request", in: body).last
                ?? frames("run_sampling_request", in: body).last,
              let turn = capture(#"(?:^|\s)turn_id="?([A-Za-z0-9_-]+)"#, in: sampling) else { return nil }
        let fields = emittedFields(in: body)
        let settings = String(fields[..<(fields.range(of: "tags_json=")?.lowerBound ?? fields.endIndex)])
        let ownTurn = frames("turn", in: body).last {
            capture(#"(?:^|\s)turn\.id="?([A-Za-z0-9_-]+)"#, in: $0) == turn
        }
        func modelValue(_ text: String) -> String? {
            capture(#"(?:^|\s)model="([^"]+)""#, in: text)
                ?? capture(#"(?:^|\s)model=([A-Za-z0-9_.-]+)"#, in: text)
        }
        let model = modelValue(settings) ?? modelValue(sampling)
        let effort = capture(#"(?:^|\s)effort=Some\(([^)]+)\)"#, in: settings)?.lowercased()
            ?? ownTurn.flatMap { capture(#"(?:^|\s)codex\.turn\.reasoning_effort="?([A-Za-z0-9_-]+)"#, in: $0)?.lowercased() }
        var issues = [String]()
        if model == nil { issues.append("Sampling model metadata is missing.") }
        if effort == nil { issues.append("Sampling reasoning metadata is missing.") }
        let tags = tagObject(fields)
        let rawTier = tags?["service_tier"] as? String
        let tier: String?
        if let rawTier {
            tier = UsageTier.canonical(rawTier)
            if !["priority","default","unset","ultrafast"].contains(tier!) {
                issues.append("Sampling service tier is unrecognized; its recorded value is preserved.")
            }
        } else {
            tier = nil
            issues.append(tags?["service_tier"] is NSNull ? "Sampling service tier was explicitly null." : "Sampling service tier metadata is missing.")
        }
        return Sample(turn: turn, model: model, effort: effort, rawTier: rawTier, tier: tier, issues: issues)
    }

    private static func isAuxiliaryFeedback(_ body: String, module: String?, file: String?) -> Bool {
        // Verified local feedback/src/lib.rs auth emissions carry inherited
        // run_sampling_request/turn/model scopes, then auth_header_attached and
        // related transport fields. They emit no settings tags/model/effort.
        let fields = emittedFields(in: body)
        return module == "codex_feedback" && file?.hasSuffix("feedback/src/lib.rs") == true
            && fields.contains("auth_header_attached=") && !fields.contains("tags_json=")
            && !fields.contains("model=\"") && !fields.contains("effort=Some(")
    }

    private static func frames(_ name: String, in body: String) -> [String] {
        let pattern = "(?:^|:)" + NSRegularExpression.escapedPattern(for: name) + #"\{([^{}]*)\}"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: body, range: NSRange(body.startIndex..., in: body)).compactMap {
            Range($0.range(at: 1), in: body).map { String(body[$0]) }
        }
    }

    /// Settings belong to the emitted fields after the scope chain. Stop the
    /// delimiter search before JSON so braces in tag values cannot select a scope.
    private static func emittedFields(in body: String) -> String {
        let prefix = body[..<(body.range(of: "tags_json=")?.lowerBound ?? body.endIndex)]
        guard let delimiter = prefix.range(of: "}:", options: .backwards) else { return body }
        return String(body[delimiter.upperBound...])
    }

    /// Decode only the JSON object following tags_json, ignoring surrounding log
    /// text. Never persist that object or any unselected message content.
    private static func tagObject(_ body: String) -> [String: Any]? {
        guard let marker = body.range(of: "tags_json="), let begin = body[marker.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0, quoted = false, escaped = false
        for index in body[begin...].indices {
            let character = body[index]
            if quoted {
                if escaped { escaped = false }
                else if character == "\\" { escaped = true }
                else if character == "\"" { quoted = false }
            } else if character == "\"" { quoted = true }
            else if character == "{" { depth += 1 }
            else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return (try? JSONSerialization.jsonObject(with: Data(body[begin...index].utf8))) as? [String: Any]
                }
            }
        }
        return nil
    }
}
