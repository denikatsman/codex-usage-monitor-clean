import XCTest
import AppKit
import SwiftUI
@testable import UsageCore
@testable import CodexUsageMonitor

actor ReadCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

final class AppLifecycleTests: XCTestCase {
    @MainActor
    func testCountdownFormatBindingPersistsAndFitsBothSurfaces() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let name = "usage-monitor-test-countdown-format-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let now = Date(timeIntervalSince1970: 1900000000)
        let reset = now.addingTimeInterval(281554)
        let data = try JSONSerialization.data(withJSONObject: ["rateLimits": ["primary": ["usedPercent": 25, "windowDurationMins": 10080, "resetsAt": reset.timeIntervalSince1970]]])
        let response = try JSONDecoder().decode(UsageResponse.self, from: data)
        let usage = UsageModel(initial: response, lastUpdated: now, now: now, subscription: SubscriptionRenewal(date: reset))
        let state = AppState(defaults: defaults, usage: usage)
        XCTAssertEqual(state.countdownFormat, .hours)
        XCTAssertNil(defaults.object(forKey: "countdownFormat"))

        func window<V: View>(_ view: V) -> NSWindow {
            let host = NSHostingView(rootView: view)
            host.sizingOptions = [.intrinsicContentSize]
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 600), styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            WindowContentSizing.fit(window, to: host.fittingSize)
            return window
        }
        let floating = UsageView(state: state, presentation: .floating, changePresentation: {}, close: {}, settings: {})
        let card = UsageView(state: state, presentation: .menuBar, changePresentation: {}, close: {}, settings: {})
        let floatingWindow = window(floating)
        let cardWindow = window(card)
        let settings = SettingsView(state: state)
        let settingsWindow = window(settings)
        let initialSize = floatingWindow.contentLayoutRect.size
        try await Task.sleep(nanoseconds: 50_000_000)
        for expectedFormat in [CountdownFormat.days, .hours] {
            // Exercise the actual binding used by the Settings switch. SwiftUI does
            // not export accessibility children for these unshown fixture windows.
            settings.showDaysInCountdowns.wrappedValue = expectedFormat == .days
            try await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertEqual(state.countdownFormat, expectedFormat)
            XCTAssertEqual(settings.showDaysInCountdowns.wrappedValue, expectedFormat == .days)
            defaults.synchronize()
            XCTAssertEqual(AppState(defaults: UserDefaults(suiteName: name)!).countdownFormat, expectedFormat)
            for surface in [floatingWindow, cardWindow] {
                surface.contentView?.layoutSubtreeIfNeeded()
                XCTAssertGreaterThanOrEqual(surface.contentLayoutRect.height + 1, try XCTUnwrap(surface.contentView).fittingSize.height)
                XCTAssertFalse(surface.isVisible)
            }
            _ = try await render(floating, name: "countdown-\(expectedFormat.rawValue)-floating", dark: true)
            _ = try await render(card, name: "countdown-\(expectedFormat.rawValue)-card", dark: true)
            _ = try await render(settings, name: "countdown-\(expectedFormat.rawValue)-settings", dark: false)
        }
        XCTAssertEqual(floatingWindow.contentLayoutRect.size, initialSize)
        _ = try await render(SettingsView(state: state), name: "countdown-settings", dark: false)
        XCTAssertGreaterThanOrEqual(settingsWindow.contentLayoutRect.height + 1, try XCTUnwrap(settingsWindow.contentView).fittingSize.height)
        if let screen = NSScreen.main { XCTAssertLessThan(settingsWindow.frame.height, screen.visibleFrame.height) }
        defaults.set("invalid", forKey: "countdownFormat")
        XCTAssertEqual(AppState(defaults: defaults).countdownFormat, .hours)
    }

    @MainActor
    func testHiddenClockKeepsCollectionAndWakeRecoveryRunning() async throws {
        let name = "usage-monitor-test-hidden-clock-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let reads = ReadCounter()
        let response = try fixture()
        let usage = UsageModel(readUsage: { await reads.increment(); return response })
        let state = AppState(defaults: defaults, usage: usage)
        state.launch(background: true); state.hideMain(); usage.start()
        defer { usage.stop() }
        for _ in 0..<100 where usage.isRefreshing { try await Task.sleep(nanoseconds: 5_000_000) }
        var clockTicks: [Date] = []
        usage.onClock = { clockTicks.append($0) } // AppState wires this callback to HistoryModel.tick.
        let previous = usage.now
        usage.onTick(Date().addingTimeInterval(61))
        XCTAssertEqual(usage.now, previous) // No per-second redraw of hidden surfaces.
        XCTAssertEqual(clockTicks.count, 1) // Optional history scheduling continues.
        for _ in 0..<100 where usage.isRefreshing { try await Task.sleep(nanoseconds: 5_000_000) }
        var count = await reads.value; XCTAssertEqual(count, 2) // Automatic allowance sampling continues.
        usage.resumeAfterWake()
        for _ in 0..<100 where usage.isRefreshing { try await Task.sleep(nanoseconds: 5_000_000) }
        count = await reads.value; XCTAssertEqual(count, 3)
        state.showCard(); XCTAssertTrue(usage.countdownVisible)
        usage.onTick(Date().addingTimeInterval(1)); XCTAssertGreaterThan(usage.now, previous)
        state.closeCard(); XCTAssertFalse(usage.countdownVisible)
        state.openMain(); XCTAssertTrue(usage.countdownVisible)
        usage.stop(); usage.resumeAfterWake(); usage.onTick(Date().addingTimeInterval(120))
        await Task.yield()
        count = await reads.value; XCTAssertEqual(count, 3)
        XCTAssertEqual(usage.scheduleStarts, 1)
    }

    private func fixture() throws -> UsageResponse {
        try JSONDecoder().decode(UsageResponse.self, from: Data(#"{"rateLimits":{"primary":{"usedPercent":43,"windowDurationMins":10080,"resetsAt":1900000000}}}"#.utf8))
    }

    @MainActor
    func testAccessTogglesPersistRejectLastRemovalAndRecoverMissingStatusItem() {
        let name = "usage-monitor-test-ui-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let state = AppState(defaults: defaults)
        XCTAssertEqual(state.access, .defaults)
        XCTAssertFalse(state.setAccess(menuBar: false, dock: false))
        for _ in 0..<30 {
            XCTAssertTrue(state.setAccess(menuBar: true, dock: true))
            XCTAssertTrue(state.setAccess(menuBar: false, dock: true))
            XCTAssertFalse(state.setAccess(menuBar: false, dock: false))
            XCTAssertTrue(state.setAccess(menuBar: true, dock: false))
        }
        XCTAssertEqual(AppState(defaults: defaults).access, .defaults)
        state.hideMain()
        XCTAssertTrue(state.statusItemRemoved())
        XCTAssertEqual(state.access, AppAccess(menuBar: false, dock: true))
        XCTAssertTrue(state.presentation.mainVisible)
        state.setAccess(menuBar: true, dock: true)
        state.hideMain()
        XCTAssertFalse(state.statusItemRemoved())
        XCTAssertFalse(state.presentation.mainVisible)
    }

    @MainActor
    func testInvalidSavedSettingsRecoverWithoutResettingPresentation() {
        let name = "usage-monitor-test-ui-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "showInMenuBar")
        defaults.set(false, forKey: "showInDock")
        defaults.set("menuBar", forKey: "presentationMode")
        let state = AppState(defaults: defaults)
        XCTAssertEqual(state.access, .defaults)
        XCTAssertTrue(defaults.bool(forKey: "showInMenuBar"))
        XCTAssertEqual(state.presentation.saved, .menuBar)
        state.launch(background: true)
        XCTAssertFalse(state.presentation.mainVisible)
        state.launch(background: false)
        XCTAssertTrue(state.presentation.mainVisible)
    }

    @MainActor
    func testRepeatedPresentationsReuseWindowStateAndOneRefreshSchedule() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let name = "usage-monitor-test-ui-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let response = try fixture()
        let counter = ReadCounter()
        let usage = UsageModel(readUsage: { await counter.increment(); return response })
        let state = AppState(defaults: defaults, usage: usage)
        let controller = WindowController(state: state, interactive: false)
        controller.start()
        let originalPanel = controller.panel
        state.start()
        state.start()
        for _ in 0..<20 {
            controller.start()
            controller.showPopover()
            XCTAssertTrue(state.presentation.mainVisible)
            XCTAssertEqual(state.presentation.saved, .floating)
            controller.closeCard()
            controller.hideMain()
            controller.reopen()
            XCTAssertTrue(state.presentation.mainVisible)
            XCTAssertTrue(controller.panel === originalPanel)
        }
        for _ in 0..<100 where usage.isRefreshing { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(usage.rows.first?.window.remainingPercent, 57)
        XCTAssertEqual(usage.scheduleStarts, 1)
        let reads = await counter.value
        XCTAssertEqual(reads, 1)
        let card = UsageView(state: state, presentation: .menuBar, changePresentation: {}, close: {}, settings: {})
        let main = UsageView(state: state, presentation: .floating, changePresentation: {}, close: {}, settings: {})
        XCTAssertTrue(card.model === main.model)
        XCTAssertTrue(card.state === main.state)
        state.stop()
        controller.stop()
        XCTAssertFalse(usage.isStarted)
    }

    @MainActor
    func testDockOnlyCloseAndReopenAndBackgroundCardIntent() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let name = "usage-monitor-test-ui-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let state = AppState(defaults: defaults)
        state.setAccess(menuBar: false, dock: true)
        state.hideMain()
        let controller = WindowController(state: state, interactive: false)
        controller.start(background: true)
        XCTAssertFalse(state.presentation.mainVisible)
        controller.showPopover()
        XCTAssertFalse(state.presentation.cardVisible)
        controller.reopen()
        XCTAssertTrue(state.presentation.mainVisible)
        XCTAssertFalse(controller.windowShouldClose(controller.panel))
        XCTAssertFalse(state.presentation.mainVisible)
        controller.reopen()
        XCTAssertTrue(state.presentation.mainVisible)
        controller.stop()
    }

    @MainActor
    func testWindowRestoresSavedPositionWithoutOverwritingItDuringSetup() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let screen = try XCTUnwrap(NSScreen.screens.last)
        let frame = NSRect(x: screen.visibleFrame.minX + 80, y: screen.visibleFrame.minY + 80,
                           width: 340, height: 264)
        let name = "usage-monitor-test-ui-frame-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let key = "NSWindow Frame CodexUsageMonitorWindow"
        let saved = "\(frame.minX) \(frame.minY) 340 264 0 0 1920 1080"
        defaults.set(saved, forKey: key)
        let controller = WindowController(state: AppState(defaults: defaults), interactive: false)
        controller.start()
        defer { controller.stop() }
        XCTAssertEqual(controller.panel.frame.minX, frame.minX)
        XCTAssertEqual(controller.panel.frame.maxY, frame.maxY)
        XCTAssertEqual(defaults.string(forKey: key), saved)
        XCTAssertFalse(controller.panel.isVisible)
    }

    @MainActor
    func testNativeWindowsFitExpandedContentAndShrinkWithoutMovingTheirTopEdge() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let name = "usage-monitor-test-native-sizing-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let usage = UsageModel(initial: try fixture())
        let state = AppState(defaults: defaults, usage: usage)
        let controller = WindowController(state: state, interactive: false)
        controller.start()
        defer { controller.stop() }
        let panel = try XCTUnwrap(controller.panel)
        let host = try XCTUnwrap(panel.contentView)
        XCTAssertGreaterThan(panel.frame.height, 264)
        XCTAssertGreaterThanOrEqual(panel.contentLayoutRect.height + 1, host.fittingSize.height)
        let top = panel.frame.maxY
        let expanded = panel.frame.height
        state.setAccountDetails(false)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertLessThan(panel.frame.height, expanded)
        XCTAssertEqual(panel.frame.maxY, top, accuracy: 1)
        state.setAccountDetails(true)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(panel.frame.height, expanded, accuracy: 1)
        XCTAssertEqual(panel.frame.maxY, top, accuracy: 1)
        controller.showSettings()
        let settings = try XCTUnwrap(controller.settingsWindow)
        XCTAssertGreaterThanOrEqual(settings.contentLayoutRect.height + 1, try XCTUnwrap(settings.contentView).fittingSize.height)
        XCTAssertGreaterThan(settings.frame.height, 400)
        XCTAssertFalse(panel.isVisible); XCTAssertFalse(settings.isVisible)
    }

    @MainActor
    func testOptionalHistoryAndObservedCreditUpdates() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("usage-monitor-test-features-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let name = "usage-monitor-test-ui-features-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        func account(_ balance: String) throws -> UsageResponse {
            let text = """
            {"accountId":"fixture","ordinaryUsageAllowed":false,"rateLimits":{"primary":{"usedPercent":100,"windowDurationMins":10080,"resetsAt":2000000000},"credits":{"balance":"\(balance)"}},"rateLimitResetCredits":{"availableCount":3,"credits":[{"id":"a","status":"available","expiresAt":2000000000},{"id":"b","status":"available","expiresAt":2000100000},{"id":"c","status":"available","expiresAt":2000200000}]}}
            """
            return try JSONDecoder().decode(UsageResponse.self, from: Data(text.utf8))
        }
        let first = try account("55050.25")
        let second = try account("54950.25")
        let third = try account("54650.25")
        let counter = ReadCounter()
        let usage = UsageModel(readUsage: {
            await counter.increment()
            let value = await counter.value
            return value == 1 ? first : (value == 2 ? second : third)
        })
        let database = root.appendingPathComponent("private/history.sqlite")
        let history = HistoryModel(storeURL: database, codexHome: root)
        let state = AppState(defaults: defaults, usage: usage, history: history)
        state.start()
        defer { state.stop() }
        for _ in 0..<100 where usage.isRefreshing { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertNil(usage.creditDebit)
        XCTAssertFalse(state.historyEnabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: database.path))
        XCTAssertEqual(usage.refreshInterval, 10)
        usage.refresh()
        for _ in 0..<100 where usage.isRefreshing { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(usage.creditDebit?.amount, 100)
        let firstID = usage.creditDebit?.id
        let card = UsageView(state: state, presentation: .menuBar, changePresentation: {}, close: {}, settings: {})
        let before = try await render(card, name: "account-credit-100", dark: true)
        usage.refresh()
        for _ in 0..<100 where usage.isRefreshing { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(usage.creditDebit?.amount, 300)
        XCTAssertNotEqual(usage.creditDebit?.id, firstID)
        let after = try await render(card, name: "account-credit-300", dark: true)
        XCTAssertEqual(before, after) // The animated debit stays in one fixed slot.
        state.setAnimateCredits(false)
        _ = try await render(card, name: "account-no-animation", dark: false)
        state.setHistoryEnabled(true)
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: database.path) { try await Task.sleep(nanoseconds: 5_000_000) }
        for _ in 0..<100 where history.status.hasPrefix("Recording from") { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.path))
        XCTAssertTrue(defaults.bool(forKey: "usageHistoryEnabled"))
        state.setHistoryEnabled(false)
        XCTAssertFalse(history.enabled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: database.path))
        state.setAccountDetails(false)
        state.setAnimateCredits(false)
        XCTAssertFalse(defaults.bool(forKey: "showAccountDetails"))
        XCTAssertFalse(defaults.bool(forKey: "animateCredits"))
        _ = try await render(HistoryView(state: state), name: "history-off", dark: true)
        var metrics = TokenMetrics(); metrics.input = 123456; metrics.cached = 100000; metrics.output = 2345; metrics.reasoning = 1500
        let chat = ChatContribution(thread: "fixture-chat", title: "A long example chat title for the usage history detail", model: "fixture-model", tokens: metrics, turns: 7, tools: 12)
        let drop = UsageDrop(id: "fixture-drop", bucket: "Weekly", fromUsed: 54, toUsed: 57,
                             intervalStart: Date(timeIntervalSince1970: 1900000000), previousObservation: Date(timeIntervalSince1970: 1900000500),
                             observedAt: Date(timeIntervalSince1970: 1900000505), chats: [chat])
        let previewHistory = HistoryModel(storeURL: database, codexHome: root, initial: HistorySnapshot(drops: [drop], note: "Synthetic activity preview"))
        let previewState = AppState(defaults: defaults, history: previewHistory)
        _ = try await render(HistoryView(state: previewState), name: "history-detail", dark: true)
    }

    @MainActor
    func testSubscriptionRefreshClearsOnSignOutAndAccountSwitch() async throws {
        let first = try JSONDecoder().decode(UsageResponse.self, from: Data(#"{"accountId":"first"}"#.utf8))
        let second = try JSONDecoder().decode(UsageResponse.self, from: Data(#"{"accountId":"second"}"#.utf8))
        let renewal = SubscriptionRenewal(date: Date(timeIntervalSince1970: 2000000000))
        let reads = ReadCounter()
        let usage = UsageModel(readUsage: {
            await reads.increment()
            let n = await reads.value
            if n == 2 { throw UsageReadError.signInRequired }
            return n == 4 ? second : first
        }, readSubscription: { $0 == "first" ? renewal : nil })
        defer { usage.stop() }
        for expected in [renewal, nil, renewal, nil] {
            usage.refresh()
            for _ in 0..<100 where usage.isRefreshing { try await Task.sleep(nanoseconds: 5_000_000) }
            XCTAssertFalse(usage.isRefreshing)
            XCTAssertEqual(usage.subscription, expected)
        }
    }

    @MainActor
    func testSubscriptionSectionFitsFloatingWindowAndMenuBar() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let name = "usage-monitor-test-subscription-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let now = Date(timeIntervalSince1970: 1899900000)
        let renewal = SubscriptionRenewal(date: now.addingTimeInterval(600000), lastChecked: now.addingTimeInterval(-86400))
        let usage = UsageModel(initial: try fixture(), lastUpdated: now, now: now, subscription: renewal)
        let state = AppState(defaults: defaults, usage: usage)
        for presentation in [UsagePresentation.floating, .menuBar] {
            let content = UsageView(state: state, presentation: presentation, changePresentation: {}, close: {}, settings: {})
                .environment(\.colorScheme, .dark)
            let size = try await render(content, name: "subscription-\(presentation.rawValue)", dark: true)
            XCTAssertLessThan(size.height, 700)
            XCTAssertEqual(size.width, presentation == .floating ? 340 : 360, accuracy: 1)
        }
        _ = try await render(SubscriptionView(subscription: renewal, now: renewal.date.addingTimeInterval(1), compact: true)
                                .frame(width: 360, height: 220, alignment: .topLeading),
                             name: "subscription-overdue", dark: false)
        let controller = WindowController(state: state, interactive: false)
        controller.start()
        defer { controller.stop() }
        let panel = try XCTUnwrap(controller.panel)
        XCTAssertGreaterThanOrEqual(panel.contentLayoutRect.height + 1, try XCTUnwrap(panel.contentView).fittingSize.height)
        XCTAssertFalse(panel.isVisible)
    }

    @MainActor
    func testOffscreenCardsAndSettings() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let name = "usage-monitor-test-ui-render-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let now = Date(timeIntervalSince1970: 1899900000)
        let response = try fixture()
        let longResponse = try JSONDecoder().decode(UsageResponse.self, from: Data(#"{"rateLimitsByLimitId":{"extended":{"limitName":"A much longer allowance name that must remain accessible","primary":{"usedPercent":86.5,"windowDurationMins":300,"resetsAt":1900000000},"secondary":{"usedPercent":14,"windowDurationMins":10080,"resetsAt":1900200000}}}}"#.utf8))
        let cases: [(String, UsageResponse?, Date?, String?)] = [
            ("fresh", response, now, nil),
            ("empty", nil, now, nil),
            ("loading", nil, nil, nil),
            ("stale", response, now.addingTimeInterval(-600), nil),
            ("error", response, now.addingTimeInterval(-600), "The connection is unavailable. Last known usage is retained while Codex reconnects; this deliberately long message must not displace the controls."),
            ("long-text", longResponse, now, nil)
        ]
        var expectedSize: NSSize?
        for (label, value, updated, error) in cases {
            for scheme in [ColorScheme.light, .dark] {
                let usage = UsageModel(initial: value, lastUpdated: updated, error: error,
                                       refreshing: label == "loading", now: now)
                let state = AppState(defaults: defaults, usage: usage)
                let content = UsageView(state: state, presentation: .menuBar, changePresentation: {}, close: {}, settings: {})
                    .environment(\.colorScheme, scheme)
                    .dynamicTypeSize(label == "long-text" ? .accessibility2 : .large)
                let size = try await render(content, name: "\(label)-\(scheme)", dark: scheme == .dark,
                                            contrast: label == "long-text")
                XCTAssertEqual(size.width, 360, accuracy: 1)
                if let expectedSize { XCTAssertEqual(size.height, expectedSize.height, accuracy: 1) }
                else { expectedSize = size }
            }
        }
        for access in [AppAccess.defaults, AppAccess(menuBar: false, dock: true), AppAccess(menuBar: true, dock: true)] {
            let state = AppState(defaults: defaults)
            state.setAccess(menuBar: access.menuBar, dock: access.dock)
            _ = try await render(SettingsView(state: state), name: "settings-\(access.menuBar)-\(access.dock)", dark: false)
        }
    }

    @MainActor
    private func render<V: View>(_ content: V, name: String, dark: Bool, contrast: Bool = false) async throws -> NSSize {
        let host = NSHostingView(rootView: content.background(Color(nsColor: .windowBackgroundColor)))
        let appearance: NSAppearance.Name = contrast
            ? (dark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua)
            : (dark ? .darkAqua : .aqua)
        host.appearance = NSAppearance(named: appearance)
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = host.appearance
        window.contentView = host
        defer { window.contentView = nil; window.close() }
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 50_000_000)
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            XCTFail("No offscreen bitmap"); return size
        }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertFalse(window.isVisible)
        XCTAssertGreaterThan(bitmap.pixelsHigh, 200)
        if let directory = ProcessInfo.processInfo.environment["CODEX_USAGE_RENDER_OUTPUT"] {
            let target = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
            try bitmap.representation(using: .png, properties: [:])?.write(to: target.appendingPathComponent(name + ".png"))
        }
        return size
    }
}
