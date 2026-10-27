import XCTest
import AppKit
@testable import CodexUsageMonitor
@testable import UsageCore

@MainActor
private final class FakeAccessDriver: AppAccessDriving {
    var actualAccess: AppAccess
    var failMenu = false
    var failDockOn = false
    var failDockOff = false
    var operations: [String] = []
    var removedLastEntry = false
    init(_ initial: AppAccess) { actualAccess = initial }
    func installMenuBar() {
        operations.append("menu-on")
        if !failMenu { actualAccess.menuBar = true }
    }
    func setDockVisible(_ visible: Bool) {
        operations.append(visible ? "dock-on" : "dock-off")
        if visible ? failDockOn : failDockOff { return }
        actualAccess.dock = visible
        if !visible && !actualAccess.valid { removedLastEntry = true }
    }
    func removeMenuBar() {
        operations.append("menu-off"); actualAccess.menuBar = false
        if !actualAccess.valid { removedLastEntry = true }
    }
}

final class AccessTransitionTests: XCTestCase {
    private let menu = AppAccess(menuBar: true, dock: false)
    private let dock = AppAccess(menuBar: false, dock: true)
    private let both = AppAccess(menuBar: true, dock: true)

    @MainActor
    func testEverySuccessfulTransitionPreservesAnEntryAndOrdersReplacementFirst() {
        for initial in [menu, dock, both] {
            for requested in [menu, dock, both] {
                let driver = FakeAccessDriver(initial)
                let result = AccessTransition.apply(requested, using: driver)
                XCTAssertEqual(result.actual, requested)
                XCTAssertNil(result.error)
                XCTAssertFalse(driver.removedLastEntry)
                if initial == menu && requested == dock { XCTAssertEqual(driver.operations, ["dock-on", "menu-off"]) }
                if initial == dock && requested == menu { XCTAssertEqual(driver.operations, ["menu-on", "dock-off"]) }
            }
        }
    }

    @MainActor
    func testAlreadyActiveDockPolicyIsSuccessWithoutCallingItsSetter() {
        let driver = FakeAccessDriver(dock)
        driver.failDockOn = true // A native setter may return false for an existing policy.
        let result = AccessTransition.apply(dock, using: driver)
        XCTAssertEqual(result.actual, dock)
        XCTAssertNil(result.error)
        XCTAssertTrue(driver.operations.isEmpty)
    }

    @MainActor
    func testFailedReplacementsKeepActualModeAndSavedPreferences() {
        for initial in [menu, dock] {
            let name = "usage-monitor-test-access-failure-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            initial.save(to: defaults)
            let state = AppState(defaults: defaults)
            let driver = FakeAccessDriver(initial)
            driver.failDockOn = true; driver.failMenu = true
            state.applyAccess = { AccessTransition.apply($0, using: driver) }
            let requested = initial == menu ? dock : menu
            XCTAssertFalse(state.setAccess(menuBar: requested.menuBar, dock: requested.dock))
            XCTAssertEqual(state.access, initial)
            XCTAssertEqual(AppAccess.load(from: defaults), initial)
            XCTAssertNotNil(state.accessError)
            XCTAssertFalse(driver.removedLastEntry)
            XCTAssertFalse(driver.operations.contains("menu-off"))
            XCTAssertFalse(driver.operations.contains("dock-off"))
        }
    }

    @MainActor
    func testFailedRemovalReportsVerifiedBothModeAndCanRecover() {
        let name = "usage-monitor-test-access-recovery-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        dock.save(to: defaults)
        let state = AppState(defaults: defaults)
        let driver = FakeAccessDriver(dock); driver.failDockOff = true
        state.applyAccess = { AccessTransition.apply($0, using: driver) }
        XCTAssertFalse(state.setAccess(menuBar: true, dock: false))
        XCTAssertEqual(state.access, both)
        XCTAssertEqual(AppAccess.load(from: defaults), both)
        XCTAssertNotNil(state.accessError)
        driver.failDockOff = false
        XCTAssertTrue(state.setAccess(menuBar: true, dock: false))
        XCTAssertEqual(state.access, menu)
        XCTAssertEqual(AppAccess.load(from: defaults), menu)
        XCTAssertNil(state.accessError)
        XCTAssertFalse(driver.removedLastEntry)
    }

    @MainActor
    func testCompleteNativeFailureShowsUnhideableRecoveryWindowAndKeepsSavedMode() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let name = "usage-monitor-test-access-unavailable-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        menu.save(to: defaults); defaults.set("menuBar", forKey: "presentationMode")
        let driver = FakeAccessDriver(AppAccess(menuBar: false, dock: false))
        driver.failMenu = true; driver.failDockOn = true
        let state = AppState(defaults: defaults)
        let windows = WindowController(state: state, interactive: false, accessDriver: driver)
        windows.start(background: true)
        defer { windows.stop() }
        XCTAssertFalse(state.access.valid)
        XCTAssertNotNil(state.accessError)
        XCTAssertEqual(AppAccess.load(from: defaults), menu)
        XCTAssertTrue(state.presentation.mainVisible)
        windows.hideMain()
        XCTAssertTrue(state.presentation.mainVisible)
    }

    @MainActor
    func testUnavailableMenuAtStartupFallsBackToVerifiedDock() {
        let driver = FakeAccessDriver(AppAccess(menuBar: false, dock: false)); driver.failMenu = true
        let result = AccessTransition.apply(menu, using: driver)
        XCTAssertEqual(result.actual, dock)
        XCTAssertNotNil(result.error)
        XCTAssertFalse(driver.removedLastEntry)
    }
}
