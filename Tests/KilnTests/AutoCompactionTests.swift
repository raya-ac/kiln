import XCTest
@testable import Kiln

final class AutoCompactionTests: XCTestCase {
    private let thread = "11111111-1111-4111-8111-111111111111"
    private func context(_ used: Int, window: Int = 1000) -> ContextUsage {
        ContextUsage(usedTokens: used, window: window, modelID: "gpt-5.5", threadID: thread)
    }
    private func jsonl(_ items: [[String: Any]]) throws -> Data {
        var data = Data()
        for item in items { data.append(try JSONSerialization.data(withJSONObject: item)); data.append(10) }
        return data
    }
    private var model: [String: Any] { ["type": "turn_context", "payload": ["model": "gpt-5.5"]] }
    private func tokens(_ used: Int, window: Int = 380_000) -> [String: Any] {
        ["type": "event_msg", "payload": ["type": "token_count", "info": [
            "last_token_usage": ["total_tokens": used],
            "total_token_usage": ["total_tokens": 9_000_000],
            "model_context_window": window,
        ]]]
    }

    func testEnabledByDefaultAndOlderSettingsMigrate() throws {
        XCTAssertTrue(KilnSettings().autoCompactEnabled)
        XCTAssertTrue(try JSONDecoder().decode(KilnSettings.self, from: Data("{}".utf8)).autoCompactEnabled)
        var settings = KilnSettings(); settings.autoCompactEnabled = false
        XCTAssertFalse(try JSONDecoder().decode(KilnSettings.self, from: JSONEncoder().encode(settings)).autoCompactEnabled)
    }

    func testExactNinetyPercentBoundaryAndUnknown() {
        XCTAssertFalse(AutoCompactionPolicy.shouldCompact(enabled: true, context: context(899)))
        XCTAssertTrue(AutoCompactionPolicy.shouldCompact(enabled: true, context: context(900)))
        XCTAssertTrue(AutoCompactionPolicy.shouldCompact(enabled: true, context: context(1200)))
        XCTAssertFalse(AutoCompactionPolicy.shouldCompact(enabled: false, context: context(1200)))
        XCTAssertFalse(AutoCompactionPolicy.shouldCompact(enabled: true, context: nil))
        XCTAssertFalse(AutoCompactionPolicy.shouldCompact(enabled: true, context: context(900, window: 0)))
        XCTAssertFalse(AutoCompactionPolicy.shouldCompact(enabled: true, context: context(-1)))
    }

    func testMeasuredContextPersistsButLegacyTotalsAreNotContext() {
        let message = ChatMessage(role: .assistant, blocks: [.trace([context(900).trace])])
        XCTAssertEqual(AutoCompactionPolicy.lastContext(in: [message], modelID: "gpt-5.5", threadID: thread), context(900))
        XCTAssertNil(AutoCompactionPolicy.lastContext(in: [message], modelID: "gpt-6-astra", threadID: thread))
        XCTAssertNil(AutoCompactionPolicy.lastContext(in: [message], modelID: "gpt-5.5", threadID: "other"))
        let legacy = ChatMessage(role: .assistant, blocks: [.trace([AgentTraceEntry(source: "codex", phase: "usage", title: "Usage", metadata: ["inputTokens": "999999", "outputTokens": "1000"])])])
        XCTAssertNil(AutoCompactionPolicy.lastContext(in: [legacy], modelID: "gpt-5.5", threadID: thread))
        XCTAssertNil(AutoCompactionPolicy.lastContext(in: [message, legacy], modelID: "gpt-5.5", threadID: thread))
    }

    func testLatestRequestAndEffectiveWindowNotAggregateUsage() throws {
        let parsed = CodexContextReader.parse(try jsonl([model, tokens(31_246)]), threadID: thread, modelID: "gpt-5.5")
        XCTAssertEqual(parsed?.usedTokens, 31_246)
        XCTAssertEqual(parsed?.window, 380_000)
        XCTAssertEqual(parsed?.fraction ?? 0, 0.08222631578947369, accuracy: 0.000001)
        XCTAssertFalse(AutoCompactionPolicy.shouldCompact(enabled: true, context: parsed))
    }

