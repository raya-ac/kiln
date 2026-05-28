import Foundation

/// Spawns and manages Codex CLI processes for chat/code sessions.
@MainActor
final class CodexService: ObservableObject {
    private static let threadMapKey = "kiln.codexThreadIds"
    private var threadIds: [String: String] = {
        (UserDefaults.standard.dictionary(forKey: threadMapKey) as? [String: String]) ?? [:]
    }() {
        didSet {
            UserDefaults.standard.set(threadIds, forKey: Self.threadMapKey)
        }
    }
    private var runningProcesses: [String: Process] = [:]

    private let codexPath: String

    init() {
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/codex",
            "/usr/local/bin/codex",
            "/opt/homebrew/bin/codex",
        ]
        self.codexPath = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? "/usr/bin/env"
    }

    func forgetThread(for sessionId: String) {
        threadIds[sessionId] = nil
    }

    func sendMessage(
        sessionId: String,
        message: String,
        model: ClaudeModel,
        workDir: String,
        options: SendOptions = SendOptions(),
        onEvent: @MainActor @Sendable @escaping (ClaudeEvent) -> Void
    ) async {
        let resolvedDir = resolveWorkDir(workDir)
        let prompt = Self.buildPrompt(message: message, options: options)

        var args: [String] = []
        if codexPath == "/usr/bin/env" {
            args.append("codex")
        }
        args += Self.buildArguments(
            threadId: threadIds[sessionId],
            model: model,
            workDir: resolvedDir,
            options: options
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: codexPath)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: resolvedDir)

        var env = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        let extraPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "\(home)/.local/bin",
            "\(home)/.cargo/bin",
            "\(home)/.bun/bin",
        ]
        let existing = env["PATH"] ?? ""
        env["PATH"] = (extraPaths + [existing]).filter { !$0.isEmpty }.joined(separator: ":")
        env["FORCE_COLOR"] = "0"
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        runningProcesses[sessionId] = process
        onEvent(.trace(Self.invocationTrace(
            args: args,
            model: model,
            workDir: resolvedDir,
            options: options
        )))

        do {
            try process.run()
        } catch {
            onEvent(.error("Failed to start codex: \(error.localizedDescription). Is Codex installed?"))
            onEvent(.done)
            return
        }

        if let data = prompt.data(using: .utf8) {
            try? stdin.fileHandleForWriting.write(contentsOf: data)
        }
        try? stdin.fileHandleForWriting.close()

        let result = await Task.detached { () -> ([(String, ClaudeEvent)], Int32, Data) in
            var collected: [(String, ClaudeEvent)] = []
            var buffer = Data()
            var emittedText = false

            let stderrTask = Task.detached { () -> Data in
                var data = Data()
                while true {
                    let chunk = stderr.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    data.append(chunk)
                }
                return data
            }

            while true {
                let chunk = stdout.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)

                while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let lineData = buffer[..<newline]
                    buffer = Data(buffer[buffer.index(after: newline)...])
                    guard !lineData.isEmpty,
                          let line = String(data: lineData, encoding: .utf8)
                    else { continue }
                    if let json = Self.decodeJSONLine(line) {
                        let events = Self.parseEvent(json, emittedText: &emittedText)
                        collected.append(contentsOf: events.map { (sessionId, $0) })
                    } else if let event = Self.streamLineEvent(line, stream: "stdout") {
                        collected.append((sessionId, event))
                    }
                }
            }

            if !buffer.isEmpty,
               let line = String(data: buffer, encoding: .utf8) {
                if let json = Self.decodeJSONLine(line) {
                    let events = Self.parseEvent(json, emittedText: &emittedText)
                    collected.append(contentsOf: events.map { (sessionId, $0) })
                } else if let event = Self.streamLineEvent(line, stream: "stdout") {
                    collected.append((sessionId, event))
                }
            }

            let stderrData = await stderrTask.value
            process.waitUntilExit()
            return (collected, process.terminationStatus, stderrData)
        }.value

        let (events, code, stderrData) = result
        for (sid, event) in events {
            if case .sessionId(let threadId) = event {
                threadIds[sid] = threadId
            }
            onEvent(event)
        }

        for event in Self.stderrTraceEvents(stderrData) {
            onEvent(event)
        }

        runningProcesses.removeValue(forKey: sessionId)

        if code != 0 {
            let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""
            onEvent(.error("Codex exited with code \(code)\(stderrStr.isEmpty ? "" : ": \(stderrStr.trimmingCharacters(in: .whitespacesAndNewlines))")"))
        }
        if !events.contains(where: {
            if case .done = $0.1 { return true }
            return false
        }) {
            onEvent(.done)
        }
    }

    func interrupt(sessionId: String) {
        runningProcesses[sessionId]?.interrupt()
    }

    func kill(sessionId: String) {
        runningProcesses[sessionId]?.terminate()
        runningProcesses.removeValue(forKey: sessionId)
    }

    nonisolated private static func buildPrompt(message: String, options: SendOptions) -> String {
        var parts: [String] = []
        if options.chatMode {
            parts.append("You are in chat-only mode. Do not modify files or run shell commands unless the user explicitly asks. Prefer plain text answers.")
        } else if options.permissions == .deny {
            parts.append("You are in no-tools mode. Do not modify files or run shell commands. Read and respond with text only.")
        } else if options.mode == .plan {
            parts.append("You are in planning mode. Inspect and explain, but do not make filesystem changes.")
        }
        if let systemPrompt = options.systemPrompt, !systemPrompt.isEmpty {
            parts.append(systemPrompt)
        }
        parts.append(message)
        return parts.joined(separator: "\n\n")
    }

    nonisolated static func buildArguments(
        threadId: String?,
        model: ClaudeModel,
        workDir: String,
        options: SendOptions
    ) -> [String] {
        var args: [String] = []
        args += fastModeArgs(for: model, options: options)
        args += reasoningArgs(for: options)
        args += approvalArgs(for: options)
        args.append("exec")

        if let threadId {
            args += [
                "resume",
                "--json",
                "--color", "never",
                "--skip-git-repo-check",
                "--model", model.rawValue,
            ]
            if options.permissions == .bypass {
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

    nonisolated private static func approvalArgs(for options: SendOptions) -> [String] {
        switch options.permissions {
        case .ask:
            // Codex 0.130.0 exposes approval policy as a top-level option,
            // not as an `exec` subcommand option. Keep this before `exec`.
            return ["--ask-for-approval", "on-request"]
        default:
            return []
        }
    }

    nonisolated private static func fastModeArgs(for model: ClaudeModel, options: SendOptions) -> [String] {
        guard options.openAIFastMode, model.supportsOpenAIFastMode else { return [] }
        return [
            "-c", #"service_tier="fast""#,
            "-c", "features.fast_mode=true",
        ]
    }

    nonisolated private static func reasoningArgs(for options: SendOptions) -> [String] {
        guard options.thinkingEnabled else { return [] }
        let effort = codexReasoningEffort(options.effortLevel ?? .medium)
        return [
            "-c", #"model_reasoning_summary="auto""#,
            "-c", #"model_reasoning_effort="\#(effort)""#,
        ]
    }

    nonisolated private static func codexReasoningEffort(_ effort: EffortLevel) -> String {
        switch effort {
        case .low: "low"
        case .medium: "medium"
        case .high: "high"
        case .max: "xhigh"
        }
    }

    nonisolated private static func sandboxMode(for options: SendOptions) -> String {
        if options.chatMode || options.mode == .plan || options.permissions == .deny {
            return "read-only"
        }
        if options.permissions == .bypass {
            return "--dangerously-bypass-approvals-and-sandbox"
        }
        return "workspace-write"
    }

    nonisolated private static func invocationTrace(
        args: [String],
        model: ClaudeModel,
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
            title: "Codex exec launched",
            detail: "codex \(displayArgs)",
            metadata: metadata
        )
    }

    nonisolated private static func redactArgument(_ arg: String) -> String {
        let lower = arg.lowercased()
        if lower.contains("token") || lower.contains("secret") || lower.contains("key") {
            return "<redacted>"
        }
        return arg
    }

    nonisolated static func parseEvent(_ json: [String: Any], emittedText: inout Bool) -> [ClaudeEvent] {
        guard let type = json["type"] as? String else { return [] }

        switch type {
        case "thread.started":
            var events: [ClaudeEvent] = [
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
            var events: [ClaudeEvent] = []
            if let usage = json["usage"] as? [String: Any] {
                let input = usage["input_tokens"] as? Int ?? 0
                let output = usage["output_tokens"] as? Int ?? 0
                events.append(.usage(inputTokens: input, outputTokens: output))
                events.append(.trace(usageTrace(usage)))
            }
            events.append(.trace(trace(level: .success, phase: "turn", title: "Turn completed", metadata: ["type": type])))
            events.append(.done)
            return events

        case "turn.failed":
            let message = (json["error"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "Codex turn failed"
            let event = ClaudeEvent.trace(trace(
                level: .error,
                phase: "turn",
                title: "Turn failed",
                detail: message,
                metadata: ["type": type]
            ))
            if let error = json["error"] as? String, !error.isEmpty {
                return [event, .error(error), .done]
            }
            return [event, .error("Codex turn failed"), .done]

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
            case "agent_message":
                guard let text = item["text"] as? String, !text.isEmpty else { return [] }
                let event = ClaudeEvent.trace(itemTrace(item, itemType: itemType, completed: true))
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
                    .toolResult(toolUseId: id, content: output, isError: exitCode != 0),
                ]
            case "file_change":
                return [.trace(itemTrace(item, itemType: itemType, completed: true))]
                    + fileChangeEvents(from: item, completed: true)
            default:
                var events: [ClaudeEvent] = [.trace(itemTrace(item, itemType: itemType, completed: true))]
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

    nonisolated private static func decodeJSONLine(_ line: String) -> [String: Any]? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"),
              let data = trimmed.data(using: .utf8)
        else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    nonisolated private static func streamLineEvent(_ line: String, stream: String) -> ClaudeEvent? {
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

    nonisolated private static func stderrTraceEvents(_ data: Data) -> [ClaudeEvent] {
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

    nonisolated private static func condenseRepeatedLines(_ lines: [String]) -> [String] {
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

    nonisolated private static func trace(
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

    nonisolated private static func usageTrace(_ usage: [String: Any]) -> AgentTraceEntry {
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

    nonisolated private static func itemTrace(
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

    nonisolated private static func itemTitle(
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

    nonisolated private static func itemDetail(_ item: [String: Any], itemType: String) -> String {
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

    nonisolated private static func humanizeItemType(_ raw: String) -> String {
        raw.split(separator: "_").map { part in
            part.prefix(1).uppercased() + part.dropFirst()
        }.joined(separator: " ")
    }

    nonisolated private static func genericToolStartEvent(from item: [String: Any], itemType: String) -> ClaudeEvent? {
        guard isLikelyToolItem(itemType) else { return nil }
        let id = item["id"] as? String ?? UUID().uuidString
        return .toolStart(
            id: id,
            name: genericToolName(from: item, itemType: itemType),
            input: genericToolInput(from: item)
        )
    }

    nonisolated private static func genericToolResultEvent(from item: [String: Any], itemType: String) -> ClaudeEvent? {
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

    nonisolated private static func isLikelyToolItem(_ itemType: String) -> Bool {
        let lowered = itemType.lowercased()
        return lowered.contains("tool")
            || lowered.contains("function")
            || lowered.contains("mcp")
            || lowered.contains("web_search")
    }

    nonisolated private static func genericToolName(from item: [String: Any], itemType: String) -> String {
        if let name = item["name"] as? String { return name }
        if let name = item["tool_name"] as? String { return name }
        if let server = item["server"] as? String, let name = item["tool"] as? String {
            return "\(server).\(name)"
        }
        return humanizeItemType(itemType)
    }

    nonisolated private static func genericToolInput(from item: [String: Any]) -> String {
        for key in ["input", "arguments", "args", "parameters"] {
            if let value = item[key] {
                return jsonString(value) ?? "\(value)"
            }
        }
        return compactJSON(item)
    }

    nonisolated private static func compactJSON(_ value: Any) -> String {
        jsonString(value) ?? "\(value)"
    }

    nonisolated private static func jsonString(_ value: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string
    }

    private func resolveWorkDir(_ workDir: String) -> String {
        let expanded = (workDir as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
            return expanded
        }
        return NSHomeDirectory()
    }

    nonisolated private static func fileChangeEvents(from item: [String: Any], completed: Bool) -> [ClaudeEvent] {
        guard let itemId = item["id"] as? String,
              let changes = item["changes"] as? [[String: Any]],
              !changes.isEmpty
        else { return [] }

        var events: [ClaudeEvent] = []
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

    nonisolated private static func toolName(for changeKind: String) -> String {
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

    nonisolated private static func fileChangeInput(path: String, kind: String, metadata: [String: Any]) -> String {
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

    nonisolated private static func fileChangeResultSummary(path: String, kind: String) -> String {
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
