import XCTest
import SwiftUI
import AppKit
@testable import Kiln

@MainActor private final class ComputerFixture {
    var target = ComputerTarget(id: 41, pid: 900, app: "Fixture", title: "A safe test window", frame: CGRect(x: 20, y: 30, width: 800, height: 600))
    var allowed = true
    var targetAvailable = true
    var dispatched = 0
    var captureID = ""
    func driver() -> ComputerDriver {
        ComputerDriver(allowed: { self.allowed }, current: { _ in
            guard self.targetAvailable else { throw ComputerUseError.targetGone }
            return self.target
        }, capture: { _ in
            let id = UUID().uuidString
            self.captureID = id
            return ComputerCapture(id: id, target: self.target, width: 800, height: 600, timestamp: .now, jpeg: Data("fixture-image".utf8))
        }, perform: { _, _, active in
            guard active() else { throw ComputerUseError.inactive }
            self.dispatched += 1
        })
    }
}

@MainActor private final class ComputerReadinessGate {
    let entered = XCTestExpectation(description: "Listener reached readiness barrier")
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        await withCheckedContinuation { continuation = $0; entered.fulfill() }
    }
    func release() { continuation?.resume(); continuation = nil }
}

final class ComputerUseTests: XCTestCase {
    @MainActor func testStatusRechecksPermissionsAndWindowExistence() async throws {
        let fixture = ComputerFixture()
        let computer = ComputerUse(driver: fixture.driver())
        defer { computer.stop() }
        try computer.enable(sessionID: "status-fixture", target: fixture.target, model: .gpt61Sol)
        let started = try await computer.startTurn(sessionID: "status-fixture", model: .gpt61Sol, options: SendOptions())
        let turn = try XCTUnwrap(started)
        let request = ComputerUse.encode(["name": "status"])
        let initial = try decode(await computer.handle(request, token: turn.token))
        XCTAssertNil(initial["isError"])
        fixture.allowed = false
        let denied = try decode(await computer.handle(request, token: turn.token))
        XCTAssertEqual(denied["isError"] as? Bool, true)
        fixture.allowed = true
        fixture.targetAvailable = false
        let closed = try decode(await computer.handle(request, token: turn.token))
        XCTAssertEqual(closed["isError"] as? Bool, true)
        XCTAssertEqual(fixture.dispatched, 0)
    }

