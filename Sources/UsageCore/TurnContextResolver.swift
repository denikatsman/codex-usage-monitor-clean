import Foundation
import CryptoKit

/// Direct chosen configuration from this rollout's own turn records, not a served-model claim.
public struct ResolvedTurnContext: Sendable {
    public let model: String?
    public let effort: String?
    public let turnID: String?
    public let contextAt: Date?
    public let contextOffset: UInt64?
    public let references: [String]
    public let issues: [String]
}

/// Confine to the recorder actor. Native indexes and rollouts are opened read-only.
public final class TurnContextResolver {
    private let codexHome: URL
    private let chunkSize = 256 * 1024
    // Exposed internally for deterministic I/O-bound tests, never stored as user telemetry.
    private(set) var sourceBytesRead: UInt64 = 0
    private struct Context {
        let offset: UInt64, length: Int
        let fingerprint: Data
        let at: Date
        let turn: String?, model: String?, effort: String?
        let modelPresent: Bool, effortPresent: Bool, isTurnStart: Bool
    }
    private struct SourceInfo: Equatable {
        let identity: String
        let size: UInt64
        let modified: Date?
    }
    private struct SourceState {
        var info: SourceInfo
        var lower: UInt64
        var upper: UInt64
        var anchor: Data
        var contexts: [Context]
    }
    private var sources: [(key: String, state: SourceState)] = []
    private let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private let whole = ISO8601DateFormatter()
    public init(codexHome: URL) { self.codexHome = codexHome }

    public func resolve(path: String, threadID: String, eventOffset: UInt64, eventAt: Date,
                        explicitTurnID: String?, createdAt: Date?) throws -> ResolvedTurnContext {
        try Task.checkCancellation()
        let url = URL(fileURLWithPath: path)
        let before = try sourceInfo(url)
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        guard eventOffset <= before.size else { return unavailable("Activity offset is beyond the current rollout; source generation changed.") }
        let header = try firstRecord(file)
        guard let payload = header?["payload"] as? [String: Any], header?["type"] as? String == "session_meta",
              payload["id"] as? String == threadID else {
            return unavailable("Rollout session identity does not match this activity's thread.")
        }
        // The thread index's creation time can change on resume and point to a newer
        // rollout. This validated source's own birth establishes its history boundary.
        let payloadBirth = (payload["timestamp"] as? String).flatMap { fractional.date(from: $0) ?? whole.date(from: $0) }
        let headerBirth = header.flatMap { date($0) }
        let effectiveCreatedAt = payloadBirth ?? headerBirth ?? createdAt
        let creationReference: String? = payloadBirth != nil ? "\(path):0:session_meta.payload.timestamp"
            : (headerBirth != nil ? "\(path):0:session_meta.timestamp" : (createdAt != nil ? "thread-index:created_at" : nil))
        let key = [path, threadID, before.identity].joined(separator: "\u{0}")
        var state: SourceState?
        if let index = sources.firstIndex(where: { $0.key == key }) {
            let old = sources.remove(at: index).state
            var reusable = old.info == before
            if !reusable, before.size > old.info.size { reusable = try stable(old, file: file) }
            if reusable { state = old }
        }
        // The event boundary and recovered context records are checked again if a writer appends.
        let eventAnchor = try anchor(file, at: eventOffset)
        var contexts = state?.contexts ?? []
        var lower = state?.lower ?? eventOffset
        var upper = state?.upper ?? eventOffset
        var hint: Hint?
        if state == nil {
            hint = try nativeHint(file: file, threadID: threadID, explicitTurnID: explicitTurnID,
                                  eventOffset: eventOffset, eventAt: eventAt)
            if let hint {
                contexts = try forwardContexts(file, from: hint.offset, to: eventOffset)
                lower = hint.offset
            }
        } else if eventOffset > upper {
            // Scan only the unexamined suffix. This includes subsequent same-turn overrides.
            contexts += try forwardContexts(file, from: upper, to: eventOffset)
            upper = eventOffset
        }
        var target = explicitTurnID
        var selected: Context?
        var model: String?, effort: String?
        var modelResolved = false, effortResolved = false
        var references: [String] = [creationReference].compactMap { $0 }
        var stop = false
        func consume(_ context: Context) {
            guard context.offset < eventOffset, context.at <= eventAt else { return }
            if let effectiveCreatedAt, context.at < effectiveCreatedAt { return }
            if target == nil { target = context.turn }
            if let target, context.turn != target {
                if selected != nil { stop = true }
                return
            }
            if context.isTurnStart {
                // A new own turn is a hard boundary even when its context was omitted.
                if selected == nil {
                    selected = context
                    references.append("\(path):\(context.offset):task_started")
                }
                stop = true
                return
            }
            let contributes = selected == nil || (!modelResolved && context.modelPresent) || (!effortResolved && context.effortPresent)
            if selected == nil { selected = context }
            if !modelResolved, context.modelPresent { model = context.model; modelResolved = true }
            if !effortResolved, context.effortPresent { effort = context.effort; effortResolved = true }
            if contributes { references.append("\(path):\(context.offset):turn_context") }
            if (modelResolved && effortResolved) || target == nil { stop = true }
        }
        if eventOffset >= lower {
            for context in contexts.sorted(by: { $0.offset > $1.offset }) {
                consume(context); if stop { break }
            }
        }
        var end = min(lower, eventOffset)
        var pending = Data()
        while end > 0 && !stop {
            try Task.checkCancellation()
            let begin = end > UInt64(chunkSize) ? end - UInt64(chunkSize) : 0
            try file.seek(toOffset: begin)
            var bytes = try read(file, count: Int(end - begin))
            guard bytes.count == Int(end - begin) else { return unavailable("Rollout changed while configuration was being read.") }
            bytes.append(pending)
            let lines = bytes.split(separator: 10, omittingEmptySubsequences: false)
            var offset = begin
            var positions: [(UInt64, Data.SubSequence)] = []
            for (index, line) in lines.enumerated() {
                if begin == 0 || index > 0 { positions.append((offset, line)) }
                offset += UInt64(line.count + 1)
            }
            for (offset, line) in positions.reversed() {
                try Task.checkCancellation()
                guard let context = parseContext(Data(line), offset: offset) else { continue }
                contexts.append(context)
                lower = min(lower, offset)
                consume(context)
                if stop { break }
            }
            pending = begin > 0 ? Data(lines.first ?? Data.SubSequence()) : Data()
            end = begin
            if begin == 0 && !stop { lower = 0 }
        }
        var issues: [String] = []
        if selected == nil { issues.append("No own-turn configuration record was available before this activity.") }
        if model == nil || effort == nil { issues.append("Chosen configuration metadata is incomplete.") }
        if let hint, let selected, hint.turn == selected.turn, hint.offset <= selected.offset {
            references.append("thread_history_1.sqlite:thread_turns:\(threadID):\(hint.turn)")
        }
        let after = try sourceInfo(url)
        if after != before {
            guard after.identity == before.identity, after.size > before.size,
                  try anchor(file, at: eventOffset) == eventAnchor,
                  try contexts.allSatisfy({ try contextStable($0, file: file) }) else {
                return unavailable("Rollout changed while configuration was being read; retry is required.")
            }
        }
        var seen = Set<UInt64>()
        contexts = contexts.sorted { $0.offset > $1.offset }.filter { seen.insert($0.offset).inserted }
        if contexts.count > 256 {
            contexts = Array(contexts.prefix(256))
            lower = max(lower, contexts.last!.offset)
        }
        upper = max(upper, eventOffset)
        let saved = SourceState(info: after, lower: lower, upper: upper, anchor: try anchor(file, at: upper), contexts: contexts)
        sources.append((key, saved))
        // At most 16 source ranges and 256 numeric/context-only records per range.
        if sources.count > 16 { sources.removeFirst(sources.count - 16) }
        return .init(model: model, effort: effort, turnID: selected?.turn ?? explicitTurnID,
                     contextAt: selected?.at, contextOffset: selected?.offset, references: references, issues: issues)
    }

