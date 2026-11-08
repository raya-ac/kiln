import XCTest
@testable import Kiln

final class GrokTests: XCTestCase {
    private let model = AgentModel(rawValue: "grok:grok-4.7")!

    @MainActor func testUnsupportedAttachmentsAreRejectedBeforeBackendLaunch() async {
        let attachment = ComposerAttachment(id: UUID().uuidString, path: "/tmp/fixture.png", name: "fixture.png")
        XCTAssertNotNil(model.attachmentError([attachment]))
        XCTAssertNil(model.attachmentError([]))
        XCTAssertNil(AgentModel.gpt61Sol.attachmentError([attachment]))
        let service = AgentService(backend: .grok, executablePath: "/usr/bin/false")
        var rejected = false
        var launched = false
        var done = 0
        await service.sendMessage(sessionId: UUID().uuidString, message: "keep this draft", model: model,
                                  workDir: NSTemporaryDirectory(), attachments: [attachment],
                                  onLaunch: { _ in launched = true }) {
            switch $0 {
            case .error(let message): rejected = message.contains("text prompts only")
            case .done: done += 1
            default: break
            }
        }
        XCTAssertTrue(rejected)
        XCTAssertFalse(launched)
        XCTAssertEqual(done, 1)
    }

    func testModelIdentityAndLiveCatalog() throws {
        XCTAssertEqual(model.provider, .grok)
        XCTAssertEqual(model.cliModel, "grok-4.7")
        XCTAssertEqual(model.contextWindow, 0)
        XCTAssertFalse(model.supportsOpenAIFastMode)
        XCTAssertTrue(model.reasoningEfforts.isEmpty)
        XCTAssertEqual(try JSONDecoder().decode(AgentModel.self, from: JSONEncoder().encode(model)), model)
        XCTAssertNil(AgentModel(rawValue: "grok:"))
        let output = """
        You are logged in with grok.com.
        Default model: grok-4.7
        Available models:
          * grok-4.7 (default)
          - grok-4.7-build-fast
          - grok-4.6
          - grok-4.7
          - other-provider
        """
        let models = GrokProtocol.parseModels(Data(output.utf8))
        XCTAssertEqual(models.map(\.model.cliModel), ["grok-4.7", "grok-4.7-build-fast", "grok-4.6"])
        XCTAssertTrue(models.allSatisfy { $0.contextWindow == 0 && $0.efforts.isEmpty })
        XCTAssertTrue(GrokProtocol.parseModels(Data("Login required\n - grok-invented".utf8)).isEmpty)
    }

    func testArgumentsKeepPromptsPrivateAndPermissionsExplicitOnResume() {
        for mode in [SessionMode.build, .plan] {
            for permission in PermissionMode.allCases {
                for chat in [true, false] {
                    var options = SendOptions()
                    options.mode = mode
                    options.permissions = permission
                    options.chatMode = chat
                    let args = GrokCLI.arguments(sessionID: "exact-session", model: model, workDir: "/tmp/a folder", options: options)
                    let readOnly = chat || mode == .plan || permission == .deny
                    XCTAssertEqual(value("--resume", in: args), "exact-session")
                    XCTAssertFalse(args.contains("--continue"))
                    XCTAssertEqual(value("--cwd", in: args), "/tmp/a folder")
                    XCTAssertEqual(value("--prompt-file", in: args), "/dev/stdin")
                    XCTAssertTrue(args.contains("--no-auto-update"))
                    XCTAssertEqual(value("--permission-mode", in: args), !readOnly && permission == .bypass ? "bypassPermissions" : "dontAsk")
                    XCTAssertEqual(value("--sandbox", in: args), readOnly ? "read-only" : permission == .bypass ? "off" : "workspace")
                    if readOnly {
                        XCTAssertTrue(args.contains("--no-subagents"))
                        XCTAssertTrue(args.contains("MCPTool"))
                        XCTAssertEqual(value("--tools", in: args), chat ? "" : "read_file,grep,list_dir")
                    }
                }
            }
        }
    }

