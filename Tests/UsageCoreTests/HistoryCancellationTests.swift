import XCTest
@testable import UsageCore

final class HistoryCancellationTests: XCTestCase {
    func testCancelledQueuedSampleDoesNotCreateOrWriteHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("history-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = root.appendingPathComponent("history.sqlite")
        let recorder = HistoryRecorder(storeURL: store, codexHome: root)
        let response = try JSONDecoder().decode(UsageResponse.self, from: Data(#"{"accountId":"fixture","rateLimits":{"primary":{"usedPercent":10}}}"#.utf8))
        let gate = DispatchSemaphore(value: 0)
        let sample = Task.detached { gate.wait(); return try await recorder.record(response, at: Date()) }
        sample.cancel(); gate.signal()
        do { _ = try await sample.value; XCTFail("Cancelled sample was written") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.path))
    }

    func testLongSQLiteQueryCancelsAndRollbackStillWorks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("history-sql-cancel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let began = DispatchSemaphore(value: 0)
        let query = Task.detached { () throws -> Bool in
            let db = try HistoryDatabase(url: root.appendingPathComponent("history.sqlite"))
            try db.run("CREATE TABLE fixture (value INTEGER)")
            try db.run("BEGIN IMMEDIATE")
            try db.run("INSERT INTO fixture VALUES (1)")
            began.signal()
            do {
                _ = try db.query("WITH RECURSIVE counter(n) AS (VALUES(1) UNION ALL SELECT n+1 FROM counter WHERE n<100000000) SELECT SUM(n) FROM counter")
                return false
            } catch is CancellationError {
                try db.run("ROLLBACK", cancellable: false)
                return try db.query("SELECT COUNT(*) AS count FROM fixture", cancellable: false).first?["count"] == "0"
            }
        }
        XCTAssertEqual(began.wait(timeout: .now() + 2), .success)
        try await Task.sleep(nanoseconds: 20_000_000)
        let start = Date(); query.cancel()
        let rolledBack = try await query.value
        XCTAssertTrue(rolledBack)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }
}
