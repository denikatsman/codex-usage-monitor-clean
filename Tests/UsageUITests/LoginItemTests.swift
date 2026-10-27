import XCTest
import AppKit
@testable import CodexUsageMonitor
@testable import UsageCore

@MainActor
private final class FakeLoginService: LoginItemServicing {
    var status: LoginItemState = .off
    var registerCalls = 0
    var unregisterCalls = 0
    var settingsCalls = 0
    var fail = false
    func register() throws {
        registerCalls += 1
        if fail { throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Registration failed"]) }
        status = .enabled
    }
    func unregister() async throws {
        unregisterCalls += 1
        if fail { throw NSError(domain: "test", code: 2, userInfo: [NSLocalizedDescriptionKey: "Removal failed"]) }
        status = .off
    }
    func openSettings() { settingsCalls += 1 }
}

final class LoginItemTests: XCTestCase {
    @MainActor
    func testOrdinaryStartAndNewModelKeepExternalRemovalOrDenial() {
        for status in [LoginItemState.off, .requiresApproval] {
            let service = FakeLoginService(); service.status = status
            let first = LoginItemModel(service: service)
            first.start(); first.start(); first.refresh(); first.stop()
            let relaunched = LoginItemModel(service: service)
            relaunched.start(); relaunched.refresh(); relaunched.stop()
            XCTAssertEqual(relaunched.status, status)
            XCTAssertEqual(service.registerCalls, 0)
            XCTAssertEqual(service.unregisterCalls, 0)
        }
    }

    @MainActor
    func testToggleUsesSystemRegistrationAndAvoidsDuplicateOperations() async {
        let service = FakeLoginService()
        let model = LoginItemModel(service: service)
        XCTAssertFalse(model.isEnabled)
        await model.setEnabled(true)
        XCTAssertTrue(model.isEnabled)
        await model.setEnabled(true)
        XCTAssertEqual(service.registerCalls, 1)
        await model.setEnabled(false)
        XCTAssertFalse(model.isEnabled)
        await model.setEnabled(false)
        XCTAssertEqual(service.unregisterCalls, 1)
        XCTAssertFalse(model.isChanging)
    }

    @MainActor
    func testMacOSDenialAndExternalChangesAreRespected() async {
        let service = FakeLoginService()
        service.status = .enabled
        let model = LoginItemModel(service: service)
        service.status = .requiresApproval // User switches it off in macOS Settings.
        model.refresh()
        XCTAssertFalse(model.isEnabled)
        XCTAssertTrue(model.explanation.contains("macOS"))
        await model.setEnabled(true)
        XCTAssertEqual(service.registerCalls, 0)
        model.openSettings()
        XCTAssertEqual(service.settingsCalls, 1)
        service.status = .enabled
        model.refresh()
        XCTAssertTrue(model.isEnabled)
        service.status = .off
        model.refresh()
        XCTAssertFalse(model.isEnabled)
        XCTAssertEqual(service.registerCalls, 0)
    }

    @MainActor
    func testFailuresShowActualStateWithoutLeavingToggleBusy() async {
        let service = FakeLoginService()
        let model = LoginItemModel(service: service)
        service.fail = true
        await model.setEnabled(true)
        XCTAssertFalse(model.isEnabled)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isChanging)
        service.status = .enabled
        await model.setEnabled(false)
        XCTAssertTrue(model.isEnabled)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertFalse(model.isChanging)
    }

    @MainActor
    func testHiddenFloatingWindowKeepsOneMonitoringSchedule() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let name = "usage-monitor-test-hidden-monitor-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let response = try JSONDecoder().decode(UsageResponse.self, from: Data(#"{"rateLimits":{"primary":{"usedPercent":10,"resetsAt":2000000000}}}"#.utf8))
        let counter = ReadCounter()
        let usage = UsageModel(readUsage: { await counter.increment(); return response })
        let state = AppState(defaults: defaults, usage: usage, loginItem: LoginItemModel(service: FakeLoginService()))
        let windows = WindowController(state: state, interactive: false)
        windows.start(); state.start()
        defer { windows.stop(); state.stop() }
        for _ in 0..<100 where usage.isRefreshing { try await Task.sleep(nanoseconds: 5_000_000) }
        windows.hideMain()
        XCTAssertTrue(state.access.menuBar)
        XCTAssertFalse(state.presentation.mainVisible)
        usage.refresh()
        for _ in 0..<100 where usage.isRefreshing { try await Task.sleep(nanoseconds: 5_000_000) }
        let reads = await counter.value
        XCTAssertEqual(reads, 2)
        XCTAssertTrue(usage.isStarted)
        XCTAssertEqual(usage.scheduleStarts, 1)
        XCTAssertFalse(windows.panel.isVisible)
    }
}