    func testStreamToolsAndTurnUsageAreNotDoubleCounted() {
        var stream = GrokProtocol.StreamState()
        let start = stream.parse(["type": "tool_call", "toolCallId": "tool1", "toolName": "read_file", "rawInput": ["path": "README.md"], "status": "in_progress"])
        XCTAssertTrue(start.contains { if case .toolStart("tool1", "read_file", _) = $0 { true } else { false } })
        let end = stream.parse(["type": "tool_call_update", "toolCallId": "tool1", "status": "completed", "rawOutput": "hello"])
        XCTAssertTrue(end.contains { if case .toolResult("tool1", "hello", false) = $0 { true } else { false } })
        XCTAssertFalse(end.contains { if case .toolStart = $0 { true } else { false } })
        XCTAssertTrue(stream.parse(["type": "usage", "usage": ["input_tokens": 999]]).isEmpty)
        let receipt: [String: Any] = ["type": "end", "sessionId": "session1", "requestId": "request1", "stopReason": "end_turn",
            "usage": ["input_tokens": 10, "cache_read_input_tokens": 90, "cache_creation_input_tokens": 2, "output_tokens": 5, "reasoning_tokens": 3]]
        let events = stream.parse(receipt)
        let measurements = events.compactMap { if case .measuredUsage(let usage) = $0 { usage } else { nil } }
        XCTAssertEqual(measurements, [MeasuredTokenUsage(sourceID: "request1", input: 102, output: 5, cached: 90, reasoning: 3)])
        XCTAssertTrue(events.contains { if case .sessionId("session1") = $0 { true } else { false } })
        XCTAssertFalse(events.contains { if case .contextUsage = $0 { true } else { false } })
        XCTAssertFalse(events.contains { if case .cost = $0 { true } else { false } })
        XCTAssertFalse(stream.parse(receipt).contains { if case .measuredUsage = $0 { true } else { false } })
    }

    func testErrorsAndIncompleteSpendRemainExplicit() {
        var stream = GrokProtocol.StreamState()
        let events = stream.parse(["type": "error", "message": "Authentication required", "cost_is_partial": true, "total_cost_usd": 0.2])
        XCTAssertTrue(events.contains { if case .error("Authentication required") = $0 { true } else { false } })
        XCTAssertFalse(events.contains { if case .cost = $0 { true } else { false } })
        let receipt = stream.parse(["type": "end", "usage": ["input_tokens": true, "output_tokens": -1]])
        XCTAssertFalse(receipt.contains { if case .measuredUsage = $0 { true } else { false } })
        var missingCache = GrokProtocol.StreamState()
        let partial = missingCache.parse(["type": "end", "usage": ["input_tokens": 12, "output_tokens": 3]])
        XCTAssertTrue(partial.contains {
            if case .measuredUsage(let value) = $0 { value.input == nil && value.cached == nil && value.output == 3 } else { false }
        })
    }

    func testSessionIdentityIsAvailableBeforeAnInterruptedTurnEnds() {
        let id = UUID().uuidString.lowercased()
        var stream = GrokProtocol.StreamState(newSessionID: id)
        XCTAssertFalse(stream.parse(["type": "available_commands"]).contains { if case .sessionId = $0 { true } else { false } })
        XCTAssertTrue(stream.parse(["type": "text", "data": "hello"]).contains { if case .sessionId(id) = $0 { true } else { false } })
        let args = GrokCLI.arguments(sessionID: nil, newSessionID: id, model: model, workDir: "/tmp", options: SendOptions())
        XCTAssertEqual(value("--session-id", in: args), id)
        let resumed = GrokCLI.arguments(sessionID: id, newSessionID: "unused", model: model, workDir: "/tmp", options: SendOptions())
        XCTAssertFalse(resumed.contains("--session-id"))
        XCTAssertEqual(value("--resume", in: resumed), id)
    }

    func testRemoteClientIncludesGrokWithoutOpenAIBranding() {
        let page = RemoteWebAssets.page
        XCTAssertTrue(page.contains("['grok','Grok']"))
        XCTAssertTrue(page.contains("brand==='grok'"))
        XCTAssertTrue(page.contains("xAI</span>"))
    }

