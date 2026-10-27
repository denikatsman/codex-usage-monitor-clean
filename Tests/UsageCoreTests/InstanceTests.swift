import XCTest
import Darwin
@testable import UsageCore

final class InstanceTests: XCTestCase {
    func testExplicitOpenTakesOwnershipAfterQuittingOwnerDrains() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = try start(root, "quitting", hold: "0.3")
        try waitForEndpoint(root)
        let next = try start(root, "retry-open", hold: "0.05")
        XCTAssertEqual(finish(owner), "owner\n")
        XCTAssertEqual(finish(next), "owner\n")
        XCTAssertEqual(next.0.terminationStatus, 0)
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("usage-monitor-test-" + UUID().uuidString.prefix(8))
    }

    private func probeURL() throws -> URL {
        var parent = Bundle(for: InstanceTests.self).bundleURL.deletingLastPathComponent()
        for _ in 0..<7 {
            let candidate = parent.appendingPathComponent("UsageInstanceProbe")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
            parent.deleteLastPathComponent()
        }
        throw NSError(domain: "Build UsageInstanceProbe before process-level instance tests", code: 1)
    }

    private func start(_ root: URL, _ action: String = "normal", hold: String = "1") throws -> (Process, Pipe) {
        let process = Process()
        let output = Pipe()
        process.executableURL = try probeURL()
        process.arguments = [root.path, action, hold]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        return (process, output)
    }

    private func finish(_ child: (Process, Pipe)) -> String {
        let data = child.1.fileHandleForReading.readDataToEndOfFile()
        child.0.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func waitForEndpoint(_ root: URL) throws {
        let end = Date().addingTimeInterval(2)
        while Date() < end {
            if FileManager.default.fileExists(atPath: root.appendingPathComponent("open.sock").path) { return }
            Thread.sleep(forTimeInterval: 0.01)
        }
        XCTFail("Owner did not publish its endpoint")
    }

    func testSimultaneousDirectLaunchesHaveOneOwnerAndOneHandoff() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try start(root)
        let b = try start(root)
        let combined = finish(a) + finish(b)
        XCTAssertEqual(combined.split(separator: "\n").filter { $0 == "owner" }.count, 1, combined)
        XCTAssertEqual(combined.split(separator: "\n").filter { $0 == "forwarded" }.count, 1, combined)
        XCTAssertEqual(combined.split(separator: "\n").filter { $0 == "open" }.count, 1, combined)
        XCTAssertEqual(a.0.terminationStatus, 0)
        XCTAssertEqual(b.0.terminationStatus, 0)
    }

    func testInitialStartupIntervalAndQuietBackgroundDuplicate() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = try start(root, "paused", hold: "1")
        try waitForEndpoint(root)
        let duplicate = try start(root)
        XCTAssertEqual(finish(duplicate), "forwarded\n")
        let background = try start(root, "background")
        XCTAssertEqual(finish(background), "quiet\n")
        XCTAssertEqual(finish(owner), "owner\nopen\n")
    }

    func testFailedHandoffIsBoundedAndDoesNotTakeOwnership() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = try start(root, "no-handoff", hold: "1.4")
        try waitForEndpoint(root)
        let began = Date()
        let duplicate = try start(root)
        XCTAssertTrue(finish(duplicate).contains("did not accept the open request"))
        XCTAssertEqual(duplicate.0.terminationStatus, 2)
        XCTAssertLessThan(Date().timeIntervalSince(began), 1.3)
        XCTAssertEqual(finish(owner), "owner\n")
    }

    func testCrashReleasesLockAndIsolatedPreviewCanOwnSeparately() throws {
        let root = temporaryRoot()
        let preview = temporaryRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: preview)
        }
        let owner = try start(root, hold: "30")
        try waitForEndpoint(root)
        let separate = try start(preview, hold: "0.05")
        XCTAssertEqual(finish(separate), "owner\n")
        // Only a disposable test child is killed; the user's application is never targeted.
        kill(owner.0.processIdentifier, SIGKILL)
        _ = finish(owner)
        let replacement = try start(root, hold: "0.05")
        XCTAssertEqual(finish(replacement), "owner\n")
    }

    func testUnsafeDirectoryIsRejected() throws {
        let root = temporaryRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(try InstanceLease.acquire(in: root))
    }
}
