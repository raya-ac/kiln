import Foundation

/// Streams and manages Codex and OpenCode CLI processes for chat/code sessions.
@MainActor
final class AgentService: ObservableObject {
    private let threadMapKey: String
    private var threadIds: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: threadMapKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: threadMapKey) }
    }
    private var runningProcesses: [String: Process] = [:]
    private let executablePath: String
    private let backend: ModelProvider

    init(backend: ModelProvider = .codex, executablePath: String? = nil) {
        self.backend = backend
        self.threadMapKey = backend == .codex ? "kiln.codexThreadIds" : "kiln.opencodeSessionIds"
        self.executablePath = executablePath ?? (backend == .codex ? CodexCLI.executablePath : OpenCodeProtocol.executablePath)
    }

    func hasThread(for sessionId: String) -> Bool { threadIds[sessionId] != nil }

    func forgetThread(for sessionId: String) {
        threadIds[sessionId] = nil
    }

    func sendMessage(
        sessionId: String,
        message: String,
        model: AgentModel,
        workDir: String,
        options: SendOptions = SendOptions(),
        onEvent: @MainActor @Sendable @escaping (AgentEvent) -> Void
    ) async {
        guard runningProcesses[sessionId] == nil else {
            onEvent(.error("A turn is already running in this session."))
            return
        }
        guard let resolvedDir = resolveWorkDir(workDir) else {
            onEvent(.error("The workspace folder is unavailable. Choose an existing folder before sending."))
            onEvent(.done)
            return
        }
        let prompt = Self.buildPrompt(message: message, options: options)

        var args: [String] = []
        if executablePath == "/usr/bin/env" {
            args.append(backend.rawValue)
        }
        args += backend == .opencode
            ? OpenCodeProtocol.arguments(sessionId: threadIds[sessionId], model: model, workDir: resolvedDir, options: options)
            : CodexProtocol.buildArguments(
            threadId: threadIds[sessionId],
            model: model,
            workDir: resolvedDir,
            options: options
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
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
        env["PWD"] = resolvedDir
        if backend == .opencode { env["OPENCODE_CONFIG_CONTENT"] = OpenCodeProtocol.configuration(options) }
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        runningProcesses[sessionId] = process
        defer { if runningProcesses[sessionId] === process { runningProcesses[sessionId] = nil } }
        onEvent(.trace(CodexProtocol.invocationTrace(
            args: args,
            model: model,
            workDir: resolvedDir,
            options: options
        )))

        do {
            try process.run()
        } catch {
            onEvent(.error("Failed to start \(backend.label): \(error.localizedDescription). Is \(backend.label) installed?"))
            onEvent(.done)
            return
        }

        let backend = self.backend
        let writeTask = Task.detached {
            defer { try? stdin.fileHandleForWriting.close() }
            try? stdin.fileHandleForWriting.write(contentsOf: Data(prompt.utf8))
        }

        // Drain both pipes concurrently; deliver each batch before reading more.
        // The old implementation held every event until process exit.
        let (code, stderrData) = await Task.detached { () -> (Int32, Data) in
            var buffer = Data()
            var emittedText = false
            let stderrTask = Task.detached { () -> Data in
                var tail = Data()
                while true {
                    let chunk = stderr.fileHandleForReading.availableData
                    if chunk.isEmpty { break }
                    tail.append(chunk)
                    if tail.count > 64 * 1024 { tail = Data(tail.suffix(64 * 1024)) }
                }
                return tail
            }
            while true {
                let chunk = stdout.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
                var batch: [AgentEvent] = []
                while let newline = buffer.firstIndex(of: 10) {
                    let line = String(decoding: buffer[..<newline], as: UTF8.self)
                    buffer.removeSubrange(...newline)
                    if let json = CodexProtocol.decodeJSONLine(line) {
                        batch += (backend == .codex ? CodexProtocol.parseEvent(json, emittedText: &emittedText) : OpenCodeProtocol.parse(json))
                    } else if let event = CodexProtocol.streamLineEvent(line, stream: "stdout") {
                        batch.append(event)
                    }
                }
                let delivered = batch
                await MainActor.run {
                    guard self.runningProcesses[sessionId] === process else { return }
                    for event in delivered {
                        if case .done = event { continue }
                        if case .sessionId(let id) = event { self.threadIds[sessionId] = id }
                        onEvent(event)
                    }
                }
            }
            if !buffer.isEmpty {
                let line = String(decoding: buffer, as: UTF8.self)
                let events = CodexProtocol.decodeJSONLine(line).map { (backend == .codex ? CodexProtocol.parseEvent($0, emittedText: &emittedText) : OpenCodeProtocol.parse($0)) } ?? []
                await MainActor.run {
                    guard self.runningProcesses[sessionId] === process else { return }
                    for event in events {
                        if case .done = event { continue }
                        if case .sessionId(let id) = event { self.threadIds[sessionId] = id }
                        onEvent(event)
                    }
                }
            }
            process.waitUntilExit()
            return (process.terminationStatus, await stderrTask.value)
        }.value
        await writeTask.value
        guard runningProcesses[sessionId] === process else { return }
        for event in CodexProtocol.stderrTraceEvents(stderrData) { onEvent(event) }
        if code != 0 {
            onEvent(.error("\(backend.label) exited with code \(code): \(String(decoding: stderrData.suffix(4000), as: UTF8.self))"))
        }
        // Finalize once, after errors, usage, and stderr have been delivered.
        onEvent(.done)
    }

    func interrupt(sessionId: String) {
        guard let process = runningProcesses[sessionId] else { return }
        process.interrupt()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if self.runningProcesses[sessionId] === process, process.isRunning { process.terminate() }
        }
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

    private func resolveWorkDir(_ workDir: String) -> String? {
        let expanded = ((workDir as NSString).expandingTildeInPath as NSString).standardizingPath
        guard (expanded as NSString).isAbsolutePath else { return nil }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
            return expanded
        }
        return nil
    }

}
