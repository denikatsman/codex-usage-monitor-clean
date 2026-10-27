import XCTest
@testable import UsageCore

final class TurnContextResolverTests: XCTestCase {
    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("turn-resolver-" + UUID().uuidString)
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        var path: String { root.appendingPathComponent("source.jsonl").path }
        init(thread: String = "own", birth: Double = 0, payloadBirth: Double? = nil) throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data().write(to: URL(fileURLWithPath: path))
            var metadata: [String: Any] = ["id": thread]
            if let payloadBirth {
                let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                metadata["timestamp"] = formatter.string(from: start.addingTimeInterval(payloadBirth))
            }
            _ = try append(type: "session_meta", payload: metadata, seconds: birth)
        }
        deinit { try? FileManager.default.removeItem(at: root) }
        @discardableResult
        func append(type: String, payload: [String: Any], seconds: Double) throws -> UInt64 {
            let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var bytes = try JSONSerialization.data(withJSONObject: ["type": type, "timestamp": formatter.string(from: start.addingTimeInterval(seconds)), "payload": payload])
            bytes.append(10)
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path)); defer { try? handle.close() }
            let offset = try handle.seekToEnd(); try handle.write(contentsOf: bytes); return offset
        }
        func context(_ payload: [String: Any], seconds: Double) throws -> UInt64 {
            try append(type: "turn_context", payload: payload, seconds: seconds)
        }
        func event(seconds: Double = 10) throws -> UInt64 {
            try append(type: "event_msg", payload: ["type": "token_count"], seconds: seconds)
        }
        func resolve(_ resolver: TurnContextResolver, offset: UInt64, turn: String? = nil, created: Double? = nil) throws -> ResolvedTurnContext {
            try resolver.resolve(path: path, threadID: "own", eventOffset: offset, eventAt: start.addingTimeInterval(10),
                                 explicitTurnID: turn, createdAt: created.map { start.addingTimeInterval($0) })
        }
    }

    func testRecoversOwnContextAcrossHalfAndSixMegabyteDistances() throws {
        for count in [512 * 1024, 6 * 1024 * 1024] {
            let f = try Fixture()
            let expected = try f.context(["model": "child-model", "effort": "high", "turn_id": "child", "root_turn_id": "parent"], seconds: 1)
            _ = try f.append(type: "response_item", payload: ["type": "message", "content": String(repeating: "x", count: count)], seconds: 2)
            let offset = try f.event()
            let result = try f.resolve(TurnContextResolver(codexHome: f.root), offset: offset)
            XCTAssertEqual(result.model, "child-model"); XCTAssertEqual(result.effort, "high")
            XCTAssertEqual(result.turnID, "child"); XCTAssertEqual(result.contextOffset, expected)
            XCTAssertTrue(result.issues.isEmpty)
            XCTAssertFalse(result.references.joined().contains(String(repeating: "x", count: 100)))
        }
    }

    func testDelayedExplicitTurnUsesThatTurnsConfiguration() throws {
        let f = try Fixture()
        _ = try f.context(["model": "model-a", "effort": "low", "turn_id": "a"], seconds: 1)
        _ = try f.context(["model": "model-b", "effort": "ultra", "turn_id": "b"], seconds: 2)
        let offset = try f.event()
        let result = try f.resolve(TurnContextResolver(codexHome: f.root), offset: offset, turn: "a")
        XCTAssertEqual(result.model, "model-a"); XCTAssertEqual(result.effort, "low"); XCTAssertEqual(result.turnID, "a")
    }

    func testSparseSameTurnMergesButDifferentTurnDoesNot() throws {
        let f = try Fixture()
        _ = try f.context(["model": "model-a", "turn_id": "a"], seconds: 1)
        let latest = try f.context(["effort": "high", "turn_id": "a"], seconds: 2)
        let first = try f.event()
        let resolver = TurnContextResolver(codexHome: f.root)
        let merged = try f.resolve(resolver, offset: first)
        XCTAssertEqual(merged.model, "model-a"); XCTAssertEqual(merged.effort, "high")
        XCTAssertEqual(merged.contextOffset, latest); XCTAssertEqual(merged.references.filter { $0.hasSuffix(":turn_context") }.count, 2)
        _ = try f.context(["model": "model-b", "turn_id": "b"], seconds: 3)
        let second = try f.event()
        let separate = try f.resolve(resolver, offset: second)
        XCTAssertEqual(separate.model, "model-b"); XCTAssertNil(separate.effort)
        XCTAssertTrue(separate.issues.contains { $0.contains("incomplete") })
    }

    func testInheritedParentContextDoesNotEstablishChildConfiguration() throws {
        let f = try Fixture(birth: 2)
        _ = try f.context(["model": "parent-model", "effort": "ultra", "turn_id": "parent"], seconds: 1)
        let offset = try f.event()
        let resolver = TurnContextResolver(codexHome: f.root)
        let missing = try f.resolve(resolver, offset: offset, created: 2)
        XCTAssertNil(missing.model); XCTAssertNil(missing.effort)
        _ = try f.context(["model": "child-model", "effort": "high", "turn_id": "child"], seconds: 3)
        let next = try f.event()
        let child = try f.resolve(resolver, offset: next, created: 2)
        XCTAssertEqual(child.model, "child-model"); XCTAssertEqual(child.effort, "high")
    }

    func testMismatchingHeaderAndMissingExplicitTurnStayUnresolved() throws {
        let wrong = try Fixture(thread: "another-thread")
        _ = try wrong.context(["model": "wrong", "effort": "high", "turn_id": "a"], seconds: 1)
        let wrongOffset = try wrong.event()
        let result = try wrong.resolve(TurnContextResolver(codexHome: wrong.root), offset: wrongOffset)
        XCTAssertNil(result.model); XCTAssertTrue(result.issues.contains { $0.contains("identity") })
        let f = try Fixture()
        _ = try f.context(["model": "model-a", "effort": "high", "turn_id": "a"], seconds: 1)
        let offset = try f.event()
        let absent = try f.resolve(TurnContextResolver(codexHome: f.root), offset: offset, turn: "missing")
        XCTAssertNil(absent.model); XCTAssertEqual(absent.turnID, "missing")
    }

    func testNativeOffsetIsValidatedAndWrongResumedFileOffsetFallsBack() throws {
        let f = try Fixture()
        let start = try f.append(type: "event_msg", payload: ["type": "task_started", "turn_id": "a"], seconds: 1)
        _ = try f.context(["model": "model-a", "effort": "high", "turn_id": "a"], seconds: 2)
        let offset = try f.event()
        let db = try HistoryDatabase(url: f.root.appendingPathComponent("thread_history_1.sqlite"))
        try db.run("CREATE TABLE thread_turns(thread_id TEXT,turn_id TEXT,started_at REAL,rollout_byte_offset INTEGER)")
        try db.run("INSERT INTO thread_turns VALUES(?,?,?,?)", ["own", "a", String(f.start.timeIntervalSince1970 + 1), String(start)])
        let indexed = try f.resolve(TurnContextResolver(codexHome: f.root), offset: offset, turn: "a")
        XCTAssertEqual(indexed.model, "model-a")
        XCTAssertTrue(indexed.references.contains { $0.contains("thread_turns") })
        try db.run("UPDATE thread_turns SET rollout_byte_offset=1")
        let fallback = try f.resolve(TurnContextResolver(codexHome: f.root), offset: offset, turn: "a")
        XCTAssertEqual(fallback.model, "model-a")
        XCTAssertFalse(fallback.references.contains { $0.contains("thread_turns") })
    }

    func testSameLengthReplacementInvalidatesCachedConfiguration() throws {
        let f = try Fixture()
        _ = try f.context(["model": "model-a", "effort": "high", "turn_id": "a"], seconds: 1)
        let offset = try f.event()
        let resolver = TurnContextResolver(codexHome: f.root)
        XCTAssertEqual(try f.resolve(resolver, offset: offset).model, "model-a")
        let url = URL(fileURLWithPath: f.path)
        let original = try String(contentsOf: url, encoding: .utf8)
        let replacement = original.replacingOccurrences(of: "model-a", with: "model-b")
        try Data(replacement.utf8).write(to: url, options: .atomic)
        XCTAssertEqual(try f.resolve(resolver, offset: offset).model, "model-b")
    }

    func testAppendedEventsReuseScannedRangeAndObserveLaterSameTurnOverrides() throws {
        let f = try Fixture()
        _ = try f.context(["model": "model-a", "effort": "high", "turn_id": "a"], seconds: 1)
        _ = try f.append(type: "response_item", payload: ["type": "message", "content": String(repeating: "x", count: 6 * 1024 * 1024)], seconds: 2)
        let first = try f.event()
        let resolver = TurnContextResolver(codexHome: f.root)
        XCTAssertEqual(try f.resolve(resolver, offset: first).model, "model-a")
        let initialReads = resolver.sourceBytesRead
        for index in 0..<40 {
            if index == 20 {
                _ = try f.context(["model": "model-b", "effort": "low", "turn_id": "a"], seconds: 3)
            }
            let offset = try f.event()
            let result = try f.resolve(resolver, offset: offset)
            XCTAssertEqual(result.model, index < 20 ? "model-a" : "model-b")
            XCTAssertEqual(result.effort, index < 20 ? "high" : "low")
        }
        // Count bytes rather than asserting a machine-dependent execution deadline.
        XCTAssertLessThan(resolver.sourceBytesRead - initialReads, 2 * 1024 * 1024)
    }

    func testTaskStartedBlocksPreviousTurnConfigurationIncludingCachedRanges() throws {
        let f = try Fixture()
        _ = try f.context(["model": "model-a", "effort": "high", "turn_id": "a"], seconds: 1)
        let first = try f.event()
        let resolver = TurnContextResolver(codexHome: f.root)
        XCTAssertEqual(try f.resolve(resolver, offset: first).model, "model-a")
        _ = try f.append(type: "event_msg", payload: ["type": "task_started", "turn_id": "b"], seconds: 2)
        let next = try f.event()
        for collector in [resolver, TurnContextResolver(codexHome: f.root)] {
            let unresolved = try f.resolve(collector, offset: next)
            XCTAssertEqual(unresolved.turnID, "b")
            XCTAssertNil(unresolved.model); XCTAssertNil(unresolved.effort)
            let delayed = try f.resolve(collector, offset: next, turn: "a")
            XCTAssertEqual(delayed.model, "model-a"); XCTAssertEqual(delayed.effort, "high")
        }
        _ = try f.context(["model": "model-b", "effort": "low", "turn_id": "b"], seconds: 3)
        let last = try f.event()
        XCTAssertEqual(try f.resolve(resolver, offset: last).model, "model-b")
    }

    func testExplicitNullAndEmptyValuesAreSameTurnPresenceBarriers() throws {
        for value in [NSNull(), "", "   "] as [Any] {
            let f = try Fixture()
            _ = try f.context(["model": "model-a", "effort": "high", "turn_id": "a"], seconds: 1)
            _ = try f.context(["model": value, "effort": value, "reasoning_effort": "ultra", "turn_id": "a"], seconds: 2)
            let offset = try f.event()
            let result = try f.resolve(TurnContextResolver(codexHome: f.root), offset: offset)
            XCTAssertEqual(result.turnID, "a")
            XCTAssertNil(result.model); XCTAssertNil(result.effort)
            XCTAssertTrue(result.issues.contains { $0.contains("incomplete") })
        }
    }

    func testOwnSourceBirthOverridesNewerResumedIndexCreation() throws {
        for payloadBirth in [nil, 0] as [Double?] {
            let f = try Fixture(birth: payloadBirth == nil ? 0 : 5, payloadBirth: payloadBirth)
            _ = try f.context(["model": "original-model", "effort": "high", "turn_id": "original-turn"], seconds: 1)
            let offset = try f.event()
            let result = try f.resolve(TurnContextResolver(codexHome: f.root), offset: offset, created: 60)
            XCTAssertEqual(result.model, "original-model"); XCTAssertEqual(result.effort, "high")
            XCTAssertTrue(result.references.contains { $0.contains(payloadBirth == nil ? "session_meta.timestamp" : "session_meta.payload.timestamp") })
        }
    }

    func testChildOwnPayloadBirthStillExcludesCopiedParentContext() throws {
        let f = try Fixture(birth: 0, payloadBirth: 2)
        _ = try f.context(["model": "parent-model", "effort": "ultra", "turn_id": "parent"], seconds: 1)
        let offset = try f.event()
        let result = try f.resolve(TurnContextResolver(codexHome: f.root), offset: offset, created: 0)
        XCTAssertNil(result.model); XCTAssertNil(result.effort)
    }

    func testCancellationIsPropagated() async throws {
        let f = try Fixture()
        let offset = try f.event()
        let task = Task {
            while !Task.isCancelled { await Task.yield() }
            return try f.resolve(TurnContextResolver(codexHome: f.root), offset: offset)
        }
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch is CancellationError { }
    }
}
