import Foundation

/// Codex CLI arguments and JSONL event mapping, independent of process lifecycle.
enum CodexProtocol {
    nonisolated static func buildArguments(
        threadId: String?,
        model: AgentModel,
        workDir: String,
        options: SendOptions
    ) -> [String] {
        var args: [String] = []
        args += fastModeArgs(for: model, options: options)
        args += reasoningArgs(for: options, model: model)
        args += approvalArgs(for: options)
        args += ["-c", "sandbox_mode=\"\(sandboxMode(for: options) == "--dangerously-bypass-approvals-and-sandbox" ? "danger-full-access" : sandboxMode(for: options))\""]
        args.append("exec")

        if let threadId {
            args += [
                "resume",
                "--json",
                "--skip-git-repo-check",
                "--model", model.rawValue,
            ]
            if sandboxMode(for: options) == "--dangerously-bypass-approvals-and-sandbox" {
                args.append("--dangerously-bypass-approvals-and-sandbox")
            }
            args += [threadId, "-"]
            return args
        }

        args += [
            "--json",
            "--color", "never",
            "--skip-git-repo-check",
            "--model", model.rawValue,
            "--cd", workDir,
        ]
        switch sandboxMode(for: options) {
        case "--dangerously-bypass-approvals-and-sandbox":
            args.append("--dangerously-bypass-approvals-and-sandbox")
        case let sandbox:
            args += ["--sandbox", sandbox]
        }
        args.append("-")
        return args
    }

    nonisolated static func approvalArgs(for options: SendOptions) -> [String] {
        switch options.permissions {
        case .ask:
            // Codex 0.130.0 exposes approval policy as a top-level option,
            // not as an `exec` subcommand option. Keep this before `exec`.
            return ["--ask-for-approval", "on-request"]
        default:
            return []
        }
    }

    nonisolated static func fastModeArgs(for model: AgentModel, options: SendOptions) -> [String] {
        guard options.openAIFastMode, model.supportsOpenAIFastMode else { return [] }
        return [
            "-c", #"service_tier="fast""#,
            "-c", "features.fast_mode=true",
        ]
    }

    nonisolated static func reasoningArgs(for options: SendOptions, model: AgentModel) -> [String] {
        guard options.thinkingEnabled else { return [] }
        let requested = codexReasoningEffort(options.effortLevel ?? .medium)
        let effort = model.reasoningEfforts.contains(requested) ? requested : (model.reasoningEfforts.last ?? "medium")
        return [
            "-c", #"model_reasoning_summary="auto""#,
            "-c", #"model_reasoning_effort="\#(effort)""#,
        ]
    }

    nonisolated static func codexReasoningEffort(_ effort: EffortLevel) -> String { effort.rawValue }

    nonisolated static func sandboxMode(for options: SendOptions) -> String {
        if options.chatMode || options.mode == .plan || options.permissions == .deny {
            return "read-only"
        }
        if options.permissions == .bypass {
            return "--dangerously-bypass-approvals-and-sandbox"
        }
        return "workspace-write"
    }

    nonisolated static func invocationTrace(
        args: [String],
        model: AgentModel,
        workDir: String,
        options: SendOptions
    ) -> AgentTraceEntry {
        let displayArgs = args.map(redactArgument).joined(separator: " ")
        var metadata: [String: String] = [
            "model": model.rawValue,
            "provider": model.providerDisplayName,
            "workDir": workDir,
            "mode": options.mode.rawValue,
            "permissions": options.permissions.rawValue,
            "sandbox": sandboxMode(for: options).replacingOccurrences(of: "--", with: ""),
        ]
        if options.thinkingEnabled {
            metadata["reasoning"] = codexReasoningEffort(options.effortLevel ?? .medium)
            metadata["reasoningSummary"] = "auto"
        }
        if options.openAIFastMode {
            metadata["serviceTier"] = "fast"
        }
        return trace(
            level: .info,
            phase: "launch",
            title: "\(model.provider.label) launched",
            detail: "\(model.provider.rawValue) \(displayArgs)",
            metadata: metadata
        )
    }

    nonisolated static func redactArgument(_ arg: String) -> String {
        let lower = arg.lowercased()
        if lower.contains("token") || lower.contains("secret") || lower.contains("key") {
            return "<redacted>"
        }
        return arg
    }

