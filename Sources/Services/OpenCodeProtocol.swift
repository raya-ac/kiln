import Foundation

enum OpenCodeProtocol {
    static var executablePath: String {
        [NSHomeDirectory() + "/.opencode/bin/opencode", "/opt/homebrew/bin/opencode", "/usr/local/bin/opencode"]
            .first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/env"
    }

    static func installedMajorVersion() async throws -> Int {
        let data = try await CodexCLI.output(["--version"], executable: executablePath, command: "opencode")
        guard let version = CLIVersion(String(decoding: data, as: UTF8.self)) else { throw CocoaError(.fileReadCorruptFile) }
        return version.major
    }

    static func arguments(sessionId: String?, model: AgentModel, workDir: String, options: SendOptions, filePaths: [String] = [], majorVersion: Int = 1) -> [String] {
        let effort = options.thinkingEnabled ? options.effortLevel?.rawValue : nil
        let variant = effort.flatMap { model.reasoningEfforts.contains($0) ? $0 : nil }
        let cliModel = model.cliModel + (majorVersion >= 2 ? variant.map { "#" + $0 } ?? "" : "")
        var args = ["run", "--format", "json", "--model", cliModel]
        args += majorVersion >= 2 ? ["--standalone"] : ["--dir", workDir, "--pure"]
        if let sessionId { args += ["--session", sessionId] }
        if options.mode == .plan || options.chatMode || options.permissions == .deny {
            args += ["--agent", "plan"]
        } else if options.permissions == .bypass {
            args.append("--auto")
        }
        if options.thinkingEnabled {
            args.append("--thinking")
            if let variant, majorVersion < 2 {
                args += ["--variant", variant]
            }
        }
        args += filePaths.flatMap { ["--file", $0] }
        return args
    }

    static func configuration(_ options: SendOptions, computerExecutable: String? = nil, majorVersion: Int = 1) -> String {
        let readOnly = options.mode == .plan || options.chatMode || options.permissions == .deny
        let permission: [String: String] = readOnly
            ? ["*": "deny", "read": "allow", "glob": "allow", "grep": "allow"]
            : ["*": options.permissions == .bypass ? "allow" : "ask"]
        var config: [String: Any] = ["share": "disabled", "permission": permission]
        if majorVersion >= 2 {
            var rules = [["action": "*", "resource": "*", "effect": readOnly ? "deny" : options.permissions == .bypass ? "allow" : "ask"]]
            var policies = [["action": "plugin.use", "resource": "*", "effect": "deny"]]
            if readOnly {
                policies.append(["action": "tool.use", "resource": "*", "effect": "deny"])
                for action in ["read", "glob", "grep"] {
                    rules.append(["action": action, "resource": "*", "effect": "allow"])
                    policies.append(["action": "tool.use", "resource": action + ":*", "effect": "allow"])
                }
            }
            config = ["permissions": rules, "policies": policies, "plugins": []]
            if readOnly {
                // Early V2 releases advertise only this policy shape in their live schema.
                config["experimental"] = ["policies": policies.filter { $0["action"] == "tool.use" }.map {
                    ["action": "permission", "resource": $0["resource"] ?? "*", "effect": $0["effect"] ?? "deny"]
                }]
            }
        }
        if let computerExecutable, !readOnly, majorVersion >= 2 {
            var rules = config["permissions"] as? [[String: String]] ?? []
            rules.append(["action": "kiln_computer_*", "resource": "*", "effect": "allow"])
            config["permissions"] = rules
            config["mcp"] = ["servers": [ComputerConnection.serverName: ComputerConnection.openCodeServer(executable: computerExecutable)]]
        }
        let data = try? JSONSerialization.data(withJSONObject: config)
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
                if let id = part["id"] as? String, !id.isEmpty {
                    events.append(.measuredUsage(.openCode(tokens, sourceID: id)))
                }
                let input = tokens["input"] as? Int ?? 0
                let output = tokens["output"] as? Int ?? 0
                events.append(.trace(AgentTraceEntry(source: "opencode", phase: "usage", title: "Token usage",
                    metadata: ["inputTokens": String(input), "outputTokens": String(output)])))
                events.append(.usage(inputTokens: input, outputTokens: output))
            }
        case "error":
            let error = json["error"] as? [String: Any] ?? [:]
            let data = error["data"] as? [String: Any] ?? [:]
            events.append(.error(data["message"] as? String ?? error["message"] as? String ?? error["name"] as? String ?? "OpenCode failed"))
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
        let major = try await OpenCodeProtocol.installedMajorVersion()
        let data = try await CodexCLI.output(major >= 2 ? ["models", "--standalone"] : ["models", "--pure", "--verbose"], executable: OpenCodeProtocol.executablePath, command: "opencode")
        let models = major >= 2 ? Self.parseV2(data) : Self.parse(data)
        guard !models.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        replace(models)
    }

    static func parseV2(_ data: Data) -> [ModelDescriptor] {
        var seen = Set<String>()
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { line in
            let id = line.trimmingCharacters(in: .whitespaces)
            guard id.split(separator: "/").count == 2, !id.contains(where: \.isWhitespace),
                  let model = AgentModel(rawValue: "opencode:" + id), seen.insert(id).inserted else { return nil }
            // V2's CLI lists IDs only; do not invent reasoning or media capabilities.
            return ModelDescriptor(model: model, displayName: model.cliModel, description: "OpenCode", contextWindow: 128_000, efforts: [])
        }
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
