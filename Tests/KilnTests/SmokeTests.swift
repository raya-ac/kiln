import XCTest

@testable import Kiln

/// Compile-smoke: proves the test target can link Kiln's module and that
/// at least one internal type is exercised. Real coverage lands as features
/// grow — treat this as a canary for the test pipeline itself.
final class SmokeTests: XCTestCase {
    func testModelsHaveDistinctRawValues() {
        let ids = Set(ClaudeModel.allCases.map(\.rawValue))
        XCTAssertEqual(ids.count, ClaudeModel.allCases.count, "Model raw values collide: \(ids)")
        XCTAssertTrue(ClaudeModel.allCases.allSatisfy { !$0.rawValue.isEmpty })
    }

    func testCodexModelsArePresent() {
        let codexModels = ClaudeModel.allCases.filter { $0.provider == .codex }
        XCTAssertTrue(codexModels.contains(.gpt55))
        XCTAssertTrue(codexModels.contains(.gpt53Codex))
        XCTAssertTrue(codexModels.contains(.gpt53CodexSpark))
        XCTAssertEqual(KilnSettings().defaultModel.provider, .codex)
    }

    func testCodexAskApprovalIsTopLevelArgument() {
        var options = SendOptions()
        options.permissions = .ask
        let args = CodexService.buildArguments(
            threadId: nil,
            model: .gpt53Codex,
            workDir: "/tmp",
            options: options
        )
        XCTAssertEqual(Array(args.prefix(3)), ["--ask-for-approval", "on-request", "exec"])
        XCTAssertFalse(args.dropFirst(3).contains("--ask-for-approval"))
    }

    func testCodexThinkingMapsToReasoningConfig() {
        var options = SendOptions()
        options.thinkingEnabled = true
        options.effortLevel = .max
        let args = CodexService.buildArguments(
            threadId: nil,
            model: .gpt53Codex,
            workDir: "/tmp",
            options: options
        )
        XCTAssertTrue(args.contains(#"model_reasoning_summary="auto""#))
        XCTAssertTrue(args.contains(#"model_reasoning_effort="xhigh""#))
        XCTAssertLessThan(args.firstIndex(of: "exec") ?? .max, args.firstIndex(of: "--json") ?? .max)
    }

    func testCodexJsonOutputDisablesAnsiColor() {
        let args = CodexService.buildArguments(
            threadId: nil,
            model: .gpt53Codex,
            workDir: "/tmp",
            options: SendOptions()
        )
        let jsonIndex = args.firstIndex(of: "--json")
        let colorIndex = args.firstIndex(of: "--color")

        XCTAssertNotNil(jsonIndex)
        XCTAssertNotNil(colorIndex)
        if let colorIndex, args.indices.contains(colorIndex + 1) {
            XCTAssertEqual(args[colorIndex + 1], "never")
        }
        XCTAssertLessThan(jsonIndex ?? .max, colorIndex ?? .max)
    }

    func testCodexReasoningEventEmitsThinkingAndTrace() {
        var emittedText = false
        let events = CodexService.parseEvent([
            "type": "item.completed",
            "item": [
                "id": "reasoning_1",
                "type": "reasoning",
                "summary": "checked the workspace and selected the narrow patch",
            ],
        ], emittedText: &emittedText)

        XCTAssertTrue(events.contains { event in
            if case .thinkingDelta(let text) = event {
                return text.contains("selected the narrow patch")
            }
            return false
        })
        XCTAssertTrue(events.contains { event in
            if case .trace(let entry) = event {
                return entry.phase == "reasoning" && entry.level == .success
            }
            return false
        })
    }

    func testCodexCommandEventEmitsToolAndTrace() {
        var emittedText = false
        let events = CodexService.parseEvent([
            "type": "item.completed",
            "item": [
                "id": "cmd_1",
                "type": "command_execution",
                "command": "/bin/zsh -lc pwd",
                "aggregated_output": "/tmp\n",
                "exit_code": 0,
                "status": "completed",
            ],
        ], emittedText: &emittedText)

        XCTAssertTrue(events.contains { event in
            if case .toolResult(let id, let content, let isError) = event {
                return id == "cmd_1" && content == "/tmp\n" && !isError
            }
            return false
        })
        XCTAssertTrue(events.contains { event in
            if case .trace(let entry) = event {
                return entry.phase == "command_execution" && entry.title == "Command completed"
            }
            return false
        })
    }

    func testSessionKindHasDistinctRawValues() {
        XCTAssertNotEqual(SessionKind.code.rawValue, SessionKind.chat.rawValue)
    }

    func testMessageBlockTextIdsAreStable() {
        let first = MessageBlock.text("same markdown body").id
        let second = MessageBlock.text("same markdown body").id
        let different = MessageBlock.text("different markdown body").id

        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, different)
        XCTAssertTrue(first.hasPrefix("text-"))
        XCTAssertTrue(first.dropFirst(5).allSatisfy { $0.isHexDigit })
    }

    func testCrashReportLocatorFindsLatestKilnDiagnostic() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let oldReport = dir.appendingPathComponent("Kiln-2026-05-01-120000.ips")
        let newReport = dir.appendingPathComponent("Kiln-2026-05-02-120000.crash")
        let ignoredReport = dir.appendingPathComponent("OtherApp-2026-05-03.ips")

        try Data("old".utf8).write(to: oldReport)
        try Data("new".utf8).write(to: newReport)
        try Data("ignored".utf8).write(to: ignoredReport)

        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: oldReport.path)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000)], ofItemAtPath: newReport.path)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 3_000)], ofItemAtPath: ignoredReport.path)

        let latest = CrashReportLocator.latestKilnReport(in: dir)
        XCTAssertEqual(latest?.url.lastPathComponent, newReport.lastPathComponent)
    }
}