    nonisolated static func parseEvent(_ json: [String: Any], emittedText: inout Bool) -> [AgentEvent] {
        guard let type = json["type"] as? String else { return [] }

        switch type {
        case "thread.started":
            var events: [AgentEvent] = [
                .trace(trace(
                    level: .info,
                    phase: "thread",
                    title: "Codex thread started",
                    detail: json["thread_id"] as? String ?? "",
                    metadata: ["type": type]
                ))
            ]
            if let threadId = json["thread_id"] as? String {
                events.insert(.sessionId(threadId), at: 0)
            }
            return events

        case "turn.started":
            return [
                .messageStart,
                .trace(trace(level: .info, phase: "turn", title: "Turn started", metadata: ["type": type])),
            ]

        case "turn.completed":
            var events: [AgentEvent] = []
            if let usage = json["usage"] as? [String: Any] {
                let input = usage["input_tokens"] as? Int ?? 0
                let output = usage["output_tokens"] as? Int ?? 0
                events.append(.usage(inputTokens: input, outputTokens: output))
                events.append(.trace(usageTrace(usage)))
            }
            events.append(.trace(trace(level: .success, phase: "turn", title: "Turn completed", metadata: ["type": type])))
            events.append(.done)
            return events

        case "error":
            return [.error(json["message"] as? String ?? "Codex error")]

        case "turn.failed":
            let message = (json["error"] as? [String: Any])?["message"] as? String
                ?? json["error"] as? String ?? "Codex turn failed"
            let event = AgentEvent.trace(trace(
                level: .error,
                phase: "turn",
                title: "Turn failed",
                detail: message,
                metadata: ["type": type]
            ))
            return [event, .error(message), .done]

        case "item.started":
            guard let item = json["item"] as? [String: Any],
                  let itemType = item["type"] as? String else { return [] }
            if itemType == "command_execution" {
                let id = item["id"] as? String ?? UUID().uuidString
                let command = item["command"] as? String ?? ""
                let input = (try? JSONSerialization.data(withJSONObject: ["command": command]))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                return [
                    .trace(itemTrace(item, itemType: itemType, completed: false)),
                    .toolStart(id: id, name: "Bash", input: input),
                ]
            }
            if itemType == "file_change" {
                return [.trace(itemTrace(item, itemType: itemType, completed: false))]
                    + fileChangeEvents(from: item, completed: false)
            }
            if let tool = genericToolStartEvent(from: item, itemType: itemType) {
                return [.trace(itemTrace(item, itemType: itemType, completed: false)), tool]
            }
            return [.trace(itemTrace(item, itemType: itemType, completed: false))]

        case "item.completed":
            guard let item = json["item"] as? [String: Any],
                  let itemType = item["type"] as? String else { return [] }
            switch itemType {
            case "error":
                let message = item["message"] as? String ?? "Codex reported a diagnostic"
                let metadataWarning = message.contains("Model metadata for")
                return [.trace(trace(
                    level: metadataWarning || message.contains("Under-development features") ? .warning : .error,
                    phase: metadataWarning ? "model_metadata" : "diagnostic",
                    title: metadataWarning ? "Model metadata unavailable" : "Codex diagnostic",
                    detail: message,
                    metadata: ["id": item["id"] as? String ?? ""]
                ))]
            case "agent_message":
                guard let text = item["text"] as? String, !text.isEmpty else { return [] }
                let event = AgentEvent.trace(itemTrace(item, itemType: itemType, completed: true))
                if emittedText {
                    return [event, .textDelta("\n\n" + text)]
                } else {
                    emittedText = true
                    return [event, .textDelta(text)]
                }
            case "reasoning":
                let text = (item["text"] as? String)
                    ?? (item["summary"] as? String)
                    ?? ((item["summaries"] as? [String])?.joined(separator: "\n"))
                guard let text, !text.isEmpty else { return [] }
                return [
                    .trace(itemTrace(item, itemType: itemType, completed: true)),
                    .thinkingDelta(text),
                ]
            case "command_execution":
                let id = item["id"] as? String ?? UUID().uuidString
                let output = item["aggregated_output"] as? String ?? ""
                let exitCode = item["exit_code"] as? Int ?? 0
                return [
                    .trace(itemTrace(item, itemType: itemType, completed: true)),
                    .toolStart(id: id, name: "Bash", input: compactJSON(["command": item["command"] as? String ?? ""])),
                    .toolResult(toolUseId: id, content: output, isError: exitCode != 0),
                ]
            case "file_change":
                return [.trace(itemTrace(item, itemType: itemType, completed: true))]
                    + fileChangeEvents(from: item, completed: true)
            default:
                var events: [AgentEvent] = [.trace(itemTrace(item, itemType: itemType, completed: true))]
                if let start = genericToolStartEvent(from: item, itemType: itemType) { events.append(start) }
                if let result = genericToolResultEvent(from: item, itemType: itemType) {
                    events.append(result)
                }
                return events
            }

        default:
            return [.trace(trace(
                level: .debug,
                phase: "event",
                title: type,
                detail: compactJSON(json),
                metadata: ["type": type]
            ))]
        }
    }

