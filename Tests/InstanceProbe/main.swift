import Foundation
import UsageCore
import Darwin

// Separate executable used only against disposable test namespaces. Never starts UI or readers.
guard CommandLine.arguments.count >= 3 else { exit(64) }
let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let action = CommandLine.arguments[2]
guard root.lastPathComponent.hasPrefix("usage-monitor-test-"), root.path.hasPrefix(NSTemporaryDirectory()) else { exit(64) }
do {
    let lease = action == "retry-open"
        ? try InstanceLease.acquireOrForwardOpen(in: root, background: false, timeout: 1)
        : try InstanceLease.acquire(in: root)
    if let owner = lease {
        print("owner"); fflush(stdout)
        if action == "paused" { Thread.sleep(forTimeInterval: 0.35) }
        if action != "no-handoff" {
            owner.start { print("open"); fflush(stdout) }
        }
        if action == "quitting" { owner.stopAcceptingOpens() }
        let hold = CommandLine.arguments.count > 3 ? Double(CommandLine.arguments[3]) ?? 1 : 1
        withExtendedLifetime(owner) { Thread.sleep(forTimeInterval: hold) }
    } else {
        if action == "background" { print("quiet"); exit(0) }
        try InstanceLease.forwardOpen(in: root, timeout: 1)
        print("forwarded")
    }
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(2)
}
