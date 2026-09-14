import Foundation
import Combine
import CryptoKit
import Darwin

struct CognitiveConfiguration: Codable, Equatable {
    var engramPython = ""
    var engramDirectory = ""
    var engramConfig = ""
    var mythicPython = "/opt/homebrew/bin/python3.12"
    var mythicLauncher = ""
    var mythicStore = ""

    static var local: Self {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var value = Self()
        value.engramDirectory = home + "/ash/engram"
        value.engramPython = value.engramDirectory + "/.venv/bin/python"
        value.engramConfig = value.engramDirectory + "/config.yaml"
        value.mythicLauncher = home + "/.local/share/mythic/current/launch.py"
        value.mythicStore = home + "/.local/share/mythic/runtime"
        return value
    }

    var engram: CognitiveLaunch {
        CognitiveLaunch(executable: engramPython,
                        arguments: ["-m", "engram", "--config", engramConfig, "api"], directory: engramDirectory)
    }
    var mythic: CognitiveLaunch {
        let command = [engramPython] + engram.arguments
        let data = (try? JSONEncoder().encode(command)) ?? Data()
        return CognitiveLaunch(executable: mythicPython,
                               arguments: ["-I", "-B", mythicLauncher, "--store", mythicStore,
                                           "--engram-command-json", String(data: data, encoding: .utf8) ?? "[]",
                                           "--engram-cwd", engramDirectory], directory: engramDirectory)
    }
}