    private func unavailable(_ issue: String) -> ResolvedTurnContext {
        .init(model: nil, effort: nil, turnID: nil, contextAt: nil, contextOffset: nil, references: [], issues: [issue])
    }
    private func sourceInfo(_ url: URL) throws -> SourceInfo {
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        let identity = [a[.systemNumber], a[.systemFileNumber], a[.creationDate]].map { value in
            if let date = value as? Date { return String(date.timeIntervalSince1970) }
            return value.map { String(describing: $0) } ?? ""
        }.joined(separator: ":")
        return SourceInfo(identity: identity, size: (a[.size] as? NSNumber)?.uint64Value ?? 0, modified: a[.modificationDate] as? Date)
    }
    private func read(_ file: FileHandle, count: Int) throws -> Data {
        try Task.checkCancellation()
        let data = try file.read(upToCount: count) ?? Data()
        sourceBytesRead += UInt64(data.count)
        return data
    }
    private func anchor(_ file: FileHandle, at offset: UInt64) throws -> Data {
        let start = offset > 128 ? offset - 128 : 0
        try file.seek(toOffset: start)
        return try read(file, count: Int(offset - start))
    }
    private func contextStable(_ context: Context, file: FileHandle) throws -> Bool {
        try file.seek(toOffset: context.offset)
        let bytes = try read(file, count: context.length)
        return bytes.count == context.length && Data(SHA256.hash(data: bytes)) == context.fingerprint
    }
    private func stable(_ state: SourceState, file: FileHandle) throws -> Bool {
        guard try anchor(file, at: state.upper) == state.anchor else { return false }
        return try state.contexts.allSatisfy { try contextStable($0, file: file) }
    }
    private func parseContext(_ data: Data, offset: UInt64) -> Context? {
        guard data.range(of: Data("\"turn_context\"".utf8)) != nil || data.range(of: Data("\"task_started\"".utf8)) != nil,
              let e = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let p = e["payload"] as? [String: Any], let at = date(e) else { return nil }
        let isTurnStart = e["type"] as? String == "event_msg" && p["type"] as? String == "task_started"
        guard isTurnStart || e["type"] as? String == "turn_context" else { return nil }
        let hasEffort = p.keys.contains("effort"), hasReasoningEffort = p.keys.contains("reasoning_effort")
        return Context(offset: offset, length: data.count, fingerprint: Data(SHA256.hash(data: data)), at: at,
                       turn: text(p["turn_id"]), model: isTurnStart ? nil : text(p["model"]),
                       effort: isTurnStart ? nil : (hasEffort ? text(p["effort"]) : text(p["reasoning_effort"])),
                       modelPresent: !isTurnStart && p.keys.contains("model"),
                       effortPresent: !isTurnStart && (hasEffort || hasReasoningEffort), isTurnStart: isTurnStart)
    }
    private func forwardContexts(_ file: FileHandle, from start: UInt64, to end: UInt64) throws -> [Context] {
        try file.seek(toOffset: start)
        var position = start, lineStart = start
        var pending = Data(), result: [Context] = []
        while position < end {
            let bytes = try read(file, count: Int(min(UInt64(chunkSize), end - position)))
            guard !bytes.isEmpty else { throw HistoryDatabase.Failure.database("Rollout changed during metadata scan") }
            position += UInt64(bytes.count)
            pending.append(bytes)
            while let newline = pending.firstIndex(of: 10) {
                let line = Data(pending[..<newline])
                if let context = parseContext(line, offset: lineStart) { result.append(context) }
                lineStart += UInt64(line.count + 1)
                pending = Data(pending[pending.index(after: newline)...])
            }
        }
        return result
    }
    private func date(_ object: [String: Any]) -> Date? {
        guard let text = object["timestamp"] as? String else { return nil }
        return fractional.date(from: text) ?? whole.date(from: text)
    }
    private func text(_ value: Any?) -> String? {
        guard let string = value as? String, !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              string.lowercased() != "unknown" else { return nil }
        return string
    }
    private func firstRecord(_ file: FileHandle) throws -> [String: Any]? {
        try file.seek(toOffset: 0)
        var data = Data()
        while true {
            try Task.checkCancellation()
            let bytes = try read(file, count: 4096)
            if let newline = bytes.firstIndex(of: 10) { data.append(bytes[..<newline]); break }
            data.append(bytes)
            if bytes.isEmpty { break }
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    private struct Hint { let offset: UInt64; let turn: String }
    private func nativeHint(file: FileHandle, threadID: String, explicitTurnID: String?,
                            eventOffset: UInt64, eventAt: Date) throws -> Hint? {
        try Task.checkCancellation()
        let url = codexHome.appendingPathComponent("thread_history_1.sqlite")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let db = try HistoryDatabase(url: url, readOnly: true)
            let rows: [[String: String]]
            if let explicitTurnID {
                rows = try db.query("SELECT turn_id,rollout_byte_offset FROM thread_turns WHERE thread_id=? AND turn_id=? LIMIT 1", [threadID, explicitTurnID])
            } else {
                rows = try db.query("SELECT turn_id,rollout_byte_offset FROM thread_turns WHERE thread_id=? AND started_at<=? ORDER BY started_at DESC LIMIT 1", [threadID, String(eventAt.timeIntervalSince1970)])
            }
            guard let row = rows.first, let turn = row["turn_id"], let offset = row["rollout_byte_offset"].flatMap(UInt64.init), offset < eventOffset else { return nil }
            try file.seek(toOffset: offset)
            // Validate an index candidate against the requested file, never its current index path.
            var data = Data()
            while true {
                try Task.checkCancellation()
                let bytes = try read(file, count: 4096)
                if let newline = bytes.firstIndex(of: 10) { data.append(bytes[..<newline]); break }
                data.append(bytes)
                if bytes.isEmpty { break }
            }
            guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = event["payload"] as? [String: Any], text(payload["turn_id"]) == turn,
                  let at = date(event), at <= eventAt,
                  (event["type"] as? String == "turn_context" || (event["type"] as? String == "event_msg" && payload["type"] as? String == "task_started")) else { return nil }
            return Hint(offset: offset, turn: turn)
        } catch is CancellationError { throw CancellationError() }
        catch { return nil } // Native index failures never prevent source fallback.
    }
}
