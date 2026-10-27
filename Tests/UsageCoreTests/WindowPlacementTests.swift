import XCTest
@testable import UsageCore

final class WindowPlacementTests: XCTestCase {
    private let main = CGRect(x: 0, y: 0, width: 1728, height: 1080)
    private let left = CGRect(x: -1920, y: 0, width: 1920, height: 1080)

    func testRestoresAbsoluteFrameWithoutRemappingToAnotherDisplay() {
        XCTAssertEqual(WindowPlacement.restoredFrame(from: "2846 3391 340 264 2624 0 2160 3810 "),
                       CGRect(x: 2846, y: 3391, width: 340, height: 264))
        XCTAssertEqual(WindowPlacement.restoredFrame(from: "-1600 240 340 264 -1920 0 1920 1080"),
                       CGRect(x: -1600, y: 240, width: 340, height: 264))
    }

    func testInvalidSavedFramesAreIgnored() {
        for saved in ["", "bad 240 340 264", "1 2 0 264", "1 2 -340 264", "nan 2 340 264", "1 inf 340 264"] {
            XCTAssertNil(WindowPlacement.restoredFrame(from: saved), saved)
        }
    }

    func testPreservesPlacementOnLeftMonitorWithNegativeCoordinates() {
        let frame = CGRect(x: -1600, y: 240, width: 340, height: 264)
        XCTAssertEqual(WindowPlacement.recover(frame, on: [main, left]), frame)
    }

    func testPreservesPlacementOnMonitorAboveMain() {
        let upper = CGRect(x: 0, y: 1080, width: 1920, height: 1080)
        let frame = CGRect(x: 480, y: 1440, width: 340, height: 264)
        XCTAssertEqual(WindowPlacement.recover(frame, on: [main, upper]), frame)
    }

    func testAllowsWindowToSpanMonitorBoundary() {
        let frame = CGRect(x: -120, y: 240, width: 340, height: 264)
        XCTAssertEqual(WindowPlacement.recover(frame, on: [main, left]), frame)
    }

    func testRecoversAfterMonitorDisconnects() {
        let frame = CGRect(x: -1600, y: 240, width: 340, height: 264)
        XCTAssertEqual(WindowPlacement.recover(frame, on: [main]), CGRect(x: 0, y: 240, width: 340, height: 264))
    }

    func testVisibleSliverDoesNotPreventRecoveryOfOffscreenDragArea() {
        let frame = CGRect(x: 480, y: -250, width: 340, height: 264)
        XCTAssertEqual(WindowPlacement.recover(frame, on: [main]), CGRect(x: 480, y: 0, width: 340, height: 264))
    }

    func testDoesNotMoveWindowWhileDisplaysAreTemporarilyUnavailable() {
        let frame = CGRect(x: -1600, y: 240, width: 340, height: 264)
        XCTAssertEqual(WindowPlacement.recover(frame, on: []), frame)
    }
}
