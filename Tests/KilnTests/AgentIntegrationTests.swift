import XCTest
@testable import Kiln

final class AgentIntegrationTests: XCTestCase {
    func testLegacyModelMigrationAndOpenCodeRoundTrip() throws {
        XCTAssertEqual(try JSONDecoder().decode(AgentModel.self, from: Data(#""claude-sonnet-4-6""#.utf8)), .defaultModel)
        XCTAssertNil(AgentModel(rawValue: "opencode:anthropic/claude-sonnet"))
        let model = try XCTUnwrap(AgentModel(rawValue: "opencode:openai/gpt-5.5"))
        XCTAssertEqual(model.provider, .opencode)
        XCTAssertEqual(model.cliModel, "openai/gpt-5.5")
        XCTAssertEqual(try JSONDecoder().decode(AgentModel.self, from: JSONEncoder().encode(model)), model)
    }

    @MainActor
    func testGPTModelsUseBundledOfficialMarks() throws {
        XCTAssertTrue(ModelBrandAssets.white.isValid)
        XCTAssertTrue(ModelBrandAssets.black.isValid)
        for model in [AgentModel.gpt6Astra, .gpt55, .gpt54, AgentModel(rawValue: "opencode:local/gpt-5.5")!] {
            if case .chatgpt = model.brand {} else { XCTFail("GPT model missing OpenAI branding") }
        }
        for color in ["white", "black"] {
            let url = try XCTUnwrap(Bundle.module.url(forResource: "OpenAI-\(color)-monoblossom", withExtension: "png", subdirectory: "brands"))
            let data = try Data(contentsOf: url)
            XCTAssertGreaterThan(data.count, 1000)
            XCTAssertEqual(Array(data.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
        }
    }

    func testCatalogFiltersHiddenAndDuplicateModels() throws {
        let data = Data(#"{"models":[{"slug":"gpt-6-astra","visibility":"list"},{"slug":"gpt-hidden","visibility":"hide"},{"slug":"gpt-6-astra","visibility":"list"},{"slug":"claude-test","visibility":"list"}]}"#.utf8)
        let models = try XCTUnwrap(ModelCatalog.parse(data))
        XCTAssertEqual(models.map(\.model.rawValue), ["gpt-6-astra"])
        XCTAssertNil(ModelCatalog.parse(Data("not JSON".utf8)))
    }

    func testOlderModelsHaveDistinctGroup() {
        let groups = AgentModel.groupedByProvider
        XCTAssertTrue(groups.contains { $0.label == "Older models" && $0.models.contains(.gpt53Codex) })
        XCTAssertEqual(Set(groups.map(\.id)).count, groups.count)
    }

    func testRepeatedBlocksHaveUniqueStableIdentity() {
        let message = ChatMessage(id: "message", role: .assistant, blocks: [.text("same"), .text("same"), .thinking("same")])
        let ids = message.transcriptBlocks.map(\.id)
        XCTAssertEqual(Set(ids).count, 3)
        XCTAssertEqual(message.transcriptBlocks.map(\.id), ids)
        let updated = ChatMessage(id: "message", role: .assistant, blocks: [.text("updated"), .text("same"), .thinking("same")])
        XCTAssertEqual(updated.transcriptBlocks.map(\.id), ids)
    }

    func testContextIsBoundedAndExcludesInternalLogs() {
        let messages = [
            ChatMessage(role: .user, blocks: [.text("older " + String(repeating: "a", count: 100))]),
            ChatMessage(role: .assistant, blocks: [.thinking("internal"), .text("recent answer")])
        ]
        let context = TranscriptContext.text(from: messages, characterLimit: 40)
        XCTAssertLessThanOrEqual(context.count, 40)
        XCTAssertTrue(context.hasSuffix("recent answer"))
        XCTAssertFalse(context.contains("internal"))
        XCTAssertEqual(TranscriptContext.text(from: messages, characterLimit: 0), "")
    }

    func testResumeKeepsReadOnlyEvenWhenBypassSelected() {
        for mode in [SessionMode.build, .plan] {
            for permission in PermissionMode.allCases {
                for chat in [true, false] {
                    var options = SendOptions()
                    options.mode = mode
                    options.permissions = permission
                    options.chatMode = chat
                    let args = CodexProtocol.buildArguments(threadId: "thread", model: .gpt55, workDir: "/tmp", options: options)
                    let readOnly = chat || mode == .plan || permission == .deny
                    XCTAssertFalse(args.contains("--color"))
                    XCTAssertEqual(args.contains("--dangerously-bypass-approvals-and-sandbox"), !readOnly && permission == .bypass)
                    if readOnly { XCTAssertTrue(args.contains(#"sandbox_mode="read-only""#)) }
                }
            }
        }
    }

    func testStructuredCodexFailureKeepsMessage() {
        var emitted = false
        let events = CodexProtocol.parseEvent(["type": "turn.failed", "error": ["message": "model unavailable"]], emittedText: &emitted)
        XCTAssertTrue(events.contains { if case .error("model unavailable") = $0 { return true }; return false })
    }

    func testOpenCodeEventsAndPermissions() throws {
        let events = OpenCodeProtocol.parse(["type": "tool_use", "sessionID": "ses_1", "part": [
            "callID": "tool_1", "tool": "bash", "state": ["status": "error", "input": ["command": "false"], "error": "failed"]
        ]])
        XCTAssertTrue(events.contains { if case .sessionId("ses_1") = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .toolStart("tool_1", "Bash", _) = $0 { return true }; return false })
        XCTAssertTrue(events.contains { if case .toolResult("tool_1", "failed", true) = $0 { return true }; return false })
        var options = SendOptions()
        options.permissions = .bypass
        options.mode = .plan
        let model = try XCTUnwrap(AgentModel(rawValue: "opencode:openai/gpt-5.5"))
        let args = OpenCodeProtocol.arguments(sessionId: "ses_1", model: model, workDir: "/tmp", options: options)
        XCTAssertFalse(args.contains("--auto"))
        XCTAssertTrue(args.contains("plan"))
        XCTAssertTrue(args.contains("ses_1"))
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(OpenCodeProtocol.configuration(options).utf8)) as? [String: Any])
        XCTAssertEqual(config["share"] as? String, "disabled")
        XCTAssertEqual((config["permission"] as? [String: String])?["*"], "deny")
    }

    @MainActor
    func testEventsArriveBeforeProcessExitAndFinishOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("fixture")
        // The child cannot finish successfully until the UI receives its first event.
        let source = """
        #!/bin/sh
        cat >/dev/null
        printf '%s\\n' '{"type":"item.completed","item":{"id":"msg1","type":"agent_message","text":"live"}}'
        i=0
        while [ ! -f received ]; do
          i=$((i+1))
          [ "$i" -gt 250 ] && exit 86
          sleep 0.02
        done
        printf '%s\\n' '{"type":"turn.completed","usage":{"input_tokens":3,"output_tokens":1}}'
        printf '%s\\n' 'diagnostic tail' >&2
        """
        try source.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let service = AgentService(executablePath: script.path)
        var output = ""
        var completions = 0
        var errors: [String] = []
        var phases: [String] = []
        await service.sendMessage(sessionId: UUID().uuidString, message: "test", model: .gpt55, workDir: directory.path) { event in
            switch event {
            case .textDelta(let value):
                output += value
                try? Data().write(to: directory.appendingPathComponent("received"))
            case .done: completions += 1; phases.append("done")
            case .error(let message): errors.append(message)
            case .trace(let trace): phases.append(trace.phase)
            default: break
            }
        }
        XCTAssertEqual(output, "live")
        XCTAssertEqual(completions, 1)
        XCTAssertTrue(errors.isEmpty, errors.joined(separator: "\n"))
        XCTAssertEqual(phases.last, "done")
        XCTAssertTrue(phases.contains("stderr"))
    }

    func testOpenCodeCatalogUsesCapabilitiesAndVariants() throws {
        let model: [String: Any] = [
            "id": "test", "providerID": "local", "name": "Local Test",
            "capabilities": ["toolcall": true, "output": ["text": true]],
            "limit": ["context": 32000], "variants": ["high": [:], "low": [:]]
        ]
        var image = model
        image["id"] = "image"
        image["capabilities"] = ["toolcall": false, "output": ["image": true]]
        let objects = try [model, image, model].map {
            "model/label\n" + String(decoding: try JSONSerialization.data(withJSONObject: $0, options: [.prettyPrinted]), as: UTF8.self)
        }.joined(separator: "\n")
        let parsed = OpenCodeModels.parse(Data(objects.utf8))
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.contextWindow, 32000)
        XCTAssertEqual(parsed.first?.efforts, ["low", "high"])
    }

    @MainActor
    func testMissingWorkspaceDoesNotFallBackToHome() async {
        let service = AgentService(executablePath: "/nonexistent/should-not-launch")
        var errors: [String] = []
        var done = 0
        await service.sendMessage(sessionId: UUID().uuidString, message: "test", model: .gpt55, workDir: "/nonexistent/workspace") {
            if case .error(let message) = $0 { errors.append(message) }
            if case .done = $0 { done += 1 }
        }
        XCTAssertEqual(errors.count, 1)
        XCTAssertTrue(errors.first?.contains("workspace folder") == true)
        XCTAssertEqual(done, 1)
    }

    /// Opt in on a machine with both CLIs authenticated. Nothing touches app sessions.
    @MainActor
    func testInstalledBackendsWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["KILN_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set KILN_LIVE_TESTS=1 to exercise authenticated CLIs")
        }
        try await OpenCodeModels.shared.reload()
        let openCodeSlug = ProcessInfo.processInfo.environment["KILN_OPENCODE_MODEL"] ?? "opencode:local/gpt-5.4-mini"
        let openCode = try XCTUnwrap(AgentModel(rawValue: openCodeSlug))
        XCTAssertTrue(OpenCodeModels.shared.models.contains(openCode))
        for model in [AgentModel.gpt54Mini, openCode] {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let marker = "KILN_PROBE_" + UUID().uuidString
            try marker.write(to: directory.appendingPathComponent("probe.txt"), atomically: true, encoding: .utf8)
            let service = AgentService(backend: model.provider)
            let session = UUID().uuidString
            defer { service.forgetThread(for: session) }
            var options = SendOptions()
            options.mode = .plan
            options.permissions = .ask
            options.thinkingEnabled = true
            options.effortLevel = .low
            var toolCalls = 0
            for prompt in [
                "Read only probe.txt in the current directory and reply with its contents. Do not modify files or inspect anything else.",
                "What exact marker did you just read? Reply with that marker only, without using tools."
            ] {
                var output = ""
                var errors: [String] = []
                var completions = 0
                let watchdog = Task { @MainActor in
                    do { try await Task.sleep(for: .seconds(90)) } catch { return }
                    service.interrupt(sessionId: session)
                }
                await service.sendMessage(sessionId: session, message: prompt, model: model, workDir: directory.path, options: options) {
                    switch $0 {
                    case .textDelta(let text): output += text
                    case .error(let message): errors.append(message)
                    case .toolStart: toolCalls += 1
                    case .done: completions += 1
                    default: break
                    }
                }
                watchdog.cancel()
                XCTAssertTrue(errors.isEmpty, "\(model.rawValue): \(errors.joined(separator: "\n"))")
                XCTAssertTrue(output.contains(marker), "\(model.rawValue) omitted the marker")
                XCTAssertEqual(completions, 1)
                XCTAssertTrue(service.hasThread(for: session))
            }
            XCTAssertGreaterThan(toolCalls, 0, "\(model.rawValue) did not report file inspection")
            XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("probe.txt"), encoding: .utf8), marker)
        }
    }

    @MainActor
    func testMissingExecutableCanBeRetried() async {
        let service = AgentService(executablePath: "/nonexistent/kiln-fixture")
        let session = UUID().uuidString
        var errors = 0
        var completions = 0
        for _ in 0..<2 {
            await service.sendMessage(sessionId: session, message: "test", model: .gpt55, workDir: "/tmp") { event in
                if case .error = event { errors += 1 }
                if case .done = event { completions += 1 }
            }
        }
        XCTAssertEqual(errors, 2)
        XCTAssertEqual(completions, 2)
    }
}
