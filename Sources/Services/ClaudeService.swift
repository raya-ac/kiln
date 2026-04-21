import Foundation

/// Spawns and manages Claude CLI processes for chat sessions.
@MainActor
final class ClaudeService: ObservableObject {
    // sessionId -> CLI resume ID. Persisted to UserDefaults so a restart
    // reconnects each Kiln session to the same Claude CLI conversation
    // (via `--resume <id>`) instead of silently starting fresh and
    // losing the conversation context the user built up.
    private static let cliMapKey = "kiln.cliSessionIds"
    private var cliSessionIds: [String: String] = {
        (UserDefaults.standard.dictionary(forKey: cliMapKey) as? [String: String]) ?? [:]
    }() {
        didSet {
            UserDefaults.standard.set(cliSessionIds, forKey: Self.cliMapKey)
        }
    }
    private var runningProcesses: [String: Process] = [:]

    /// Reverse lookup: CLI session ID (as reported by the hook payload) → our
    /// internal kiln session ID. Used by the PreToolUse hook endpoint so the
    /// approval UI can attach the pending request to the right session.
    func kilnSession(forCLI cliId: String) -> String? {
        cliSessionIds.first { $0.value == cliId }?.key
    }

    /// Forget the CLI resume ID for a Kiln session. Last-resort — prefer
    /// migrateCLISession when the workdir changes so conversation context
    /// carries across the move.
    func forgetCLISession(for sessionId: String) {
        cliSessionIds[sessionId] = nil
    }

    /// Whether we have a CLI resume ID on file for this session.
    func hasCLISession(for sessionId: String) -> Bool {
        cliSessionIds[sessionId] != nil
    }

