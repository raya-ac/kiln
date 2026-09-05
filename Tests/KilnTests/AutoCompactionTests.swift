import XCTest
@testable import Kiln

final class AutoCompactionTests: XCTestCase {
    func testEnabledByDefaultAndOlderSettingsMigrate() throws {
        XCTAssertTrue(KilnSettings().autoCompactEnabled)
        XCTAssertTrue(try JSONDecoder().decode(KilnSettings.self, from: Data("{}".utf8)).autoCompactEnabled)
        var settings = KilnSettings()
        settings.autoCompactEnabled = false
        XCTAssertFalse(try JSONDecoder().decode(KilnSettings.self, from: JSONEncoder().encode(settings)).autoCompactEnabled)
    }

    func testExactNinetyPercentBoundaryAndDisable() {
        XCTAssertFalse(AutoCompactionPolicy.shouldCompact(enabled: true, inputTokens: 889, outputTokens: 10, contextWindow: 1000))
        XCTAssertTrue(AutoCompactionPolicy.shouldCompact(enabled: true, inputTokens: 890, outputTokens: 10, contextWindow: 1000))
        XCTAssertTrue(AutoCompactionPolicy.shouldCompact(enabled: true, inputTokens: 1200, outputTokens: 10, contextWindow: 1000))
        XCTAssertFalse(AutoCompactionPolicy.shouldCompact(enabled: false, inputTokens: 1200, outputTokens: 10, contextWindow: 1000))
        XCTAssertFalse(AutoCompactionPolicy.shouldCompact(enabled: true, inputTokens: 900, outputTokens: 0, contextWindow: 0))
    }

    func testUsageRecoversFromPersistedMessages() throws {
        let usage = AgentTraceEntry(source: "codex", phase: "usage", title: "Usage", metadata: ["inputTokens": "890", "outputTokens": "10"])
        let message = ChatMessage(role: .assistant, blocks: [.trace([usage])])
        let restored = AutoCompactionPolicy.lastUsage(in: [message])
        XCTAssertEqual(restored.input, 890)
        XCTAssertEqual(restored.output, 10)
        XCTAssertTrue(AutoCompactionPolicy.shouldCompact(enabled: true, inputTokens: restored.input, outputTokens: restored.output, contextWindow: 1000))
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
        XCTAssertEqual(restored.id, session.id)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testOpenCodeAlsoPersistsUsageForCompaction() {
        let events = OpenCodeProtocol.parse(["type": "step_finish", "part": ["tokens": ["input": 890, "output": 10]]])
        let traces = events.compactMap { event -> AgentTraceEntry? in if case .trace(let trace) = event { return trace }; return nil }
        let usage = AutoCompactionPolicy.lastUsage(in: [ChatMessage(role: .assistant, blocks: [.trace(traces)])])
        XCTAssertEqual(usage.input, 890)
        XCTAssertEqual(usage.output, 10)
    }
}