    nonisolated static func decodeJSONLine(_ line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8)
        else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    nonisolated static func streamLineEvent(_ line: String, stream: String) -> AgentEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let level: AgentTraceLevel = trimmed.localizedCaseInsensitiveContains("error") ? .error :
            (trimmed.localizedCaseInsensitiveContains("warn") ? .warning : .debug)
        return .trace(trace(
            level: level,
            phase: stream,
            title: "\(stream) output",
            detail: String(trimmed.prefix(1_200)),
            metadata: ["stream": stream]
        ))
    }

    nonisolated static func stderrTraceEvents(_ data: Data) -> [AgentEvent] {
        guard let raw = String(data: data, encoding: .utf8) else { return [] }
        let lines = raw
            .split(whereSeparator: \.isNewline)
            .map(String.init)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return [] }

        let condensed = condenseRepeatedLines(lines)
        let shown = condensed.prefix(40)
        var events = shown.compactMap { streamLineEvent($0, stream: "stderr") }
        if condensed.count > shown.count {
            events.append(.trace(trace(
                level: .warning,
                phase: "stderr",
                title: "stderr condensed",
                detail: "\(condensed.count - shown.count) more stderr lines were hidden or grouped",
                metadata: ["stream": "stderr", "hiddenLines": "\(condensed.count - shown.count)"]
            )))
        }
        return events
    }

    nonisolated static func condenseRepeatedLines(_ lines: [String]) -> [String] {
        var counts: [String: Int] = [:]
        var ordered: [String] = []
        for line in lines {
            if counts[line] == nil {
                ordered.append(line)
            }
            counts[line, default: 0] += 1
        }
        return ordered.map { line in
            let count = counts[line] ?? 1
            return count > 1 ? "\(line) (repeated \(count)x)" : line
        }
    }

    nonisolated static func trace(
        level: AgentTraceLevel,
        phase: String,
        title: String,
        detail: String = "",
        metadata: [String: String] = [:]
    ) -> AgentTraceEntry {
        AgentTraceEntry(
            source: "codex",
            level: level,
            phase: phase,
            title: title,
            detail: detail,
            metadata: metadata
        )
    }

    nonisolated static func usageTrace(_ usage: [String: Any]) -> AgentTraceEntry {
        let input = usage["input_tokens"] as? Int ?? 0
        let cached = usage["cached_input_tokens"] as? Int ?? 0
        let output = usage["output_tokens"] as? Int ?? 0
        let reasoning = usage["reasoning_output_tokens"] as? Int ?? 0
        let detail = "input \(input), cached \(cached), output \(output), reasoning \(reasoning)"
        return trace(
            level: .success,
            phase: "usage",
            title: "Token usage",
            detail: detail,
            metadata: [
                "inputTokens": "\(input)",
                "cachedInputTokens": "\(cached)",
                "outputTokens": "\(output)",
                "reasoningOutputTokens": "\(reasoning)",
            ]
        )
    }

    nonisolated static func itemTrace(
        _ item: [String: Any],
        itemType: String,
        completed: Bool
    ) -> AgentTraceEntry {
        let id = item["id"] as? String ?? ""
        let status = (item["status"] as? String) ?? (completed ? "completed" : "started")
        let level: AgentTraceLevel = {
            if let exit = item["exit_code"] as? Int, exit != 0 { return .error }
            return completed ? .success : .info
        }()
        return trace(
            level: level,
            phase: itemType,
            title: itemTitle(item, itemType: itemType, completed: completed),
            detail: itemDetail(item, itemType: itemType),
            metadata: [
                "id": id,
                "type": itemType,
                "status": status,
            ]
        )
    }

    nonisolated static func itemTitle(
        _ item: [String: Any],
        itemType: String,
        completed: Bool
    ) -> String {
        switch itemType {
        case "agent_message":
            return completed ? "Assistant message emitted" : "Assistant message started"
        case "reasoning":
            return completed ? "Reasoning summary captured" : "Reasoning started"
        case "command_execution":
            return completed ? "Command completed" : "Command started"
        case "file_change":
            return completed ? "File changes completed" : "File changes started"
        default:
            return "\(humanizeItemType(itemType)) \(completed ? "completed" : "started")"
        }
    }

    nonisolated static func itemDetail(_ item: [String: Any], itemType: String) -> String {
        switch itemType {
        case "agent_message":
            return String((item["text"] as? String ?? "").prefix(1_200))
        case "reasoning":
            let text = (item["text"] as? String)
                ?? (item["summary"] as? String)
                ?? ((item["summaries"] as? [String])?.joined(separator: "\n"))
            return String((text ?? "").prefix(1_200))
        case "command_execution":
            let command = item["command"] as? String ?? ""
            let output = item["aggregated_output"] as? String ?? ""
            if output.isEmpty { return command }
            return "\(command)\n\n\(String(output.prefix(1_200)))"
        case "file_change":
            guard let changes = item["changes"] as? [[String: Any]], !changes.isEmpty else {
                return compactJSON(item)
            }
            return changes.map { change in
                let kind = change["kind"] as? String ?? "modify"
                let path = change["path"] as? String ?? ""
                return "\(kind) \(path)"
            }.joined(separator: "\n")
        default:
            return compactJSON(item)
        }
    }

    nonisolated static func humanizeItemType(_ raw: String) -> String {
        raw.split(separator: "_").map { part in
            part.prefix(1).uppercased() + part.dropFirst()
        }.joined(separator: " ")
    }

    nonisolated static func genericToolStartEvent(from item: [String: Any], itemType: String) -> AgentEvent? {
        guard isLikelyToolItem(itemType) else { return nil }
        let id = item["id"] as? String ?? UUID().uuidString
        return .toolStart(
            id: id,
            name: genericToolName(from: item, itemType: itemType),
            input: genericToolInput(from: item)
        )
    }

    nonisolated static func genericToolResultEvent(from item: [String: Any], itemType: String) -> AgentEvent? {
        guard isLikelyToolItem(itemType) else { return nil }
        let id = item["id"] as? String ?? UUID().uuidString
        let result = (item["result"] as? String)
            ?? (item["output"] as? String)
            ?? (item["content"] as? String)
            ?? compactJSON(item)
        let failed = (item["is_error"] as? Bool)
            ?? ((item["status"] as? String)?.localizedCaseInsensitiveContains("fail") ?? false)
        return .toolResult(toolUseId: id, content: result, isError: failed)
    }

    nonisolated static func isLikelyToolItem(_ itemType: String) -> Bool {
        let lowered = itemType.lowercased()
        return lowered.contains("tool")
            || lowered.contains("function")
            || lowered.contains("mcp")
            || lowered.contains("web_search")
    }

    nonisolated static func genericToolName(from item: [String: Any], itemType: String) -> String {
        if let name = item["name"] as? String { return name }
        if let name = item["tool_name"] as? String { return name }
        if let server = item["server"] as? String, let name = item["tool"] as? String {
            return "\(server).\(name)"
        }
        return humanizeItemType(itemType)
    }

    nonisolated static func genericToolInput(from item: [String: Any]) -> String {
        for key in ["input", "arguments", "args", "parameters"] {
            if let value = item[key] {
                return jsonString(value) ?? "\(value)"
            }
        }
        return compactJSON(item)
    }

    nonisolated static func compactJSON(_ value: Any) -> String {
        jsonString(value) ?? "\(value)"
    }

    nonisolated static func jsonString(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string
    }

    nonisolated static func fileChangeEvents(from item: [String: Any], completed: Bool) -> [AgentEvent] {
        guard let itemId = item["id"] as? String,
              let changes = item["changes"] as? [[String: Any]],
              !changes.isEmpty
        else { return [] }

        var events: [AgentEvent] = []
        for (index, change) in changes.enumerated() {
            let path = change["path"] as? String ?? ""
            let kind = change["kind"] as? String ?? "modify"
            let toolId = "\(itemId):\(index)"
            let toolName = toolName(for: kind)
            let input = fileChangeInput(path: path, kind: kind, metadata: change)

            events.append(.toolStart(id: toolId, name: toolName, input: input))
            if completed {
                events.append(.toolResult(
                    toolUseId: toolId,
                    content: fileChangeResultSummary(path: path, kind: kind),
                    isError: false
                ))
            }
        }
        return events
    }

    nonisolated static func toolName(for changeKind: String) -> String {
        switch changeKind {
        case "add":
            return "Write"
        case "delete", "remove":
            return "Edit"
        case "rename", "move":
            return "MultiEdit"
        default:
            return "Edit"
        }
    }

    nonisolated static func fileChangeInput(path: String, kind: String, metadata: [String: Any]) -> String {
        var payload: [String: Any] = [
            "file_path": path,
            "path": path,
            "kind": kind,
        ]

        for key in ["old_path", "previous_path", "from_path", "to_path", "new_path"] {
            if let value = metadata[key] {
                payload[key] = value
            }
        }

        if let json = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
           let string = String(data: json, encoding: .utf8) {
            return string
        }
        return #"{"file_path":"","kind":"modify"}"#
    }

    nonisolated static func fileChangeResultSummary(path: String, kind: String) -> String {
        let filename = path.isEmpty ? "file" : URL(fileURLWithPath: path).lastPathComponent
        switch kind {
        case "add":
            return "Created \(filename)"
        case "delete", "remove":
            return "Deleted \(filename)"
        case "rename", "move":
            return "Renamed \(filename)"
        default:
            return "Updated \(filename)"
        }
    }
}
