import Foundation
import SQLite3

/// Confined to HistoryRecorder's actor. Source indexes always open read-only.
final class HistoryDatabase {
    private var db: OpaquePointer?
    private let location: String
    enum Failure: LocalizedError {
        case database(String)
        var errorDescription: String? { if case .database(let message) = self { return "Usage history: \(message)" }; return nil }
    }
    init(url: URL, readOnly: Bool = false) throws {
        location = url.path
        let flags = readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE
        guard sqlite3_open_v2(url.path, &db, flags | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            let error = failure(); sqlite3_close(db); db = nil; throw error
        }
        sqlite3_busy_timeout(db, 1500)
    }
    deinit { sqlite3_close(db) }
    func backup(to url: URL) throws {
        try Task.checkCancellation()
        guard !FileManager.default.fileExists(atPath: url.path) else { throw Failure.database("Backup destination already exists") }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        var successful = false
        defer { if !successful { try? FileManager.default.removeItem(at: url) } }
        let target = try HistoryDatabase(url: url)
        guard let backup = sqlite3_backup_init(target.db, "main", db, "main") else { throw target.failure() }
        var finished = false
        defer { if !finished { sqlite3_backup_finish(backup) } }
        var retries = 0
        while true {
            try Task.checkCancellation()
            let code = sqlite3_backup_step(backup, 128)
            if code == SQLITE_DONE {
                let result = sqlite3_backup_finish(backup); finished = true
                guard result == SQLITE_OK else { throw target.failure() }
                // A portable snapshot must not depend on source WAL sidecars.
                try target.run("PRAGMA journal_mode=DELETE")
                successful = true
                return
            }
            if code == SQLITE_OK { continue }
            if (code == SQLITE_BUSY || code == SQLITE_LOCKED), retries < 100 { retries += 1; Thread.sleep(forTimeInterval: 0.01); continue }
            throw target.failure()
        }
    }
    private func failure() -> Failure { .database(location + ": " + (db.map { String(cString: sqlite3_errmsg($0)) } ?? "Could not open local database")) }
    func run(_ sql: String, _ values: [String?] = [], cancellable: Bool = true) throws {
        _ = try query(sql, values, cancellable: cancellable)
    }
    func query(_ sql: String, _ values: [String?] = [], cancellable: Bool = true) throws -> [[String: String]] {
        if cancellable { try Task.checkCancellation() }
        if cancellable { sqlite3_progress_handler(db, 1000, { _ in Task.isCancelled ? 1 : 0 }, nil) }
        defer { sqlite3_progress_handler(db, 0, nil, nil) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { throw failure() }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            if let value { sqlite3_bind_text(statement, Int32(index + 1), value, -1, transient) }
            else { sqlite3_bind_null(statement, Int32(index + 1)) }
        }
        var rows: [[String: String]] = []
        while true {
            if cancellable { try Task.checkCancellation() }
            let code = sqlite3_step(statement)
            if code == SQLITE_INTERRUPT, Task.isCancelled { throw CancellationError() }
            if code == SQLITE_DONE { return rows }
            guard code == SQLITE_ROW else { throw failure() }
            var row: [String: String] = [:]
            for i in 0..<sqlite3_column_count(statement) {
                if let text = sqlite3_column_text(statement, i) {
                    row[String(cString: sqlite3_column_name(statement, i))] = String(cString: text)
                }
            }
            rows.append(row)
        }
    }
}
