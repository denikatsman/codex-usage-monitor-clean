import XCTest
@testable import UsageCore

final class CodexReaderTests: XCTestCase {
    private func withServer(_ script: String, body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake-codex")
        try Data(("#!/bin/sh\n" + script).utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try body(executable)
    }

    func testHandshakeOnlyRequestsUsageAndHandlesSplitFrames() throws {
        try withServer(#"""
        IFS= read -r request
        case "$request" in *'"method":"initialize"'*) ;; *) exit 10 ;; esac
        printf '{"id":1,"result":{}}\n'
        IFS= read -r request
        case "$request" in *'"method":"initialized"'*) ;; *) exit 11 ;; esac
        IFS= read -r request
        case "$request" in *'"method":"account\/rateLimits\/read"'*|*'"method":"account/rateLimits/read"'*) ;; *) exit 12 ;; esac
        printf '{"method":"account/updated","params":{}}\n{"id":2,'
        printf '"result":{"rateLimits":{"primary":{"usedPercent":25,"windowDurationMins":300}}}}\n'
        IFS= read -r request
        """#) { executable in
            let response = try CodexReader().read(executable: executable, timeout: 3)
            XCTAssertEqual(response.rows.first?.window.remainingPercent, 75)
        }
    }

    func testAuthErrorIsActionable() throws {
        try withServer(#"""
        IFS= read -r request
        printf '{"id":1,"error":{"code":-1,"message":"ChatGPT authentication required"}}\n'
        """#) { executable in
            XCTAssertThrowsError(try CodexReader().read(executable: executable, timeout: 3)) {
                guard case UsageReadError.signInRequired = $0 else { return XCTFail("Wrong error: \($0)") }
            }
        }
    }

    func testDisconnectedServerDoesNotHang() throws {
        try withServer("exit 0\n") { executable in
            XCTAssertThrowsError(try CodexReader().read(executable: executable, timeout: 2))
        }
    }

    func testDisconnectAfterInitializeReturnsErrorInsteadOfTerminating() throws {
        try withServer(#"""
        IFS= read -r request
        exec 0<&-
        printf '{"id":1,"result":{}}\n'
        """#) { executable in
            XCTAssertThrowsError(try CodexReader().read(executable: executable, timeout: 2)) {
                guard case UsageReadError.disconnected = $0 else { return XCTFail("Wrong error: \($0)") }
            }
        }
    }

    func testUnresponsiveServerHasBoundedTimeout() throws {
        try withServer("exec /bin/sleep 30\n") { executable in
            let start = Date()
            XCTAssertThrowsError(try CodexReader().read(executable: executable, timeout: 0.2)) {
                guard case UsageReadError.timedOut = $0 else { return XCTFail("Wrong error: \($0)") }
            }
            XCTAssertLessThan(Date().timeIntervalSince(start), 3)
        }
    }

    func testMalformedPayloadIsNotPresentedAsZeroUsage() throws {
        try withServer(#"""
        IFS= read -r request
        printf '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":"invalid"}}}}\n'
        """#) { executable in
            XCTAssertThrowsError(try CodexReader().read(executable: executable, timeout: 3)) {
                guard case UsageReadError.invalidResponse = $0 else { return XCTFail("Wrong error: \($0)") }
            }
        }
    }

    func testSuccessfulReadReapsAHelperThatIgnoresTerminationPromptly() throws {
        try withServer(#"""
        trap '' TERM
        IFS= read -r request
        printf '{"id":2,"result":{"rateLimits":{"primary":{"usedPercent":25}}}}\n'
        exec /bin/sleep 30
        """#) { executable in
            let began = Date()
            XCTAssertEqual(try CodexReader().read(executable: executable, timeout: 0.2).rows.first?.window.remainingPercent, 75)
            XCTAssertLessThan(Date().timeIntervalSince(began), 1.6)
        }
    }

    func testCancellationWaitsForHelperAndItsDescendantAndReaderCanBeReused() throws {
        try withServer(#"""
        trap '' TERM
        /bin/sleep 30 &
        printf '%s %s' "$$" "$!" > "${0%/*}/pids"
        wait
        """#) { executable in
            let reader = CodexReader()
            let finished = DispatchGroup(); finished.enter()
            DispatchQueue.global().async {
                defer { finished.leave() }
                do { _ = try reader.read(executable: executable, timeout: 20); XCTFail("Cancelled helper returned a result") }
                catch { XCTAssertTrue(error is CancellationError) }
            }
            let pids = executable.deletingLastPathComponent().appendingPathComponent("pids")
            let deadline = Date().addingTimeInterval(2)
            while !FileManager.default.fileExists(atPath: pids.path), Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
            let values = try String(contentsOf: pids).split(separator: " ").compactMap { Int32($0) }
            XCTAssertEqual(values.count, 2)
            XCTAssertThrowsError(try reader.read(executable: executable, timeout: 1))
            let began = Date(); reader.cancel()
            XCTAssertEqual(finished.wait(timeout: .now() + 0.1), .success)
            XCTAssertLessThan(Date().timeIntervalSince(began), 1.8)
            for pid in values {
                let until = Date().addingTimeInterval(1)
                while kill(pid, 0) == 0, Date() < until { Thread.sleep(forTimeInterval: 0.01) }
                XCTAssertEqual(kill(pid, 0), -1, "Owned helper process remains alive: \(pid)")
            }
            XCTAssertNil(reader.activeProcessIdentifier)
            try Data("#!/bin/sh\nread request\nprintf '{\"id\":2,\"result\":{}}\\n'\n".utf8).write(to: executable)
            XCTAssertNoThrow(try reader.read(executable: executable, timeout: 1))
        }
    }

    func testExitedHelperWithDescendantHoldingStdoutHasBoundedTimeout() throws {
        try withServer(#"""
        /bin/sleep 30 &
        printf '%s' "$!" > "${0%/*}/descendant"
        exit 0
        """#) { executable in
            let began = Date()
            XCTAssertThrowsError(try CodexReader().read(executable: executable, timeout: 0.2)) {
                guard case UsageReadError.timedOut = $0 else { return XCTFail("Wrong error: \($0)") }
            }
            XCTAssertLessThan(Date().timeIntervalSince(began), 1.8)
            let pid = try XCTUnwrap(Int32(String(contentsOf: executable.deletingLastPathComponent().appendingPathComponent("descendant"))))
            XCTAssertEqual(kill(pid, 0), -1)
        }
    }

    func testRepeatedReadsReleaseFileDescriptors() throws {
        try withServer(#"""
        read request
        printf '{"id":2,"result":{}}\n'
        read request
        """#) { executable in
            let reader = CodexReader()
            _ = try reader.read(executable: executable, timeout: 1)
            let before = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
            for _ in 0..<12 { _ = try reader.read(executable: executable, timeout: 1) }
            let after = try FileManager.default.contentsOfDirectory(atPath: "/dev/fd").count
            XCTAssertLessThanOrEqual(after, before + 4)
        }
    }
}