    @MainActor func testAgentInjectsGuidanceOnlyWhileComputerTurnIsActive() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("fixture")
        try "#!/bin/sh\n/bin/cat > received\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let fixture = ComputerFixture()
        let computer = ComputerUse(driver: fixture.driver())
        defer { computer.stop() }
        let service = AgentService(executablePath: script.path, computer: computer)
        let id = UUID().uuidString
        try computer.enable(sessionID: id, target: fixture.target, model: .gpt61Sol)
        await service.sendMessage(sessionId: id, message: "Can you see the shared window?", model: .gpt61Sol,
                                  workDir: directory.path) { _ in }
        let received = directory.appendingPathComponent("received")
        let shared = try String(contentsOf: received, encoding: .utf8)
        XCTAssertTrue(shared.contains(ComputerConnection.instructions))
        computer.stop(sessionID: id)
        await service.sendMessage(sessionId: id, message: "Sharing stopped.", model: .gpt61Sol,
                                  workDir: directory.path) { _ in }
        let unshared = try String(contentsOf: received, encoding: .utf8)
        XCTAssertFalse(unshared.contains(ComputerConnection.instructions))
        XCTAssertEqual(unshared, "Sharing stopped.")
        XCTAssertEqual(fixture.dispatched, 0)
    }

    @MainActor func testBusyRequestDoesNotInvalidateApprovalAlreadyOnScreen() async throws {
        let fixture = ComputerFixture()
        let computer = ComputerUse(driver: fixture.driver())
        defer { computer.stop() }
        try computer.enable(sessionID: "chat-a", target: fixture.target, model: .gpt61Sol)
        let started = try await computer.startTurn(sessionID: "chat-a", model: .gpt61Sol, options: SendOptions())
        let turn = try XCTUnwrap(started)
        _ = await computer.handle(ComputerUse.encode(["name": "observe"]), token: turn.token)
        let data = ComputerUse.encode(["name": "click", "arguments": ["capture_id": fixture.captureID, "x": 10, "y": 10]])
        let first = Task { await computer.handle(data, token: turn.token) }
        for _ in 0..<100 where computer.pending == nil { await Task.yield() }
        let proposal = try XCTUnwrap(computer.pending)
        let second = await computer.handle(data, token: turn.token)
        XCTAssertTrue(String(decoding: second, as: UTF8.self).contains("awaiting approval"))
        XCTAssertEqual(computer.pending?.id, proposal.id)
        computer.decide(id: proposal.id, allow: true)
        let result = await first.value
        XCTAssertNil(try decode(result)["isError"])
        XCTAssertEqual(fixture.dispatched, 1)
    }

    @MainActor func testListenerStartupHasDeadlineAndCannotPublishLateGrant() async throws {
        let fixture = ComputerFixture()
        let gate = ComputerReadinessGate()
        let computer = ComputerUse(driver: fixture.driver(), listenerStartupTimeout: 0.1, listenerReadyGate: { await gate.wait() })
        defer { gate.release(); computer.stop() }
        try computer.enable(sessionID: "chat-a", target: fixture.target, model: .gpt61Sol)
        let task = Task { try await computer.startTurn(sessionID: "chat-a", model: .gpt61Sol, options: SendOptions()) }
        await fulfillment(of: [gate.entered], timeout: 3)
        do { _ = try await task.value; XCTFail("Startup must time out") }
        catch { guard case ComputerUseError.listenerTimeout = error else { return XCTFail("Unexpected error: \(error)") } }
        XCTAssertTrue(computer.startingSessions.isEmpty)
        gate.release()
        await Task.yield()
        XCTAssertTrue(computer.startingSessions.isEmpty)
    }

    @MainActor func testStopDuringComputerStartupEmitsCancellationNotError() async throws {
        let fixture = ComputerFixture()
        let gate = ComputerReadinessGate()
        let computer = ComputerUse(driver: fixture.driver(), listenerReadyGate: { await gate.wait() })
        defer { gate.release(); computer.stop() }
        let service = AgentService(executablePath: "/usr/bin/false", computer: computer)
        let id = UUID().uuidString
        try computer.enable(sessionID: id, target: fixture.target, model: .gpt61Sol)
        var cancelled = false, failed = false, started = false
        var done = 0
        let task = Task {
            await service.sendMessage(sessionId: id, message: "fixture", model: .gpt61Sol, workDir: NSTemporaryDirectory()) {
                switch $0 {
                case .cancelled: cancelled = true
                case .error: failed = true
                case .started: started = true
                case .done: done += 1
                default: break
                }
            }
        }
        await fulfillment(of: [gate.entered], timeout: 3)
        service.interrupt(sessionId: id)
        gate.release()
        await task.value
        XCTAssertTrue(cancelled)
        XCTAssertFalse(failed)
        XCTAssertFalse(started)
        XCTAssertEqual(done, 1)
    }

    @MainActor func testFailedOldActionDoesNotConsumeNewObservation() async throws {
        let fixture = ComputerFixture()
        let computer = ComputerUse(driver: fixture.driver())
        defer { computer.stop() }
        try computer.enable(sessionID: "chat-a", target: fixture.target, model: .gpt61Sol)
        let started = try await computer.startTurn(sessionID: "chat-a", model: .gpt61Sol, options: SendOptions())
        let turn = try XCTUnwrap(started)
        _ = await computer.handle(ComputerUse.encode(["name": "observe"]), token: turn.token)
        let oldAction = ComputerUse.encode(["name": "click", "arguments": ["capture_id": fixture.captureID, "x": 10, "y": 10]])
        let pendingAction = Task { await computer.handle(oldAction, token: turn.token) }
        for _ in 0..<100 where computer.pending == nil { await Task.yield() }
        let proposal = try XCTUnwrap(computer.pending)
        _ = await computer.handle(ComputerUse.encode(["name": "observe"]), token: turn.token)
        let newID = fixture.captureID
        computer.decide(id: proposal.id, allow: false)
        _ = await pendingAction.value
        let rejected = await computer.handle(oldAction, token: turn.token)
        XCTAssertEqual(try decode(rejected)["isError"] as? Bool, true)
        let next = Task { await computer.handle(ComputerUse.encode(["name": "click", "arguments": [
            "capture_id": newID, "x": 10, "y": 10]]), token: turn.token) }
        for _ in 0..<100 where computer.pending == nil { await Task.yield() }
        computer.decide(id: try XCTUnwrap(computer.pending).id, allow: true)
        let result = await next.value
        XCTAssertNil(try decode(result)["isError"])
        XCTAssertEqual(fixture.dispatched, 1)
    }

    func testReadinessReportsEveryBlockerInsteadOfOnlyBackend() {
        var options = SendOptions()
        options.chatMode = true; options.mode = .plan; options.permissions = .deny
        let reasons = ComputerConnection.blockers(provider: .grok, options: options, screenAllowed: true,
            inputAllowed: false, windowSelected: true, consent: false)
        XCTAssertEqual(reasons.count, 6)
        XCTAssertTrue(reasons.contains { $0.contains("Grok") })
        XCTAssertTrue(reasons.contains { $0.contains("Accessibility") })
        XCTAssertFalse(reasons.contains { $0.contains("Screen Recording") })
        XCTAssertFalse(reasons.contains("Choose a window."))
        XCTAssertTrue(ComputerConnection.blockers(provider: .codex, options: SendOptions(), screenAllowed: true,
            inputAllowed: true, windowSelected: true, consent: true).isEmpty)
    }

    @MainActor func testStoppingAnotherChatDoesNotCancelPendingListenerStart() async throws {
        let fixture = ComputerFixture()
        let gate = ComputerReadinessGate()
        let computer = ComputerUse(driver: fixture.driver(), listenerReadyGate: { await gate.wait() })
        defer { gate.release(); computer.stop() }
        try computer.enable(sessionID: "chat-a", target: fixture.target, model: .gpt61Sol)
        let first = Task { try await computer.startTurn(sessionID: "chat-a", model: .gpt61Sol, options: SendOptions()) }
        await fulfillment(of: [gate.entered], timeout: 3)
        computer.stop(sessionID: "chat-b")
        gate.release()
        let started = try await first.value
        let turn = try XCTUnwrap(started)
        let reply = await computer.handle(ComputerUse.encode(["name": "status"]), token: turn.token)
        XCTAssertFalse(String(decoding: reply, as: UTF8.self).contains("isError"))
    }

    @MainActor func testConcurrentStartsShareReadinessAndRevocationIsScoped() async throws {
        let fixture = ComputerFixture()
        let gate = ComputerReadinessGate()
        let computer = ComputerUse(driver: fixture.driver(), listenerReadyGate: { await gate.wait() })
        defer { gate.release(); computer.stop() }
        try computer.enable(sessionID: "chat-a", target: fixture.target, model: .gpt61Sol)
        try computer.enable(sessionID: "chat-b", target: fixture.target, model: .gpt61Sol)
        let first = Task { try await computer.startTurn(sessionID: "chat-a", model: .gpt61Sol, options: SendOptions()) }
        await fulfillment(of: [gate.entered], timeout: 3)
        let second = Task { try await computer.startTurn(sessionID: "chat-b", model: .gpt61Sol, options: SendOptions()) }
        for _ in 0..<100 where !computer.startingSessions.contains("chat-b") { await Task.yield() }
        XCTAssertTrue(computer.startingSessions.contains("chat-b"))
        computer.stop(sessionID: "chat-a")
        gate.release()
        do { _ = try await first.value; XCTFail("Revoked chat must not get a grant") } catch {}
        let started = try await second.value
        let turn = try XCTUnwrap(started)
        XCTAssertGreaterThan(turn.port, 0)
    }

    @MainActor func testBackgroundApprovalNamesOriginRatherThanVisibleChat() async throws {
        let fixture = ComputerFixture()
        let computer = ComputerUse(driver: fixture.driver())
        defer { computer.stop() }
        try computer.enable(sessionID: "chat-a", target: fixture.target, model: .gpt61Sol)
        let started = try await computer.startTurn(sessionID: "chat-a", model: .gpt61Sol, options: SendOptions())
        let turn = try XCTUnwrap(started)
        _ = await computer.handle(ComputerUse.encode(["name": "observe"]), token: turn.token)
        let action = Task { await computer.handle(ComputerUse.encode(["name": "click", "arguments": [
            "capture_id": fixture.captureID, "x": 10, "y": 10]]), token: turn.token) }
        for _ in 0..<100 where computer.pending == nil { await Task.yield() }
        let pending = try XCTUnwrap(computer.pending)
        let names = ["chat-a": "Origin chat", "chat-b": "Visible chat"]
        let label = pending.originLabel(chatName: names[pending.sessionID])
        XCTAssertTrue(label.contains("Origin chat"))
        XCTAssertTrue(label.contains("chat-a"))
        XCTAssertFalse(label.contains("Visible chat"))
        XCTAssertTrue(pending.originLabel(chatName: nil).contains("chat-a"))
        computer.decide(id: pending.id, allow: false)
        _ = await action.value
        XCTAssertEqual(fixture.dispatched, 0)
    }

    func testPointerHitRejectsOverlappingSameProcessPanels() {
        let target = ComputerTarget(id: 1, pid: 90, app: "Test", title: "Selected", frame: CGRect(x: 10, y: 10, width: 500, height: 400))
        let point = CGPoint(x: 100, y: 100)
        let panel = ComputerTarget(id: 2, pid: 90, app: "Test", title: "Floating", frame: CGRect(x: 80, y: 80, width: 100, height: 100))
        XCTAssertTrue(target.isTopmost(at: point, windowsFrontToBack: [target]))
        XCTAssertFalse(target.isTopmost(at: point, windowsFrontToBack: [panel, target]))
        XCTAssertTrue(target.isTopmost(at: point, windowsFrontToBack: [target, panel]))
        XCTAssertFalse(target.isTopmost(at: point, windowsFrontToBack: []))
        let otherApp = ComputerTarget(id: 3, pid: 91, app: "Other", title: "", frame: panel.frame)
        XCTAssertFalse(target.isTopmost(at: point, windowsFrontToBack: [otherApp, target]))
    }

    @MainActor func testComputerPreviewAndHistoryAreScopedToTheirChat() async throws {
        let fixture = ComputerFixture()
        let computer = ComputerUse(driver: fixture.driver())
        defer { computer.stop() }
        try computer.enable(sessionID: "chat-a", target: fixture.target, model: .gpt61Sol)
        let started = try await computer.startTurn(sessionID: "chat-a", model: .gpt61Sol, options: SendOptions())
        let turn = try XCTUnwrap(started)
        _ = await computer.handle(ComputerUse.encode(["name": "observe"]), token: turn.token)
        XCTAssertNotNil(computer.preview(for: "chat-a"))
        XCTAssertNil(computer.preview(for: "chat-b"))
        XCTAssertNil(computer.preview(for: nil))
        let data = ComputerUse.encode(["name": "click", "arguments": ["capture_id": fixture.captureID, "x": 10, "y": 10]])
        let action = Task { await computer.handle(data, token: turn.token) }
        for _ in 0..<100 where computer.pending == nil { await Task.yield() }
        computer.decide(id: try XCTUnwrap(computer.pending).id, allow: true)
        _ = await action.value
        XCTAssertEqual(computer.history(for: "chat-a").count, 1)
        XCTAssertTrue(computer.history(for: "chat-b").isEmpty)
        try computer.enable(sessionID: "chat-b", target: fixture.target, model: .gpt61Sol)
        let second = try await computer.startTurn(sessionID: "chat-b", model: .gpt61Sol, options: SendOptions())
        _ = await computer.handle(ComputerUse.encode(["name": "observe"]), token: try XCTUnwrap(second).token)
        computer.stop(sessionID: "chat-a")
        XCTAssertNil(computer.preview(for: "chat-a"))
        XCTAssertTrue(computer.history(for: "chat-a").isEmpty)
        XCTAssertNotNil(computer.preview(for: "chat-b"))
    }

    func testActionsAreBoundedAndCannotUseClipboardOrGlobalShortcuts() throws {
        let id = UUID().uuidString
        let good = try ComputerAction(name: "click", arguments: ["capture_id": id, "x": 100, "y": 50])
        XCTAssertEqual(good.title, "Click at 100, 50")
        for bad: Any in [true, -1, 1280, Double.infinity, Double.nan, 1e100] {
            XCTAssertThrowsError(try ComputerAction(name: "click", arguments: ["capture_id": id, "x": bad, "y": 1]))
        }
        for key in ["cmd+v", "cmd+c", "cmd+q", "cmd+Tab", "cmd+space", "unknown"] {
            XCTAssertThrowsError(try ComputerAction(name: "press_key", arguments: ["capture_id": id, "key": key]))
        }
        XCTAssertThrowsError(try ComputerAction(name: "type_text", arguments: ["capture_id": id, "text": String(repeating: "a", count: 2001)]))
        XCTAssertThrowsError(try ComputerAction(name: "type_text", arguments: ["capture_id": id, "text": "a\u{001B}b"]))
        XCTAssertThrowsError(try ComputerAction(name: "click", arguments: ["capture_id": "not-a-capture", "x": 1, "y": 1]))
        XCTAssertThrowsError(try ComputerAction(name: "scroll", arguments: ["capture_id": id, "x": 1, "y": 1, "direction": "down", "amount": 1.5]))
        XCTAssertNoThrow(try ComputerAction(name: "type_text", arguments: ["capture_id": id, "text": "hello\nworld"]))
    }

    func testCaptureCoordinatesFailClosedOnAgeAndWindowChanges() throws {
        let target = ComputerTarget(id: 1, pid: 2, app: "Fixture", title: "Test", frame: CGRect(x: 10, y: 20, width: 1000, height: 500))
        let now = Date()
        let capture = ComputerCapture(id: UUID().uuidString, target: target, width: 500, height: 250, timestamp: now, jpeg: Data())
        XCTAssertEqual(try capture.point(x: 250, y: 125, current: target, now: now), CGPoint(x: 510, y: 270))
        XCTAssertThrowsError(try capture.point(x: 1, y: 1, current: target, now: now.addingTimeInterval(61)))
        XCTAssertThrowsError(try capture.point(x: 1, y: 1, current: target, now: now.addingTimeInterval(-1)))
        XCTAssertThrowsError(try capture.point(x: 500, y: 1, current: target, now: now))
        let moved = ComputerTarget(id: 1, pid: 2, app: "Fixture", title: "Test", frame: target.frame.offsetBy(dx: 1, dy: 0))
        XCTAssertThrowsError(try capture.point(x: 1, y: 1, current: moved, now: now))
        let reused = ComputerTarget(id: 1, pid: 3, app: "Other", title: "Test", frame: target.frame)
        XCTAssertThrowsError(try capture.point(x: 1, y: 1, current: reused, now: now))
    }

    func testLocalHTTPRejectsBrowserRequestsAndAmbiguousFrames() throws {
        let body = Data("{}".utf8)
        let header = "POST /computer HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nAuthorization: Bearer secret\r\nContent-Length: 2\r\n"
        XCTAssertNil(try ComputerHTTPRequest.parse(Data(header.utf8)))
        let parsed = try XCTUnwrap(ComputerHTTPRequest.parse(Data((header + "\r\n{}").utf8)))
        XCTAssertEqual(parsed.token, "secret")
        XCTAssertEqual(parsed.body, body)
        for field in ["Origin: https://evil.invalid\r\n", "Transfer-Encoding: chunked\r\n", "Content-Length: 2\r\n"] {
            XCTAssertThrowsError(try ComputerHTTPRequest.parse(Data((header + field + "\r\n{}").utf8)))
        }
        XCTAssertThrowsError(try ComputerHTTPRequest.parse(Data(repeating: 65, count: 4097)))
        XCTAssertThrowsError(try ComputerHTTPRequest.parse(Data((header + "\r\n{}extra").utf8)))
    }

    func testComputerConfigurationNeverIncludesSecretsAndRespectsModes() throws {
        for provider in [ModelProvider.codex, .opencode, .grok] {
            for mode in [SessionMode.build, .plan] {
                for permission in PermissionMode.allCases {
                    var options = SendOptions(); options.mode = mode; options.permissions = permission
                    XCTAssertEqual(ComputerConnection.eligible(provider: provider, options: options), provider == .codex && mode == .build && permission != .deny)
                    options.chatMode = true
                    XCTAssertFalse(ComputerConnection.eligible(provider: provider, options: options))
                }
            }
        }
        let args = ComputerConnection.codexArguments(executable: "/tmp/a \"quoted\"/Kiln")
        XCTAssertTrue(args.contains { $0.contains("env_vars=") })
        XCTAssertTrue(args.contains("mcp_servers.kiln_computer.required=true"))
        XCTAssertFalse(args.contains { $0.contains("Bearer") })
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(OpenCodeProtocol.configuration(SendOptions(), computerExecutable: "/app/Kiln", majorVersion: 2).utf8)) as? [String: Any])
        let servers = (config["mcp"] as? [String: Any])?["servers"] as? [String: Any]
        XCTAssertNotNil(servers?["kiln_computer"])
        var readOnly = SendOptions(); readOnly.permissions = .deny
        XCTAssertFalse(OpenCodeProtocol.configuration(readOnly, computerExecutable: "/app/Kiln").contains("kiln_computer"))
        XCTAssertEqual(CLIVersion("opencode v2.0.22")?.major, 2)
    }

    func testWindowIdentityRejectsDuplicateBoundsAndReusedIdentifiers() {
        let first = ComputerTarget(id: 1, pid: 9, app: "Fixture", title: "", frame: CGRect(x: 10, y: 10, width: 500, height: 400))
        let duplicate = ComputerTarget(id: 2, pid: 9, app: "Fixture", title: "", frame: first.frame)
        XCTAssertTrue(first.uniquelyIdentifies([first]))
        XCTAssertFalse(first.uniquelyIdentifies([first, duplicate]))
        XCTAssertFalse(first.uniquelyIdentifies([duplicate]))
    }

    @MainActor func testConsentRevokedWhileListenerStartsCannotCreateALateGrant() async throws {
        let fixture = ComputerFixture()
        let computer = ComputerUse(driver: fixture.driver())
        let session = UUID().uuidString
        try computer.enable(sessionID: session, target: fixture.target, model: .gpt55)
        let task = Task { try await computer.startTurn(sessionID: session, model: .gpt55, options: SendOptions()) }
        await Task.yield()
        computer.stop()
        do { let turn = try await task.value; XCTAssertNil(turn) }
        catch { XCTAssertNil(computer.enabled[session]) }
    }

    func testOpenCodeV2UsesPrivateServerAndCurrentPermissionSchema() throws {
        var options = SendOptions(); options.permissions = .deny
        let model = try XCTUnwrap(AgentModel(rawValue: "opencode:openai/gpt-5.5"))
        let args = OpenCodeProtocol.arguments(sessionId: "existing", model: model, workDir: "/tmp", options: options, majorVersion: 2)
        XCTAssertTrue(args.contains("--standalone"))
        XCTAssertFalse(args.contains("--pure"))
        XCTAssertFalse(args.contains("--dir"))
        XCTAssertFalse(args.contains("--variant"))
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(OpenCodeProtocol.configuration(options, majorVersion: 2).utf8)) as? [String: Any])
        let rules = try XCTUnwrap(config["permissions"] as? [[String: String]])
        XCTAssertEqual(rules.first?["effect"], "deny")
        let policies = try XCTUnwrap(config["policies"] as? [[String: String]])
        XCTAssertTrue(policies.contains(["action": "plugin.use", "resource": "*", "effect": "deny"]))
        let legacy = try XCTUnwrap((config["experimental"] as? [String: Any])?["policies"] as? [[String: String]])
        XCTAssertEqual(legacy.first, ["action": "permission", "resource": "*", "effect": "deny"])
        XCTAssertTrue(legacy.contains(["action": "permission", "resource": "read:*", "effect": "allow"]))
        XCTAssertNil(config["permission"])
        let models = OpenCodeModels.parseV2(Data("openai/gpt-5.5\nnot a model\nopenai/gpt-5.5\n".utf8))
        XCTAssertEqual(models.count, 1)
        XCTAssertTrue(models[0].efforts.isEmpty)
        let events = OpenCodeProtocol.parse(["type": "error", "error": ["message": "Model unavailable"]])
        XCTAssertTrue(events.contains { if case .error("Model unavailable") = $0 { true } else { false } })
    }

    @MainActor func testMCPHandshakeAndInactiveCallsDoNotStartUIOrGrantAccess() async throws {
        let initReply = await ComputerMCP.response(["id": 1, "method": "initialize", "params": ["protocolVersion": "2025-11-25"]], environment: [:])
        let result = try XCTUnwrap(initReply?["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, "2025-11-25")
        XCTAssertEqual(result["instructions"] as? String, ComputerConnection.instructions)
        let list = await ComputerMCP.response(["id": 2, "method": "tools/list"], environment: [:])
        let tools = try XCTUnwrap((list?["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        XCTAssertEqual(Set(tools.compactMap { $0["name"] as? String }), ["status", "observe", "click", "type_text", "press_key", "scroll"])
        let denied = await ComputerMCP.response(["id": 3, "method": "tools/call", "params": ["name": "observe"]], environment: [:])
        XCTAssertEqual((denied?["result"] as? [String: Any])?["isError"] as? Bool, true)
        let notification = await ComputerMCP.response(["method": "notifications/initialized"], environment: [:])
        XCTAssertNil(notification)
    }

    func testSharedWindowGuidanceOnlyAppearsInConnectedTurns() {
        var options = SendOptions()
        options.systemPrompt = "Keep the user's existing session instructions."
        let message = "Can you see the thing I am sharing?"
        let inactive = AgentService.buildPrompt(message: message, options: options)
        XCTAssertFalse(inactive.contains(ComputerConnection.instructions))
        let connected = AgentService.buildPrompt(message: message, options: options, computerConnected: true)
        XCTAssertTrue(connected.contains(options.systemPrompt!))
        XCTAssertTrue(connected.contains(ComputerConnection.instructions))
        XCTAssertTrue(connected.hasSuffix(message))
        let next = AgentService.buildPrompt(message: "Sharing stopped.", options: options)
        XCTAssertFalse(next.contains(ComputerConnection.instructions))
        XCTAssertTrue(ComputerConnection.instructions.hasPrefix("Kiln's selected-window tools"))
        XCTAssertTrue(ComputerConnection.instructions.prefix(512).contains("status tool, then observe"))
    }

    @MainActor func testInputWaitsForApprovalAndCaptureCannotBeReplayed() async throws {
        let fixture = ComputerFixture()
        let computer = ComputerUse(driver: fixture.driver())
        let session = UUID().uuidString
        try computer.enable(sessionID: session, target: fixture.target, model: .gpt55)
        let started = try await computer.startTurn(sessionID: session, model: .gpt55, options: SendOptions())
        let turn = try XCTUnwrap(started)
        defer { computer.stop() }
        _ = await computer.handle(ComputerUse.encode(["name": "observe"]), token: turn.token)
        let action = ComputerUse.encode(["name": "click", "arguments": ["capture_id": fixture.captureID, "x": 30, "y": 40]])
        let request = Task { await computer.handle(action, token: turn.token) }
        for _ in 0..<100 where computer.pending == nil { await Task.yield() }
        XCTAssertEqual(fixture.dispatched, 0)
        let proposal = try XCTUnwrap(computer.pending)
        computer.decide(id: "wrong-proposal", allow: true)
        XCTAssertNotNil(computer.pending)
        computer.decide(id: proposal.id, allow: true)
        let response = try decode(await request.value)
        XCTAssertNil(response["isError"])
        XCTAssertEqual(fixture.dispatched, 1)
        let replay = try decode(await computer.handle(action, token: turn.token))
        XCTAssertEqual(replay["isError"] as? Bool, true)
        XCTAssertEqual(fixture.dispatched, 1)
    }

    @MainActor func testStopPermissionLossAndMovedWindowInvalidatePendingApproval() async throws {
        for change in ["stop", "permission", "move"] {
            let fixture = ComputerFixture()
            let computer = ComputerUse(driver: fixture.driver())
            let session = UUID().uuidString
            try computer.enable(sessionID: session, target: fixture.target, model: .gpt55)
            let started = try await computer.startTurn(sessionID: session, model: .gpt55, options: SendOptions())
            let turn = try XCTUnwrap(started)
            _ = await computer.handle(ComputerUse.encode(["name": "observe"]), token: turn.token)
            let data = ComputerUse.encode(["name": "click", "arguments": ["capture_id": fixture.captureID, "x": 10, "y": 10]])
            let request = Task { await computer.handle(data, token: turn.token) }
            for _ in 0..<100 where computer.pending == nil { await Task.yield() }
            let proposal = try XCTUnwrap(computer.pending)
            if change == "stop" { computer.stop() }
            if change == "permission" { fixture.allowed = false }
            if change == "move" { fixture.target = ComputerTarget(id: fixture.target.id, pid: fixture.target.pid, app: "Fixture", title: "Test", frame: fixture.target.frame.offsetBy(dx: 1, dy: 0)) }
            computer.decide(id: proposal.id, allow: true)
            let response = await request.value
            XCTAssertEqual(try decode(response)["isError"] as? Bool, true)
            XCTAssertEqual(fixture.dispatched, 0, change)
            computer.stop()
        }
    }

    @MainActor func testExpiredApprovalAndModelSwitchFailClosed() async throws {
        let fixture = ComputerFixture()
        let computer = ComputerUse(driver: fixture.driver(), approvalLifetime: 0.02)
        let session = UUID().uuidString
        try computer.enable(sessionID: session, target: fixture.target, model: .gpt55)
        let started = try await computer.startTurn(sessionID: session, model: .gpt55, options: SendOptions())
        let turn = try XCTUnwrap(started)
        defer { computer.stop() }
        _ = await computer.handle(ComputerUse.encode(["name": "observe"]), token: turn.token)
        let response = await computer.handle(ComputerUse.encode(["name": "press_key", "arguments": ["capture_id": fixture.captureID, "key": "Enter"]]), token: turn.token)
        XCTAssertEqual(try decode(response)["isError"] as? Bool, true)
        XCTAssertEqual(fixture.dispatched, 0)
        computer.endTurn(turn)
        do { _ = try await computer.startTurn(sessionID: session, model: .gpt54, options: SendOptions()); XCTFail("Model change must revoke consent") }
        catch { XCTAssertNil(computer.enabled[session]) }
    }

    @MainActor func testMCPProxyUsesOnlyActiveTurnAndRejectsRevokedToken() async throws {
        let fixture = ComputerFixture()
        let computer = ComputerUse(driver: fixture.driver())
        let session = UUID().uuidString
        try computer.enable(sessionID: session, target: fixture.target, model: .gpt55)
        let started = try await computer.startTurn(sessionID: session, model: .gpt55, options: SendOptions())
        let turn = try XCTUnwrap(started)
        defer { computer.stop() }
        let result = await ComputerMCP.response(["id": 1, "method": "tools/call", "params": ["name": "observe"]], environment: turn.environment)
        XCTAssertNotNil((result?["result"] as? [String: Any])?["content"])
        computer.endTurn(turn)
        let denied = try decode(await computer.handle(ComputerUse.encode(["name": "observe"]), token: turn.token))
        XCTAssertEqual(denied["isError"] as? Bool, true)
    }

    @MainActor func testRemoteOriginsNeverInheritNativeConsent() async throws {
        let fixture = ComputerFixture()
        let computer = ComputerUse(driver: fixture.driver())
        let session = UUID().uuidString
        try computer.enable(sessionID: session, target: fixture.target, model: .gpt55)
        defer { computer.stop() }
        var options = SendOptions(); options.computerUseAllowed = false
        let turn = try await computer.startTurn(sessionID: session, model: .gpt55, options: options)
        XCTAssertNil(turn)
        XCTAssertEqual(fixture.dispatched, 0)
    }

    func testRunLogsOmitScreenshotPayloadsAndComputerTyping() throws {
        let input: [String: Any] = ["type": "tool_call", "toolName": "kiln_computer__type_text", "rawInput": ["text": "private typing"],
                                  "rawOutput": ["content": [["type": "image", "data": "private-pixels", "mimeType": "image/jpeg"]]]]
        let redacted = try JSONSerialization.data(withJSONObject: ToolOutputPrivacy.redact(input))
        let text = String(decoding: redacted, as: UTF8.self)
        XCTAssertFalse(text.contains("private typing"))
        XCTAssertFalse(text.contains("private-pixels"))
        XCTAssertTrue(text.contains("kiln_computer"))
        let encoded: [String: Any] = ["tool": "kiln_computer_observe", "output": "[{\"type\":\"image\",\"data\":\"private-pixels\"}]"]
        let rendered = try JSONSerialization.data(withJSONObject: ToolOutputPrivacy.redact(encoded))
        XCTAssertFalse(String(decoding: rendered, as: UTF8.self).contains("private-pixels"))
        let pretty: [String: Any] = ["tool_name": "kiln_computer_type_text", "arguments": " \n {\"text\":\"private typing\"}"]
        let prettyData = try JSONSerialization.data(withJSONObject: ToolOutputPrivacy.redact(pretty))
        XCTAssertFalse(String(decoding: prettyData, as: UTF8.self).contains("private typing"))
        XCTAssertEqual(ToolOutputPrivacy.redact(["type": "text", "data": "ordinary response"])["data"] as? String, "ordinary response")
    }

    private func decode(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
