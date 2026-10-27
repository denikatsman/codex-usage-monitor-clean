import XCTest
import AppKit
import SwiftUI
@testable import UsageCore
@testable import CodexUsageMonitor

final class UsageAnalysisViewTests: XCTestCase {
    @MainActor
    func testAnalysisPagesFitMinimumWindowInBothAppearances() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let suite = "usage-monitor-analysis-view-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        var tokens = TokenMetrics()
        tokens.input = 123456; tokens.cached = 100000; tokens.cacheWrite = 3200
        tokens.output = 9876; tokens.reasoning = 5000
        let date = Date(timeIntervalSince1970: 1900000000)
        let segment = ActivitySegment(id: "segment", threadID: "fixture-chat", title: "Reviewing a long-running project with multiple agents", project: "/Users/example/GitHub/fixture-project", parentThreadID: "parent-chat", agentPath: "/root/review", turnID: "fixture-turn", model: "gpt-fixture", effort: "high", speed: "standard", tokens: tokens, completedTurns: 2, toolCalls: 14, firstAt: date.addingTimeInterval(5), lastAt: date.addingTimeInterval(55), turnDurationSeconds: 50, provenance: ["rollout:fixture.jsonl:42:turn_context.model", "request:fixture-turn:service_tier=default"])
        let interval = UsageInterval(id: "closed", meterID: "weekly", title: "Weekly", plan: "Pro", resetAt: date.addingTimeInterval(604800), epoch: "fixture", startAt: date, endAt: date.addingTimeInterval(60), previousObservationAt: date.addingTimeInterval(45), fromUsed: 59, toUsed: 60, isBaseline: false, segments: [segment], isCalibrationEligible: true, totals: tokens, durationSeconds: 60)
        let summary = CalibrationSummary(id: "calibration", meterID: "weekly", title: "Weekly", plan: "Pro", model: "gpt-fixture", effort: "high", speed: "standard", sampleCount: 3, totalPoints: 3, medianTokensPerPoint: 133332, lowerTokensPerPoint: 115000, upperTokensPerPoint: 160000, inputPerPoint: 123456, cachedPerPoint: 100000, outputPerPoint: 9876, reasoningPerPoint: 5000, cacheWritePerPoint: 3200)
        let snapshot = AnalysisSnapshot(intervals: [interval], calibration: [summary], generatedAt: date.addingTimeInterval(60))
        let history = HistoryModel(storeURL: root.appendingPathComponent("history.sqlite"), codexHome: root, initial: HistorySnapshot(drops: [], note: "Synthetic analysis preview", analysis: snapshot))
        let state = AppState(defaults: defaults, history: history)
        defer { state.usage.stop(); history.stop() }
        for dark in [true, false] {
            for page in [0, 1] {
                let host = NSHostingView(rootView: HistoryView(state: state, initialPage: page)
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .background(Color(nsColor: .windowBackgroundColor)))
                host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let size = NSSize(width: 760, height: 500)
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = host.appearance
                window.contentView = host
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(nanoseconds: 100_000_000)
                XCTAssertEqual(host.frame.width, 760, accuracy: 1)
                XCTAssertEqual(host.frame.height, 500, accuracy: 1)
                XCTAssertFalse(window.isVisible)
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                XCTAssertGreaterThan(bitmap.pixelsWide, 700)
                if let directory = ProcessInfo.processInfo.environment["CODEX_USAGE_RENDER_OUTPUT"] {
                    let target = URL(fileURLWithPath: directory, isDirectory: true)
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
                    let image = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    try image.write(to: target.appendingPathComponent("analysis-\(page == 0 ? "interval" : "calibration")-\(dark ? "dark" : "light").png"))
                }
                window.contentView = nil
                window.close()
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }
}