    func testCompactionAndModelSwitchInvalidatePreviousContext() throws {
        for marker: [String: Any] in [
            ["type": "compacted", "payload": [:]],
            ["type": "event_msg", "payload": ["type": "context_compacted"]],
            ["type": "turn_context", "payload": ["model": "different"]],
        ] {
            XCTAssertNil(CodexContextReader.parse(try jsonl([model, tokens(360_000), marker]), threadID: thread, modelID: "gpt-5.5"))
        }
        XCTAssertNil(CodexContextReader.parse(try jsonl([tokens(360_000)]), threadID: thread, modelID: "gpt-5.5"))
        XCTAssertNil(CodexContextReader.parse(try jsonl([model, tokens(360_000, window: 0)]), threadID: thread, modelID: "gpt-5.5"))
        XCTAssertNil(CodexContextReader.parse(try jsonl([["type": "session_meta", "payload": ["id": "wrong"]], model, tokens(50)]), threadID: thread, modelID: "gpt-5.5"))
    }

    func testIncompleteWritesAndRateLimitOnlyUpdates() throws {
        var data = try jsonl([model, tokens(100), ["type": "event_msg", "payload": ["type": "token_count", "info": NSNull()]]])
        data.append(Data(#"{"type":"event_msg","payload":"#.utf8))
        XCTAssertEqual(CodexContextReader.parse(data, threadID: thread, modelID: "gpt-5.5")?.usedTokens, 100)
    }

    func testReadsOnlyMatchingRolloutAndSurvivesNewReader() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = home.appendingPathComponent("sessions/2026/09/05")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try jsonl([model, tokens(1234)]).write(to: directory.appendingPathComponent("rollout-test-" + thread + ".jsonl"))
        let reader = CodexContextReader()
        let value = await reader.read(threadID: thread, modelID: "gpt-5.5", home: home)
        XCTAssertEqual(value?.usedTokens, 1234)
        let restored = await CodexContextReader().read(threadID: thread, modelID: "gpt-5.5", home: home)
        XCTAssertEqual(restored, value)
        let invalid = await reader.read(threadID: "../../private", modelID: "gpt-5.5", home: home)
        XCTAssertNil(invalid)
    }

    func testNativeCompactionWaitsForMatchingCompletedTurn() throws {
        var state = CodexCompactionProgress(threadID: thread)
        try state.consume(["method": "turn/started", "params": ["threadId": thread, "turn": ["id": "turn"]]])
        try state.consume(["method": "item/completed", "params": ["threadId": "other", "turnId": "turn", "item": ["type": "contextCompaction"]]])
        XCTAssertFalse(state.compacted)
        try state.consume(["method": "item/completed", "params": ["threadId": thread, "turnId": "turn", "item": ["type": "contextCompaction"]]])
        XCTAssertFalse(state.complete)
        try state.consume(["method": "turn/completed", "params": ["threadId": thread, "turn": ["id": "turn", "status": "completed"]]])
        XCTAssertTrue(state.complete)
        var failed = CodexCompactionProgress(threadID: thread, turnID: "turn")
        XCTAssertThrowsError(try failed.consume(["method": "turn/completed", "params": ["threadId": thread, "turn": ["id": "turn", "status": "failed"]]]))
    }

    func testCompactionArchiveRetainsFullTranscript() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-archive-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var session = Session(workDir: "/tmp", name: "archive test")
        session.messages = [ChatMessage(role: .user, blocks: [.text("keep the original")])]
        try Persistence.saveCompactionArchive(session, directory: directory)
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).first)
        let restored = try XCTUnwrap(Persistence.decodeSessionData(Data(contentsOf: file)))
        XCTAssertEqual(restored.toSession().messages.first?.id, session.messages.first?.id)
    }

    func testOpenCodeUsageCannotAccidentallyTriggerContextCompaction() {
        let events = OpenCodeProtocol.parse(["type": "step_finish", "part": ["tokens": ["input": 900_000, "output": 10]]])
        XCTAssertFalse(events.contains { if case .contextUsage = $0 { return true }; return false })
    }
}
