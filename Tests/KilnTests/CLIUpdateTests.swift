import XCTest
@testable import Kiln

final class CLIUpdateTests: XCTestCase {
    func testCatalogMustMatchTheSelectedCLI() throws {
        let data = Data(#"{"client_version":"0.151.0","models":[{"slug":"gpt-6-astra","visibility":"list"}]}"#.utf8)
        XCTAssertNotNil(ModelCatalog.parse(data, installedVersion: CLIVersion("0.151.0")))
        XCTAssertNil(ModelCatalog.parse(data, installedVersion: CLIVersion("0.153.4")))
        XCTAssertEqual(AgentModel.defaultModel, .gpt55)
    }

    func testMetadataDiagnosticIsAWarningNotSuccess() {
        var emitted = false
        let events = CodexProtocol.parseEvent(["type": "item.completed", "item": [
            "id": "item_3", "type": "error",
            "message": "Model metadata for gpt-6-astra not found. Defaulting to fallback metadata."
        ]], emittedText: &emitted)
        XCTAssertTrue(events.contains { if case .trace(let entry) = $0 { return entry.phase == "model_metadata" && entry.level == .warning }; return false })
        XCTAssertFalse(events.contains { if case .trace(let entry) = $0 { return entry.level == .success }; return false })
    }

    @MainActor
    func testProcessUsesRequestedDirectoryAndPWD() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kiln work " + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("fixture")
        let source = """
        #!/bin/sh
        cat >/dev/null
        pwd -P > actual-dir
        printf '{"type":"item.completed","item":{"type":"agent_message","text":"%s"}}\\n' "$PWD"
        """
        try source.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let service = AgentService(executablePath: script.path)
        var output = ""
        await service.sendMessage(sessionId: UUID().uuidString, message: "test", model: .gpt55, workDir: directory.path) {
            if case .textDelta(let text) = $0 { output += text }
        }
        let actual = try String(contentsOf: directory.appendingPathComponent("actual-dir"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(output, actual)
        let expectedID = try FileManager.default.attributesOfItem(atPath: directory.path)[.systemFileNumber] as? NSNumber
        let actualID = try FileManager.default.attributesOfItem(atPath: actual)[.systemFileNumber] as? NSNumber
        XCTAssertNotNil(expectedID)
        XCTAssertEqual(actualID, expectedID)
    }

    @MainActor
    func testAstraMetadataWithSelectedCodexWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["KILN_LIVE_CODEX_MODEL_CHECK"] == "1" else {
            throw XCTSkip("Opt-in live model metadata check")
        }
        let service = AgentService()
        let id = UUID().uuidString
        defer { service.forgetThread(for: id) }
        var options = SendOptions()
        options.permissions = .deny
        var output = ""
        var errors: [String] = []
        var metadataWarnings = 0
        let timeout = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            service.interrupt(sessionId: id)
        }
        await service.sendMessage(sessionId: id, message: "Reply with KILN_MODEL_OK only. Do not use tools.", model: .gpt6Astra, workDir: "/tmp", options: options) {
            if case .textDelta(let text) = $0 { output += text }
            if case .error(let error) = $0 { errors.append(error) }
            if case .trace(let trace) = $0, trace.phase == "model_metadata" { metadataWarnings += 1 }
        }
        timeout.cancel()
        XCTAssertTrue(errors.isEmpty, errors.joined(separator: "\n"))
        XCTAssertTrue(output.contains("KILN_MODEL_OK"))
        XCTAssertEqual(metadataWarnings, 0)
    }

    func testVersionParsingAndOrdering() throws {
        XCTAssertEqual(CLIVersion("codex-cli 0.153.4\n")?.text, "0.153.4")
        XCTAssertEqual(CLIVersion("v1.18.29")?.text, "1.18.29")
        XCTAssertEqual(CLIVersion("rust-v0.153.4")?.text, "0.153.4")
        XCTAssertNil(CLIVersion("unknown"))
        XCTAssertNil(CLIVersion("error: version 1.2.3 unavailable"))
        XCTAssertNil(CLIVersion("1.2"))
        let ordered = ["1.2.3-alpha.2", "1.2.3-alpha.10", "1.2.3-beta", "1.2.3", "1.2.10", "1.10.0", "2.0.0"]
        let versions = try ordered.map { try XCTUnwrap(CLIVersion($0)) }
        for index in 1..<versions.count { XCTAssertLessThan(versions[index - 1], versions[index]) }
        XCTAssertEqual(CLIVersion("1.2.3+build1"), CLIVersion("1.2.3+build2"))
    }

