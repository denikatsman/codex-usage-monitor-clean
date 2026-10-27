import XCTest
@testable import UsageCore

final class HistoryBackupTests: XCTestCase {
    func testWALBackupIsConsistentPortablePrivateAndDoesNotChangeSourceMode() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("usage-history-backup-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try HistoryDatabase(url: root.appendingPathComponent("source.sqlite"))
        try source.run("PRAGMA journal_mode=WAL")
        try source.run("CREATE TABLE evidence(id INTEGER PRIMARY KEY,value TEXT)")
        try source.run("INSERT INTO evidence VALUES(1,'committed evidence')")
        // Another connection's pending write must not appear in the snapshot.
        let writer = try HistoryDatabase(url: root.appendingPathComponent("source.sqlite"))
        try writer.run("BEGIN IMMEDIATE")
        defer { try? writer.run("ROLLBACK") }
        try writer.run("INSERT INTO evidence VALUES(2,'uncommitted evidence')")
        let target = root.appendingPathComponent("Backups/snapshot.sqlite")
        try source.backup(to: target)
        let saved = try HistoryDatabase(url: target, readOnly: true)
        XCTAssertEqual(try saved.query("SELECT * FROM evidence"), [["id": "1", "value": "committed evidence"]])
        XCTAssertEqual(try saved.query("PRAGMA integrity_check").first?["integrity_check"], "ok")
        XCTAssertEqual(try saved.query("PRAGMA journal_mode").first?["journal_mode"], "delete")
        XCTAssertEqual(try source.query("PRAGMA journal_mode").first?["journal_mode"], "wal")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path + "-wal"))
        // SQLite may retain an unused -shm file after leaving WAL mode on macOS.
        // The independent main-file copy below proves it is not a dependency.
        let permissions = try FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber
        let parentPermissions = try FileManager.default.attributesOfItem(atPath: target.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
        XCTAssertEqual(parentPermissions?.intValue, 0o700)
        let portable = root.appendingPathComponent("portable.sqlite")
        try FileManager.default.copyItem(at: target, to: portable)
        let copied = try HistoryDatabase(url: portable, readOnly: true)
        XCTAssertEqual(try copied.query("SELECT * FROM evidence"), try saved.query("SELECT * FROM evidence"))
    }

    func testExistingBackupDestinationIsNeverOverwrittenOrRemoved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("usage-history-backup-existing-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try HistoryDatabase(url: root.appendingPathComponent("source.sqlite"))
        try source.run("CREATE TABLE evidence(value TEXT)")
        try source.run("INSERT INTO evidence VALUES('new source data')")
        let target = root.appendingPathComponent("existing.sqlite")
        let sentinel = Data("existing backup must survive".utf8)
        try sentinel.write(to: target)
        XCTAssertThrowsError(try source.backup(to: target))
        XCTAssertEqual(try Data(contentsOf: target), sentinel)
    }
}
