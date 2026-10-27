import Foundation
import Darwin

public enum UsageReadError: LocalizedError {
    case codexMissing, timedOut, disconnected, invalidResponse, signInRequired, rejected

    public var errorDescription: String? {
        switch self {
        case .codexMissing: return "Codex could not be found. Install Codex, then reopen this app."
        case .timedOut: return "Codex did not respond. Retrying automatically."
        case .disconnected: return "Could not connect to Codex. Retrying automatically."
        case .invalidResponse: return "Codex returned an unreadable usage response."
        case .signInRequired: return "Sign in to Codex with your ChatGPT account, then refresh."
        case .rejected: return "Usage is unavailable. Check your Codex sign-in and connection."
        }
    }
}

/// Short-lived, read-only app-server connection. No credentials or usage are stored.
/// Run read() off the main thread; the UI serializes refreshes.
public final class CodexReader: @unchecked Sendable {
    private let lock = NSLock()
    private var activeProcess: Process?
    private var completion: DispatchGroup?
    private var generation: UInt64 = 0

    public var activeProcessIdentifier: Int32? {
        lock.lock(); defer { lock.unlock() }
        return activeProcess?.processIdentifier
    }

    public init() {}

    public static func findCodex(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let explicit = environment["CODEX_USAGE_CODEX_PATH"].map { [$0] } ?? []
        let paths = (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/codex" }
        let candidates = explicit + [
            "\(home)/.local/bin/codex",
            "\(home)/.codex/packages/standalone/current/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "\(home)/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex"
        ] + paths
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:)).map(URL.init(fileURLWithPath:))
    }

    public func cancel() {
        lock.lock()
        generation &+= 1
        let pending = completion
        lock.unlock()
        // read() polls cancellation, closes stdin, stops its process group and reaps.
        // Quit waits for that cleanup rather than abandoning a detached helper.
        _ = pending?.wait(timeout: .now() + 2)
    }

    public func read(executable: URL? = nil, timeout: TimeInterval = 20) throws -> UsageResponse {
        let done = DispatchGroup()
        lock.lock()
        guard completion == nil else { lock.unlock(); throw UsageReadError.rejected }
        let current = generation
        done.enter(); completion = done
        lock.unlock()
        defer {
            lock.lock(); activeProcess = nil; completion = nil; lock.unlock()
            done.leave()
        }
        try checkCancellation(current)
        guard let executable = executable ?? Self.findCodex() else { throw UsageReadError.codexMissing }
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        // A helper may exit between protocol messages. Treat EPIPE as a read failure
        // instead of allowing SIGPIPE to terminate the entire monitor.
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw UsageReadError.disconnected
        }
        process.executableURL = executable
        process.arguments = ["app-server", "--listen", "stdio://"]
        // Avoid loading project-specific configuration or launching work in a repository.
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = [executable.deletingLastPathComponent().path, environment["PATH"] ?? "",
                               "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
        environment["RUST_LOG"] = "off"
        process.environment = environment
        lock.lock()
        guard current == generation, !Task.isCancelled else { lock.unlock(); throw CancellationError() }
        do { try process.run() } catch { lock.unlock(); throw UsageReadError.disconnected }
        activeProcess = process
        lock.unlock()
        let pid = process.processIdentifier
        // Foundation starts its child in a separate process group on macOS. Verify
        // ownership before ever signalling a group; never signal the monitor's group.
        let ownGroup = pid != getpgrp() && (getpgid(pid) == pid || kill(-pid, 0) == 0)
        defer {
            try? input.fileHandleForWriting.close()
            Self.stopAndReap(process, ownGroup: ownGroup)
            try? output.fileHandleForReading.close()
        }
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        let fd = output.fileHandleForReading.fileDescriptor
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw UsageReadError.disconnected }

        func send(_ message: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: message)
            data.append(0x0a)
            do { try input.fileHandleForWriting.write(contentsOf: data) }
            catch { throw UsageReadError.disconnected }
        }

        try send(["id": 1, "method": "initialize", "params": [
            "clientInfo": ["name": "codex_usage_monitor", "title": "Codex Usage Monitor", "version": "1.0.0"],
            "capabilities": NSNull()
        ]])
        var buffer = Data()
        var initialized = false
        while true {
            try checkCancellation(current)
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw UsageReadError.timedOut }
            var item = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP), revents: 0)
            let ready = poll(&item, 1, Int32(min(100, max(1, remaining * 1000))))
            if ready < 0 {
                if errno == EINTR { continue }
                throw UsageReadError.disconnected
            }
            if ready == 0 { continue }
            var chunk = [UInt8](repeating: 0, count: 65536)
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count < 0, errno == EAGAIN || errno == EINTR { continue }
            guard count > 0 else { throw UsageReadError.disconnected }
            buffer.append(contentsOf: chunk.prefix(count))
            guard buffer.count <= 4 * 1024 * 1024 else { throw UsageReadError.invalidResponse }
            while let newline = buffer.firstIndex(of: 0x0a) {
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                      let id = message["id"] as? Int else { continue }
                if let error = message["error"] as? [String: Any] {
                    let detail = (error["message"] as? String ?? "").lowercased()
                    if ["auth", "sign in", "log in", "login", "chatgpt"].contains(where: detail.contains) {
                        throw UsageReadError.signInRequired
                    }
                    throw UsageReadError.rejected
                }
                if id == 1 {
                    guard !initialized else { continue }
                    initialized = true
                    try send(["method": "initialized"])
                    try send(["id": 2, "method": "account/rateLimits/read"])
                } else if id == 2 {
                    guard let result = message["result"] as? [String: Any] else { throw UsageReadError.invalidResponse }
                    do {
                        return try JSONDecoder().decode(UsageResponse.self, from: JSONSerialization.data(withJSONObject: result))
                    } catch { throw UsageReadError.invalidResponse }
                }
            }
        }
    }

    private func checkCancellation(_ current: UInt64) throws {
        lock.lock(); let cancelled = generation != current; lock.unlock()
        if cancelled || Task.isCancelled { throw CancellationError() }
    }

    private static func stopAndReap(_ process: Process, ownGroup: Bool) {
        let pid = process.processIdentifier
        func groupExists() -> Bool { ownGroup && kill(-pid, 0) == 0 }
        if ownGroup { _ = kill(-pid, SIGTERM) }
        else if process.isRunning { process.terminate() }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.5
        while (process.isRunning || groupExists()), ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        // Only a verified, private child group can be escalated after the grace period.
        if groupExists() { _ = kill(-pid, SIGKILL) }
        else if process.isRunning { _ = kill(pid, SIGKILL) }
        process.waitUntilExit()
    }
}
