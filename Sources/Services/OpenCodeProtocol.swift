import Foundation

enum OpenCodeProtocol {
    static var executablePath: String {
        [NSHomeDirectory() + "/.opencode/bin/opencode", "/opt/homebrew/bin/opencode", "/usr/local/bin/opencode"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/env"
    }

    static func arguments(sessionId: String?, model: AgentModel, workDir: String, options: SendOptions, filePaths: [String] = []) -> [String] {
        var args = ["run", "--format", "json", "--model", model.cliModel, "--dir", workDir, "--pure"]
        if let sessionId { args += ["--session", sessionId] }
        if options.mode == .plan || options.chatMode || options.permissions == .deny {
            args += ["--agent", "plan"]
        } else if options.permissions == .bypass {
            args.append("--auto")
        }
        if options.thinkingEnabled {
            args.append("--thinking")
            if let effort = options.effortLevel?.rawValue, model.reasoningEfforts.contains(effort) {
                args += ["--variant", effort]
            }
        }
        args += filePaths.flatMap { ["--file", $0] }
        return args
    }

    static func configuration(_ options: SendOptions) -> String {
        let readOnly = options.mode == .plan || options.chatMode || options.permissions == .deny
        let permission: [String: String] = readOnly
            ? ["*": "deny", "read": "allow", "glob": "allow", "grep": "allow"]
            : ["*": options.permissions == .bypass ? "allow" : "ask"]
        let data = try? JSONSerialization.data(withJSONObject: ["share": "disabled", "permission": permission])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    static func parse(_ json: [String: Any]) -> [AgentEvent] {
        guard let type = json["type"] as? String else { return [] }
        var events: [AgentEvent] = []
        if let id = json["sessionID"] as? String { events.append(.sessionId(id)) }
        let part = json["part"] as? [String: Any] ?? [:]
        events.append(.trace(AgentTraceEntry(source: "opencode", phase: type, title: type.replacingOccurrences(of: "_", with: " "))))
        switch type {
        case "text":
            if let text = part["text"] as? String { events.append(.textDelta(text + "\n\n")) }
        case "reasoning":
            if let text = part["text"] as? String { events.append(.thinkingDelta(text + "\n")) }
        case "tool_use":
            let id = part["callID"] as? String ?? part["id"] as? String ?? UUID().uuidString
            let state = part["state"] as? [String: Any] ?? [:]
            let input = state["input"] as? [String: Any] ?? [:]
            let data = try? JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
            let name = part["tool"] as? String ?? "tool"
            let mapped = ["bash": "Bash", "read": "Read", "edit": "Edit", "write": "Write"][name] ?? name
            events.append(.toolStart(id: id, name: mapped, input: data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"))
            if let status = state["status"] as? String, status == "completed" || status == "error" {
                events.append(.toolResult(toolUseId: id,
                    content: state["output"] as? String ?? state["error"] as? String ?? "",
                    isError: status == "error"))
            }
        case "step_finish":
            if let cost = part["cost"] as? Double { events.append(.cost(cost)) }
            if let tokens = part["tokens"] as? [String: Any] {
                let input = tokens["input"] as? Int ?? 0
                let output = tokens["output"] as? Int ?? 0
                events.append(.trace(AgentTraceEntry(source: "opencode", phase: "usage", title: "Token usage",
                    metadata: ["inputTokens": String(input), "outputTokens": String(output)])))
                events.append(.usage(inputTokens: input, outputTokens: output))
            }
        case "error":
            let error = json["error"] as? [String: Any] ?? [:]
            let data = error["data"] as? [String: Any] ?? [:]
            events.append(.error(data["message"] as? String ?? error["name"] as? String ?? "OpenCode failed"))
        default: break
        }
        return events
    }
}

final class OpenCodeModels: @unchecked Sendable {
    static let shared = OpenCodeModels()
    private let lock = NSLock()
    private var snapshot: [ModelDescriptor] = []
    var descriptors: [ModelDescriptor] {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }
    var models: [AgentModel] { descriptors.map(\.model) }

    private func replace(_ value: [ModelDescriptor]) {
        lock.lock()
        snapshot = value
        lock.unlock()
    }

    func reload() async throws {
        let data = try await CodexCLI.output(["models", "--pure", "--verbose"], executable: OpenCodeProtocol.executablePath, command: "opencode")
        let models = Self.parse(data)
        guard !models.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        replace(models)
    }

    /// The CLI frames each pretty-printed JSON object between unindented braces.
    /// Decode the objects structurally; never infer capabilities from a model name.
    static func parse(_ data: Data) -> [ModelDescriptor] {
        var object: [String] = []
        var models: [ModelDescriptor] = []
        var seen = Set<String>()
        for line in String(decoding: data, as: UTF8.self).components(separatedBy: .newlines) {
            if line == "{" { object = [line]; continue }
            guard !object.isEmpty else { continue }
            object.append(line)
            guard line == "}" else { continue }
            defer { object = [] }
            guard let json = try? JSONSerialization.jsonObject(with: Data(object.joined(separator: "\n").utf8)) as? [String: Any],
                  let id = json["id"] as? String,
                  let provider = json["providerID"] as? String,
                  let model = AgentModel(rawValue: "opencode:" + provider + "/" + id),
                  let capabilities = json["capabilities"] as? [String: Any],
                  capabilities["toolcall"] as? Bool == true,
                  let output = capabilities["output"] as? [String: Bool],
                  output["text"] == true, output["image"] != true, output["audio"] != true,
                  seen.insert(model.rawValue).inserted else { continue }
            let limit = json["limit"] as? [String: Int] ?? [:]
            let variants = json["variants"] as? [String: Any] ?? [:]
            models.append(ModelDescriptor(model: model, displayName: json["name"] as? String ?? id,
                description: provider, contextWindow: max(1, limit["context"] ?? 128_000),
                efforts: EffortLevel.allCases.map(\.rawValue).filter { variants[$0] != nil }))
        }
        return models.sorted { $0.model.rawValue < $1.model.rawValue }
    }
}
