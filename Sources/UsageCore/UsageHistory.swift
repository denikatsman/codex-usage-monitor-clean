import Foundation
import CryptoKit

public struct TokenMetrics: Codable, Equatable, Sendable {
    public var input: Int64 = 0
    public var cached: Int64 = 0
    public var cacheWrite: Int64 = 0
    public var output: Int64 = 0
    public var reasoning: Int64 = 0
    public var total: Int64 { input + output }
    public init() {}
    private enum CodingKeys: String, CodingKey { case input, cached, cacheWrite, output, reasoning }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        input = try c.decodeIfPresent(Int64.self, forKey: .input) ?? 0
        cached = try c.decodeIfPresent(Int64.self, forKey: .cached) ?? 0
        cacheWrite = try c.decodeIfPresent(Int64.self, forKey: .cacheWrite) ?? 0
        output = try c.decodeIfPresent(Int64.self, forKey: .output) ?? 0
        reasoning = try c.decodeIfPresent(Int64.self, forKey: .reasoning) ?? 0
    }
    init(_ object: [String: Any]) {
        input = max(0, (object["input_tokens"] as? NSNumber)?.int64Value ?? 0)
        cached = max(0, (object["cached_input_tokens"] as? NSNumber)?.int64Value ?? 0)
        cacheWrite = max(0, (object["cache_write_input_tokens"] as? NSNumber)?.int64Value ?? 0)
        output = max(0, (object["output_tokens"] as? NSNumber)?.int64Value ?? 0)
        reasoning = max(0, (object["reasoning_output_tokens"] as? NSNumber)?.int64Value ?? 0)
    }
    func delta(from old: Self) -> Self? {
        guard input >= old.input, cached >= old.cached, cacheWrite >= old.cacheWrite, output >= old.output, reasoning >= old.reasoning else { return nil }
        var value = Self()
        value.input = input - old.input; value.cached = cached - old.cached
        value.cacheWrite = cacheWrite - old.cacheWrite
        value.output = output - old.output; value.reasoning = reasoning - old.reasoning
        return value
    }
}

public struct ChatContribution: Identifiable, Sendable {
    public let thread: String
    public let title: String
    public let model: String
    public let tokens: TokenMetrics
    public let turns: Int
    public let tools: Int
    public var id: String { thread + "|" + model }
}

public struct UsageDrop: Identifiable, Sendable {
    public let id: String
    public let bucket: String
    public let fromUsed: Double
    public let toUsed: Double
    public let intervalStart: Date
    public let previousObservation: Date
    public let observedAt: Date
    public let chats: [ChatContribution]
    public var capturedAt: Date? = nil
    public var observationSource = "Account read"
    public var points: Double { toUsed - fromUsed }
    public var tokens: Int64 { chats.reduce(0) { $0 + $1.tokens.total } }
}

public struct HistorySnapshot: Sendable {
    public let drops: [UsageDrop]
    public let note: String
    public var analysis: AnalysisSnapshot = .init()
    public init(drops: [UsageDrop], note: String, analysis: AnalysisSnapshot = .init()) {
        self.drops = drops; self.note = note; self.analysis = analysis
    }
}

