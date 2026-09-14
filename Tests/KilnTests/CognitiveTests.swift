import XCTest
@testable import Kiln

final class CognitiveTests: XCTestCase {
    private func fixture(_ code: String) -> CognitiveLaunch {
        CognitiveLaunch(executable: "/usr/bin/python3", arguments: ["-I", "-B", "-u", "-c", code], directory: "/tmp")
    }

    func testPersistentJSONLAndProtocolIsolation() async throws {
        let transport = LocalCognitiveTransport()
        let config = fixture("""
        import sys,json,os
        for line in sys.stdin:
            req=json.loads(line)
            print(json.dumps({'id':req['id'],'result':{'pid':os.getpid(),'operation':req['operation'],'params':req['params']}}),flush=True)
        """)
        let first = try await transport.call("status", launch: config)
        let second = try await transport.call("recall", params: ["project_id": .string("/tmp/project")], launch: config)
        XCTAssertEqual(first["pid"], second["pid"])
        XCTAssertEqual(second["params"]["project_id"].string, "/tmp/project")
        await transport.disconnect()
    }

    func testTimeoutAndMalformedResponseFailClosed() async throws {
        let transport = LocalCognitiveTransport()
        do {
            _ = try await transport.call("status", launch: fixture("import time; time.sleep(20)"), timeout: 0.1)
            XCTFail("must time out")
        } catch { XCTAssertTrue(error.localizedDescription.contains("timed out")) }
        do {
            _ = try await transport.call("status", launch: fixture("import sys; sys.stdin.readline(); print('{\"id\":\"wrong\",\"result\":{}}',flush=True)"))
            XCTFail("must reject wrong request id")
        } catch { XCTAssertTrue(error.localizedDescription.contains("mismatched")) }
        await transport.disconnect()
    }

    func testFullStdinCannotBlockTheDeadline() async throws {
        let transport = LocalCognitiveTransport()
        do {
            _ = try await transport.call("stall", params: ["text": .string(String(repeating: "x", count: 60_000))],
                                         launch: fixture("import time; time.sleep(20)"), timeout: 0.1)
            XCTFail("a child that never reads must time out")
        } catch { XCTAssertTrue(error.localizedDescription.contains("timed out")) }
        await transport.disconnect()
    }

