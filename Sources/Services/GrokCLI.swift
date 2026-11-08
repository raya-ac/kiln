import Foundation
import CoreFoundation

enum GrokCLI {
    static var executablePath: String {
        let home = NSHomeDirectory()
        let grokHome = ProcessInfo.processInfo.environment["GROK_HOME"] ?? "\(home)/.grok"
        let paths = ["\(grokHome)/bin", "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]
            + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        return paths.map { $0 + "/grok" }.first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/usr/bin/env"
    }

    static func arguments(sessionID: String?, newSessionID: String? = nil, model: AgentModel, workDir: String, options: SendOptions) -> [String] {
        var args = ["--no-auto-update", "--output-format", "streaming-json", "--prompt-file", "/dev/stdin",
                    "--model", model.cliModel, "--cwd", workDir]
        if let sessionID { args += ["--resume", sessionID] }
        else if let newSessionID { args += ["--session-id", newSessionID] }
        let readOnly = options.chatMode || options.mode == .plan || options.permissions == .deny
        args += ["--permission-mode", !readOnly && options.permissions == .bypass ? "bypassPermissions" : "dontAsk"]
        args += ["--sandbox", readOnly ? "read-only" : (options.permissions == .bypass ? "off" : "workspace")]
        if readOnly {
            args += ["--no-subagents", "--deny", "MCPTool", "--deny", "Bash", "--deny", "Edit", "--deny", "Write",
                     "--tools", options.chatMode ? "" : "read_file,grep,list_dir"]
            if options.chatMode { args += ["--deny", "*"] }
        }
        if let maxTurns = options.maxTurns, maxTurns > 0 { args += ["--max-turns", String(maxTurns)] }
        if options.thinkingEnabled, let effort = options.effortLevel?.rawValue, model.reasoningEfforts.contains(effort) {
            args += ["--reasoning-effort", effort]
        }
        return args
    }

    static func updateVersion(_ data: Data) throws -> CLIVersion {
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard json?["error"] == nil || json?["error"] is NSNull,
              let raw = json?["latestVersion"] as? String, let version = CLIVersion(raw) else {
            throw CLIUpdateError.invalidRelease
        }
        return version
    }

    static func installedVersion(_ data: Data) -> CLIVersion? {
        let parts = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isWhitespace)
        guard parts.count >= 2, parts[0] == "grok" else { return nil }
        return CLIVersion(String(parts[1]))
    }
}

