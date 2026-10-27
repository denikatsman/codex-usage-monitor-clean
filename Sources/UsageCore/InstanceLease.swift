import Foundation
import Darwin

public enum InstanceError: LocalizedError {
    case unsafeDirectory, system(String), unavailable
    public var errorDescription: String? {
        switch self {
        case .unsafeDirectory: return "The private instance directory is not safe to use."
        case .system(let operation): return "Could not establish application ownership (\(operation))."
        case .unavailable: return "Codex Usage Monitor is already running, but did not accept the open request. Open it from its menu bar or Dock, or quit that copy and try again."
        }
    }
}

/// Per-user lifetime flock plus a private, bounded Unix-socket open-only handoff.
/// The lock inode is never removed, and close-on-exec prevents helpers inheriting ownership.
public final class InstanceLease: @unchecked Sendable {
    public static var productionDirectory: URL {
        // Independent of bundle location, launch method, and a caller's TMPDIR override.
        URL(fileURLWithPath: "/tmp/local.codex-usage-monitor-\(geteuid())", isDirectory: true)
    }

    private let lockFD: Int32
    private let listenerFD: Int32
    private let queue = DispatchQueue(label: "local.codex-usage-monitor.handoff")
    private var source: DispatchSourceRead?
    private let acceptanceLock = NSLock()
    private var acceptingOpens = true

    private init(lockFD: Int32, listenerFD: Int32) {
        self.lockFD = lockFD
        self.listenerFD = listenerFD
    }

    public static func acquire(in directory: URL) throws -> InstanceLease? {
        try prepare(directory)
        let lockPath = directory.appendingPathComponent("owner.lock").path
        let fd = open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw InstanceError.system("lock file") }
        var owned = false
        defer { if !owned { close(fd) } }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == geteuid(),
              info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_mode & 0o077 == 0 else { throw InstanceError.unsafeDirectory }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK { return nil }
            throw InstanceError.system("lifetime lock")
        }
        let socketPath = directory.appendingPathComponent("open.sock").path
        // Only the lock owner may remove a stale endpoint left by an exited owner.
        guard unlink(socketPath) == 0 || errno == ENOENT else { throw InstanceError.system("stale endpoint") }
        let listener = try makeSocket()
        var listening = false
        defer { if !listening { close(listener) } }
        var address = try socketAddress(socketPath)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(socketPath, 0o600) == 0, listen(listener, 8) == 0 else {
            throw InstanceError.system("local endpoint")
        }
        owned = true
        listening = true
        return InstanceLease(lockFD: fd, listenerFD: listener)
    }

    public func start(onOpen: @escaping @Sendable () -> Void) {
        guard source == nil else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: listenerFD, queue: queue)
        let listener = listenerFD
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // Limit each turn of the queue; no unbounded threads or arbitrary commands.
            for _ in 0..<8 {
                guard self.acceptsOpens else { break }
                let client = accept(listener, nil, nil)
                guard client >= 0 else { break }
                defer { close(client) }
                var uid: uid_t = 0
                var gid: gid_t = 0
                guard getpeereid(client, &uid, &gid) == 0, uid == geteuid() else { continue }
                Self.configure(client)
                if Self.readLine(client, until: Self.uptime() + 0.25) == "open\n", self.acceptsOpens {
                    onOpen()
                    _ = Self.sendLine("ok\n", to: client, until: Self.uptime() + 0.25)
                }
            }
        }
        source.setCancelHandler { close(listener) }
        self.source = source
        source.resume()
    }

    private var acceptsOpens: Bool {
        acceptanceLock.lock(); defer { acceptanceLock.unlock() }
        return acceptingOpens
    }

    public func stopAcceptingOpens() {
        acceptanceLock.lock(); acceptingOpens = false; acceptanceLock.unlock()
        source?.cancel()
    }

    /// A quitting owner may release its lock before a second launch can hand off.
    /// Retry ownership after a failed handoff rather than losing that explicit open.
    public static func acquireOrForwardOpen(in directory: URL, background: Bool, timeout: TimeInterval = 3) throws -> InstanceLease? {
        let deadline = uptime() + timeout
        repeat {
            if let owner = try acquire(in: directory) { return owner }
            if background { return nil }
            do { try forwardOpen(in: directory, timeout: min(0.3, max(0, deadline - uptime()))); return nil }
            catch InstanceError.unavailable { /* The old owner may be draining Quit. */ }
        } while uptime() < deadline
        throw InstanceError.unavailable
    }

    public static func forwardOpen(in directory: URL, timeout: TimeInterval = 3) throws {
        try prepare(directory)
        let deadline = uptime() + timeout
        while uptime() < deadline {
            if try attemptOpen(in: directory, until: deadline) { return }
            Thread.sleep(forTimeInterval: 0.04)
        }
        throw InstanceError.unavailable
    }

    private static func attemptOpen(in directory: URL, until deadline: TimeInterval) throws -> Bool {
        let fd = try makeSocket()
        defer { close(fd) }
        var address = try socketAddress(directory.appendingPathComponent("open.sock").path)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN,
                  ready(fd, for: Int16(POLLOUT), until: deadline) else { return false }
            var error: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0, error == 0 else { return false }
        }
        return sendLine("open\n", to: fd, until: deadline) && readLine(fd, until: deadline) == "ok\n"
    }

    private static func prepare(_ directory: URL) throws {
        // mkdir applies permissions atomically. Foundation can briefly expose its default
        // mode before applying attributes, causing a simultaneous launch to reject it.
        guard mkdir(directory.path, 0o700) == 0 || errno == EEXIST else {
            throw InstanceError.system("private instance directory")
        }
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_uid == geteuid(),
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0 else {
            throw InstanceError.unsafeDirectory
        }
    }

    private static func socketAddress(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        let bytes = Array(path.utf8) + [0]
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw InstanceError.system("endpoint path is too long")
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        return address
    }

    private static func makeSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw InstanceError.system("socket") }
        configure(fd)
        return fd
    }

    private static func configure(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        var yes: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
    }

    private static func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
    private static func ready(_ fd: Int32, for events: Int16, until deadline: TimeInterval) -> Bool {
        var item = pollfd(fd: fd, events: events, revents: 0)
        while uptime() < deadline {
            let result = poll(&item, 1, Int32(max(1, (deadline - uptime()) * 1000)))
            if result > 0 { return item.revents & events != 0 }
            if result == 0 || errno != EINTR { return false }
        }
        return false
    }

    private static func sendLine(_ text: String, to fd: Int32, until deadline: TimeInterval) -> Bool {
        let bytes = Array(text.utf8)
        var offset = 0
        return bytes.withUnsafeBytes { buffer in
            while offset < buffer.count {
                guard ready(fd, for: Int16(POLLOUT), until: deadline) else { return false }
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count > 0 { offset += count }
                else if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                else { return false }
            }
            return true
        }
    }

    private static func readLine(_ fd: Int32, until deadline: TimeInterval) -> String? {
        var bytes: [UInt8] = []
        while bytes.count < 16, ready(fd, for: Int16(POLLIN), until: deadline) {
            var chunk = [UInt8](repeating: 0, count: 16 - bytes.count)
            let count = Darwin.read(fd, &chunk, chunk.count)
            if count <= 0 { return nil }
            bytes.append(contentsOf: chunk.prefix(count))
            if bytes.contains(10) { return String(bytes: bytes, encoding: .utf8) }
        }
        return nil
    }

    deinit {
        if let source { source.cancel() } else { close(listenerFD) }
        close(lockFD)
        // Never unlink the lifetime lock or an endpoint that a new owner may now own.
    }
}
