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
        let isResume = threadIds[sessionId] != nil
        let prompt = Self.buildPrompt(message: message, options: options)

        var args: [String] = []
        if codexPath == "/usr/bin/env" {
            args.append("codex")
        }

        if let threadId = threadIds[sessionId] {
            args += ["exec", "resume", "--json", threadId, "-m", model.rawValue, "-"]
            if options.permissions == .bypass {
                args.append("--dangerously-bypass-approvals-and-sandbox")
            } else if options.mode == .plan {
                args.append("--full-auto")
            }
        } else {
            args += ["exec", "--json", "--skip-git-repo-check", "--model", model.rawValue, "--cd", resolvedDir, "-"]
            switch Self.sandboxMode(for: options) {
            case "--dangerously-bypass-approvals-and-sandbox":
                args.append("--dangerously-bypass-approvals-and-sandbox")
            case let sandbox:
                args += ["--sandbox", sandbox]
            }
        }

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
                          let line = String(data: lineData, encoding: .utf8),
                          let data = line.data(using: .utf8),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                    else { continue }
                    let events = Self.parseEvent(json, emittedText: &emittedText)
                    collected.append(contentsOf: events.map { (sessionId, $0) })
                }
            }

            if !buffer.isEmpty,
               let line = String(data: buffer, encoding: .utf8),
               let data = line.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let events = Self.parseEvent(json, emittedText: &emittedText)
                collected.append(contentsOf: events.map { (sessionId, $0) })
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

        _ = isResume
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
        } else if options.mode == .plan {
            parts.append("You are in planning mode. Inspect and explain, but do not make filesystem changes.")
        }
        if let systemPrompt = options.systemPrompt, !systemPrompt.isEmpty {
            parts.append(systemPrompt)
        }
        parts.append(message)
        return parts.joined(separator: "\n\n")
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

    nonisolated private static func parseEvent(_ json: [String: Any], emittedText: inout Bool) -> [ClaudeEvent] {
        guard let type = json["type"] as? String else { return [] }

        switch type {
        case "thread.started":
            if let threadId = json["thread_id"] as? String {
                return [.sessionId(threadId)]
            }
            return []

        case "turn.started":
            return [.messageStart]

        case "turn.completed":
            var events: [ClaudeEvent] = []
            if let usage = json["usage"] as? [String: Any] {
                let input = usage["input_tokens"] as? Int ?? 0
                let output = usage["output_tokens"] as? Int ?? 0
                events.append(.usage(inputTokens: input, outputTokens: output))
            }
            events.append(.done)
            return events

        case "item.started":
            guard let item = json["item"] as? [String: Any],
                  let itemType = item["type"] as? String else { return [] }
            if itemType == "command_execution" {
                let id = item["id"] as? String ?? UUID().uuidString
                let command = item["command"] as? String ?? ""
                let input = (try? JSONSerialization.data(withJSONObject: ["command": command]))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                return [.toolStart(id: id, name: "Bash", input: input)]
            }
            if itemType == "file_change" {
                return fileChangeEvents(from: item, completed: false)
            }
            return []

        case "item.completed":
            guard let item = json["item"] as? [String: Any],
                  let itemType = item["type"] as? String else { return [] }
            switch itemType {
            case "agent_message":
                guard let text = item["text"] as? String, !text.isEmpty else { return [] }
                if emittedText {
                    return [.textDelta("\n\n" + text)]
                } else {
                    emittedText = true
                    return [.textDelta(text)]
                }
            case "command_execution":
                let id = item["id"] as? String ?? UUID().uuidString
                let output = item["aggregated_output"] as? String ?? ""
                let exitCode = item["exit_code"] as? Int ?? 0
                return [.toolResult(toolUseId: id, content: output, isError: exitCode != 0)]
            case "file_change":
                return fileChangeEvents(from: item, completed: true)
            default:
                return []
            }

        default:
            return []
        }
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