@MainActor
final class CognitiveStore: ObservableObject {
    static let shared = CognitiveStore()
    @Published var configuration: CognitiveConfiguration
    @Published private(set) var connected = false
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var engramStatus: CognitiveJSON = .null
    @Published private(set) var mythicStatus: CognitiveJSON = .null
    @Published private(set) var context: CognitiveJSON = .null
    @Published private(set) var searchResults: [CognitiveJSON] = []
    @Published private(set) var dormantEvents: [CognitiveJSON] = []
    @Published private(set) var dormantCandidate: CognitiveJSON = .null
    @Published private(set) var assumptions: CognitiveJSON = .null
    @Published private(set) var evidence: CognitiveJSON = .null
    @Published private(set) var snapshot: CognitiveJSON = .null
    @Published private(set) var selection = ""
    @Published private(set) var checkedActions: [String: String] = [:]
    private let engram = LocalCognitiveTransport()
    private let mythic = LocalCognitiveTransport()
    private let defaults: UserDefaults
    private var bindings: [String: String]
    private var project = ""
    private var kilnSession = ""
    private var connectionGeneration = UUID()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        configuration = defaults.data(forKey: "kiln.cognitive.configuration")
            .flatMap { try? JSONDecoder().decode(CognitiveConfiguration.self, from: $0) } ?? .local
        bindings = defaults.dictionary(forKey: "kiln.cognitive.sessions") as? [String: String] ?? [:]
    }

    static func canonicalProject(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        // Foundation hides /private in macOS temp paths; Python uses POSIX realpath.
        if let resolved = realpath(expanded, nil) {
            defer { free(resolved) }
            return String(cString: resolved)
        }
        var parent = URL(fileURLWithPath: expanded).standardizedFileURL
        var suffix: [String] = []
        while parent.path != "/" {
            suffix.insert(parent.lastPathComponent, at: 0)
            parent.deleteLastPathComponent()
            if let resolved = realpath(parent.path, nil) {
                defer { free(resolved) }
                let root = String(cString: resolved)
                return (root == "/" ? "" : root) + "/" + suffix.joined(separator: "/")
            }
        }
        return "/" + suffix.joined(separator: "/")
    }
    static func scopeKey(project: String, session: String) -> String {
        SHA256.hash(data: Data((canonicalProject(project) + "\u{0}" + session).utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func select(project: String, session: String) async {
        let canonical = Self.canonicalProject(project)
        let key = Self.scopeKey(project: canonical, session: session)
        guard selection != key else { return }
        self.project = canonical; kilnSession = session; selection = key
        context = .null; assumptions = .null; evidence = .null; snapshot = .null
        searchResults = []; dormantEvents = []; dormantCandidate = .null
        if connected { await refresh() }
    }

    func connect() async {
        guard !busy else { return }
        busy = true; error = nil; connected = false
        let generation = UUID(); connectionGeneration = generation
        let config = configuration
        defer { busy = false }
        do {
            let discovery = try await engram.call("operations", launch: config.engram)
            guard discovery["protocol"].string == "engram-jsonl", discovery["version"].number == 1 else { throw CognitiveTransportError.malformed }
            let ed = try await engram.call("status", launch: config.engram)
            let md = try await mythic.call("operations", launch: config.mythic)
            guard md["protocol"].string == "mythic-local-v1" else { throw CognitiveTransportError.malformed }
            let ms = try await mythic.call("status", launch: config.mythic)
            guard ms["transport"].string == "local-jsonl", ms["engram"]["connected"].bool else { throw CognitiveTransportError.disconnected }
            guard generation == connectionGeneration, configuration == config else { throw CognitiveTransportError.configuration }
            engramStatus = ed; mythicStatus = ms; connected = true
            defaults.set(try JSONEncoder().encode(configuration), forKey: "kiln.cognitive.configuration")
        } catch { self.error = error.localizedDescription }
        if connected { await refresh() }
    }

    func disconnect() async {
        connectionGeneration = UUID(); connected = false
        await engram.disconnect(); await mythic.disconnect()
        context = .null; assumptions = .null; evidence = .null; snapshot = .null
        dormantEvents = []; dormantCandidate = .null; searchResults = []
    }

    private var scope: [String: CognitiveJSON] {
        ["project_id": .string(project), "session_id": .string(bindings[selection] ?? "")]
    }

    func refresh() async {
        guard connected, !selection.isEmpty else { return }
        let key = selection, generation = connectionGeneration, params = scope
        do {
            let result = try await engram.call("session_resume", params: ["project_id": .string(project), "task": .string(kilnSession)], launch: configuration.engram)
            guard key == selection, generation == connectionGeneration else { return }
            guard result["project_path"].string == project else { throw CognitiveTransportError.malformed }
            context = result
            if bindings[key] != nil {
                let value = try await mythic.call("assumption_inspect", params: params, launch: configuration.mythic)
                guard key == selection, generation == connectionGeneration else { return }
                assumptions = value
            }
        } catch { if key == selection { self.error = error.localizedDescription } }
    }

    func search(_ query: String) async {
        await perform { [self] in
            let result = try await engram.call("search", params: ["query": .string(query), "top_k": .number(8)], launch: configuration.engram, timeout: 90)
            searchResults = result.array
        }
    }

    func reviewDormant() async {
        await perform { [self] in
            dormantCandidate = .null
            dormantEvents = try await engram.call("dormant_review", params: ["limit": .number(20)], launch: configuration.engram).array
        }
    }

    func inspectDormant(_ id: String) async {
        await perform { [self] in dormantCandidate = try await engram.call("dormant_inspect", params: ["event_id": .string(id)], launch: configuration.engram) }
    }

    func feedbackDormant(_ category: String) async {
        let id = dormantCandidate["event_id"].string
        guard !id.isEmpty else { return }
        await perform { [self] in
            _ = try await engram.call("dormant_feedback", params: ["event_id": .string(id), "category": .string(category)], launch: configuration.engram)
            dormantCandidate = .null
        }
    }

    func checkpoint(_ summary: String) async {
        let key = selection, params: [String: CognitiveJSON] = ["project_id": .string(project), "task": .string(kilnSession), "summary": .string(summary)]
        await perform { [self] in
            _ = try await engram.call("session_checkpoint", params: params, launch: configuration.engram)
            if key == selection { await refresh() }
        }
    }

    func createAssumption(statement: String, action: String, maxAge: Double, impact: Int = 2) async {
        let key = selection, project = project
        await perform { [self] in
            var id = bindings[key]
            if id == nil {
                let session = try await mythic.call("session_start", params: ["goal": .string(action)], launch: configuration.mythic)
                id = session["session"]["id"].string
                guard let id, !id.isEmpty else { throw CognitiveTransportError.malformed }
                bindings[key] = id
                defaults.set(bindings, forKey: "kiln.cognitive.sessions")
            }
            _ = try await mythic.call("assumption_create", params: ["project_id": .string(project), "session_id": .string(id!),
                "statement": .string(statement), "decision": .string(action), "impact": .number(Double(impact)), "max_age_seconds": .number(maxAge)], launch: configuration.mythic)
            if key == selection { await refresh() }
        }
    }

    func check(_ assumption: CognitiveJSON, type: String, parameter: String) async {
        var params = scope
        params["assumption_id"] = assumption["id"]
        params["check_type"] = .string(type)
        params["parameters"] = .object(type == "engram_status" ? [:] : [type == "project_file_exists" ? "path" : "tool": .string(parameter)])
        let key = selection
        await perform { [self] in
            let result = try await mythic.call("assumption_check", params: params, launch: configuration.mythic)
            if key == selection { evidence = result; await refresh() }
        }
    }

    func publishEvidence(_ assumption: CognitiveJSON) async {
        var params = scope
        params["assumption_id"] = assumption["id"]
        params["evidence_id"] = assumption["latest_evidence"]["id"]
        let key = selection
        await perform { [self] in
            let result = try await mythic.call("assumption_publish_evidence", params: params, launch: configuration.mythic)
            if key == selection { evidence = result }
        }
    }

    func inspectEvidence(_ assumption: CognitiveJSON) async {
        var params = scope; params["assumption_id"] = assumption["id"]
        let key = selection
        await perform { [self] in
            let result = try await mythic.call("assumption_evidence", params: params, launch: configuration.mythic)
            if key == selection { evidence = result }
        }
    }

    func inspectSession() async {
        guard let id = bindings[selection] else { return }
        let key = selection
        await perform { [self] in
            let result = try await mythic.call("session_snapshot", params: ["session_id": .string(id)], launch: configuration.mythic)
            if key == selection { snapshot = result }
        }
    }

    func useForNextRequest(_ action: String) { checkedActions[selection] = action }
    func checkedAction(project: String, session: String) -> String? {
        checkedActions[Self.scopeKey(project: project, session: session)]
    }
    func clearCheckedAction(project: String, session: String) {
        checkedActions.removeValue(forKey: Self.scopeKey(project: project, session: session))
    }

    /// Gate only an explicitly selected dependency. Corrective and ordinary chat stays usable.
    func preflight(project: String, session: String, action: String? = nil) async -> String? {
        guard let action else { return nil }
        let canonical = Self.canonicalProject(project)
        let key = Self.scopeKey(project: canonical, session: session)
        guard let id = bindings[key] else { return "No saved assumptions belong to this project and session." }
        guard connected else { return "Connect Mythic to check this session's saved assumptions before sending." }
        let params: [String: CognitiveJSON] = ["project_id": .string(canonical), "session_id": .string(id)]
        do {
            let result = try await mythic.call("assumption_inspect", params: params, launch: configuration.mythic)
            let all = result["assumptions"].array + result["deferred"].array
            guard all.contains(where: { $0["decision"].string == action }) else { return "This decision has no saved assumptions in the current session." }
            do {
                var decisionParams = params; decisionParams["action"] = .string(action)
                let decision = try await mythic.call("assumption_decide", params: decisionParams, launch: configuration.mythic)
                if decision["disposition"].string != "proceed" {
                    if key == selection { assumptions = result; evidence = decision }
                    return "Request held: \(action). Review its \(decision["disposition"].string) decision in Memory > Assumptions."
                }
            }
            return nil
        } catch { return "Request held: assumption checks are unavailable. " + error.localizedDescription }
    }

    private func perform(_ body: () async throws -> Void) async {
        guard connected, !busy else { return }
        busy = true; error = nil
        defer { busy = false }
        do { try await body() } catch { self.error = error.localizedDescription }
    }
}
