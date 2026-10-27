import AppKit
import SwiftUI
import UsageCore
import Carbon

private enum LaunchError: LocalizedError {
    case earlierVersionRunning

    var errorDescription: String? {
        "An earlier Codex Usage Monitor is running. Quit that copy, then reopen the updated app."
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windows: WindowController?
    private var state: AppState?
    private var pendingOpen = false
    private var isQuitting = false
    weak var instanceLease: InstanceLease?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let state = AppState()
        self.state = state
        let windows = WindowController(state: state)
        self.windows = windows
        windows.start(background: Self.isBackgroundLaunch && !pendingOpen)
        state.start()
        if pendingOpen { windows.reopen(); pendingOpen = false }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !Self.currentEventIsBackground { requestOpen() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        windows?.stop()
        state?.stop()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isQuitting else { return .terminateLater }
        isQuitting = true
        instanceLease?.stopAcceptingOpens()
        windows?.stop()
        Task { @MainActor in
            await state?.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func requestOpen() {
        guard !isQuitting else { return }
        guard let windows else { pendingOpen = true; return }
        windows.reopen()
    }

    static var isBackgroundLaunch: Bool {
        CommandLine.arguments.contains("--background") || currentEventIsBackground
    }

    static var currentEventIsBackground: Bool {
        let event = NSAppleEventManager.shared().currentAppleEvent
        return event?.paramDescriptor(forKeyword: keyAELaunchedAsLogInItem) != nil
            || event?.paramDescriptor(forKeyword: keyAELaunchedAsServiceItem) != nil
            || event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}

@main
enum Application {
    @MainActor static func main() {
      do {
        if CommandLine.arguments.contains("--self-test") { try selfTest(); return }
        if CommandLine.arguments.contains("--disable-login") {
            // Explicit diagnostic action; ordinary launches never change registration.
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            Task { @MainActor in
                do {
                    try await SystemLoginItemService().unregister()
                    try printLoginStatus()
                    exit(0)
                } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
            }
            app.run()
            return
        }
        if CommandLine.arguments.contains("--enable-login") || CommandLine.arguments.contains("--login-item-status") {
            let login = SystemLoginItemService()
            if CommandLine.arguments.contains("--enable-login"), login.status != .enabled {
                if login.status != .requiresApproval { try login.register() }
            }
            try printLoginStatus()
            if CommandLine.arguments.contains("--enable-login"), login.status != .enabled { exit(2) }
            return
        }
        let directory = InstanceLease.productionDirectory
        let owner: InstanceLease?
        if CommandLine.arguments.contains("--check") || CommandLine.arguments.contains("--repair-history") {
            guard let lease = try InstanceLease.acquire(in: directory) else { throw InstanceError.unavailable }
            owner = lease
        } else { owner = try InstanceLease.acquireOrForwardOpen(in: directory, background: AppDelegate.isBackgroundLaunch) }
        guard let owner else { return }
        // Releases before 1.2 do not participate in the lock. Fail closed during migration.
        // New simultaneous contenders have not finished launching before the guard.
        if NSRunningApplication.runningApplications(withBundleIdentifier: "local.codex-usage-monitor")
            .contains(where: { $0.processIdentifier != getpid() && $0.isFinishedLaunching }) {
            throw LaunchError.earlierVersionRunning
        }
        if CommandLine.arguments.contains("--repair-history") {
            func argument(_ flag: String) -> URL? {
                guard let i = CommandLine.arguments.firstIndex(of: flag), i + 1 < CommandLine.arguments.count else { return nil }
                return URL(fileURLWithPath: CommandLine.arguments[i + 1])
            }
            let home = FileManager.default.homeDirectoryForCurrentUser
            let codexHome = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".codex")
            let recorder = HistoryRecorder(storeURL: home.appendingPathComponent("Library/Application Support/local.codex-usage-monitor/history.sqlite"), codexHome: codexHome)
            let app = NSApplication.shared
            app.setActivationPolicy(.prohibited)
            Task {
                do {
                    let result = try await recorder.recoverSaved(requestCapture: argument("--request-evidence"), requestLogHome: argument("--request-log-backup"))
                    print(String(decoding: try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]), as: UTF8.self))
                    exit(0)
                } catch { fputs("Metadata recovery failed: \(error.localizedDescription)\n", stderr); exit(1) }
            }
            withExtendedLifetime(owner) { app.run() }
            return
        }
        if CommandLine.arguments.contains("--check") {
            try withExtendedLifetime(owner) { try check() }
            return
        }
        let delegate = AppDelegate()
        delegate.instanceLease = owner
        owner.start { DispatchQueue.main.async { delegate.requestOpen() } }
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(owner) { app.run() }
      } catch {
        fputs("\(error.localizedDescription)\n", stderr)
        if Bundle.main.bundleURL.pathExtension == "app",
           !AppDelegate.isBackgroundLaunch, !CommandLine.arguments.contains("--check"),
           !CommandLine.arguments.contains("--self-test"), !CommandLine.arguments.contains("--enable-login"),
           !CommandLine.arguments.contains("--login-item-status"), !CommandLine.arguments.contains("--repair-history") {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let alert = NSAlert()
            alert.messageText = "Couldn’t open Codex Usage Monitor"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            app.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        exit(1)
      }
    }

    @MainActor private static func printLoginStatus() throws {
        let login = SystemLoginItemService()
        let data = try JSONSerialization.data(withJSONObject: ["status": login.status.rawValue,
            "enabled": login.status == .enabled, "app": Bundle.main.bundleURL.path], options: [.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }

    private static func check() throws {
        let usage = try CodexReader().read()
        let now = Date()
        let format = CountdownFormat.load(from: .standard)
        guard !usage.rows.isEmpty else { throw UsageReadError.rejected }
        for row in usage.rows {
            let remaining = row.window.remainingPercent.map(UsageFormatting.percent) ?? "unavailable"
            let reset = row.window.resetDate.map { UsageFormatting.resetDate($0) } ?? "unavailable"
            let countdown = row.window.resetDate.map { UsageFormatting.countdown(to: $0, from: now, format: format) } ?? "unavailable"
            print("\(row.title): \(remaining) remaining | resets \(reset) | \(countdown)")
        }
        print("Credits: \(usage.credits?.amount.map(AccountCredits.format) ?? "unavailable")")
        if let subscription = SubscriptionMetadata.read(accountID: usage.accountId) {
            print("Subscription renewal (cached account metadata): \(UsageFormatting.resetDate(subscription.date)) | \(UsageFormatting.countdown(to: subscription.date, from: now, format: format))")
        } else { print("Subscription renewal: unavailable") }
        if let resets = usage.rateLimitResetCredits {
            print("Available resets: \(resets.availableCount.map(String.init) ?? "unavailable")")
            for credit in resets.available(at: now) { print("Expires: \(credit.expiry.label)") }
        }
    }

    private static func selfTest() throws {
        let data = Data(#"{"accountId":"self-test","ordinaryUsageAllowed":false,"rateLimits":{"primary":{"usedPercent":100,"windowDurationMins":10080,"resetsAt":2000000000},"credits":{"balance":"12345.25"}},"rateLimitResetCredits":{"availableCount":1,"credits":[{"id":"fixture","status":"available","expiresAt":2000000000}]}}"#.utf8)
        let value = try JSONDecoder().decode(UsageResponse.self, from: data)
        let payload = Data(#"{"https://api.openai.com/auth":{"chatgpt_account_id":"self-test","chatgpt_subscription_active_until":"2030-01-01T12:00:00Z"}}"#.utf8).base64EncodedString()
        let auth = try JSONSerialization.data(withJSONObject: ["auth_mode": "chatgpt",
            "tokens": ["account_id": "self-test", "id_token": "fixture.\(payload).fixture"]])
        let subscription = SubscriptionMetadata.decode(auth, accountID: "self-test")
        let anchor = Date(timeIntervalSince1970: 1900000000)
        let meters = (0...2).map { i in MeterObservation(id: String(i), account: "fixture", epoch: "fixture", meterID: "weekly", title: "Weekly", used: Double(i), observedAt: anchor.addingTimeInterval(Double(i * 15))) }
        var tokens = TokenMetrics(); tokens.input = 1000; tokens.output = 500
        let activity = ActivityObservation(id: "fixture", account: "fixture", epoch: "fixture", threadID: "fixture", title: "Fixture", model: "fixture", effort: "high", speed: "default", sourceAt: anchor.addingTimeInterval(20), capturedAt: anchor.addingTimeInterval(21), tokens: tokens)
        let analysis = UsageAnalysis.build(meters: meters, activity: [activity], now: anchor.addingTimeInterval(30))
        guard UsageTier.canonical("fast") == "priority", !UsageTier.isComparable("unset"),
              analysis.intervals.count == 2, analysis.calibration.first?.medianTokensPerPoint == 1500,
              value.rows.first?.window.remainingPercent == 0,
              value.credits?.amount == Decimal(string: "12345.25"),
              value.rateLimitResetCredits?.available(at: Date(timeIntervalSince1970: 1900000000)).count == 1,
              subscription?.date == ISO8601DateFormatter().date(from: "2030-01-01T12:00:00Z"),
              UsageFormatting.countdown(to: Date(timeIntervalSince1970: 281554), from: Date(timeIntervalSince1970: 0), format: .days) == "3d 06h 12m 34s",
              UsageFormatting.countdown(to: Date(timeIntervalSince1970: 281554), from: Date(timeIntervalSince1970: 0)) == "78h 12m 34s",
              WindowPlacement.restoredFrame(from: "1 2 340 264 0 0 1920 1080")?.origin == NSPoint(x: 1, y: 2) else {
            throw UsageReadError.invalidResponse
        }
        print("Codex Usage Monitor: usage analysis, countdown formats, account decoding, subscription renewal, credits, reset expiry and placement self-test passed.")
    }
}
