import Foundation

/// Streams and manages supported agent CLI processes for chat/code sessions.
@MainActor
final class AgentService: ObservableObject {
    private let threadMapKey: String
    private var threadIds: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: threadMapKey) as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: threadMapKey) }
    }
    private var runningProcesses: [String: Process] = [:]
    private var turnIDs: [String: UUID] = [:]
    private let executablePath: String
    private let backend: ModelProvider
    private let openCodeVersion: @MainActor () async throws -> Int
    private let computer: ComputerUse

    init(backend: ModelProvider = .codex, executablePath: String? = nil,
         openCodeVersion: @escaping @MainActor () async throws -> Int = { try await OpenCodeProtocol.installedMajorVersion() },
         computer: ComputerUse = .shared) {
        self.backend = backend
        self.openCodeVersion = openCodeVersion
        self.computer = computer
        switch backend {
        case .codex:
            threadMapKey = "kiln.codexThreadIds"
            self.executablePath = executablePath ?? CodexCLI.executablePath
        case .opencode:
            threadMapKey = "kiln.opencodeSessionIds"
            self.executablePath = executablePath ?? OpenCodeProtocol.executablePath
        case .grok:
            threadMapKey = "kiln.grokSessionIds"
            self.executablePath = executablePath ?? GrokCLI.executablePath
        }
    }

    func hasThread(for sessionId: String) -> Bool { threadIds[sessionId] != nil }
    func threadID(for sessionId: String) -> String? { threadIds[sessionId] }

    func currentContext(sessionId: String, model: AgentModel) async -> ContextUsage? {
        guard backend == .codex, let thread = threadIds[sessionId] else { return nil }
        let path = ProcessInfo.processInfo.environment["CODEX_HOME"] ?? NSHomeDirectory() + "/.codex"
        return await CodexContextReader.shared.read(threadID: thread, modelID: model.rawValue,
            home: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
    }

    func compactThread(sessionId: String, workDir: String) async throws {
        guard backend == .codex, runningProcesses[sessionId] == nil, let thread = threadIds[sessionId] else { throw CocoaError(.featureUnsupported) }
        try await CodexThreadCompactor.compact(threadID: thread, executable: executablePath, workDir: workDir)
    }

    func forgetThread(for sessionId: String) {
        threadIds[sessionId] = nil
    }

    func flushThreadMapping() -> Bool { UserDefaults.standard.synchronize() }

    func sendMessage(
        sessionId: String,
        message: String,
        model: AgentModel,
        workDir: String,
        options: SendOptions = SendOptions(),
        attachments: [ComposerAttachment] = [],
        resetThread: Bool = false,
        onLaunch: @MainActor @Sendable (Int32) throws -> Void = { _ in },
        onEvent: @MainActor @Sendable @escaping (AgentEvent) -> Void
    ) async {
        guard runningProcesses[sessionId] == nil, turnIDs[sessionId] == nil else {
            onEvent(.error("A turn is already running in this session."))
            return
        }
        let turnID = UUID()
        turnIDs[sessionId] = turnID
        defer { if turnIDs[sessionId] == turnID { turnIDs[sessionId] = nil } }
        guard let resolvedDir = resolveWorkDir(workDir) else {
            onEvent(.error("The workspace folder is unavailable. Choose an existing folder before sending."))
            onEvent(.done)
            return
        }
        let prompt = Self.buildPrompt(message: message, options: options)
        let existingThread = resetThread ? nil : threadIds[sessionId]
        let grokNewSessionID = backend == .grok && existingThread == nil ? UUID().uuidString.lowercased() : nil

        if let problem = model.attachmentError(attachments) {
            onEvent(.error(problem))
            onEvent(.done)
            return
        }

        let openCodeMajor: Int
        do { openCodeMajor = backend == .opencode ? try await openCodeVersion() : 1 }
        catch {
            if turnIDs[sessionId] != turnID || Task.isCancelled { onEvent(.cancelled) }
            else { onEvent(.error("Could not read the installed OpenCode version: " + error.localizedDescription)) }
            onEvent(.done); return
        }
        guard turnIDs[sessionId] == turnID, !Task.isCancelled else { onEvent(.cancelled); onEvent(.done); return }
        let computerTurn: ComputerTurn?
        do { computerTurn = try await computer.startTurn(sessionID: sessionId, model: model, options: options) }
        catch {
            if turnIDs[sessionId] != turnID || Task.isCancelled { onEvent(.cancelled) }
            else { onEvent(.error(error.localizedDescription)) }
            onEvent(.done); return
        }
        defer { if let computerTurn { computer.endTurn(computerTurn) } }
        guard turnIDs[sessionId] == turnID, !Task.isCancelled else { onEvent(.cancelled); onEvent(.done); return }

        var args: [String] = []
        if executablePath == "/usr/bin/env" {
            args.append(backend.rawValue)
        }
        switch backend {
        case .codex:
            if computerTurn != nil { args += ComputerConnection.codexArguments(executable: computer.helperExecutable) }
            args += CodexProtocol.buildArguments(threadId: existingThread, model: model,
                workDir: resolvedDir, options: options, imagePaths: attachments.filter(\.isImage).map(\.path))
        case .opencode:
            args += OpenCodeProtocol.arguments(sessionId: existingThread, model: model,
                workDir: resolvedDir, options: options, filePaths: attachments.map(\.path), majorVersion: openCodeMajor)
        case .grok:
            args += GrokCLI.arguments(sessionID: existingThread, newSessionID: grokNewSessionID,
                model: model, workDir: resolvedDir, options: options)
            if computerTurn != nil { args += ["--allow", "MCPTool(kiln_computer__*)"] }
        }

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
            "\(home)/.grok/bin",
        ]
        let existing = env["PATH"] ?? ""
        env["PATH"] = (extraPaths + [existing]).filter { !$0.isEmpty }.joined(separator: ":")
        env["FORCE_COLOR"] = "0"
        env["PWD"] = resolvedDir
        for key in ComputerConnection.environmentKeys { env[key] = nil }
        if let computerTurn { env.merge(computerTurn.environment) { _, new in new } }
        var openCodeConfig: URL?
        defer { if let openCodeConfig { try? FileManager.default.removeItem(at: openCodeConfig.deletingLastPathComponent()) } }
        if backend == .opencode {
            let configuration = OpenCodeProtocol.configuration(options,
                computerExecutable: computerTurn == nil ? nil : computer.helperExecutable, majorVersion: openCodeMajor)
            if openCodeMajor >= 2 {
                do {
                    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-opencode-" + UUID().uuidString)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                    let file = directory.appendingPathComponent("opencode.json")
                    openCodeConfig = file
                    try Data(configuration.utf8).write(to: file, options: [.atomic])
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                    env["OPENCODE_CONFIG_CONTENT"] = nil
                    env["OPENCODE_CONFIG"] = file.path
                } catch { onEvent(.error("Could not prepare OpenCode settings: " + error.localizedDescription)); onEvent(.done); return }
            } else { env["OPENCODE_CONFIG_CONTENT"] = configuration }
        }
        if backend == .grok { env["GROK_DISABLE_AUTOUPDATER"] = "1"; env["NO_COLOR"] = "1" }
        process.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        runningProcesses[sessionId] = process
        defer { if runningProcesses[sessionId] === process { runningProcesses[sessionId] = nil } }
        if backend == .grok {
            onEvent(.trace(AgentTraceEntry(source: backend.rawValue, phase: "launch", title: "\(backend.label) launched",
                detail: args.filter { $0 != prompt }.joined(separator: " "),
                metadata: ["model": model.cliModel, "provider": backend.label, "workDir": resolvedDir,
                          "mode": options.mode.rawValue, "permissions": options.permissions.rawValue])))
        } else {
            onEvent(.trace(CodexProtocol.invocationTrace(args: args, model: model, workDir: resolvedDir, options: options)))
        }

        do {
            try process.run()
        } catch {
            onEvent(.error("Failed to start \(backend.label): \(error.localizedDescription). Is \(backend.label) installed?"))
            onEvent(.done)
            return
        }
        do { try onLaunch(process.processIdentifier) }
        catch {
            process.terminate()
            try? stdin.fileHandleForWriting.close()
            await Task.detached {
                let deadline = Date().addingTimeInterval(1)
                while process.isRunning, Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
                if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
            }.value
            onEvent(.error("Could not commit the launched turn: " + error.localizedDescription))
            onEvent(.done)
            return
        }
        if resetThread { forgetThread(for: sessionId) }
        onEvent(.started)

        let contextTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.runningProcesses[sessionId] === process else { return }
                let context = await self.currentContext(sessionId: sessionId, model: model)
                guard !Task.isCancelled, self.runningProcesses[sessionId] === process else { return }
                onEvent(.contextUsage(context))
                try? await Task.sleep(for: .seconds(1))
            }
        }
        defer { contextTask.cancel() }
        let backend = self.backend
        let input = Data(prompt.utf8)
        let writeTask = Task.detached {
            defer { try? stdin.fileHandleForWriting.close() }
            try? stdin.fileHandleForWriting.write(contentsOf: input)
        }

        // Drain both pipes concurrently; deliver each batch before reading more.
        // The old implementation held every event until process exit.
        let (code, stderrData) = await Task.detached { () -> (Int32, Data) in
            var buffer = Data()
            var emittedText = false
            var grokStream = GrokProtocol.StreamState(newSessionID: grokNewSessionID)
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
                    if let decoded = CodexProtocol.decodeJSONLine(line) {
                        let json = ToolOutputPrivacy.redact(decoded)
                        switch backend {
                        case .codex: batch += CodexProtocol.parseEvent(json, emittedText: &emittedText)
                        case .opencode: batch += OpenCodeProtocol.parse(json)
                        case .grok: batch += grokStream.parse(json)
                        }
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
                let events = CodexProtocol.decodeJSONLine(line).map { decoded -> [AgentEvent] in
                    let json = ToolOutputPrivacy.redact(decoded)
                    return switch backend {
                    case .codex: CodexProtocol.parseEvent(json, emittedText: &emittedText)
                    case .opencode: OpenCodeProtocol.parse(json)
                    case .grok: grokStream.parse(json)
                    }
                } ?? []
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
        if backend == .grok {
            for line in String(decoding: stderrData, as: UTF8.self).split(whereSeparator: \.isNewline).suffix(40) {
                let detail = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !detail.isEmpty else { continue }
                onEvent(.trace(AgentTraceEntry(source: backend.rawValue, level: .warning, phase: "stderr",
                    title: "CLI output", detail: String(detail.prefix(1_200)), metadata: ["stream": "stderr"])))
            }
        } else {
            for event in CodexProtocol.stderrTraceEvents(stderrData) { onEvent(event) }
        }
        if turnIDs[sessionId] != turnID || Task.isCancelled {
            onEvent(.cancelled)
        } else if code != 0 {
            onEvent(.error("\(backend.label) exited with code \(code): \(String(decoding: stderrData.suffix(4000), as: UTF8.self))"))
        }
        contextTask.cancel()
        let context = await currentContext(sessionId: sessionId, model: model)
        guard runningProcesses[sessionId] === process else { return }
        onEvent(.contextUsage(context))
        if turnIDs[sessionId] != turnID || Task.isCancelled { onEvent(.cancelled) }
        // Finalize once, after errors, usage, and stderr have been delivered.
        onEvent(.done)
    }

    func interrupt(sessionId: String) {
        turnIDs[sessionId] = nil
        computer.stop(sessionID: sessionId)
        guard let process = runningProcesses[sessionId] else { return }
        process.interrupt()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if self.runningProcesses[sessionId] === process, process.isRunning { process.terminate() }
        }
    }

    func kill(sessionId: String) {
        turnIDs[sessionId] = nil
        computer.stop(sessionID: sessionId)
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
