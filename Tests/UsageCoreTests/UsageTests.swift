import XCTest
@testable import UsageCore

final class UsageTests: XCTestCase {
    func testDaysCountdownUsesElapsed24HourDaysAndRollsOverAtZero() {
        let now = Date(timeIntervalSince1970: 1000)
        let cases: [(TimeInterval, String)] = [
            (281554, "3d 06h 12m 34s"), (86399, "0d 23h 59m 59s"),
            (86400, "1d 00h 00m 00s"), (86400.1, "1d 00h 00m 01s"),
            (0.4, "0d 00h 00m 01s"), (0, "0d 00h 00m 00s"), (-1, "0d 00h 00m 00s")
        ]
        for (interval, expected) in cases {
            XCTAssertEqual(UsageFormatting.countdown(to: now.addingTimeInterval(interval), from: now, format: .days), expected)
        }
        XCTAssertEqual(UsageFormatting.countdown(to: now.addingTimeInterval(281554), from: now), "78h 12m 34s")
        XCTAssertEqual(UsageFormatting.countdown(to: Date(timeIntervalSince1970: .infinity), from: now, format: .days), "—")
    }

    func testDaysAreElapsedHoursAcrossDaylightSavingChange() throws {
        let iso = ISO8601DateFormatter()
        let start = try XCTUnwrap(iso.date(from: "2026-10-24T12:00:00+02:00"))
        let end = try XCTUnwrap(iso.date(from: "2026-10-25T12:00:00+01:00"))
        XCTAssertEqual(UsageFormatting.countdown(to: end, from: start, format: .days), "1d 01h 00m 00s")
    }

    private func decode(_ json: String) throws -> UsageResponse {
        try JSONDecoder().decode(UsageResponse.self, from: Data(json.utf8))
    }

    func testWeeklyPrimaryDoesNotInventFiveHourWindow() throws {
        let response = try decode(#"{"rateLimits":{"primary":{"usedPercent":43,"windowDurationMins":10080,"resetsAt":1900000000},"secondary":null}}"#)
        XCTAssertEqual(response.rows.count, 1)
        XCTAssertEqual(response.rows[0].title, "Weekly")
        XCTAssertEqual(response.rows[0].window.remainingPercent, 57)
        XCTAssertEqual(response.rows[0].window.resetDate?.timeIntervalSince1970, 1900000000)
    }

    func testAllBucketsPreferCurrentMultiBucketView() throws {
        let response = try decode(#"""
        {"rateLimits":{"primary":{"usedPercent":99}},"rateLimitsByLimitId":{
          "codex_other":{"limitName":"Extra","primary":{"usedPercent":20,"windowDurationMins":60}},
          "codex":{"primary":{"usedPercent":10,"windowDurationMins":300},"secondary":{"usedPercent":30,"windowDurationMins":10080}}
        }}
        """#)
        XCTAssertEqual(response.rows.map(\.title), ["5-hour", "Weekly", "Extra · 1-hour"])
        XCTAssertEqual(response.rows.compactMap(\.window.remainingPercent), [90, 70, 80])
        XCTAssertEqual(Set(response.rows.map(\.id)).count, 3)
    }

    func testMissingInformationStaysUnknown() throws {
        let response = try decode(#"{"rateLimits":{"primary":{},"secondary":null},"rateLimitsByLimitId":null}"#)
        XCTAssertEqual(response.rows.count, 1)
        XCTAssertNil(response.rows[0].window.remainingPercent)
        XCTAssertNil(response.rows[0].window.resetDate)
        XCTAssertTrue(try decode(#"{"rateLimits":null}"#).rows.isEmpty)
    }

    func testEmptyMapFallsBackAndPercentsAreClamped() throws {
        let response = try decode(#"{"rateLimits":{"primary":{"usedPercent":103},"secondary":{"usedPercent":-8}},"rateLimitsByLimitId":{}}"#)
        XCTAssertEqual(response.rows.compactMap(\.window.remainingPercent), [0, 100])
        let fractional = try decode(#"{"rateLimits":{"primary":{"usedPercent":43.25}}}"#)
        XCTAssertEqual(fractional.rows[0].window.remainingPercent, 56.75)
    }

    func testCountdownKeepsTotalHoursAndClampsAtZero() {
        let now = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(UsageFormatting.countdown(to: now.addingTimeInterval(176461), from: now), "49h 01m 01s")
        XCTAssertEqual(UsageFormatting.countdown(to: now.addingTimeInterval(0.4), from: now), "00h 00m 01s")
        XCTAssertEqual(UsageFormatting.countdown(to: now.addingTimeInterval(-20), from: now), "00h 00m 00s")
    }

    func testResetBoundaryDoesNotAssumeReplenishment() throws {
        let response = try decode(#"{"rateLimits":{"primary":{"usedPercent":99,"resetsAt":2000}}}"#)
        let window = response.rows[0].window
        XCTAssertFalse(window.isAwaitingReset(at: Date(timeIntervalSince1970: 1999)))
        XCTAssertTrue(window.isAwaitingReset(at: Date(timeIntervalSince1970: 2000)))
        XCTAssertTrue(window.isAwaitingReset(at: Date(timeIntervalSince1970: 9000)))
        XCTAssertEqual(window.remainingPercent, 1)
    }

    func testResetDateIncludesYearSecondsAndCorrectDSTOffset() {
        let zone = TimeZone(identifier: "Europe/Zurich")!
        let iso = ISO8601DateFormatter()
        let summer = UsageFormatting.resetDate(iso.date(from: "2026-07-01T12:34:56Z")!, timeZone: zone)
        let winter = UsageFormatting.resetDate(iso.date(from: "2026-12-01T12:34:56Z")!, timeZone: zone)
        XCTAssertTrue(summer.contains("2026 · 14:34:56"), summer)
        XCTAssertTrue(winter.contains("2026 · 13:34:56"), winter)
        XCTAssertTrue(summer.contains("CEST") || summer.contains("GMT+2"), summer)
        XCTAssertTrue(winter.contains("CET") || winter.contains("GMT+1"), winter)
        let utc = UsageFormatting.resetDate(iso.date(from: "2026-12-01T12:34:56Z")!, timeZone: TimeZone(secondsFromGMT: 0)!)
        XCTAssertTrue(utc.contains("12:34:56"), utc) // Cached labels must follow a changed time zone.
    }
}