    func testNativeUpdaterAndUsageProvider() throws {
        XCTAssertEqual(GrokCLI.installedVersion(Data("grok 1.0.77 (50ca579fa996) [stable]\n".utf8))?.text, "1.0.77")
        XCTAssertEqual(GrokCLI.installedVersion(Data("grok 1.0.78-alpha.1 (commit) [alpha]".utf8))?.text, "1.0.78-alpha.1")
        XCTAssertNil(GrokCLI.installedVersion(Data("not a version".utf8)))
        XCTAssertEqual(try GrokCLI.updateVersion(Data(#"{"currentVersion":"1.0.77","latestVersion":"1.0.78","updateAvailable":true,"error":null}"#.utf8)).text, "1.0.78")
        XCTAssertThrowsError(try GrokCLI.updateVersion(Data(#"{"latestVersion":"1.0.78","error":"offline"}"#.utf8)))
        XCTAssertEqual(CLIInstallMethod.detect(provider: .grok, resolvedPath: "/Users/test/.grok/downloads/grok-1.0.77-macos-aarch64"), .standalone)
        XCTAssertEqual(CLIInstallMethod.standalone.updateCommand(provider: .grok, executable: "/tmp/a'b/grok"), "'/tmp/a'\\''b/grok' update")
        let usage = KilnUsageEvent(eventID: UUID().uuidString, provider: "grok", model: "grok-4.7", occurredAt: .now,
            inputTokens: 100, sessionID: "opaque-session-000000000001")
        XCTAssertTrue(usage.isValid())
    }

    @MainActor
    func testProcessStreamsAndResumesOnlyItsOwnSession() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-grok-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("fixture")
        let source = """
        #!/bin/sh
        printf '%s\\n' "$@" > args
        cat > prompt
        printf '%s\\n' '{"type":"text","data":"live"}'
        i=0
        while [ ! -f received ]; do
          i=$((i+1))
          [ "$i" -gt 200 ] && exit 86
          sleep 0.02
        done
        printf '%s' '{"type":"end","sessionId":"owned-grok-session","requestId":"receipt","usage":{"input_tokens":2,"output_tokens":1}}'
        """
        try source.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let service = AgentService(backend: .grok, executablePath: script.path)
        let id = UUID().uuidString
        defer { service.forgetThread(for: id) }
        for turn in 0..<2 {
            var output = ""
            var finished = 0
            var errors: [String] = []
            await service.sendMessage(sessionId: id, message: "--a prompt", model: model, workDir: directory.path) { event in
                switch event {
                case .textDelta(let text):
                    output += text
                    FileManager.default.createFile(atPath: directory.appendingPathComponent("received").path, contents: Data())
                case .error(let error): errors.append(error)
                case .done: finished += 1
                default: break
                }
            }
            XCTAssertEqual(output, "live")
            XCTAssertEqual(finished, 1)
            XCTAssertTrue(errors.isEmpty, errors.joined(separator: "; "))
            XCTAssertEqual(service.threadID(for: id), "owned-grok-session")
            let args = try String(contentsOf: directory.appendingPathComponent("args"), encoding: .utf8)
            XCTAssertEqual(args.contains("--resume\nowned-grok-session"), turn == 1)
            XCTAssertFalse(args.contains("--a prompt"))
            XCTAssertTrue(try String(contentsOf: directory.appendingPathComponent("prompt"), encoding: .utf8).contains("--a prompt"))
            try FileManager.default.removeItem(at: directory.appendingPathComponent("received"))
        }
    }

    @MainActor
    func testInstalledGrokToolCallAndResumeWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["KILN_GROK_LIVE_TESTS"] == "1" else {
            throw XCTSkip("Set KILN_GROK_LIVE_TESTS=1 for authenticated Grok calls")
        }
        try await GrokModels.shared.reload()
        let installedModel = try XCTUnwrap(GrokModels.shared.models.first)
        let update = await CLIUpdateInspector.inspect(.grok)
        XCTAssertNil(update.problem, update.problem ?? "")
        XCTAssertNotNil(update.latest)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-grok-live-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = "kiln-" + UUID().uuidString.lowercased()
        try marker.write(to: directory.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let sessionID = UUID().uuidString
        var options = SendOptions()
        options.permissions = .deny
        options.maxTurns = 4
        var tools = 0
        var initialThread: String?
        for turn in 0..<2 {
            let service = AgentService(backend: .grok)
            defer { if turn == 1 { service.forgetThread(for: sessionID) } }
            var text = ""
            var receipts = 0
            var errors: [String] = []
            options.chatMode = turn == 1
            let prompt = turn == 0 ? "Use read_file to read README.md. Reply with only its exact contents." : "Repeat the exact contents you just read, without using tools."
            await service.sendMessage(sessionId: sessionID, message: prompt, model: installedModel, workDir: directory.path, options: options) {
                switch $0 {
                case .textDelta(let value): text += value
                case .toolResult(_, _, false): tools += 1
                case .measuredUsage: receipts += 1
                case .error(let error): errors.append(error)
                default: break
                }
            }
            XCTAssertTrue(errors.isEmpty, errors.joined(separator: "; "))
            XCTAssertTrue(text.contains(marker), text)
            XCTAssertEqual(receipts, 1)
            if turn == 0 { initialThread = service.threadID(for: sessionID) }
            XCTAssertNotNil(initialThread)
            XCTAssertEqual(service.threadID(for: sessionID), initialThread)
        }
        XCTAssertGreaterThan(tools, 0)
    }

    private func value(_ flag: String, in args: [String]) -> String? {
        guard let index = args.firstIndex(of: flag), index + 1 < args.count else { return nil }
        return args[index + 1]
    }
}
