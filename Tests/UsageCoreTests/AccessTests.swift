import XCTest
@testable import UsageCore

final class AccessTests: XCTestCase {
    func testAllValidModesPersistAndInvalidModeRecovers() {
        let name = "usage-monitor-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(AppAccess.load(from: defaults), .defaults)
        for value in [AppAccess.defaults, AppAccess(menuBar: false, dock: true), AppAccess(menuBar: true, dock: true)] {
            value.save(to: defaults)
            XCTAssertEqual(AppAccess.load(from: UserDefaults(suiteName: name)!), value)
        }
        defaults.set(false, forKey: "showInMenuBar")
        defaults.set(false, forKey: "showInDock")
        XCTAssertEqual(AppAccess.load(from: defaults), .defaults)
    }

    func testCardNeverChangesMainVisibilityOrSavedPresentation() {
        for saved in [UsagePresentation.floating, .menuBar] {
            var state = PresentationState(saved: saved)
            state.launch(background: true)
            let visible = state.mainVisible
            for _ in 0..<20 {
                state.showCard()
                XCTAssertTrue(state.cardVisible)
                XCTAssertEqual(state.mainVisible, visible)
                XCTAssertEqual(state.saved, saved)
                state.closeCard()
            }
        }
    }

    func testExplicitReopenRestoresHiddenMainAfterBackgroundStart() {
        var state = PresentationState(saved: .menuBar)
        state.launch(background: true)
        XCTAssertFalse(state.mainVisible)
        state.openMain()
        XCTAssertTrue(state.mainVisible)
        state.hideMain()
        state.launch(background: false)
        XCTAssertTrue(state.mainVisible)
    }
}