    /// Claude CLI stores each conversation at
    /// `~/.claude/projects/<dashed-abs-path>/<cliId>.jsonl`. The "hash" is
    /// just the absolute path with `/` rewritten to `-` — reversible and
    /// deterministic. We build it ourselves rather than scan, because it
    /// needs to exist before the next `claude --resume` runs.
    private func projectDir(for workDir: String) -> URL {
        let expanded = (workDir as NSString).expandingTildeInPath
        let dashed = "-" + expanded
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: "/", with: "-")
        return URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/projects/\(dashed)", isDirectory: true)
    }

    /// Copy the CLI conversation file from the old workdir's project dir
    /// into the new one, so `--resume <cliId>` keeps working after the
    /// user moves the session to a different folder. Returns true if the
    /// migration succeeded (or wasn't needed) — false only if we had a
    /// cliId on file but couldn't find the source file to copy.
    ///
    /// Note: the CLI conversation file embeds the original cwd in each
    /// turn's metadata. Claude tolerates resuming it from a different
    /// cwd — new turns get the new cwd and tools run there. The old
    /// turns' cwd in the JSONL is historical but harmless.
    @discardableResult
    func migrateCLISession(for sessionId: String, from oldWorkDir: String, to newWorkDir: String) -> Bool {
        guard let cliId = cliSessionIds[sessionId] else { return true }
        if oldWorkDir == newWorkDir { return true }
        let fm = FileManager.default
        let src = projectDir(for: oldWorkDir).appendingPathComponent("\(cliId).jsonl")
        let dstDir = projectDir(for: newWorkDir)
        let dst = dstDir.appendingPathComponent("\(cliId).jsonl")
        guard fm.fileExists(atPath: src.path) else {
            // Source gone — drop the mapping so we don't try to --resume an
            // unresolvable id in the new dir.
            cliSessionIds[sessionId] = nil
            return false
        }
        try? fm.createDirectory(at: dstDir, withIntermediateDirectories: true)
        // If a file with the same id already exists at dst (shouldn't
        // normally), leave it alone rather than clobber.
        if !fm.fileExists(atPath: dst.path) {
            try? fm.copyItem(at: src, to: dst)
        }
        return fm.fileExists(atPath: dst.path)
    }

    private let claudePath: String

    init() {
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/claude",
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
        ]
        self.claudePath = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
            ?? candidates[0]
    }

    /// Send a message to Claude CLI and stream events back via the callback.
    /// The callback is always called on the MainActor.
    func sendMessage(
        sessionId: String,
        message: String,
        model: ClaudeModel,
        workDir: String,
        options: SendOptions = SendOptions(),
        onEvent: @MainActor @Sendable @escaping (ClaudeEvent) -> Void
    ) async {
        // --input-format stream-json is critical: without it, --print exits
        // before MCP servers finish connecting, so the tools list snapshot
        // never includes mcp__engram__* tools. With stream-json input the
        // process stays open long enough for MCP servers to register their
        // tools before the user message is processed.
        var args = [
            "--print",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--model", model.rawValue,
        ]

        // MCP servers: --print mode doesn't load user settings' mcpServers by default.
        // Pass the config inline via --mcp-config, which does load them reliably.
        if let mcpConfigJSON = Self.loadUserMcpConfigJSON() {
            args += ["--mcp-config", mcpConfigJSON]
        }

        // All built-in Claude Code tools — used to fully block tool use in chat mode
        let allBuiltinTools = [
            "Task", "Bash", "BashOutput", "KillShell", "Glob", "Grep",
            "ExitPlanMode", "Read", "Edit", "Write", "NotebookEdit",
            "WebFetch", "WebSearch", "TodoWrite", "SlashCommand",
        ]

        if options.chatMode {
            // Chat mode: block every built-in tool. Engram MCP tools remain available
            // so memory still works. Skip permission prompts for engram calls.
            args += ["--disallowedTools"] + allBuiltinTools
            args += ["--dangerously-skip-permissions"]
            // Prepend system prompt instruction reinforcing chat-only behavior
            let chatInstruction = "You are in chat-only mode. The only tools available to you are the engram memory tools (mcp__engram__*). Do NOT attempt to use any file, shell, web, or code tools — they are disabled. Respond with text and, when relevant, use engram to recall or remember."
            if let existing = options.systemPrompt, !existing.isEmpty {
                args += ["--system-prompt", "\(chatInstruction)\n\n\(existing)"]
            } else {
                args += ["--system-prompt", chatInstruction]
            }
            // Skip all other tool-related flags
        } else {
            // Permission mode
            switch options.permissions {
            case .bypass:
                args += ["--dangerously-skip-permissions"]
            case .ask:
                // Install a PreToolUse hook that phones home to Kiln's loopback
                // HTTP server for every tool call. --permission-mode
                // bypassPermissions tells CC not to show its own prompts — the
                // hook is the sole gate. Fail-closed on unreachable server.
                if let settingsPath = Self.installPreToolUseHook(
                    port: options.hookPort,
                    secret: options.hookSecret
                ) {
                    args += [
                        "--permission-mode", "bypassPermissions",
                        "--settings", settingsPath,
                    ]
                } else {
                    // Couldn't stage the hook (filesystem error) — fall back to
                    // deny-by-default rather than silently opening the gate.
                    args += ["--disallowedTools"] + allBuiltinTools
                }
            case .deny:
                args += ["--disallowedTools"] + allBuiltinTools
            }

            // System prompt override
            if let systemPrompt = options.systemPrompt {
                args += ["--system-prompt", systemPrompt]
            }

            // Allowed tools filter
            if let allowedTools = options.allowedTools, !allowedTools.isEmpty {
                for tool in allowedTools {
                    args += ["--allowedTools", tool]
                }
            }

            // Planning mode: restrict to read-only tools
            if options.mode == .plan {
                args += ["--allowedTools", "Read,Glob,Grep,WebSearch,WebFetch"]
            }
        }

        // Max turns (applies to both modes)
        if let maxTurns = options.maxTurns {
            args += ["--max-turns", String(maxTurns)]
        }

        // Effort level (applies to both modes) — triggers extended thinking
        if let effort = options.effortLevel {
            args += ["--effort", effort.cliValue]
        }

        if let resumeId = cliSessionIds[sessionId] {
            args += ["--resume", resumeId]
        }

        // Message is sent via stdin as a stream-json user message, not as an arg.

        let resolvedDir = resolveWorkDir(workDir)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudePath)
        process.arguments = args
        process.currentDirectoryURL = URL(fileURLWithPath: resolvedDir)
        var env = ProcessInfo.processInfo.environment
        // GUI apps launched by launchd get a minimal PATH — MCP servers like engram
        // may live in /opt/homebrew/bin, ~/.local/bin, etc. Inject a fuller PATH so
        // spawned claude can find them.
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
        // PreToolUse hook transport — the hook script reads these at invocation.
        env["KILN_PORT"] = String(options.hookPort)
        env["KILN_HOOK_SECRET"] = options.hookSecret
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
            onEvent(.error("Failed to start claude: \(error.localizedDescription). Is Claude Code installed?"))
            onEvent(.done)
            return
        }

        // MCP servers (engram etc.) connect asynchronously after process start.
        // If we write the user message to stdin immediately, the CLI snapshots
        // the tools list while MCP is still "pending" and no mcp__* tools
        // reach the model. Delaying the write by ~1.5s lets MCP connect first
        // so engram's 66 tools show up in the tools list. Runs on a detached
        // task so the main actor isn't blocked.
        let stdinWrite = stdin.fileHandleForWriting
        let messageCopy = message
        Task.detached {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            let userMsg: [String: Any] = [
                "type": "user",
                "message": [
                    "role": "user",
                    "content": messageCopy,
                ],
            ]
            if let data = try? JSONSerialization.data(withJSONObject: userMsg),
               var line = String(data: data, encoding: .utf8) {
                line += "\n"
                if let lineData = line.data(using: .utf8) {
                    try? stdinWrite.write(contentsOf: lineData)
                }
            }
            try? stdinWrite.close()
        }

        let fileHandle = stdout.fileHandleForReading
        let stderrHandle = stderr.fileHandleForReading
        _ = claudePath

        // Do the blocking I/O off the main actor
        let result = await Task.detached { () -> ([(String, ClaudeEvent)], Int32, Data) in
            var buffer = Data()
            var collectedEvents: [(String, ClaudeEvent)] = [] // (sessionId, event) pairs
            var stderrData = Data()

            // Read stderr in background
            let stderrTask = Task.detached { () -> Data in
                var data = Data()
                while true {
                    let chunk = stderrHandle.availableData
                    if chunk.isEmpty { break }
                    data.append(chunk)
                }
                return data
            }

            while true {
                let chunk = fileHandle.availableData
                if chunk.isEmpty { break }

                buffer.append(chunk)

                // Parse every complete line we have, and dispatch each event
                // to the main actor IMMEDIATELY — not at the end of the chunk.
                // Batching a full stdout chunk meant the user saw tokens arrive
                // in big chunks separated by pauses. Per-event dispatch lets
                // SwiftUI coalesce at its own refresh rate (~60Hz) so the
                // text streams smoothly.
                while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let lineData = buffer[buffer.startIndex..<newlineIndex]
                    buffer = Data(buffer[buffer.index(after: newlineIndex)...])

                    guard !lineData.isEmpty,
                          let line = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespaces),
                          !line.isEmpty else { continue }

                    if let data = line.data(using: .utf8),
                       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        let events = ClaudeService.parseEvent(json)
                        if events.isEmpty { continue }
                        await MainActor.run { [weak self] in
                            for event in events {
                                if case .sessionId(let cliId) = event {
                                    self?.cliSessionIds[sessionId] = cliId
                                }
                                onEvent(event)
                            }
                        }
                    }
                }
            }

            // Flush remaining buffer
            if !buffer.isEmpty,
               let line = String(data: buffer, encoding: .utf8)?.trimmingCharacters(in: .whitespaces),
               !line.isEmpty,
               let data = line.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let events = ClaudeService.parseEvent(json)
                for event in events {
                    collectedEvents.append((sessionId, event))
                }
            }

            // Dispatch remaining events
            if !collectedEvents.isEmpty {
                let batch = collectedEvents
                await MainActor.run { [weak self] in
                    for (sid, event) in batch {
                        if case .sessionId(let cliId) = event {
                            self?.cliSessionIds[sid] = cliId
                        }
                        onEvent(event)
                    }
                }
            }

            stderrData = await stderrTask.value
            process.waitUntilExit()
            let code = process.terminationStatus

            return ([], code, stderrData)
        }.value

        let (_, code, stderrData) = result

        // Back on MainActor — update state
        runningProcesses.removeValue(forKey: sessionId)

        if code != 0 {
            let stderrStr = String(data: stderrData, encoding: .utf8) ?? ""
            onEvent(.error("Claude exited with code \(code)\(stderrStr.isEmpty ? "" : ": \(stderrStr.trimmingCharacters(in: .whitespacesAndNewlines))")"))
        }
        onEvent(.done)
    }

    func interrupt(sessionId: String) {
        runningProcesses[sessionId]?.interrupt()
    }

    func kill(sessionId: String) {
        runningProcesses[sessionId]?.terminate()
        runningProcesses.removeValue(forKey: sessionId)
    }

    // MARK: - Event parsing (nonisolated static)

    nonisolated static func parseEvent(_ json: [String: Any]) -> [ClaudeEvent] {
        guard let type = json["type"] as? String else { return [] }

        switch type {
        case "system":
            if let sid = json["session_id"] as? String {
                return [.sessionId(sid)]
            }
            return []

        case "stream_event":
            guard let event = json["event"] as? [String: Any] else { return [] }
            return parseStreamEvent(event)

        case "assistant":
            guard let msg = json["message"] as? [String: Any],
                  let content = msg["content"] as? [[String: Any]] else { return [] }
            var events: [ClaudeEvent] = []
            for block in content {
                let blockType = block["type"] as? String
                if blockType == "tool_use" {
                    let id = block["id"] as? String ?? UUID().uuidString
                    let name = block["name"] as? String ?? "unknown"
                    let input = block["input"] as? [String: Any] ?? [:]
                    let inputStr = (try? JSONSerialization.data(withJSONObject: input))
                        .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                    events.append(.toolStart(id: id, name: name, input: inputStr))
                } else if blockType == "tool_result" {
                    let toolUseId = block["tool_use_id"] as? String ?? ""
                    let isError = block["is_error"] as? Bool ?? false
                    // Content can be string or array of content blocks
                    var resultContent = ""
                    if let str = block["content"] as? String {
                        resultContent = str
                    } else if let contentArr = block["content"] as? [[String: Any]] {
                        for item in contentArr {
                            if let text = item["text"] as? String {
                                resultContent += text
                            }
                        }
                    }
                    events.append(.toolResult(toolUseId: toolUseId, content: resultContent, isError: isError))
                }
            }
            return events

        case "result":
            var events: [ClaudeEvent] = []
            if let sid = json["session_id"] as? String {
                events.append(.sessionId(sid))
            }
            if let cost = json["total_cost_usd"] as? Double {
                events.append(.cost(cost))
            }
            // Parse usage from result
            if let usage = json["usage"] as? [String: Any] {
                let input = usage["input_tokens"] as? Int ?? 0
                let output = usage["output_tokens"] as? Int ?? 0
                events.append(.usage(inputTokens: input, outputTokens: output))
            }
            return events

        default:
            return []
        }
    }

    nonisolated private static func parseStreamEvent(_ event: [String: Any]) -> [ClaudeEvent] {
        guard let type = event["type"] as? String else { return [] }

        switch type {
        case "content_block_start":
            guard let block = event["content_block"] as? [String: Any],
                  let blockType = block["type"] as? String else { return [] }

            if blockType == "tool_use" {
                let id = block["id"] as? String ?? UUID().uuidString
                let name = block["name"] as? String ?? "unknown"
                return [.toolStart(id: id, name: name, input: "")]
            }
            return []

        case "content_block_delta":
            guard let delta = event["delta"] as? [String: Any],
                  let deltaType = delta["type"] as? String else { return [] }

            switch deltaType {
            case "text_delta":
                if let text = delta["text"] as? String {
                    return [.textDelta(text)]
                }
            case "thinking_delta":
                if let text = delta["thinking"] as? String {
                    return [.thinkingDelta(text)]
                }
            case "input_json_delta":
                if let json = delta["partial_json"] as? String {
                    return [.toolInputDelta(json)]
                }
            default:
                break
            }
            return []

        case "content_block_stop":
            let index = event["index"] as? Int ?? -1
            return [.blockStop(index: index)]

        case "message_start":
            // Parse usage from message_start.message.usage
            if let msg = event["message"] as? [String: Any],
               let usage = msg["usage"] as? [String: Any] {
                let input = usage["input_tokens"] as? Int ?? 0
                let output = usage["output_tokens"] as? Int ?? 0
                return [.messageStart, .usage(inputTokens: input, outputTokens: output)]
            }
            return [.messageStart]

        case "message_delta":
            // Parse usage from message_delta
            if let usage = event["usage"] as? [String: Any] {
                let input = usage["input_tokens"] as? Int ?? 0
                let output = usage["output_tokens"] as? Int ?? 0
                return [.usage(inputTokens: input, outputTokens: output)]
            }
            return []

        case "message_stop":
            return [.messageStop]

        default:
            return []
        }
    }

    // MARK: - Helpers

    nonisolated private func resolveWorkDir(_ dir: String) -> String {
        if dir == "~" || dir.hasPrefix("~/") {
            return dir.replacingOccurrences(of: "~", with: NSHomeDirectory(), options: [], range: dir.startIndex..<dir.index(dir.startIndex, offsetBy: 1))
        }
        return dir
    }

    /// Stages the PreToolUse hook: writes the hook script + a minimal settings
    /// JSON that registers it into `~/.kiln/hooks/`, returns the settings path
    /// (to be passed via `--settings`). Returns nil if any filesystem write
    /// fails — caller must fail-closed.
    ///
    /// The hook script contents are static; the per-launch secret and port
    /// are passed to it via env vars (`KILN_PORT`, `KILN_HOOK_SECRET`) at
    /// subprocess spawn time, not baked into the file.
    nonisolated static func installPreToolUseHook(port: UInt16, secret: String) -> String? {
        _ = port; _ = secret // informational — actual values travel via env
        let home = NSHomeDirectory()
        let dir = "\(home)/.kiln/hooks"
        let hookPath = "\(dir)/pretooluse.js"
        let settingsPath = "\(dir)/settings.json"

        let fm = FileManager.default
        do {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        // Hook script: reads CC's JSON from stdin, POSTs to the Kiln server,
        // relays the decision via CC's hookSpecificOutput protocol.
        // Fail-closed — any transport error denies the call.
        let hookJS = #"""
        #!/usr/bin/env node
        "use strict";
        const http = require("node:http");
        const PORT = process.env.KILN_PORT || "8421";
        const SECRET = process.env.KILN_HOOK_SECRET || "";
        const TIMEOUT_MS = 5 * 60 * 1000; // human-in-the-loop

        function deny(reason) {
          process.stderr.write(JSON.stringify({
            hookSpecificOutput: { permissionDecision: "deny" },
            systemMessage: reason,
          }));
          process.exit(2);
        }

        let body = "";
        process.stdin.on("data", (c) => (body += c));
        process.stdin.on("end", () => {
          const req = http.request({
            hostname: "127.0.0.1",
            port: PORT,
            path: "/api/hooks/pretooluse",
            method: "POST",
            headers: {
              "Content-Type": "application/json",
              "Content-Length": Buffer.byteLength(body),
              "X-Kiln-Hook-Secret": SECRET,
            },
            timeout: TIMEOUT_MS,
          }, (res) => {
            let out = "";
            res.on("data", (c) => (out += c));
            res.on("end", () => {
              try {
                const d = JSON.parse(out);
                if (d.permissionDecision === "deny") {
                  deny(d.reason || "Denied by user");
                }
                process.stderr.write(JSON.stringify({
                  hookSpecificOutput: { permissionDecision: "approve" },
                }));
                process.exit(0);
              } catch {
                deny("Kiln approval server returned malformed response");
              }
            });
          });
          req.on("error", () => deny("Kiln approval server unreachable"));
          req.on("timeout", () => { req.destroy(); deny("Approval timed out"); });
          req.write(body);
          req.end();
        });
        """#

        do {
            try hookJS.write(toFile: hookPath, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookPath)
        } catch {
            return nil
        }

        // Find a node binary. CC needs one to run the hook, so wherever CC is
        // installed there's a node on PATH — but the CLI may have been
        // launched from a GUI context with a stripped PATH. Hardcoding a
        // resolved path in the settings file sidesteps that.
        let nodeCandidates = [
            "\(home)/.volta/bin/node",
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "\(home)/.nvm/versions/node/current/bin/node",
            "/usr/bin/node",
        ]
        let nodePath = nodeCandidates.first { fm.isExecutableFile(atPath: $0) } ?? "node"

        let settings: [String: Any] = [
            "hooks": [
                "PreToolUse": [[
                    "matcher": ".*",
                    "hooks": [[
                        "type": "command",
                        "command": "\(nodePath) \(hookPath)",
                    ]],
                ]],
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted]) else {
            return nil
        }
        do {
            try data.write(to: URL(fileURLWithPath: settingsPath))
        } catch {
            return nil
        }
        return settingsPath
    }

    /// Reads mcpServers from ~/.claude/settings.json and ~/.claude.json, merges them,
    /// normalizes each entry so it adheres to the --mcp-config schema (explicit `type`
    /// field), and skips any entry that can't be normalized. Returns nil if no servers
    /// are usable.
    nonisolated static func loadUserMcpConfigJSON() -> String? {
        let home = NSHomeDirectory()
        let sources = [
            "\(home)/.claude/settings.json",
            "\(home)/.claude.json",
        ]

        var merged: [String: [String: Any]] = [:]
        for path in sources {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let servers = json["mcpServers"] as? [String: Any] else { continue }
            for (k, v) in servers where merged[k] == nil {
                guard let entry = v as? [String: Any],
                      let normalized = normalizeMcpServer(entry) else { continue }
                merged[k] = normalized
            }
        }

        guard !merged.isEmpty else { return nil }

        let wrapper: [String: Any] = ["mcpServers": merged]
        guard let data = try? JSONSerialization.data(withJSONObject: wrapper),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    /// Normalize a single MCP server entry. Returns nil if the entry can't be classified.
    nonisolated private static func normalizeMcpServer(_ entry: [String: Any]) -> [String: Any]? {
        var out = entry

        if let explicitType = entry["type"] as? String, !explicitType.isEmpty {
            // Trust the explicit type — just ensure required fields exist.
            switch explicitType {
            case "stdio":
                guard entry["command"] is String else { return nil }
            case "http", "sse":
                guard entry["url"] is String else { return nil }
            default:
                return nil
            }
            return out
        }

        // Infer type from shape
        if entry["command"] is String {
            out["type"] = "stdio"
            return out
        }
        if entry["url"] is String {
            out["type"] = "http"
            return out
        }
        return nil
    }
}

// MARK: - Events

enum ClaudeEvent: Sendable {
    case sessionId(String)
    case messageStart
    case textDelta(String)
    case thinkingDelta(String)
    case toolStart(id: String, name: String, input: String)
    case toolInputDelta(String)
    case blockStop(index: Int)
    case messageStop
    case usage(inputTokens: Int, outputTokens: Int)
    case toolResult(toolUseId: String, content: String, isError: Bool)
    case cost(Double)
    case error(String)
    case done
}