/// One app-owned actor. Its database is private; the Codex chat index and rollouts are read-only.
public actor HistoryRecorder {
    private let storeURL: URL
    private let codexHome: URL
    private var database: HistoryDatabase?
    private var currentAccount: String?
    private var legacyCache: [String: [UsageDrop]] = [:]
    private var collectionIssue: String? = "Local activity collection has not completed its initial scan."
    private let startedAt: Date
    private let epoch = UUID().uuidString
    private let readOnly: Bool
    private var note = "Local chats only. Activity in an interval is not exact billing attribution."
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private let fractional = ISO8601DateFormatter()
    private let whole = ISO8601DateFormatter()
    private lazy var enricher = AttributionEnricher(codexHome: codexHome)
    private var lastEnrichment = Date.distantPast

    private struct Cursor: Codable {
        var offset: UInt64
        var counter: TokenMetrics?
        var model: String
        var skippingLongLine: Bool = false
        var fileGeneration = UUID().uuidString
        var effort: String = "Unknown"
        var speed: String = "Unknown"
        var project: String = "Unknown"
        var parentThread: String?
        var agentPath: String?
        var turnID: String?
        var pendingIssues: [String] = []
        var sourceIdentity: String?
        var sourceAnchor: String?
    }

    public init(storeURL: URL, codexHome: URL, startedAt: Date = Date(), readOnly: Bool = false) {
        self.storeURL = storeURL; self.codexHome = codexHome; self.startedAt = startedAt
        self.readOnly = readOnly
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    public static func accountKey(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func open() throws -> HistoryDatabase {
        if let database { return database }
        if readOnly {
            let db = try HistoryDatabase(url: storeURL, readOnly: true)
            database = db; return db
        }
        try FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let db = try HistoryDatabase(url: storeURL)
        try db.run("PRAGMA journal_mode=WAL")
        try db.run("CREATE TABLE IF NOT EXISTS observations (id TEXT PRIMARY KEY, account TEXT NOT NULL, bucket TEXT NOT NULL, title TEXT NOT NULL, at REAL NOT NULL, used REAL NOT NULL, reset REAL, captured REAL NOT NULL, epoch TEXT NOT NULL)")
        try db.run("CREATE INDEX IF NOT EXISTS observation_time ON observations(account, at)")
        try db.run("CREATE TABLE IF NOT EXISTS activity (id TEXT PRIMARY KEY, account TEXT NOT NULL, thread TEXT NOT NULL, title TEXT NOT NULL, model TEXT NOT NULL, at REAL NOT NULL, input INTEGER NOT NULL, cached INTEGER NOT NULL, output INTEGER NOT NULL, reasoning INTEGER NOT NULL, turns INTEGER NOT NULL, tools INTEGER NOT NULL, raw TEXT)")
        try db.run("CREATE INDEX IF NOT EXISTS activity_time ON activity(account, at)")
        try db.run("CREATE TABLE IF NOT EXISTS cursors (path TEXT PRIMARY KEY, data TEXT NOT NULL)")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: storeURL.path)
        let hadAnalysis = !(try db.query("SELECT name FROM sqlite_master WHERE type='table' AND name='analysis_activity_v1'")).isEmpty
        let hadOverlay = !(try db.query("SELECT name FROM sqlite_master WHERE type='table' AND name='analysis_attribution_v2'")).isEmpty
        if hadAnalysis, !hadOverlay, !(try db.query("SELECT 1 FROM analysis_activity_v1 LIMIT 1")).isEmpty {
            let backup = storeURL.deletingLastPathComponent().appendingPathComponent("Backups/metadata-v2-" + UUID().uuidString + ".sqlite")
            try db.backup(to: backup)
        }
        try AnalysisStore.create(in: db)
        database = db
        return db
    }

    public func record(_ response: UsageResponse, at date: Date, includeAnalysis: Bool = true) throws -> HistorySnapshot {
        try Task.checkCancellation()
        guard !readOnly else { throw HistoryDatabase.Failure.database("Recording is disabled") }
        let db = try open()
        guard let account = response.accountId, !account.isEmpty else {
            note = "Account identity unavailable. Recording is paused to avoid mixing accounts."
            currentAccount = nil
            return HistorySnapshot(drops: [], note: note)
        }
        currentAccount = Self.accountKey(account)
        for row in response.rows {
            try AnalysisStore.meter(db, account: currentAccount!, epoch: epoch, row: row,
                                    plan: response.plan(for: row.id), date: date)
        }
        return try snapshot(includeAnalysis: includeAnalysis)
    }

    public func loadSaved(accountId: String) throws -> HistorySnapshot {
        guard FileManager.default.fileExists(atPath: storeURL.path) else {
            return HistorySnapshot(drops: [], note: "No saved history yet.")
        }
        currentAccount = Self.accountKey(accountId)
        return try snapshot()
    }

    public func scan(at now: Date = Date(), includeAnalysis: Bool = true) throws -> HistorySnapshot? {
        do { return try scanSources(at: now, includeAnalysis: includeAnalysis) }
        catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            guard let account = currentAccount else { throw error }
            let db = try open()
            note = "Local activity collection is incomplete: " + error.localizedDescription
            try coverage(db, account: account, at: now, message: "A local source read failed; activity coverage is incomplete.")
            return try snapshot(includeAnalysis: includeAnalysis)
        }
    }

    private func scanSources(at now: Date, includeAnalysis: Bool) throws -> HistorySnapshot? {
        try Task.checkCancellation()
        guard let account = currentAccount else { return nil }
        let db = try open()
        let previousIssue = collectionIssue
        collectionIssue = nil
        let indexes = try FileManager.default.contentsOfDirectory(at: codexHome, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard let indexURL = indexes.last else {
            note = "Chat index unavailable. Allowance history continues; chat coverage is incomplete."
            try coverage(db, account: account, at: now, message: note)
            return try snapshot(includeAnalysis: includeAnalysis)
        }
        let index = try HistoryDatabase(url: indexURL, readOnly: true)
        let cutoff = [String(Int64(now.addingTimeInterval(-86400).timeIntervalSince1970))]
        let rows: [[String: String]]
        do { rows = try index.query("SELECT id,title,model,rollout_path,creator_account_id,created_at,created_at_ms FROM threads WHERE updated_at >= ?", cutoff) }
        catch { rows = try index.query("SELECT id,title,model,rollout_path,creator_account_id,created_at FROM threads WHERE updated_at >= ?", cutoff) }
        let matching = rows.filter { $0["creator_account_id"].map(Self.accountKey) == account }
        if matching.isEmpty {
            note = "No matching local chat records are available. Activity coverage is incomplete."
            try coverage(db, account: account, at: now, message: note)
        } else { note = "Local chats only. Activity in an interval is not exact billing attribution." }
        var changed = matching.isEmpty
        for row in matching {
            try Task.checkCancellation()
            guard let creator = row["creator_account_id"], Self.accountKey(creator) == account,
                  let path = row["rollout_path"], let thread = row["id"] else { continue }
            let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
            let allowed = ["sessions", "archived_sessions"].contains {
                url.path.hasPrefix(codexHome.appendingPathComponent($0).resolvingSymlinksInPath().path + "/")
            }
            guard allowed else { continue }
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = (attrs?[.size] as? NSNumber)?.uint64Value else {
                try coverage(db, account: account, thread: thread, at: now, message: "Local rollout is unavailable; activity coverage is incomplete.")
                changed = true; continue
            }
            // A recording epoch owns its cursor cache, including during rapid toggles.
            // Starting again never imports work from the disabled interval.
            let saved = try db.query("SELECT data FROM cursors WHERE path=?", [epoch + path]).first?["data"]
            var cursor = saved.flatMap { $0.data(using: .utf8) }.flatMap { try? decoder.decode(Cursor.self, from: $0) }
            guard let handle = try? FileHandle(forReadingFrom: url) else {
                try coverage(db, account: account, thread: thread, at: now, message: "Local rollout could not be read; activity coverage is incomplete.")
                changed = true; continue
            }
            defer { try? handle.close() }
            let identity = [attrs?[.systemNumber], attrs?[.systemFileNumber], attrs?[.creationDate]].map { String(describing: $0) }.joined(separator: ":")
            var replaced = false
            if let savedCursor = cursor, savedCursor.offset <= size {
                let identityChanged = savedCursor.sourceIdentity.map { $0 != identity } ?? false
                let anchorChanged = try savedCursor.sourceAnchor.map { $0 != (try sourceAnchor(handle, offset: savedCursor.offset)) } ?? false
                replaced = identityChanged || anchorChanged
            }
            let created = row["created_at_ms"].flatMap(Double.init).map { $0 / 1000 }
                ?? Double(row["created_at"] ?? "0") ?? 0
            let sourceStart = max(startedAt.timeIntervalSince1970, created)
            if cursor == nil || cursor!.offset > size || replaced {
                let restarted = cursor != nil
                if restarted { note = "A source file restarted. Recording resumed with a new baseline; coverage is partial." }
                let isNew = !restarted && created >= startedAt.timeIntervalSince1970
                var baseline: TokenMetrics?
                var context: [String: Any]?
                var metadata: [String: Any]?
                if !isNew, size > 0 {
                    try handle.seek(toOffset: size > 262144 ? size - 262144 : 0)
                    let tail = try handle.read(upToCount: Int(min(size, 262144))) ?? Data()
                    for line in tail.split(separator: 10).reversed() {
                        guard let event = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                              let p = event["payload"] as? [String: Any] else { continue }
                        if baseline == nil, p["type"] as? String == "token_count",
                           let info = p["info"] as? [String: Any], let total = info["total_token_usage"] as? [String: Any] { baseline = TokenMetrics(total) }
                        if context == nil, event["type"] as? String == "turn_context" { context = p }
                        if metadata == nil, event["type"] as? String == "session_meta" { metadata = p }
                    }
                }
                cursor = Cursor(offset: isNew ? 0 : size, counter: baseline, model: "Unknown")
                if let context { updateContext(&cursor!, payload: context) }
                // Session metadata is normally at the head, outside the bounded tail.
                if metadata == nil, size > 0 {
                    try handle.seek(toOffset: 0)
                    let head = try handle.read(upToCount: Int(min(size, 65536))) ?? Data()
                    if let line = head.split(separator: 10).first,
                       let e = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                       e["type"] as? String == "session_meta" { metadata = e["payload"] as? [String: Any] }
                }
                if let metadata { updateMetadata(&cursor!, payload: metadata) }
                cursor!.sourceIdentity = identity
                cursor!.sourceAnchor = try sourceAnchor(handle, offset: cursor!.offset)
                if !isNew {
                    try AnalysisStore.activity(db, ActivityObservation(id: epoch + path + ":baseline", account: account, epoch: epoch,
                        threadID: thread, title: String((row["title"] ?? "Untitled chat").prefix(180)),
                        model: cursor!.model, effort: cursor!.effort, sourceAt: now, capturedAt: now, tokens: .init(),
                        issues: [restarted ? "Source file restarted; a new counter baseline was established." : "Recording began with an existing chat; earlier activity was not imported."]))
                    changed = true
                }
                try save(db, cursor: cursor!, path: path)
            }
            guard var c = cursor, c.offset < size else { continue }
            try handle.seek(toOffset: c.offset)
            let bytes = try handle.read(upToCount: 4 * 1024 * 1024) ?? Data()
            let lines = bytes.split(separator: 10, omittingEmptySubsequences: false).dropLast()
            if lines.isEmpty, bytes.count == 4 * 1024 * 1024 {
                c.offset += UInt64(bytes.count); c.skippingLongLine = true
                note = "An oversized source record was omitted; activity coverage is partial."
                try coverage(db, account: account, thread: thread, at: now, message: note)
                changed = true
                c.sourceIdentity = identity; c.sourceAnchor = try sourceAnchor(handle, offset: c.offset)
                try save(db, cursor: c, path: path); continue
            }
            try db.run("BEGIN IMMEDIATE")
            do {
                for line in lines {
                    try Task.checkCancellation()
                    let eventID = path + ":" + c.fileGeneration + ":" + String(c.offset)
                    c.offset += UInt64(line.count + 1)
                    if c.skippingLongLine { c.skippingLongLine = false; continue }
                    guard let e = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                          let p = e["payload"] as? [String: Any], let stamp = e["timestamp"] as? String,
                          let date = fractional.date(from: stamp) ?? whole.date(from: stamp) else {
                        if !line.isEmpty { try coverage(db, account: account, thread: thread, at: now, message: "A source record was unreadable; activity coverage is incomplete."); changed = true }
                        continue
                    }
                    let type = p["type"] as? String
                    if e["type"] as? String == "session_meta" { updateMetadata(&c, payload: p) }
                    if e["type"] as? String == "turn_context", date.timeIntervalSince1970 >= created { updateContext(&c, payload: p) }
                    if date.timeIntervalSince1970 < sourceStart {
                        // Forked rollouts can contain their parent's old records. Use
                        // those counters only as a baseline, never as fresh activity.
                        if type == "token_count", let info = p["info"] as? [String: Any],
                           let total = info["total_token_usage"] as? [String: Any] { c.counter = TokenMetrics(total) }
                        continue
                    }
                    var tokens = TokenMetrics(); var turns = 0; var tools = 0
                    var isTokenRecord = false
                    var issues: [String] = []
                    var duration: Double?
                    if e["type"] as? String == "event_msg", type == "token_count" {
                        isTokenRecord = true
                        if let info = p["info"] as? [String: Any], let total = info["total_token_usage"] as? [String: Any] {
                            let current = TokenMetrics(total)
                            if let previous = c.counter {
                                if let delta = current.delta(from: previous) { tokens = delta }
                                else {
                                    note = "A token counter restarted. Its first value was treated as a baseline."
                                    issues.append("Token counter restarted; first value omitted from totals.")
                                }
                            } else { issues.append("First token counter established a baseline; preceding activity is unknown.") }
                            if tokens.total > 0 { issues += c.pendingIssues; c.pendingIssues = [] }
                            c.counter = current
                        }
                    }
                    if e["type"] as? String == "event_msg", type == "task_complete" {
                        turns = 1
                        duration = (p["duration_ms"] as? NSNumber).map { $0.doubleValue / 1000 }
                    }
                    if e["type"] as? String == "response_item", ["function_call", "custom_tool_call"].contains(type ?? "") { tools = 1 }
                    if (isTokenRecord && (!issues.isEmpty || tokens.total > 0 || tokens.cacheWrite > 0)) || turns > 0 || tools > 0 {
                        // Only selected numeric/context fields enter the analysis store.
                        try AnalysisStore.activity(db, ActivityObservation(id: epoch + eventID, account: account, epoch: epoch,
                            threadID: thread, title: String((row["title"] ?? "Untitled chat").prefix(180)), project: c.project,
                            parentThreadID: c.parentThread, agentPath: c.agentPath, turnID: p["turn_id"] as? String ?? c.turnID,
                            model: c.model, effort: c.effort, speed: c.speed, sourceAt: date, capturedAt: now,
                            tokens: tokens, completedTurns: turns, toolCalls: tools, turnDurationSeconds: duration, issues: issues))
                        changed = true
                    }
                }
                if c.offset < size { collectionIssue = "Local source scan is catching up; calibration waits for complete records." }
                c.sourceIdentity = identity; c.sourceAnchor = try sourceAnchor(handle, offset: c.offset)
                try save(db, cursor: c, path: path)
                try db.run("COMMIT")
            } catch { try? db.run("ROLLBACK", cancellable: false); throw error }
        }
        if now.timeIntervalSince(lastEnrichment) >= 5 {
            do {
                let owners = try accountThreads(account: account)
                try collectEvidence(db, account: account, threads: owners)
                let enriched = try enricher.enrich(db, account: account, threads: owners, limit: 200, at: now)
                changed = changed || enriched > 0
                lastEnrichment = now
            } catch is CancellationError { throw CancellationError() }
            catch { note = "Activity is recorded; metadata recovery will retry: " + error.localizedDescription }
        }
        return changed || previousIssue != collectionIssue ? try snapshot(includeAnalysis: includeAnalysis) : nil
    }

    private func accountThreads(account: String) throws -> [[String:String]] {
        let indexes = try FileManager.default.contentsOfDirectory(at: codexHome, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("state_") && $0.pathExtension == "sqlite" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard let path = indexes.last else { return [] }
        let db = try HistoryDatabase(url: path, readOnly: true)
        let rows: [[String:String]]
        do { rows = try db.query("SELECT id,creator_account_id,created_at,created_at_ms,rollout_path FROM threads") }
        catch { rows = try db.query("SELECT id,creator_account_id,created_at,rollout_path FROM threads") }
        return rows.filter { $0["creator_account_id"].map(Self.accountKey) == account }
    }

    private func collectEvidence(_ db: HistoryDatabase, account: String, threads: [[String:String]], source: URL? = nil) throws {
        let earliest = try db.query("SELECT MIN(at) AS at FROM analysis_activity_v1 WHERE account=?",[account]).first?["at"].flatMap(Double.init) ?? startedAt.timeIntervalSince1970
        let through: Date?
        if let source {
            through = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: [.contentModificationDateKey])
                .filter { $0.lastPathComponent.hasPrefix("logs_") && $0.pathExtension == "sqlite" }
                .compactMap { try $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max()
        } else { through = nil }
        let recorded = Set(try db.query("SELECT DISTINCT thread FROM analysis_activity_v1 WHERE account=?", [account]).compactMap { $0["thread"] })
        try RequestEvidence.collect(into: db, codexHome: source ?? codexHome, account: account,
                                    threads: Set(threads.compactMap { $0["id"] }).intersection(recorded), since: Date(timeIntervalSince1970: earliest - 86400), through: through)
    }

    /// Explicit maintenance operation; writes only new evidence/attribution tables.
    /// No account request, auth refresh, or token/meter rewrite is performed.
    public func recoverSaved(requestCapture: URL? = nil, requestLogHome: URL? = nil) throws -> [String:Int] {
        guard !readOnly else { throw HistoryDatabase.Failure.database("Metadata recovery requires a writable history store") }
        let db = try open()
        let accounts = try db.query("SELECT DISTINCT account FROM analysis_activity_v1").compactMap { $0["account"] }
        var processed = 0
        for account in accounts {
            let threads = try accountThreads(account: account)
            if let requestCapture { try RequestEvidence.importCapture(requestCapture, into: db, account: account, threads: Set(threads.compactMap { $0["id"] })) }
            if let requestLogHome { try collectEvidence(db, account: account, threads: threads, source: requestLogHome) }
            try collectEvidence(db, account: account, threads: threads)
            let at = Date()
            // Each processed row's retry time advances beyond this fixed instant.
            // Missing overlays sort first, so new records cannot starve older recovery.
            while true {
                let count = try enricher.enrich(db, account: account, threads: threads, limit: 200, at: at)
                processed += count
                if count == 0 { break }
            }
        }
        let r = try db.query("""
            SELECT COUNT(*) AS total,
                   SUM(CASE WHEN v.model != 'Unknown' AND v.effort != 'Unknown' THEN 1 ELSE 0 END) AS known,
                   SUM(CASE WHEN v.speed='unset' THEN 1 ELSE 0 END) AS unset,
                   SUM(CASE WHEN v.speed='priority' THEN 1 ELSE 0 END) AS fast,
                   SUM(CASE WHEN v.speed='default' THEN 1 ELSE 0 END) AS standard
            FROM analysis_activity_v1 a LEFT JOIN analysis_attribution_v2 v ON a.id=v.activity_id WHERE a.input+a.output>0
            """).first ?? [:]
        return ["processed":processed,"tokenRecords":Int(r["total"] ?? "0") ?? 0,"modelAndEffortRecovered":Int(r["known"] ?? "0") ?? 0,
                "unsetTier":Int(r["unset"] ?? "0") ?? 0,"fastTier":Int(r["fast"] ?? "0") ?? 0,"standardTier":Int(r["standard"] ?? "0") ?? 0]
    }

    private func coverage(_ db: HistoryDatabase, account: String, thread: String = "coverage", at date: Date, message: String) throws {
        let id = epoch + ":coverage:" + thread + ":" + String(Int(date.timeIntervalSince1970 / 15)) + message
        try AnalysisStore.activity(db, .init(id: id, account: account, epoch: epoch, threadID: thread,
            title: "Collection coverage", sourceAt: date, capturedAt: date, tokens: .init(), issues: [message]))
    }

    private func updateMetadata(_ cursor: inout Cursor, payload: [String: Any]) {
        let source = payload["source"] as? [String: Any]
        let agent = source?["subagent"] as? [String: Any]
        let spawn = agent?["thread_spawn"] as? [String: Any]
        cursor.parentThread = payload["parent_thread_id"] as? String ?? spawn?["parent_thread_id"] as? String ?? cursor.parentThread
        cursor.agentPath = payload["agent_path"] as? String ?? spawn?["agent_path"] as? String ?? cursor.agentPath
        if let cwd = payload["cwd"] as? String { cursor.project = cwd }
    }

    private func updateContext(_ cursor: inout Cursor, payload: [String: Any]) {
        let model = payload["model"] as? String ?? "Unknown"
        let effort = payload["effort"] as? String ?? payload["reasoning_effort"] as? String ?? "Unknown"
        let speed = payload["speed"] as? String ?? "Unknown"
        if cursor.counter != nil, (model != cursor.model || effort != cursor.effort || speed != cursor.speed) {
            cursor.pendingIssues = ["Counter span crosses a configuration change; attribution may include earlier work."]
        }
        cursor.model = model; cursor.effort = effort; cursor.speed = speed
        cursor.turnID = payload["turn_id"] as? String
        if let cwd = payload["cwd"] as? String { cursor.project = cwd }
    }

    private func sourceAnchor(_ handle: FileHandle, offset: UInt64) throws -> String {
        let count = Int(min(offset, 256))
        try handle.seek(toOffset: offset - UInt64(count))
        let bytes = try handle.read(upToCount: count) ?? Data()
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    private func save(_ db: HistoryDatabase, cursor: Cursor, path: String) throws {
        let text = String(decoding: try encoder.encode(cursor), as: UTF8.self)
        try db.run("INSERT OR REPLACE INTO cursors VALUES (?,?)", [epoch + path, text])
    }

    public func snapshot(includeAnalysis: Bool = true) throws -> HistorySnapshot {
        guard includeAnalysis else { return HistorySnapshot(drops: [], note: note) }
        guard let account = currentAccount else { return HistorySnapshot(drops: [], note: note) }
        let db = try open()
        let analysis = try AnalysisStore.snapshot(db, account: account, paused: readOnly, coverageIssues: readOnly ? [] : [collectionIssue].compactMap { $0 })
        if let saved = legacyCache[account] { return HistorySnapshot(drops: saved, note: note, analysis: analysis) }
        let records = try db.query("SELECT * FROM (SELECT * FROM observations WHERE account=? ORDER BY at DESC LIMIT 50000) ORDER BY at,id", [account])
        struct State { var used: Double; var start: Double; var last: Double; var reset: Double? }
        var states: [String: State] = [:]
        var drops: [(row: [String: String], state: State)] = []
        for row in records {
            try Task.checkCancellation()
            guard let name = row["bucket"], let at = Double(row["at"] ?? ""), let used = Double(row["used"] ?? "") else { continue }
            let bucket = name + (row["epoch"] ?? "")
            let reset = row["reset"].flatMap(Double.init)
            if var s = states[bucket] {
                if used < s.used || ((reset == nil) != (s.reset == nil)) || (reset != nil && s.reset != nil && abs(reset! - s.reset!) > 120) {
                    s = State(used: used, start: at, last: at, reset: reset)
                } else if used - s.used >= 0.999999 {
                    drops.append((row, s))
                    s.used = used; s.start = at
                }
                s.last = at; s.reset = reset; states[bucket] = s
            } else { states[bucket] = State(used: used, start: at, last: at, reset: reset) }
        }
        var result: [UsageDrop] = []
        for (row, s) in drops.suffix(200).reversed() {
            try Task.checkCancellation()
            let at = Double(row["at"]!)!
            let contributions = try db.query("SELECT thread,title,model,SUM(input) AS i,SUM(cached) AS c,SUM(output) AS o,SUM(reasoning) AS r,SUM(turns) AS t,SUM(tools) AS u FROM activity WHERE account=? AND at>? AND at<=? GROUP BY thread,model HAVING SUM(input)+SUM(output)+SUM(turns)+SUM(tools)>0 ORDER BY SUM(input)+SUM(output) DESC", [account, String(s.start), String(at)])
            let chats = contributions.map { value -> ChatContribution in
                var tokens = TokenMetrics()
                tokens.input = Int64(value["i"] ?? "0") ?? 0; tokens.cached = Int64(value["c"] ?? "0") ?? 0
                tokens.output = Int64(value["o"] ?? "0") ?? 0; tokens.reasoning = Int64(value["r"] ?? "0") ?? 0
                return ChatContribution(thread: value["thread"] ?? "", title: value["title"] ?? "Untitled chat", model: value["model"] ?? "Unknown model", tokens: tokens, turns: Int(value["t"] ?? "0") ?? 0, tools: Int(value["u"] ?? "0") ?? 0)
            }
            result.append(UsageDrop(id: row["id"]!, bucket: row["title"]!, fromUsed: s.used,
                                    toUsed: Double(row["used"]!)!, intervalStart: Date(timeIntervalSince1970: s.start),
                                    previousObservation: Date(timeIntervalSince1970: s.last), observedAt: Date(timeIntervalSince1970: at), chats: chats,
                                    capturedAt: row["captured"].flatMap(Double.init).map { Date(timeIntervalSince1970: $0) },
                                    observationSource: row["id"]?.hasPrefix("/") == true ? "Local Codex record" : "Account read"))
        }
        legacyCache[account] = result
        return HistorySnapshot(drops: result, note: note, analysis: analysis)
    }
}