    func testDisconnectAllowsEOFCleanupBeforeTerminating() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let transport = LocalCognitiveTransport()
        let configuration = fixture("""
        import sys,json,time,pathlib
        for line in sys.stdin:
            req=json.loads(line)
            print(json.dumps({'id':req['id'],'result':{}}),flush=True)
        time.sleep(0.1)
        pathlib.Path(\(String(reflecting: file.path))).write_text('closed')
        """)
        _ = try await transport.call("status", launch: configuration)
        await transport.disconnect()
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "closed")
    }

    func testSizeLimitsAndNonExecutableConfiguration() async throws {
        let transport = LocalCognitiveTransport()
        do {
            _ = try await transport.call("status", params: ["text": .string(String(repeating: "x", count: 70_000))], launch: fixture(""))
            XCTFail("must reject oversized requests before starting")
        } catch { XCTAssertTrue(error.localizedDescription.contains("size limit")) }
        do {
            _ = try await transport.call("status", launch: CognitiveLaunch(executable: "python", arguments: [], directory: "/tmp"))
            XCTFail("must reject relative executable")
        } catch { XCTAssertTrue(error.localizedDescription.contains("executable")) }
    }

    @MainActor func testScopeIdentityAndUnconfiguredPreflight() async {
        XCTAssertEqual(CognitiveStore.canonicalProject("/var"), "/private/var")
        XCTAssertEqual(CognitiveStore.scopeKey(project: "/tmp", session: "s"), CognitiveStore.scopeKey(project: "/private/tmp", session: "s"))
        XCTAssertEqual(CognitiveStore.scopeKey(project: "/tmp/a/../b", session: "s"), CognitiveStore.scopeKey(project: "/tmp/b", session: "s"))
        XCTAssertNotEqual(CognitiveStore.scopeKey(project: "/tmp/a", session: "s"), CognitiveStore.scopeKey(project: "/tmp/b", session: "s"))
        let name = "kiln-test-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = CognitiveStore(defaults: defaults)
        let result = await store.preflight(project: "/tmp/a", session: "s")
        XCTAssertNil(result, "ordinary chats do not require local cognition")
    }

    func testMeasuredUsagePreservesUnknownAndRejectsInvalidCounts() {
        let missing = MeasuredTokenUsage.codex(["input_tokens": 12], sourceID: nil)
        XCTAssertEqual(missing.input, 12)
        XCTAssertNil(missing.output)
        XCTAssertNil(missing.cached)
        XCTAssertNil(MeasuredTokenUsage.count(true))
        XCTAssertNil(MeasuredTokenUsage.count(-1))
        XCTAssertNil(MeasuredTokenUsage.count(1.5))
        XCTAssertNil(MeasuredTokenUsage.count(Double.infinity))
        let step = MeasuredTokenUsage.openCode(["input": 10, "output": 5, "cache": ["read": 2], "reasoning": 1], sourceID: "step-id")
        XCTAssertEqual(step.cached, 2)
        XCTAssertEqual(step.reasoning, 1)
        XCTAssertEqual(step.sourceID, "step-id")
    }

    @MainActor func testRealNativeMissingDependencyPersistsAndResumes() async throws {
        guard let configPath = ProcessInfo.processInfo.environment["KILN_NATIVE_COGNITIVE_FIXTURE"] else {
            throw XCTSkip("Set KILN_NATIVE_COGNITIVE_FIXTURE to an initialized isolated Engram config")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-cognitive-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "kiln-cognitive-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CognitiveStore(defaults: defaults)
        store.configuration.engramConfig = configPath
        store.configuration.mythicStore = root.appendingPathComponent("mythic").path
        await store.select(project: root.path, session: "native-test")
        await store.connect()
        XCTAssertTrue(store.connected, store.error ?? "not connected")
        guard store.connected else { return }
        await store.createAssumption(statement: "Required file exists", action: "Build fixture", maxAge: 1)
        XCTAssertNil(store.error)
        let assumption = try XCTUnwrap(store.assumptions["assumptions"].array.first)
        await store.check(assumption, type: "project_file_exists", parameter: "required.txt")
        XCTAssertEqual(store.assumptions["assumptions"].array.first?["state"].string, "contradicted")
        let held = await store.preflight(project: root.path, session: "native-test", action: "Build fixture")
        XCTAssertNotNil(held)
        let ordinary = await store.preflight(project: root.path, session: "native-test")
        XCTAssertNil(ordinary, "a held dependency must not block corrective conversation")
        let checked = try XCTUnwrap(store.assumptions["assumptions"].array.first)
        await store.publishEvidence(checked)
        XCTAssertNil(store.error)
        XCTAssertFalse(store.evidence["verified_by_engram"].bool)
        let receiptID = store.evidence["id"].string
        XCTAssertFalse(receiptID.isEmpty)
        let foreign = await store.preflight(project: root.appendingPathComponent("foreign").path, session: "native-test")
        XCTAssertNil(foreign, "bindings must not cross projects")
        await store.disconnect()
        let resumed = CognitiveStore(defaults: defaults)
        await resumed.select(project: root.path, session: "native-test")
        await resumed.connect()
        XCTAssertTrue(resumed.connected, resumed.error ?? "not connected")
        XCTAssertEqual(resumed.assumptions["assumptions"].array.first?["id"], assumption["id"])
        XCTAssertEqual(resumed.assumptions["decisions"].array.last?["disposition"].string, "revise")
        let restored = try XCTUnwrap(resumed.assumptions["assumptions"].array.first)
        try Data("fixture".utf8).write(to: root.appendingPathComponent("required.txt"))
        await resumed.check(restored, type: "project_file_exists", parameter: "required.txt")
        let allowed = await resumed.preflight(project: root.path, session: "native-test", action: "Build fixture")
        XCTAssertNil(allowed)
        try await Task.sleep(for: .milliseconds(1100))
        let stale = await resumed.preflight(project: root.path, session: "native-test", action: "Build fixture")
        XCTAssertNotNil(stale)
        await resumed.disconnect()
    }
}