    func testInstallationDetectionAndCommands() {
        XCTAssertEqual(CLIInstallMethod.detect(provider: .opencode, resolvedPath: "/opt/homebrew/Cellar/opencode/1.0.0/bin/opencode"), .homebrew)
        XCTAssertEqual(CLIInstallMethod.detect(provider: .codex, resolvedPath: "/opt/homebrew/Caskroom/codex/1.0.0/codex"), .cask)
        XCTAssertEqual(CLIInstallMethod.detect(provider: .codex, resolvedPath: "/usr/local/lib/node_modules/@openai/codex/bin/codex.js"), .npm)
        XCTAssertEqual(CLIInstallMethod.detect(provider: .codex, resolvedPath: "/home/user/.codex/packages/standalone/1/bin/codex"), .standalone)
        XCTAssertEqual(CLIInstallMethod.detect(provider: .codex, resolvedPath: "/home/user/bin/custom-wrapper"), .custom)
        XCTAssertEqual(CLIInstallMethod.homebrew.updateCommand(provider: .opencode, executable: "unused"), "brew upgrade opencode")
        XCTAssertEqual(CLIInstallMethod.npm.updateCommand(provider: .codex, executable: "unused"), "npm install -g @openai/codex@latest")
        XCTAssertEqual(CLIInstallMethod.standalone.updateCommand(provider: .codex, executable: "/Users/test's/bin/codex"), "'/Users/test'\\''s/bin/codex' update")
        XCTAssertNil(CLIInstallMethod.custom.updateCommand(provider: .codex, executable: "/custom"))
    }

    func testReleaseDecodingRejectsNonStableAndInvalidResponses() throws {
        XCTAssertEqual(try CLIReleaseSource.codex.parse(Data(#"{"version":"0.153.4"}"#.utf8)).text, "0.153.4")
        XCTAssertEqual(try CLIReleaseSource.opencode.parse(Data(#"{"tag_name":"v1.18.29","draft":false,"prerelease":false}"#.utf8)).text, "1.18.29")
        XCTAssertEqual(try CLIReleaseSource.brew(.opencode, cask: false).parse(Data(#"{"versions":{"stable":"1.18.20"}}"#.utf8)).text, "1.18.20")
        XCTAssertEqual(try CLIReleaseSource.brew(.codex, cask: true).parse(Data(#"{"version":"0.153.4"}"#.utf8)).text, "0.153.4")
        XCTAssertThrowsError(try CLIReleaseSource.opencode.parse(Data(#"{"tag_name":"v2.0.0","draft":true,"prerelease":false}"#.utf8)))
        XCTAssertThrowsError(try CLIReleaseSource.opencode.parse(Data(#"{"tag_name":"v2.0.0-beta","draft":false,"prerelease":true}"#.utf8)))
        XCTAssertThrowsError(try CLIReleaseSource.codex.parse(Data(#"{"message":"rate limited"}"#.utf8)))
        XCTAssertThrowsError(try CLIReleaseSource.codex.parse(Data("<html>offline</html>".utf8)))
    }

    func testHomebrewLagIsNotAnInstallableUpdate() {
        var result = CLIUpdateResult(provider: .opencode, executable: "/opt/homebrew/bin/opencode", method: .homebrew,
            installed: CLIVersion("1.18.20"), latest: CLIVersion("1.18.29"), available: CLIVersion("1.18.20"), checkedAt: Date())
        XCTAssertEqual(result.status, "Waiting for Homebrew")
        XCTAssertFalse(result.hasUpdate)
        XCTAssertNil(result.command)
        result.available = CLIVersion("1.18.29")
        XCTAssertEqual(result.status, "Update available")
        XCTAssertEqual(result.command, "brew upgrade opencode")
        result.installed = CLIVersion("1.18.29")
        XCTAssertEqual(result.status, "Up to date")
        result.installed = CLIVersion("1.19.0-beta.1")
        XCTAssertEqual(result.status, "Newer than stable")
        result.problem = "Offline"
        XCTAssertEqual(result.status, "Check failed")
        XCTAssertNil(result.command)
    }

    func testNotInstalledAndUncheckedAreDistinct() {
        var result = CLIUpdateResult(provider: .codex)
        XCTAssertEqual(result.status, "Not checked")
        result.checkedAt = Date()
        XCTAssertEqual(result.status, "Not installed")
    }

    @MainActor
    func testChecksCoalesceAndSuccessfulResultsAreCached() async {
        actor Counter {
            var calls = 0
            func increment() { calls += 1 }
        }
        let counter = Counter()
        let checker = CLIUpdateChecker { provider in
            await counter.increment()
            try? await Task.sleep(for: .milliseconds(30))
            return CLIUpdateResult(provider: provider, checkedAt: Date())
        }
        async let first: Void = checker.check()
        async let second: Void = checker.check()
        _ = await (first, second)
        await checker.check(force: false)
        let calls = await counter.calls
        XCTAssertEqual(calls, 2)
        XCTAssertFalse(checker.isChecking)
        XCTAssertNotNil(checker.checkedAt)
        XCTAssertTrue(checker.results.allSatisfy { $0.checkedAt != nil })
    }

    func testLiveReadOnlyChecksWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["KILN_LIVE_UPDATE_CHECKS"] == "1" else {
            throw XCTSkip("Set KILN_LIVE_UPDATE_CHECKS=1 for read-only installed CLI and release checks")
        }
        for provider in [ModelProvider.codex, .opencode] {
            let result = await CLIUpdateInspector.inspect(provider)
            XCTAssertNil(result.problem, result.problem ?? "")
            XCTAssertNotNil(result.installed)
            XCTAssertNotNil(result.latest)
            XCTAssertNotNil(result.available)
            print("\(provider.label): installed=\(result.installed?.text ?? "?") latest=\(result.latest?.text ?? "?") available=\(result.available?.text ?? "?") status=\(result.status)")
        }
    }
}