enum GrokProtocol {
    static func parseModels(_ data: Data) -> [ModelDescriptor] {
        var inModels = false
        var seen = Set<String>()
        return String(decoding: data, as: UTF8.self).components(separatedBy: .newlines).compactMap { line in
            let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if line == "Available models:" { inModels = true; return nil }
            guard inModels, line.hasPrefix("* ") || line.hasPrefix("- "),
                  let slug = line.dropFirst(2).split(whereSeparator: \.isWhitespace).first,
                  slug.hasPrefix("grok-"), slug.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }),
                  let model = AgentModel(rawValue: "grok:" + slug), seen.insert(model.rawValue).inserted else { return nil }
            // `grok models` does not advertise context limits or effort menus.
            return ModelDescriptor(model: model, displayName: String(slug),
                description: line.contains("(default)") ? "Grok CLI default" : "Grok CLI model", contextWindow: 0, efforts: [])
        }
    }

    struct StreamState {
        var newSessionID: String? = nil
        private var started = false
        private var sessionRecorded = false
        private var tools = Set<String>()
        private var completedTools = Set<String>()
        private var receiptRecorded = false
        private var costRecorded = false

        init(newSessionID: String? = nil) {
            self.newSessionID = newSessionID
        }

        mutating func parse(_ json: [String: Any]) -> [AgentEvent] {
            guard let type = json["type"] as? String else { return [] }
            var events: [AgentEvent] = []
            if !started { started = true; events.append(.messageStart) }
            if !sessionRecorded, ["text", "thought", "tool_call", "usage"].contains(type), let newSessionID {
                sessionRecorded = true
                events.append(.sessionId(newSessionID))
            }
            if let id = json["sessionId"] as? String, !id.isEmpty { events.append(.sessionId(id)) }
            switch type {
            case "text":
                if let text = json["data"] as? String, !text.isEmpty { events.append(.textDelta(text)) }
            case "thought":
                if let text = json["data"] as? String, !text.isEmpty { events.append(.thinkingDelta(text)) }
            case "tool_call", "tool_call_update":
                guard let id = json["toolCallId"] as? String, !id.isEmpty else { return events }
                if tools.insert(id).inserted {
                    events.append(.toolStart(id: id, name: json["toolName"] as? String ?? json["title"] as? String ?? "tool",
                        input: Self.text(json["rawInput"] ?? [:])))
                }
                let status = json["status"] as? String ?? ""
                if ["completed", "failed", "cancelled"].contains(status), completedTools.insert(id).inserted {
                    let content = json["rawOutput"].map(Self.text) ?? Self.text(json["content"] ?? [])
                    events.append(.toolResult(toolUseId: id, content: content, isError: status != "completed"))
                }
            case "end", "error":
                // End/error spend is prompt-local. Per-response usage lines overlap it.
                if !receiptRecorded, let usage = json["usage"] as? [String: Any] {
                    receiptRecorded = true
                    let uncached = MeasuredTokenUsage.count(usage["input_tokens"])
                    let cached = MeasuredTokenUsage.count(usage["cache_read_input_tokens"])
                    let created = MeasuredTokenUsage.count(usage["cache_creation_input_tokens"])
                    let input: Int?
                    if let uncached, let cached, let created {
                        input = MeasuredTokenUsage.count(uncached + cached + created)
                    } else { input = nil }
                    let output = MeasuredTokenUsage.count(usage["output_tokens"])
                    let measured = MeasuredTokenUsage(sourceID: json["requestId"] as? String,
                        input: input, output: output, cached: cached, reasoning: MeasuredTokenUsage.count(usage["reasoning_tokens"]))
                    if measured.hasMeasurement { events.append(.measuredUsage(measured)) }
                    if input != nil || output != nil { events.append(.usage(inputTokens: input ?? 0, outputTokens: output ?? 0)) }
                }
                if !costRecorded, json["cost_is_partial"] as? Bool != true, json["usage_is_incomplete"] as? Bool != true,
                   let cost = json["total_cost_usd"] as? NSNumber, CFGetTypeID(cost) != CFBooleanGetTypeID(),
                   cost.doubleValue.isFinite, cost.doubleValue >= 0 {
                    costRecorded = true
                    events.append(.cost(cost.doubleValue))
                }
                if json["usage_is_incomplete"] as? Bool == true {
                    events.append(.trace(AgentTraceEntry(source: "grok", level: .warning, phase: "usage",
                        title: "Usage is incomplete", detail: "Reported token counts may omit unfinished subagent work.")))
                }
                if type == "error" { events.append(.error(json["message"] as? String ?? "Grok could not complete this turn.")) }
                if type == "end" {
                    let reason = json["stopReason"] as? String ?? "end_turn"
                    events.append(.trace(AgentTraceEntry(source: "grok", level: reason == "end_turn" ? .success : .warning,
                        phase: "turn", title: reason == "end_turn" ? "Turn completed" : "Turn stopped: \(reason)")))
                }
            case "usage", "available_commands": break
            case "plan", "max_turns_reached":
                events.append(.trace(AgentTraceEntry(source: "grok", phase: type, title: type.replacingOccurrences(of: "_", with: " "), detail: Self.text(json))))
            default:
                if type.hasPrefix("auto_compact_") {
                    events.append(.trace(AgentTraceEntry(source: "grok", phase: "compaction", title: type.replacingOccurrences(of: "_", with: " "))))
                }
            }
            return events
        }

        private static func text(_ value: Any) -> String {
            if let string = value as? String { return string }
            return (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
        }
    }
}

final class GrokModels: @unchecked Sendable {
    static let shared = GrokModels()
    private let lock = NSLock()
    private var snapshot: [ModelDescriptor] = []
    var descriptors: [ModelDescriptor] { lock.withLock { snapshot } }
    var models: [AgentModel] { descriptors.map(\.model) }

    func reload() async throws {
        let data = try await CodexCLI.output(["--no-auto-update", "models"], executable: GrokCLI.executablePath, command: "grok",
            environment: ["GROK_DISABLE_AUTOUPDATER": "1", "NO_COLOR": "1"])
        let parsed = GrokProtocol.parseModels(data)
        guard !parsed.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        lock.withLock { snapshot = parsed }
    }
}
