import Foundation
import Network
import AppKit
import Security

/// Tiny HTTP server that exposes Kiln for remote control:
/// - JSON API for scripts/CLI clients
/// - Web UI served at / for phone/tablet browsers on the LAN
///
/// Bound to 127.0.0.1 by default; flip `allowLAN` to let other devices reach it.
/// Optional bearer token via `Authorization: Bearer <token>` header or `?t=` query param.
enum RemoteAccessLevel: String, CaseIterable, Sendable {
    case loopback   // 127.0.0.1 only
    case lan        // all interfaces, LAN IP surfaced
    case tailscale  // all interfaces, Tailscale tailnet IP surfaced
}

@MainActor
final class RemoteControlServer: ObservableObject {
    @Published private(set) var isRunning: Bool = false
    @Published private(set) var lastError: String?
    @Published var port: UInt16 = 8421
    @Published var token: String = ""
    @Published var allowLAN: Bool = false
    @Published var accessLevel: RemoteAccessLevel = .loopback
    @Published private(set) var tailscaleIP: String?
    @Published private(set) var tailscaleStatus: String = "unknown"

    /// Sliding-window brute-force protection for the bearer token. We
    /// record failure timestamps; if >10 failures land inside 60 seconds
    /// the server refuses all auth-required requests for the next 60s.
    /// Global rather than per-IP — single-tenant server, sufficient.
    private var authFailures: [Date] = []
    private var authLockoutUntil: Date?
    private let authFailureWindow: TimeInterval = 60
    private let authFailureLimit: Int = 10
    private let authLockoutDuration: TimeInterval = 60

    /// Per-process shared secret used by the PreToolUse hook script to
    /// authenticate its callbacks into `/api/hooks/pretooluse`. Regenerated on
    /// every launch — not persisted, not exposed to the user. The hook script
    /// receives it via the `KILN_HOOK_SECRET` env var at spawn time.
    let hookSecret: String = {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }()

    private var listener: NWListener?
    nonisolated private let queue = DispatchQueue(label: "kiln.remote", qos: .userInitiated)
    private weak var store: AppStore?

    init(store: AppStore) {
        self.store = store
    }

    // MARK: - Lifecycle

    func start() {
        stop()
        // Refresh Tailscale info on start (fire-and-forget).
        Task { await refreshTailscale() }
        do {
            let params = NWParameters.tcp
            // Reuse the local endpoint — otherwise restarting (or a crash that
            // leaves the port in TIME_WAIT) blocks re-binding for ~30-60s.
            params.allowLocalEndpointReuse = true
            // Loopback-only unless LAN/Tailscale access is explicitly enabled.
            if accessLevel == .loopback {
                params.requiredInterfaceType = .loopback
            }
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                lastError = "Invalid port"
                return
            }
            let listener = try NWListener(using: params, on: nwPort)
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.isRunning = true
                        self?.lastError = nil
                    case .failed(let err):
                        self?.isRunning = false
                        self?.lastError = err.localizedDescription
                    case .cancelled:
                        self?.isRunning = false
                    default:
                        break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                self?.accept(conn)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            lastError = error.localizedDescription
            isRunning = false
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    // MARK: - Connection handling (nonisolated — runs on internal queue)

    nonisolated private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        readRequest(conn, buffer: Data())
    }

    nonisolated private func readRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data = data { buf.append(data) }

            // Try to parse headers; if we have them and the body is complete, handle.
            if let request = HTTPRequest.parse(buf) {
                Task { @MainActor in
                    let response = await self.route(request)
                    self.send(response, on: conn)
                }
                return
            }

            if error != nil || isComplete {
                conn.cancel()
                return
            }
            self.readRequest(conn, buffer: buf)
        }
    }

    nonisolated private func send(_ response: HTTPResponse, on conn: NWConnection) {
        conn.send(content: response.serialize(), completion: .contentProcessed { _ in
            conn.cancel()
        })
    }

    // MARK: - Routing

    @MainActor
    private func route(_ req: HTTPRequest) async -> HTTPResponse {
        // The PreToolUse hook endpoint authenticates with its own per-process
        // shared secret (X-Kiln-Hook-Secret) — the bearer token is for humans
        // on the remote UI, not for hook callbacks spawned by the local CLI.
        if req.path == "/api/hooks/pretooluse" {
            let provided = req.headers["x-kiln-hook-secret"] ?? ""
            if !Self.constantTimeEq(provided, hookSecret) {
                return .json(["error": "unauthorized"], status: 401)
            }
            return await handlePreToolUseHook(req)
        }

        // Auth check (skip for root HTML so browsers can load the page and prompt)
        let needsAuth = !token.isEmpty && !req.path.hasPrefix("/static") && req.path != "/"
        if needsAuth {
            // Lockout gate — if we're inside a lockout window, reject
            // unconditionally without even looking at the credential.
            if let until = authLockoutUntil, Date() < until {
                return .json(["error": "rate_limited", "retry_after": Int(until.timeIntervalSinceNow)], status: 429)
            }
            let provided = req.headers["authorization"]?
                .replacingOccurrences(of: "Bearer ", with: "")
                ?? req.query["t"] ?? ""
            if !Self.constantTimeEq(provided, token) {
                recordAuthFailure()
                return .json(["error": "unauthorized"], status: 401)
            }
            // Success — don't reset the failure list (a valid request
            // inside a flood shouldn't excuse the flood).
        }

        guard let store = store else { return .text("no store", status: 500) }

        switch (req.method, req.path) {
        case ("GET", "/"):
            return .html(Self.indexHTML)

        case ("GET", "/api/state"):
            return .json(Self.fullState(store: store))

        case ("GET", "/api/status"):
            return .json([
                "running": true,
                "isBusy": store.isBusy,
                "activeSessionId": store.activeSessionId as Any,
                "sessionCount": store.sessions.count,
                "inputTokens": store.inputTokens,
                "outputTokens": store.outputTokens,
                "totalCost": store.totalCost,
                "streamingText": store.streamingText,
                "thinkingText": store.thinkingText,
                "activeToolCalls": store.activeToolCalls.map(Self.toolUseJSON),
                "lastError": store.lastError as Any,
            ])

        case ("GET", "/api/sessions"):
            let list = store.sessions.map(Self.sessionJSON)
            return .json(["sessions": list, "activeSessionId": store.activeSessionId as Any])

        case ("GET", "/api/messages"):
            let sid = req.query["session"] ?? store.activeSessionId ?? ""
            guard let session = store.sessions.first(where: { $0.id == sid }) else {
                return .json(["error": "session not found"], status: 404)
            }
            let msgs = session.messages.map(Self.messageJSON)
            return .json([
                "messages": msgs,
                "session": Self.sessionJSON(session),
                "live": [
                    "isBusy": store.isBusy,
                    "streamingText": store.streamingText,
                    "thinkingText": store.thinkingText,
                    "activeToolCalls": store.activeToolCalls.map(Self.toolUseJSON),
                ],
            ])

        case ("GET", "/api/toolbar"):
            return .json(Self.toolbarJSON(store: store))

        case ("GET", "/api/settings"):
            return .json([
                "defaultModel": store.settings.defaultModel.rawValue,
                "defaultMode": store.settings.defaultMode.rawValue,
                "defaultPermissions": store.settings.defaultPermissions.rawValue,
                "defaultWorkDir": store.settings.defaultWorkDir,
                "language": store.settings.language.rawValue,
                "useEngram": store.settings.useEngram,
                "systemPrompt": store.settings.systemPrompt,
                "themeMode": store.settings.themeMode.rawValue,
                "accentHex": store.settings.accentHex,
            ])

        case ("GET", "/api/export"):
            let sid = req.query["session"] ?? store.activeSessionId ?? ""
            guard store.sessions.contains(where: { $0.id == sid }) else {
                return .json(["error": "session not found"], status: 404)
            }
            let md = store.exportSessionMarkdown(sid)
            return HTTPResponse(
                status: 200,
                headers: [
                    "Content-Type": "text/markdown; charset=utf-8",
                    "Content-Disposition": "attachment; filename=chat.md",
                ],
                body: Data(md.utf8)
            )

        case ("GET", "/api/export-json"):
            let sid = req.query["session"] ?? store.activeSessionId ?? ""
            guard let data = store.exportSessionJSONData(sid) else {
                return .json(["error": "session not found"], status: 404)
            }
            let fname = "kiln-session-\(sid).json"
            return HTTPResponse(
                status: 200,
                headers: [
                    "Content-Type": "application/json; charset=utf-8",
                    "Content-Disposition": "attachment; filename=\(fname)",
                ],
                body: data
            )

        case ("POST", "/api/session/import"):
            // Body is the raw session JSON (same shape as `/api/export-json`).
            guard !req.body.isEmpty else {
                return .json(["error": "empty body"], status: 400)
            }
            guard let newId = store.importSessionJSON(req.body) else {
                return .json(["error": "invalid session json"], status: 400)
            }
            return .json(["status": "imported", "sessionId": newId])

        case ("GET", "/api/settings/export"):
            guard let data = store.exportSettingsJSONData() else {
                return .json(["error": "encode failed"], status: 500)
            }
            return HTTPResponse(
                status: 200,
                headers: [
                    "Content-Type": "application/json; charset=utf-8",
                    "Content-Disposition": "attachment; filename=kiln-settings.json",
                ],
                body: data
            )

        case ("POST", "/api/settings/import"):
            guard !req.body.isEmpty else {
                return .json(["error": "empty body"], status: 400)
            }
            guard store.importSettingsJSON(req.body) else {
                return .json(["error": "invalid settings json"], status: 400)
            }
            return .json(["status": "imported"])

        case ("GET", "/api/remote"):
            return .json(remoteInfoJSON())

        case ("POST", "/api/send"):
            guard let body = req.jsonBody,
                  let text = body["text"] as? String
            else { return .json(["error": "missing text"], status: 400) }
            if let sid = body["sessionId"] as? String, sid != store.activeSessionId {
                store.activeSessionId = sid
            }
            guard store.activeSession != nil else {
                return .json(["error": "no active session"], status: 400)
            }
            // Attachments arrive as file paths (array of strings).
            let attachments = (body["attachments"] as? [String]) ?? []
            let prefix: String
            if attachments.isEmpty {
                prefix = ""
            } else {
                let lines = attachments.map { "- \($0)" }.joined(separator: "\n")
                prefix = "Attached files:\n\(lines)\n\n"
            }
            let full = prefix + text
            guard !full.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .json(["error": "empty"], status: 400)
            }
            Task { await store.sendMessage(full) }
            return .json(["status": "queued"])

        case ("POST", "/api/interrupt"):
            store.interrupt()
            return .json(["status": "interrupted"])

        case ("POST", "/api/retry"):
            Task { await store.retryLastMessage() }
            return .json(["status": "queued"])

        case ("POST", "/api/session"):
            let body = req.jsonBody ?? [:]
            let workDir = (body["workDir"] as? String) ?? store.settings.defaultWorkDir
            let kindStr = (body["kind"] as? String) ?? "code"
            let kind: SessionKind = (kindStr == "chat") ? .chat : .code
            let model = (body["model"] as? String).flatMap { ClaudeModel(rawValue: $0) }
            store.createSession(workDir: workDir, model: model, kind: kind)
            return .json([
                "status": "created",
                "sessionId": store.activeSessionId as Any,
            ])

        case ("POST", "/api/session/delete"):
            guard let body = req.jsonBody,
                  let sid = body["sessionId"] as? String
            else { return .json(["error": "missing sessionId"], status: 400) }
            store.deleteSession(sid)
            return .json(["status": "ok"])

        case ("POST", "/api/session/rename"):
            guard let body = req.jsonBody,
                  let sid = body["sessionId"] as? String,
                  let name = body["name"] as? String
            else { return .json(["error": "missing sessionId or name"], status: 400) }
            store.renameSession(sid, name: name)
            return .json(["status": "ok"])

        case ("POST", "/api/session/pin"):
            guard let body = req.jsonBody,
                  let sid = body["sessionId"] as? String
            else { return .json(["error": "missing sessionId"], status: 400) }
            store.togglePin(sid)
            return .json(["status": "ok"])

        case ("POST", "/api/session/archive"):
            guard let body = req.jsonBody,
                  let sid = body["sessionId"] as? String
            else { return .json(["error": "missing sessionId"], status: 400) }
            store.toggleArchiveSession(sid)
            return .json(["status": "ok"])

        case ("POST", "/api/session/clear"):
            guard let body = req.jsonBody,
                  let sid = body["sessionId"] as? String
            else { return .json(["error": "missing sessionId"], status: 400) }
            store.clearSession(sid)
            return .json(["status": "ok"])

        case ("POST", "/api/session/duplicate"):
            guard let body = req.jsonBody,
                  let sid = body["sessionId"] as? String
            else { return .json(["error": "missing sessionId"], status: 400) }
            store.duplicateSession(sid)
            return .json(["status": "ok", "activeSessionId": store.activeSessionId as Any])

        case ("POST", "/api/session/group"):
            guard let body = req.jsonBody,
                  let sid = body["sessionId"] as? String
            else { return .json(["error": "missing sessionId"], status: 400) }
            let group = body["group"] as? String
            // An empty string is treated as "remove from group".
            store.setGroup(sid, group: (group?.isEmpty == false) ? group : nil)
            return .json(["status": "ok"])

        case ("POST", "/api/session/tag"):
            guard let body = req.jsonBody,
                  let sid = body["sessionId"] as? String,
                  let tag = body["tag"] as? String
            else { return .json(["error": "missing sessionId or tag"], status: 400) }
            let op = (body["op"] as? String) ?? "add"
            if op == "remove" { store.removeTag(tag, from: sid) }
            else { store.addTag(tag, to: sid) }
            return .json(["status": "ok"])

        case ("GET", "/api/session/continuation"):
            let sid = req.query["session"] ?? store.activeSessionId ?? ""
            guard store.sessions.contains(where: { $0.id == sid }) else {
                return .json(["error": "session not found"], status: 404)
            }
            let text = store.sessionAsContinuationPrompt(sid)
            return .json(["text": text])

        case ("POST", "/api/select"):
            guard let body = req.jsonBody,
                  let sid = body["sessionId"] as? String
            else { return .json(["error": "missing sessionId"], status: 400) }
            store.activeSessionId = sid
            return .json(["status": "ok"])

        case ("POST", "/api/model"):
            guard let body = req.jsonBody,
                  let name = body["model"] as? String,
                  let m = ClaudeModel(rawValue: name)
            else { return .json(["error": "invalid model"], status: 400) }
            store.setModel(m)
            return .json(["status": "ok"])

        case ("POST", "/api/attach/upload"):
            guard let body = req.jsonBody,
                  let name = body["name"] as? String,
                  let b64 = body["base64"] as? String,
                  let data = Data(base64Encoded: b64)
            else { return .json(["error": "bad payload"], status: 400) }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-remote-uploads", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let safe = name.replacingOccurrences(of: "/", with: "_")
            let file = dir.appendingPathComponent("\(Int(Date().timeIntervalSince1970))-\(safe)")
            do {
                try data.write(to: file)
                return .json(["status": "ok", "path": file.path, "name": safe])
            } catch {
                return .json(["error": "write failed: \(error.localizedDescription)"], status: 500)
            }

        case ("POST", "/api/toolbar"):
            let body = req.jsonBody ?? [:]
            if let v = body["sessionMode"] as? String, let m = SessionMode(rawValue: v) {
                store.sessionMode = m
            }
            if let v = body["permissionMode"] as? String, let m = PermissionMode(rawValue: v) {
                store.permissionMode = m
            }
            if let v = body["effortLevel"] as? String, let e = EffortLevel(rawValue: v) {
                store.effortLevel = e
            }
            if let v = body["thinkingEnabled"] as? Bool {
                store.thinkingEnabled = v
            }
            if let v = body["extendedContext"] as? Bool {
                store.extendedContext = v
            }
            if let v = body["maxTurns"] {
                if v is NSNull { store.maxTurns = nil }
                else if let n = v as? Int { store.maxTurns = n }
            }
            return .json(Self.toolbarJSON(store: store))

        default:
            return .json(["error": "not found", "path": req.path], status: 404)
        }
    }

    // MARK: - PreToolUse hook handler

    /// Handles the POST from `hook-pretooluse.sh`. The CC payload includes
    /// `tool_name`, `tool_input`, and `session_id` (the CLI-side ID). We map
    /// the CLI session back to our internal kiln session, enqueue a
    /// `PendingApproval`, and block on the user's decision via a continuation.
    ///
    /// Returns `{ permissionDecision: "approve" | "deny", reason: "..." }`.
    /// Fail-closed: malformed bodies or missing session mapping → deny.
    @MainActor
    private func handlePreToolUseHook(_ req: HTTPRequest) async -> HTTPResponse {
        guard let store = store else {
            return .json(["permissionDecision": "deny", "reason": "Kiln not ready"], status: 200)
        }
        guard let body = req.jsonBody else {
            return .json(["permissionDecision": "deny", "reason": "Malformed hook payload"], status: 200)
        }
        let toolName = (body["tool_name"] as? String) ?? "unknown"
        let toolInput = body["tool_input"] ?? [:]
        let cliSessionId = (body["session_id"] as? String) ?? ""
        let kilnId = store.claude.kilnSession(forCLI: cliSessionId)

        // Pretty-print tool_input for the approval dialog.
        let inputJSON: String = {
            if let data = try? JSONSerialization.data(
                withJSONObject: toolInput,
                options: [.prettyPrinted, .sortedKeys]
            ), let s = String(data: data, encoding: .utf8) {
                return s
            }
            return "\(toolInput)"
        }()

        let approval = PendingApproval(
            id: UUID().uuidString,
            kilnSessionId: kilnId,
            cliSessionId: cliSessionId,
            toolName: toolName,
            toolInputJSON: inputJSON,
            createdAt: Date()
        )

        let decision = await store.awaitApproval(approval)
        var payload: [String: Any] = [
            "permissionDecision": decision.approve ? "approve" : "deny",
        ]
        if let reason = decision.reason, !reason.isEmpty {
            payload["reason"] = reason
        }
        return .json(payload)
    }

    /// Reads the persistent auto-generated PSK from `~/.kiln/psk`, creating
    /// it with 32 bytes of hex-encoded entropy + 0600 perms on first call.
    /// Unlike `hookSecret` this value survives relaunches so remote bookmarks
    /// keep working across sessions.
    nonisolated static func loadOrCreatePersistentPSK() -> String {
        let home = NSHomeDirectory()
        let dir = "\(home)/.kiln"
        let path = "\(dir)/psk"
        let fm = FileManager.default

        if let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !s.isEmpty {
            return s
        }

        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        try? hex.write(toFile: path, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return hex
    }

    /// Record one failed auth attempt and, if the sliding window has
    /// crossed the limit, engage the lockout.
    private func recordAuthFailure() {
        let now = Date()
        authFailures.append(now)
        // Drop anything older than the window.
        let cutoff = now.addingTimeInterval(-authFailureWindow)
        authFailures.removeAll { $0 < cutoff }
        if authFailures.count >= authFailureLimit {
            authLockoutUntil = now.addingTimeInterval(authLockoutDuration)
        }
    }

    /// Constant-time string equality for auth tokens / shared secrets.
    /// Short-circuits only on length mismatch (which leaks length, but length
    /// is fixed per deployment so that's acceptable).
    private static func constantTimeEq(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        if aBytes.count != bBytes.count { return false }
        var diff: UInt8 = 0
        for i in 0..<aBytes.count {
            diff |= aBytes[i] ^ bBytes[i]
        }
        return diff == 0
    }

    // MARK: - JSON serialization

    @MainActor
    private static func fullState(store: AppStore) -> [String: Any] {
        let sessions = store.sessions.map(sessionJSON)
        let messages: [[String: Any]] = {
            guard let s = store.activeSession else { return [] }
            return s.messages.map(messageJSON)
        }()
        return [
            "sessions": sessions,
            "activeSessionId": store.activeSessionId as Any,
            "messages": messages,
            "live": [
                "isBusy": store.isBusy,
                "streamingText": store.streamingText,
                "thinkingText": store.thinkingText,
                "activeToolCalls": store.activeToolCalls.map(toolUseJSON),
                "lastError": store.lastError as Any,
            ],
            "toolbar": toolbarJSON(store: store),
            "usage": [
                "inputTokens": store.inputTokens,
                "outputTokens": store.outputTokens,
                "totalCost": store.totalCost,
            ],
            "settings": [
                "defaultWorkDir": store.settings.defaultWorkDir,
                "language": store.settings.language.rawValue,
                "themeMode": store.settings.themeMode.rawValue,
                "accentHex": store.settings.accentHex,
            ],
            "models": ClaudeModel.allCases.map { ["id": $0.rawValue, "label": $0.label, "full": $0.fullId, "contextWindow": $0.contextWindow, "extended": $0.extendedContextWindow ?? 0] },
        ]
    }

    @MainActor
    private static func toolbarJSON(store: AppStore) -> [String: Any] {
        [
            "sessionMode": store.sessionMode.rawValue,
            "permissionMode": store.permissionMode.rawValue,
            "effortLevel": store.effortLevel.rawValue,
            "thinkingEnabled": store.thinkingEnabled,
            "extendedContext": store.extendedContext,
            "maxTurns": store.maxTurns as Any,
        ]
    }

    private static func sessionJSON(_ s: Session) -> [String: Any] {
        [
            "id": s.id,
            "name": s.name,
            "kind": s.kind.rawValue,
            "model": s.model.rawValue,
            "workDir": s.workDir,
            "messageCount": s.messages.count,
            "createdAt": s.createdAt.timeIntervalSince1970,
            "updatedAt": (s.messages.last?.timestamp ?? s.createdAt).timeIntervalSince1970,
            "isPinned": s.isPinned,
            "isArchived": s.isArchived,
            "tags": s.tags,
            "group": s.group as Any,
            "forkedFrom": s.forkedFrom as Any,
        ]
    }

    private static func messageJSON(_ m: ChatMessage) -> [String: Any] {
        [
            "id": m.id,
            "role": m.role.rawValue,
            "timestamp": m.timestamp.timeIntervalSince1970,
            "blocks": m.blocks.map(blockJSON),
        ]
    }

    private static func blockJSON(_ b: MessageBlock) -> [String: Any] {
        switch b {
        case .text(let s): return ["type": "text", "text": s]
        case .thinking(let s): return ["type": "thinking", "text": s]
        case .toolUse(let t): return ["type": "toolUse", "tool": toolUseJSON(t)]
        case .toolResult(let r): return ["type": "toolResult", "toolUseId": r.toolUseId, "content": r.content, "isError": r.isError]
        case .suggestions(let s):
            return ["type": "suggestions", "prompts": s.map { ["id": $0.id, "label": $0.label, "prompt": $0.prompt, "icon": $0.icon] }]
        case .attachment(let a):
            return ["type": "attachment", "name": a.name, "path": a.path]
        }
    }

    private static func toolUseJSON(_ t: ToolUseBlock) -> [String: Any] {
        [
            "id": t.id,
            "name": t.name,
            "input": t.input,
            "isDone": t.isDone,
            "result": t.result as Any,
            "isError": t.isError,
        ]
    }

    @MainActor
    private func remoteInfoJSON() -> [String: Any] {
        [
            "port": Int(port),
            "accessLevel": accessLevel.rawValue,
            "allowLAN": allowLAN,
            "tailscale": [
                "status": tailscaleStatus,
                "ip": tailscaleIP as Any,
            ],
            "urls": [
                "local": "http://127.0.0.1:\(port)",
                "lan": Self.localIPv4().map { "http://\($0):\(port)" } as Any,
                "tailscale": tailscaleIP.map { "http://\($0):\(port)" } as Any,
            ],
        ]
    }

    // MARK: - Helpers

    /// Primary URL to show, based on access level.
    var primaryURL: String {
        switch accessLevel {
        case .loopback: return "http://127.0.0.1:\(port)"
        case .lan:
            if let ip = Self.localIPv4() { return "http://\(ip):\(port)" }
            return "http://127.0.0.1:\(port)"
        case .tailscale:
            if let ip = tailscaleIP { return "http://\(ip):\(port)" }
            return "http://127.0.0.1:\(port)"
        }
    }

    /// Back-compat LAN URL (used by settings).
    var lanURL: String? {
        switch accessLevel {
        case .loopback: return "http://127.0.0.1:\(port)"
        case .lan, .tailscale:
            if let ip = Self.localIPv4() { return "http://\(ip):\(port)" }
            return "http://127.0.0.1:\(port)"
        }
    }

    // MARK: - Tailscale detection

    /// Checks if `tailscale` CLI is available and fetches the current tailnet IPv4.
    func refreshTailscale() async {
        let (status, ip) = await Self.detectTailscale()
        await MainActor.run {
            self.tailscaleStatus = status
            self.tailscaleIP = ip
        }
    }

    /// Runs `tailscale ip -4` if the binary exists. Returns (status, ip?).
    /// Status values: "active" | "installed" | "absent" | "error"
    nonisolated private static func detectTailscale() async -> (String, String?) {
        let candidates = [
            "/usr/local/bin/tailscale",
            "/opt/homebrew/bin/tailscale",
            "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        ]
        guard let bin = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            return ("absent", nil)
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = ["ip", "-4"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let out = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .components(separatedBy: "\n").first?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if proc.terminationStatus == 0, let ip = out, !ip.isEmpty {
                return ("active", ip)
            }
            return ("installed", nil)
        } catch {
            return ("error", nil)
        }
    }

    static func localIPv4() -> String? {
        var addr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addr) == 0, let first = addr else { return nil }
        defer { freeifaddrs(addr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while ptr != nil {
            let iface = ptr!.pointee
            let family = iface.ifa_addr.pointee.sa_family
            if family == UInt8(AF_INET) {
                let name = String(cString: iface.ifa_name)
                if name.hasPrefix("en") || name.hasPrefix("bridge") {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(iface.ifa_addr, socklen_t(iface.ifa_addr.pointee.sa_len),
                                   &host, socklen_t(host.count),
                                   nil, 0, NI_NUMERICHOST) == 0 {
                        let ip = String(cString: host)
                        if !ip.hasPrefix("127.") && !ip.hasPrefix("169.254") {
                            return ip
                        }
                    }
                }
            }
            ptr = iface.ifa_next
        }
        return nil
    }

    // MARK: - Embedded Web UI

    static let indexHTML = #"""
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
    <title>Kiln · Remote</title>
    <script src="https://cdn.jsdelivr.net/npm/marked/marked.min.js"></script>
    <style>
      :root {
        --bg: #0e0e10;
        --surface: #18181b;
        --surface-hover: #1f1f23;
        --surface-elevated: #27272a;
        --border: #27272a;
        --border-subtle: #1f1f23;
        --text: #e4e4e7;
        --text-secondary: #a1a1aa;
        --text-tertiary: #71717a;
        --muted: #52525b;
        --accent: #f97316;
        --accent-muted: rgba(249, 115, 22, 0.15);
        --user-bg: #1e293b;
        --purple: #a855f7;
        --blue: #3b82f6;
        --cyan: #06b6d4;
        --amber: #D97706;
        --red: #ef4444;
        --green: #22c55e;
      }
      /* Light mode. Follows the OS by default; force either mode by setting
         data-theme="light" | "dark" on <html>. The JS below flips it when
         the user's native-app theme setting comes in over /api/settings. */
      html[data-theme="light"], html[data-theme="system"]:not([data-theme-override]) {
        color-scheme: light;
      }
      @media (prefers-color-scheme: light) {
        :root {
          --bg: #fafaf9;
          --surface: #ffffff;
          --surface-hover: #f4f4f5;
          --surface-elevated: #f4f4f5;
          --border: #e4e4e7;
          --border-subtle: #f4f4f5;
          --text: #09090b;
          --text-secondary: #52525b;
          --text-tertiary: #71717a;
          --muted: #a1a1aa;
          --accent: #ea580c;
          --accent-muted: rgba(234, 88, 12, 0.14);
          --user-bg: #e0f2fe;
        }
      }
      html[data-theme="light"] {
        --bg: #fafaf9;
        --surface: #ffffff;
        --surface-hover: #f4f4f5;
        --surface-elevated: #f4f4f5;
        --border: #e4e4e7;
        --border-subtle: #f4f4f5;
        --text: #09090b;
        --text-secondary: #52525b;
        --text-tertiary: #71717a;
        --muted: #a1a1aa;
        --accent: #ea580c;
        --accent-muted: rgba(234, 88, 12, 0.14);
        --user-bg: #e0f2fe;
      }
      html[data-theme="dark"] {
        --bg: #0e0e10;
        --surface: #18181b;
        --surface-hover: #1f1f23;
        --surface-elevated: #27272a;
        --border: #27272a;
        --border-subtle: #1f1f23;
        --text: #e4e4e7;
        --text-secondary: #a1a1aa;
        --text-tertiary: #71717a;
        --muted: #52525b;
        --accent: #f97316;
        --accent-muted: rgba(249, 115, 22, 0.15);
        --user-bg: #1e293b;
      }
      * { box-sizing: border-box; }
      html, body { margin: 0; padding: 0; height: 100%; background: var(--bg); color: var(--text); font-family: -apple-system, system-ui, sans-serif; font-size: 13px; }
      body { display: flex; flex-direction: column; height: 100vh; overflow: hidden; }
      button { font-family: inherit; cursor: pointer; }
      ::-webkit-scrollbar { width: 8px; height: 8px; }
      ::-webkit-scrollbar-track { background: transparent; }
      ::-webkit-scrollbar-thumb { background: var(--border); border-radius: 4px; }
      ::-webkit-scrollbar-thumb:hover { background: var(--surface-elevated); }

      /* Top bar */
      .topbar { display: flex; align-items: center; gap: 10px; padding: 8px 12px; border-bottom: 1px solid var(--border); background: var(--surface); flex-shrink: 0; min-height: 44px; }
      .topbar .logo { font-weight: 700; font-size: 14px; color: var(--accent); letter-spacing: 0.3px; }
      .topbar .session-name { font-size: 13px; font-weight: 600; color: var(--text); }
      .topbar .badge { font-size: 10px; padding: 2px 6px; border-radius: 4px; background: var(--surface-elevated); color: var(--text-tertiary); font-weight: 500; }
      .topbar .badge.running { background: var(--accent-muted); color: var(--accent); }
      .topbar .spacer { flex: 1; }
      .topbar button { background: transparent; color: var(--text-secondary); border: 1px solid var(--border); border-radius: 6px; padding: 5px 10px; font-size: 11px; font-weight: 500; }
      .topbar button:hover { background: var(--surface-hover); color: var(--text); }
      .topbar .mobile-toggle { display: none; }
      @media (max-width: 900px) { .topbar .mobile-toggle { display: inline-flex; } }

      /* Layout */
      .layout { flex: 1; display: grid; grid-template-columns: 260px 1fr 280px; min-height: 0; overflow: hidden; }
      @media (max-width: 900px) {
        .layout { grid-template-columns: 1fr; }
        .sidebar, .right-panel { display: none; }
        .layout.show-sidebar .sidebar { display: flex; position: absolute; top: 44px; left: 0; bottom: 0; width: 280px; z-index: 10; background: var(--bg); border-right: 1px solid var(--border); }
        .layout.show-right .right-panel { display: flex; position: absolute; top: 44px; right: 0; bottom: 0; width: 280px; z-index: 10; background: var(--bg); border-left: 1px solid var(--border); }
      }

      /* Sidebar */
      .sidebar { display: flex; flex-direction: column; background: var(--surface); border-right: 1px solid var(--border); overflow: hidden; }
      .sidebar-tabs { display: flex; padding: 8px; gap: 4px; border-bottom: 1px solid var(--border); }
      .sidebar-tab { flex: 1; padding: 6px 10px; border-radius: 6px; background: transparent; color: var(--text-tertiary); border: 1px solid transparent; font-size: 11px; font-weight: 600; }
      .sidebar-tab.active { background: var(--accent); color: var(--bg); }
      .new-session-btn { margin: 8px; padding: 8px 12px; background: var(--accent); color: var(--bg); border: none; border-radius: 6px; font-weight: 600; font-size: 12px; display: flex; align-items: center; justify-content: center; gap: 6px; }
      .new-session-btn:hover { opacity: 0.9; }
      .session-list { flex: 1; overflow-y: auto; padding: 0 8px 8px; }
      .session-group { margin-top: 12px; }
      .session-group-label { font-size: 9px; font-weight: 700; color: var(--text-tertiary); letter-spacing: 1px; padding: 4px 8px; text-transform: uppercase; }
      .session-item { padding: 8px 10px; margin-bottom: 2px; border-radius: 6px; cursor: pointer; display: flex; align-items: center; gap: 8px; border: 1px solid transparent; position: relative; }
      .session-item:hover { background: var(--surface-hover); }
      .session-item.active { background: var(--accent-muted); border-color: var(--accent); }
      .session-item .si-icon { font-size: 11px; color: var(--text-tertiary); }
      .session-item.active .si-icon { color: var(--accent); }
      .session-item .si-body { flex: 1; min-width: 0; }
      .session-item .si-name { font-size: 12px; font-weight: 600; color: var(--text); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
      .session-item .si-meta { font-size: 10px; color: var(--text-tertiary); margin-top: 2px; }
      .session-item .si-delete { opacity: 0; background: transparent; border: none; color: var(--text-tertiary); padding: 2px 6px; border-radius: 4px; font-size: 12px; }
      .session-item:hover .si-delete { opacity: 1; }
      .session-item .si-delete:hover { background: var(--red); color: white; }
      .session-item .si-pin { color: var(--accent); font-size: 10px; }
      .session-item.archived { opacity: 0.55; }
      .session-item.archived .si-name { text-decoration: line-through; text-decoration-color: var(--muted); }
      .si-tags { display: flex; flex-wrap: wrap; gap: 3px; margin-top: 4px; }
      .si-tag { font-size: 9px; padding: 1px 5px; border-radius: 3px; background: var(--surface-elevated); color: var(--text-tertiary); font-weight: 600; }
      .si-rename { flex: 1; background: var(--bg); border: 1px solid var(--accent); border-radius: 4px; padding: 3px 6px; color: var(--text); font-size: 12px; font-family: inherit; min-width: 0; }
      .si-rename:focus { outline: none; }

      /* Sidebar search + archive toggle */
      .sb-search { display: flex; align-items: center; gap: 6px; margin: 0 8px 6px; padding: 5px 8px; background: var(--bg); border: 1px solid var(--border-subtle); border-radius: 6px; }
      .sb-search input { flex: 1; background: transparent; border: none; color: var(--text); font-size: 11px; font-family: inherit; outline: none; min-width: 0; }
      .sb-search .sb-glass { font-size: 10px; color: var(--text-tertiary); }
      .sb-archive { display: flex; align-items: center; padding: 0 8px 6px; }
      .sb-archive button { background: var(--surface-elevated); border: none; border-radius: 5px; padding: 4px 8px; font-size: 10px; font-weight: 600; color: var(--text-tertiary); display: inline-flex; align-items: center; gap: 4px; }
      .sb-archive button.on { background: var(--accent-muted); color: var(--accent); }

      /* Context menu */
      .ctx-menu { position: fixed; z-index: 100; background: var(--surface); border: 1px solid var(--border); border-radius: 8px; padding: 4px; min-width: 200px; box-shadow: 0 8px 24px rgba(0,0,0,0.5); display: none; font-size: 12px; }
      .ctx-menu.show { display: block; }
      .ctx-item { padding: 6px 10px; border-radius: 5px; color: var(--text); cursor: pointer; display: flex; align-items: center; gap: 8px; user-select: none; }
      .ctx-item:hover { background: var(--surface-hover); }
      .ctx-item.destructive { color: var(--red); }
      .ctx-item.destructive:hover { background: rgba(239,68,68,0.12); }
      .ctx-item .ctx-icon { width: 14px; text-align: center; opacity: 0.7; font-size: 11px; }
      .ctx-sep { height: 1px; background: var(--border-subtle); margin: 4px 2px; }
      .ctx-sub { position: relative; }
      .ctx-sub > .ctx-item::after { content: '▸'; margin-left: auto; opacity: 0.5; font-size: 9px; }
      .ctx-sub-menu { position: absolute; left: 100%; top: -4px; background: var(--surface); border: 1px solid var(--border); border-radius: 8px; padding: 4px; min-width: 160px; box-shadow: 0 8px 24px rgba(0,0,0,0.5); display: none; }
      .ctx-sub:hover > .ctx-sub-menu { display: block; }

      /* Main */
      .main { display: flex; flex-direction: column; background: var(--bg); min-width: 0; overflow: hidden; }
      .chat-header { padding: 8px 16px; border-bottom: 1px solid var(--border); background: var(--surface); display: flex; align-items: center; gap: 8px; font-size: 12px; flex-shrink: 0; }
      .chat-header .ch-model { margin-left: auto; font-family: ui-monospace, monospace; font-size: 10px; color: var(--accent); background: var(--accent-muted); padding: 2px 8px; border-radius: 4px; font-weight: 600; }
      .messages { flex: 1; overflow-y: auto; padding: 12px 16px; }
      .msg-wrap { max-width: 800px; margin: 0 auto 16px; }
      .msg-wrap.user { display: flex; justify-content: flex-end; }
      .msg-wrap.assistant { display: flex; justify-content: flex-start; }
      .msg { padding: 10px 14px; border-radius: 12px; max-width: 100%; font-size: 14px; line-height: 1.5; word-wrap: break-word; }
      .msg.user { background: var(--user-bg); color: var(--text); max-width: 80%; }
      .msg.assistant { background: transparent; color: var(--text); flex: 1; }
      .msg p { margin: 0 0 8px; }
      .msg p:last-child { margin-bottom: 0; }
      .msg pre { background: var(--surface); border: 1px solid var(--border); border-radius: 6px; padding: 10px 12px; overflow-x: auto; font-size: 12px; font-family: ui-monospace, monospace; }
      .msg code { background: var(--surface); padding: 1px 5px; border-radius: 3px; font-family: ui-monospace, monospace; font-size: 12px; }
      .msg pre code { background: transparent; padding: 0; }
      .msg ul, .msg ol { margin: 0 0 8px; padding-left: 22px; }
      .msg a { color: var(--accent); }

      .block-thinking { margin: 6px 0; padding: 8px 12px; background: rgba(168, 85, 247, 0.08); border-left: 2px solid var(--purple); border-radius: 4px; font-size: 12px; color: var(--text-secondary); white-space: pre-wrap; }
      .block-thinking-label { font-size: 10px; color: var(--purple); font-weight: 700; text-transform: uppercase; letter-spacing: 0.5px; margin-bottom: 4px; }

      .tool-block { margin: 6px 0; background: var(--surface); border: 1px solid var(--border); border-radius: 6px; overflow: hidden; }
      .tool-head { padding: 6px 10px; display: flex; align-items: center; gap: 8px; font-size: 11px; }
      .tool-head .tname { font-family: ui-monospace, monospace; font-weight: 600; color: var(--accent); }
      .tool-head .tdot { width: 6px; height: 6px; border-radius: 50%; background: var(--amber); }
      .tool-head .tdot.done { background: var(--green); }
      .tool-head .tdot.error { background: var(--red); }
      .tool-body { padding: 8px 10px; border-top: 1px solid var(--border); font-family: ui-monospace, monospace; font-size: 11px; color: var(--text-secondary); white-space: pre-wrap; max-height: 180px; overflow-y: auto; }
      .tool-result { padding: 6px 10px; border-top: 1px solid var(--border); font-family: ui-monospace, monospace; font-size: 11px; color: var(--text-tertiary); white-space: pre-wrap; max-height: 140px; overflow-y: auto; background: rgba(255,255,255,0.02); }
      .tool-result.error { color: var(--red); }

      .live-dot { display: inline-block; width: 6px; height: 6px; border-radius: 50%; background: var(--accent); margin-left: 4px; animation: pulse 1.2s ease-in-out infinite; }
      @keyframes pulse { 0%, 100% { opacity: 1 } 50% { opacity: 0.3 } }

      .err-row { max-width: 800px; margin: 10px auto; padding: 10px 14px; background: rgba(239, 68, 68, 0.1); border-left: 3px solid var(--red); border-radius: 6px; font-size: 13px; color: var(--red); }

      /* Composer */
      .composer { border-top: 1px solid var(--border); background: var(--bg); flex-shrink: 0; }
      .composer-bar { display: flex; gap: 4px; padding: 6px 12px; overflow-x: auto; border-bottom: 1px solid var(--border-subtle); }
      .composer-bar::-webkit-scrollbar { height: 0; }
      .pill { display: inline-flex; align-items: center; gap: 4px; background: var(--surface); border: 1px solid var(--border-subtle); border-radius: 6px; padding: 4px 9px; font-size: 10px; font-weight: 600; color: var(--text-tertiary); white-space: nowrap; cursor: pointer; }
      .pill:hover { background: var(--surface-hover); }
      .pill.active { color: var(--accent); border-color: rgba(249, 115, 22, 0.3); }
      .pill.active.plan { color: var(--cyan); border-color: rgba(6, 182, 212, 0.3); }
      .pill.active.think { color: var(--purple); border-color: rgba(168, 85, 247, 0.3); }
      .pill.active.deny { color: var(--red); border-color: rgba(239, 68, 68, 0.3); }
      .pill.active.ask { color: var(--blue); border-color: rgba(59, 130, 246, 0.3); }
      .pill.active.max { color: var(--amber); border-color: rgba(217, 119, 6, 0.3); }
      .pill-divider { width: 1px; background: var(--border); margin: 4px 2px; }
      .pill.model { font-family: ui-monospace, monospace; font-size: 9px; font-weight: 700; }
      .pill.model.selected { background: var(--accent); color: var(--bg); border-color: var(--accent); }
      .pill.model.selected.opus { background: var(--amber); border-color: var(--amber); }
      .context-info { margin-left: auto; display: flex; align-items: center; gap: 6px; font-size: 10px; font-family: ui-monospace, monospace; color: var(--text-tertiary); padding-right: 4px; white-space: nowrap; }

      .attach-chips { display: flex; gap: 6px; padding: 6px 12px; overflow-x: auto; border-bottom: 1px solid var(--border-subtle); }
      .attach-chips:empty { display: none; }
      .chip { display: inline-flex; align-items: center; gap: 6px; background: var(--surface); border: 1px solid var(--border); border-radius: 6px; padding: 4px 8px; font-size: 11px; }
      .chip .chip-name { color: var(--text); font-weight: 500; max-width: 160px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
      .chip .chip-x { background: transparent; border: none; color: var(--text-tertiary); cursor: pointer; padding: 0 2px; }

      .composer-row { display: flex; gap: 8px; padding: 10px 12px; align-items: flex-end; }
      .composer-attach { background: var(--surface); border: 1px solid var(--border); border-radius: 50%; width: 32px; height: 32px; display: flex; align-items: center; justify-content: center; color: var(--text-secondary); font-size: 16px; flex-shrink: 0; }
      .composer-attach:hover { background: var(--surface-hover); color: var(--text); }
      .composer-input { flex: 1; background: var(--surface); color: var(--text); border: 1px solid var(--border); border-radius: 12px; padding: 10px 14px; font-size: 14px; font-family: inherit; resize: none; min-height: 40px; max-height: 200px; }
      .composer-input:focus { outline: none; border-color: rgba(249, 115, 22, 0.5); }
      .composer-send { background: var(--accent); color: var(--bg); border: none; border-radius: 50%; width: 40px; height: 40px; font-size: 18px; display: flex; align-items: center; justify-content: center; flex-shrink: 0; }
      .composer-send:disabled { background: var(--surface-elevated); color: var(--text-tertiary); cursor: not-allowed; }
      .composer-stop { background: var(--red); color: white; border: none; border-radius: 50%; width: 40px; height: 40px; font-size: 16px; flex-shrink: 0; }

      /* Right panel */
      .right-panel { display: flex; flex-direction: column; background: var(--surface); border-left: 1px solid var(--border); overflow: hidden; }
      .right-tabs { display: flex; padding: 8px; gap: 4px; border-bottom: 1px solid var(--border); }
      .right-tab { flex: 1; padding: 6px; background: transparent; color: var(--text-tertiary); border: 1px solid transparent; border-radius: 6px; font-size: 10px; font-weight: 600; }
      .right-tab.active { background: var(--surface-elevated); color: var(--text); }
      .right-body { flex: 1; overflow-y: auto; padding: 10px 12px; }
      .activity-item { padding: 8px 10px; margin-bottom: 6px; background: var(--bg); border: 1px solid var(--border); border-radius: 6px; font-size: 11px; }
      .activity-item .ai-name { font-family: ui-monospace, monospace; font-weight: 600; color: var(--accent); font-size: 11px; }
      .activity-item .ai-input { margin-top: 4px; color: var(--text-tertiary); font-family: ui-monospace, monospace; font-size: 10px; white-space: pre-wrap; max-height: 80px; overflow-y: auto; }
      .stats-row { display: flex; justify-content: space-between; padding: 6px 0; font-size: 12px; border-bottom: 1px solid var(--border-subtle); }
      .stats-row .sl { color: var(--text-tertiary); }
      .stats-row .sv { color: var(--text); font-weight: 600; font-family: ui-monospace, monospace; }
      .empty { color: var(--text-tertiary); text-align: center; padding: 30px 12px; font-size: 12px; }

      /* Modal */
      .modal-bg { position: fixed; inset: 0; background: rgba(0,0,0,0.6); display: none; align-items: center; justify-content: center; z-index: 50; }
      .modal-bg.show { display: flex; }
      .modal { background: var(--bg); border: 1px solid var(--border); border-radius: 10px; padding: 20px; width: min(460px, 92vw); max-height: 86vh; overflow-y: auto; }
      .modal h2 { margin: 0 0 16px; font-size: 15px; font-weight: 600; }
      .modal label { display: block; font-size: 11px; color: var(--text-tertiary); margin: 10px 0 4px; font-weight: 600; text-transform: uppercase; letter-spacing: 0.5px; }
      .modal input, .modal select { width: 100%; background: var(--surface); color: var(--text); border: 1px solid var(--border); border-radius: 6px; padding: 8px 10px; font-size: 13px; font-family: inherit; }
      .modal .row { display: flex; gap: 8px; margin-top: 16px; justify-content: flex-end; }
      .modal .btn { padding: 7px 14px; border-radius: 6px; font-size: 12px; font-weight: 600; border: 1px solid var(--border); background: var(--surface); color: var(--text); }
      .modal .btn.primary { background: var(--accent); color: var(--bg); border-color: var(--accent); }
      .modal .info-box { background: var(--surface); border: 1px solid var(--border); border-radius: 6px; padding: 10px 12px; font-size: 11px; font-family: ui-monospace, monospace; color: var(--text-secondary); margin-top: 6px; word-break: break-all; }
      .modal .info-box .lbl { color: var(--text-tertiary); margin-right: 6px; }

      .drop-overlay { position: absolute; inset: 0; background: rgba(249, 115, 22, 0.08); display: none; align-items: center; justify-content: center; pointer-events: none; z-index: 20; font-weight: 600; color: var(--accent); }
      .drop-overlay.show { display: flex; }
    </style>
    </head>
    <body>
      <div class="topbar">
        <button class="mobile-toggle" onclick="document.querySelector('.layout').classList.toggle('show-sidebar')">☰</button>
        <div class="logo">Kiln Code</div>
        <span id="activeSessionName" class="session-name">No session</span>
        <span id="busyBadge" class="badge">idle</span>
        <span class="spacer"></span>
        <button id="retryBtn" title="Retry last (⇧⌘R)">↻ Retry</button>
        <button id="exportBtn" title="Export chat">⤓ Export</button>
        <button id="settingsBtn" title="Settings">⚙</button>
        <button class="mobile-toggle" onclick="document.querySelector('.layout').classList.toggle('show-right')">▸</button>
      </div>

      <div class="layout">
        <!-- Sidebar -->
        <aside class="sidebar">
          <div class="sidebar-tabs">
            <button class="sidebar-tab active" data-kind="code">⌨ Code</button>
            <button class="sidebar-tab" data-kind="chat">💬 Chat</button>
          </div>
          <button class="new-session-btn" id="newSessionBtn">+ New Session</button>
          <div class="sb-search">
            <span class="sb-glass">🔍</span>
            <input id="sessionSearch" placeholder="Search sessions, tags, paths…" spellcheck="false" autocomplete="off">
          </div>
          <div class="sb-archive" id="archiveBar"></div>
          <div class="session-list" id="sessionList"></div>
        </aside>

        <!-- Main chat -->
        <main class="main" id="main">
          <div class="chat-header">
            <span id="chatHdrIcon">💬</span>
            <span id="chatHdrName">Select a session</span>
            <span id="chatHdrBusy" style="display:none; color:var(--accent); font-size:11px;">working<span class="live-dot"></span></span>
            <span id="chatHdrModel" class="ch-model" style="display:none;"></span>
          </div>
          <div class="messages" id="messages"></div>

          <div class="composer">
            <div class="composer-bar" id="composerBar"></div>
            <div class="attach-chips" id="attachChips"></div>
            <div class="composer-row">
              <button class="composer-attach" id="attachBtn" title="Attach files or images">📎</button>
              <input type="file" id="fileInput" multiple style="display:none">
              <textarea class="composer-input" id="composerInput" rows="1" placeholder="Message Claude…"></textarea>
              <button class="composer-send" id="sendBtn" title="Send">➤</button>
              <button class="composer-stop" id="stopBtn" title="Stop" style="display:none;">■</button>
            </div>
          </div>
          <div class="drop-overlay" id="dropOverlay">Drop to attach</div>
        </main>

        <!-- Right panel -->
        <aside class="right-panel">
          <div class="right-tabs">
            <button class="right-tab active" data-tab="activity">Activity</button>
            <button class="right-tab" data-tab="stats">Stats</button>
            <button class="right-tab" data-tab="remote">Remote</button>
          </div>
          <div class="right-body" id="rightBody"></div>
        </aside>
      </div>

      <!-- Settings / new session modal -->
      <div class="modal-bg" id="modalBg">
        <div class="modal" id="modalContent"></div>
      </div>

      <!-- Session context menu (right-click / long-press on a session item) -->
      <div class="ctx-menu" id="ctxMenu"></div>

    <script>
    const token = new URLSearchParams(location.search).get('t') || '';
    const qt = token ? ('?t=' + encodeURIComponent(token)) : '';
    const authHeaders = token ? { 'Authorization': 'Bearer ' + token } : {};

    async function api(path, opts = {}) {
      const sep = path.includes('?') ? '&' : '?';
      const fullPath = token ? path + sep + 't=' + encodeURIComponent(token) : path;
      const res = await fetch(fullPath, {
        ...opts,
        headers: { 'Content-Type': 'application/json', ...authHeaders, ...(opts.headers || {}) },
      });
      if (!res.ok && res.status === 401) { alert('Unauthorized — check your token.'); throw new Error('401'); }
      const ct = res.headers.get('content-type') || '';
      if (ct.includes('json')) return res.json();
      return res.text();
    }

    // --- App state ---
    const state = {
      sessions: [],
      activeId: null,
      activeSession: null,
      messages: [],
      live: { isBusy: false, streamingText: '', thinkingText: '', activeToolCalls: [], lastError: null },
      toolbar: { sessionMode: 'build', permissionMode: 'bypass', effortLevel: 'medium', thinkingEnabled: false, extendedContext: false, maxTurns: null },
      usage: { inputTokens: 0, outputTokens: 0, totalCost: 0 },
      settings: { defaultWorkDir: '~' },
      models: [],
      sidebarKind: 'code',
      rightTab: 'activity',
      attachments: [],  // { path, name }
      remote: null,
      search: '',
      showArchived: false,
      renamingId: null,
    };

    // --- Render ---
    function escHTML(s) {
      return (s || '').replace(/[&<>"']/g, c => ({ '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;' })[c]);
    }

    function matchesSearch(s, q) {
      if (!q) return true;
      const needle = q.toLowerCase();
      const tagQuery = needle.startsWith('#') ? needle.slice(1) : needle;
      return (
        s.name.toLowerCase().includes(needle) ||
        (s.workDir || '').toLowerCase().includes(needle) ||
        (s.group || '').toLowerCase().includes(needle) ||
        (s.tags || []).some(t => t.includes(tagQuery))
      );
    }

    function renderArchiveBar() {
      const bar = document.getElementById('archiveBar');
      const archivedCount = state.sessions.filter(s => s.kind === state.sidebarKind && s.isArchived).length;
      if (!archivedCount && !state.showArchived) { bar.innerHTML = ''; return; }
      const cls = state.showArchived ? 'on' : '';
      const label = state.showArchived ? '← Back to active' : `📦 Archive (${archivedCount})`;
      bar.innerHTML = `<button class="${cls}" id="archiveToggle">${label}</button>`;
      document.getElementById('archiveToggle').onclick = () => {
        state.showArchived = !state.showArchived;
        renderSessions();
        renderArchiveBar();
      };
    }

    function renderSessions() {
      const box = document.getElementById('sessionList');
      box.innerHTML = '';
      const filtered = state.sessions.filter(s =>
        s.kind === state.sidebarKind &&
        (state.showArchived ? s.isArchived : !s.isArchived) &&
        matchesSearch(s, state.search)
      );
      if (!filtered.length) {
        box.innerHTML = '<div class="empty">No ' + (state.showArchived ? 'archived' : state.sidebarKind) + ' sessions' + (state.search ? ' matching "' + escHTML(state.search) + '"' : '') + '.</div>';
        return;
      }
      // Pinned float to top, in a synthetic "Pinned" group. Everything else
      // keeps its real group. When searching, flatten so hits don't hide
      // behind collapsed groups.
      const groups = {};
      if (state.search) {
        groups['—'] = filtered.slice();
      } else {
        const pinned = filtered.filter(s => s.isPinned);
        if (pinned.length) groups['📌 Pinned'] = pinned;
        for (const s of filtered) {
          if (s.isPinned) continue;
          const g = s.group || '—';
          (groups[g] = groups[g] || []).push(s);
        }
      }
      for (const [gname, list] of Object.entries(groups)) {
        const ge = document.createElement('div');
        ge.className = 'session-group';
        if (gname !== '—') {
          const lbl = document.createElement('div');
          lbl.className = 'session-group-label';
          lbl.textContent = gname;
          ge.appendChild(lbl);
        }
        for (const s of list) {
          const it = document.createElement('div');
          const cls = ['session-item'];
          if (s.id === state.activeId) cls.push('active');
          if (s.isArchived) cls.push('archived');
          it.className = cls.join(' ');
          it.dataset.id = s.id;

          const icon = s.forkedFrom ? '⑂' : (s.kind === 'chat' ? '💬' : '⌨');
          const pin = s.isPinned ? '<span class="si-pin" title="Pinned">📌</span>' : '';
          const tags = (s.tags || []).length
            ? `<div class="si-tags">${s.tags.map(t => `<span class="si-tag">#${escHTML(t)}</span>`).join('')}</div>`
            : '';

          // Inline rename mode
          if (state.renamingId === s.id) {
            it.innerHTML = `
              <span class="si-icon">${icon}</span>
              <input class="si-rename" value="${escHTML(s.name)}" autofocus>
            `;
            const input = it.querySelector('.si-rename');
            const commit = async () => {
              const newName = input.value.trim();
              state.renamingId = null;
              if (newName && newName !== s.name) {
                await api('/api/session/rename', { method: 'POST', body: JSON.stringify({ sessionId: s.id, name: newName }) });
              }
              await refreshAll();
            };
            input.addEventListener('keydown', (e) => {
              if (e.key === 'Enter') { e.preventDefault(); commit(); }
              else if (e.key === 'Escape') { state.renamingId = null; renderSessions(); }
            });
            input.addEventListener('blur', commit);
            setTimeout(() => { input.focus(); input.select(); }, 0);
          } else {
            it.innerHTML = `
              <span class="si-icon">${icon}</span>
              <div class="si-body">
                <div class="si-name">${pin}${escHTML(s.name)}</div>
                <div class="si-meta">${s.messageCount} msg · ${escHTML(s.model)}</div>
                ${tags}
              </div>
              <button class="si-delete" data-id="${s.id}" title="Delete">×</button>
            `;
            it.addEventListener('click', async (e) => {
              if (e.target.classList.contains('si-delete')) return;
              state.activeId = s.id;
              await api('/api/select', { method: 'POST', body: JSON.stringify({ sessionId: s.id }) });
              await refreshAll();
              if (window.innerWidth <= 900) document.querySelector('.layout').classList.remove('show-sidebar');
            });
            it.addEventListener('dblclick', (e) => {
              if (e.target.classList.contains('si-delete')) return;
              state.renamingId = s.id;
              renderSessions();
            });
            it.addEventListener('contextmenu', (e) => {
              e.preventDefault();
              openSessionMenu(e.clientX, e.clientY, s);
            });
            // Long-press for touch devices — same menu as right-click.
            let lpTimer = null;
            it.addEventListener('touchstart', (e) => {
              lpTimer = setTimeout(() => {
                const t = e.touches[0];
                openSessionMenu(t.clientX, t.clientY, s);
              }, 500);
            }, { passive: true });
            it.addEventListener('touchend', () => { if (lpTimer) clearTimeout(lpTimer); });
            it.addEventListener('touchmove', () => { if (lpTimer) clearTimeout(lpTimer); });
            it.querySelector('.si-delete').addEventListener('click', async (e) => {
              e.stopPropagation();
              if (!confirm('Delete session "' + s.name + '"?')) return;
              await api('/api/session/delete', { method: 'POST', body: JSON.stringify({ sessionId: s.id }) });
              await refreshAll();
            });
          }
          ge.appendChild(it);
        }
        box.appendChild(ge);
      }
    }

    function renderChatHeader() {
      const s = state.activeSession;
      if (!s) {
        document.getElementById('chatHdrName').textContent = 'Select a session';
        document.getElementById('chatHdrIcon').textContent = '💬';
        document.getElementById('chatHdrModel').style.display = 'none';
        return;
      }
      document.getElementById('chatHdrName').textContent = s.name;
      document.getElementById('chatHdrIcon').textContent = s.kind === 'chat' ? '💬' : '⌨';
      const model = state.models.find(m => m.id === s.model);
      document.getElementById('chatHdrModel').textContent = model ? model.label : s.model;
      document.getElementById('chatHdrModel').style.display = 'inline-block';
      document.getElementById('chatHdrBusy').style.display = state.live.isBusy ? 'inline' : 'none';
      document.getElementById('activeSessionName').textContent = s.name;
      document.getElementById('busyBadge').textContent = state.live.isBusy ? 'working…' : 'idle';
      document.getElementById('busyBadge').className = 'badge' + (state.live.isBusy ? ' running' : '');
    }

    function renderBlock(block) {
      if (block.type === 'text') {
        return `<div class="block-text">${marked.parse(block.text || '')}</div>`;
      } else if (block.type === 'thinking') {
        return `<div class="block-thinking">
          <div class="block-thinking-label">✨ thinking</div>
          ${escHTML(block.text || '')}
        </div>`;
      } else if (block.type === 'toolUse') {
        const t = block.tool;
        const cls = t.isError ? 'error' : (t.isDone ? 'done' : '');
        return `<div class="tool-block">
          <div class="tool-head">
            <span class="tdot ${cls}"></span>
            <span class="tname">${escHTML(t.name)}</span>
          </div>
          ${t.input ? `<div class="tool-body">${escHTML(t.input)}</div>` : ''}
          ${t.result ? `<div class="tool-result ${t.isError ? 'error' : ''}">${escHTML(t.result)}</div>` : ''}
        </div>`;
      } else if (block.type === 'toolResult') {
        return `<div class="tool-result ${block.isError ? 'error' : ''}">${escHTML(block.content || '')}</div>`;
      }
      return '';
    }

    function renderMessages() {
      const box = document.getElementById('messages');
      const atBottom = box.scrollHeight - box.scrollTop - box.clientHeight < 50;
      let html = '';
      for (const m of state.messages) {
        const blockHTML = (m.blocks || []).map(renderBlock).join('');
        html += `<div class="msg-wrap ${m.role}">
          <div class="msg ${m.role}">${blockHTML}</div>
        </div>`;
      }
      // Live assistant row (streaming)
      const live = state.live;
      if (live.isBusy || live.streamingText || live.thinkingText || (live.activeToolCalls && live.activeToolCalls.length)) {
        let liveBlocks = '';
        if (live.thinkingText) liveBlocks += renderBlock({ type: 'thinking', text: live.thinkingText });
        for (const t of (live.activeToolCalls || [])) {
          liveBlocks += renderBlock({ type: 'toolUse', tool: t });
        }
        if (live.streamingText) liveBlocks += renderBlock({ type: 'text', text: live.streamingText });
        if (!liveBlocks) liveBlocks = '<div style="color:var(--text-tertiary); font-size:12px;">thinking<span class="live-dot"></span></div>';
        html += `<div class="msg-wrap assistant"><div class="msg assistant">${liveBlocks}</div></div>`;
      }
      if (live.lastError) {
        html += `<div class="err-row">⚠ ${escHTML(live.lastError)}</div>`;
      }
      box.innerHTML = html;
      if (atBottom) box.scrollTop = box.scrollHeight;
    }

    function renderToolbar() {
      const s = state.activeSession;
      if (!s) { document.getElementById('composerBar').innerHTML = ''; return; }
      const tb = state.toolbar;
      const isChat = s.kind === 'chat';
      const pills = [];
      if (!isChat) {
        pills.push(`<button class="pill active ${tb.sessionMode === 'plan' ? 'plan' : ''}" data-action="mode">${tb.sessionMode === 'plan' ? '📋 plan' : '🔨 build'}</button>`);
        const permLabel = { bypass: '🔓 bypass', ask: '❓ ask', deny: '🚫 deny' }[tb.permissionMode] || tb.permissionMode;
        const permCls = tb.permissionMode === 'ask' ? 'ask' : (tb.permissionMode === 'deny' ? 'deny' : '');
        pills.push(`<button class="pill active ${permCls}" data-action="perm">${permLabel}</button>`);
        const turns = tb.maxTurns === null || tb.maxTurns === undefined ? '∞ turns' : (tb.maxTurns + ' turns');
        pills.push(`<button class="pill ${tb.maxTurns != null ? 'active' : ''}" data-action="turns">↺ ${turns}</button>`);
      }
      pills.push(`<button class="pill ${tb.thinkingEnabled ? 'active think' : ''}" data-action="think">🧠 ${tb.thinkingEnabled ? 'think' : 'no think'}</button>`);
      if (tb.thinkingEnabled) {
        const effCls = tb.effortLevel === 'max' ? 'max' : '';
        pills.push(`<button class="pill active ${effCls}" data-action="effort">⚡ ${tb.effortLevel}</button>`);
      }
      if (!isChat) pills.push('<span class="pill-divider"></span>');
      // Models
      for (const m of state.models) {
        const sel = s.model === m.id;
        const isOpus = m.id.includes('opus');
        pills.push(`<button class="pill model ${sel ? 'selected' : ''} ${isOpus ? 'opus' : ''}" data-model="${m.id}">✦ ${m.label}</button>`);
      }
      const ctxWindow = state.toolbar.extendedContext ? 1_000_000 : 200_000;
      const totalTokens = (state.usage.inputTokens || 0) + (state.usage.outputTokens || 0);
      const pct = Math.min(100, (totalTokens / ctxWindow * 100));
      const ctxText = totalTokens > 0 ? `${formatTokens(totalTokens)}/${formatTokens(ctxWindow)} · $${(state.usage.totalCost || 0).toFixed(2)}` : '';
      const bar = document.getElementById('composerBar');
      bar.innerHTML = pills.join('') + (ctxText ? `<span class="context-info">${ctxText}</span>` : '');
      bar.querySelectorAll('[data-model]').forEach(b => b.onclick = () => api('/api/model', { method: 'POST', body: JSON.stringify({ model: b.dataset.model }) }).then(refreshAll));
      bar.querySelectorAll('[data-action]').forEach(b => b.onclick = () => handleToolbarClick(b.dataset.action));
    }

    function formatTokens(n) {
      if (n >= 1_000_000) return (n/1_000_000).toFixed(1) + 'M';
      if (n >= 1_000) return Math.round(n/1_000) + 'K';
      return String(n);
    }

    async function handleToolbarClick(action) {
      const tb = { ...state.toolbar };
      if (action === 'mode') tb.sessionMode = tb.sessionMode === 'build' ? 'plan' : 'build';
      else if (action === 'perm') tb.permissionMode = { bypass: 'ask', ask: 'deny', deny: 'bypass' }[tb.permissionMode];
      else if (action === 'turns') {
        const cycle = [null, 5, 10, 25, 50];
        const idx = cycle.indexOf(tb.maxTurns);
        tb.maxTurns = cycle[(idx + 1) % cycle.length];
      }
      else if (action === 'think') tb.thinkingEnabled = !tb.thinkingEnabled;
      else if (action === 'effort') {
        const cycle = ['low', 'medium', 'high', 'max'];
        tb.effortLevel = cycle[(cycle.indexOf(tb.effortLevel) + 1) % cycle.length];
      }
      const resp = await api('/api/toolbar', { method: 'POST', body: JSON.stringify(tb) });
      state.toolbar = resp;
      renderToolbar();
    }

    function renderAttachments() {
      const box = document.getElementById('attachChips');
      if (!state.attachments.length) { box.innerHTML = ''; return; }
      box.innerHTML = state.attachments.map((a, i) => `
        <div class="chip">
          <span>📎</span>
          <span class="chip-name" title="${escHTML(a.path)}">${escHTML(a.name)}</span>
          <button class="chip-x" data-i="${i}">×</button>
        </div>
      `).join('');
      box.querySelectorAll('.chip-x').forEach(b => b.onclick = () => {
        state.attachments.splice(parseInt(b.dataset.i), 1);
        renderAttachments();
      });
    }

    function renderRightPanel() {
      const box = document.getElementById('rightBody');
      if (state.rightTab === 'activity') {
        const calls = state.live.activeToolCalls || [];
        if (!calls.length && !state.live.isBusy) { box.innerHTML = '<div class="empty">No activity yet.</div>'; return; }
        box.innerHTML = calls.map(t => `
          <div class="activity-item">
            <div class="ai-name">${escHTML(t.name)}</div>
            ${t.input ? `<div class="ai-input">${escHTML(t.input.slice(0, 500))}</div>` : ''}
          </div>
        `).join('') || '<div class="empty">Working…</div>';
      } else if (state.rightTab === 'stats') {
        box.innerHTML = `
          <div class="stats-row"><span class="sl">Input tokens</span><span class="sv">${formatTokens(state.usage.inputTokens || 0)}</span></div>
          <div class="stats-row"><span class="sl">Output tokens</span><span class="sv">${formatTokens(state.usage.outputTokens || 0)}</span></div>
          <div class="stats-row"><span class="sl">Total cost</span><span class="sv">$${(state.usage.totalCost || 0).toFixed(4)}</span></div>
          <div class="stats-row"><span class="sl">Sessions</span><span class="sv">${state.sessions.length}</span></div>
          <div class="stats-row"><span class="sl">Messages</span><span class="sv">${state.messages.length}</span></div>
        `;
      } else if (state.rightTab === 'remote') {
        const r = state.remote || {};
        const urls = r.urls || {};
        const ts = r.tailscale || {};
        const tsBadge = { active: '🟢 active', installed: '🟡 installed (not logged in)', absent: '⚫ not installed', error: '🔴 error' }[ts.status] || ts.status;
        box.innerHTML = `
          <div style="font-size:10px; color:var(--text-tertiary); font-weight:700; letter-spacing:1px; margin-bottom:8px;">URLS</div>
          ${urls.local ? `<div class="stats-row"><span class="sl">local</span><span class="sv" style="font-size:10px;">${urls.local}</span></div>` : ''}
          ${urls.lan ? `<div class="stats-row"><span class="sl">lan</span><span class="sv" style="font-size:10px;">${urls.lan}</span></div>` : ''}
          ${urls.tailscale ? `<div class="stats-row"><span class="sl">tailscale</span><span class="sv" style="font-size:10px;">${urls.tailscale}</span></div>` : ''}
          <div style="font-size:10px; color:var(--text-tertiary); font-weight:700; letter-spacing:1px; margin:16px 0 8px;">TAILSCALE</div>
          <div class="stats-row"><span class="sl">status</span><span class="sv" style="font-size:10px;">${tsBadge}</span></div>
          ${ts.ip ? `<div class="stats-row"><span class="sl">ip</span><span class="sv" style="font-size:10px;">${ts.ip}</span></div>` : ''}
          <div style="font-size:10px; color:var(--text-tertiary); font-weight:700; letter-spacing:1px; margin:16px 0 8px;">ACCESS</div>
          <div class="stats-row"><span class="sl">level</span><span class="sv" style="font-size:10px;">${r.accessLevel || '—'}</span></div>
          <div class="stats-row"><span class="sl">port</span><span class="sv">${r.port || '—'}</span></div>
        `;
      }
    }

    function render() {
      renderSessions();
      renderArchiveBar();
      renderChatHeader();
      renderMessages();
      renderToolbar();
      renderAttachments();
      renderRightPanel();
    }

    // --- Session context menu ---
    function closeCtxMenu() {
      const m = document.getElementById('ctxMenu');
      m.classList.remove('show');
      m.innerHTML = '';
    }
    document.addEventListener('click', (e) => {
      const m = document.getElementById('ctxMenu');
      if (m.classList.contains('show') && !m.contains(e.target)) closeCtxMenu();
    });
    document.addEventListener('keydown', (e) => {
      if (e.key === 'Escape') closeCtxMenu();
    });

    function openSessionMenu(x, y, s) {
      const m = document.getElementById('ctxMenu');
      const pinLabel = s.isPinned ? 'Unpin' : 'Pin';
      const pinIcon = s.isPinned ? '📌' : '📍';
      const archLabel = s.isArchived ? 'Unarchive' : 'Archive';
      const archIcon = s.isArchived ? '📤' : '📦';
      const existingTags = (s.tags || []).map(t =>
        `<div class="ctx-item" data-act="untag" data-tag="${escHTML(t)}"><span class="ctx-icon">✕</span>Remove #${escHTML(t)}</div>`
      ).join('');
      m.innerHTML = `
        <div class="ctx-item" data-act="rename"><span class="ctx-icon">✎</span>Rename</div>
        <div class="ctx-item" data-act="pin"><span class="ctx-icon">${pinIcon}</span>${pinLabel}</div>
        <div class="ctx-item" data-act="duplicate"><span class="ctx-icon">⎘</span>Duplicate (empty)</div>
        <div class="ctx-sep"></div>
        <div class="ctx-item" data-act="group"><span class="ctx-icon">📁</span>Set group…</div>
        <div class="ctx-sub">
          <div class="ctx-item"><span class="ctx-icon">🏷</span>Tags</div>
          <div class="ctx-sub-menu">
            <div class="ctx-item" data-act="tag-add"><span class="ctx-icon">+</span>Add tag…</div>
            ${existingTags ? '<div class="ctx-sep"></div>' + existingTags : ''}
          </div>
        </div>
        <div class="ctx-sep"></div>
        <div class="ctx-item" data-act="copy-continuation"><span class="ctx-icon">📋</span>Copy as continuation</div>
        <div class="ctx-item" data-act="copy-path"><span class="ctx-icon">⌘</span>Copy path</div>
        <div class="ctx-item" data-act="copy-id"><span class="ctx-icon">#</span>Copy session ID</div>
        <div class="ctx-item" data-act="export"><span class="ctx-icon">⤓</span>Export markdown</div>
        <div class="ctx-item" data-act="export-json"><span class="ctx-icon">{ }</span>Export JSON</div>
        <div class="ctx-sep"></div>
        <div class="ctx-item" data-act="clear"><span class="ctx-icon">🧹</span>Clear messages</div>
        <div class="ctx-item" data-act="archive"><span class="ctx-icon">${archIcon}</span>${archLabel}</div>
        <div class="ctx-sep"></div>
        <div class="ctx-item destructive" data-act="delete"><span class="ctx-icon">🗑</span>Delete</div>
      `;
      // Position (keep inside viewport)
      m.style.left = '0px'; m.style.top = '0px';
      m.classList.add('show');
      const rect = m.getBoundingClientRect();
      const px = Math.min(x, window.innerWidth - rect.width - 8);
      const py = Math.min(y, window.innerHeight - rect.height - 8);
      m.style.left = px + 'px';
      m.style.top = py + 'px';

      m.querySelectorAll('[data-act]').forEach(el => {
        el.addEventListener('click', async (ev) => {
          ev.stopPropagation();
          const act = el.dataset.act;
          closeCtxMenu();
          await handleSessionAction(act, s, el.dataset);
        });
      });
    }

    async function handleSessionAction(act, s, data) {
      const id = s.id;
      try {
        switch (act) {
          case 'rename':
            state.renamingId = id;
            renderSessions();
            return;
          case 'pin':
            await api('/api/session/pin', { method: 'POST', body: JSON.stringify({ sessionId: id }) });
            break;
          case 'duplicate':
            await api('/api/session/duplicate', { method: 'POST', body: JSON.stringify({ sessionId: id }) });
            break;
          case 'archive':
            await api('/api/session/archive', { method: 'POST', body: JSON.stringify({ sessionId: id }) });
            break;
          case 'clear':
            if (!confirm('Clear all messages in "' + s.name + '"? This cannot be undone.')) return;
            await api('/api/session/clear', { method: 'POST', body: JSON.stringify({ sessionId: id }) });
            break;
          case 'delete':
            if (!confirm('Delete session "' + s.name + '"?')) return;
            await api('/api/session/delete', { method: 'POST', body: JSON.stringify({ sessionId: id }) });
            break;
          case 'group': {
            const g = prompt('Group name (empty to remove from group):', s.group || '');
            if (g === null) return;
            await api('/api/session/group', { method: 'POST', body: JSON.stringify({ sessionId: id, group: g }) });
            break;
          }
          case 'tag-add': {
            const t = prompt('Add tag (no # prefix):', '');
            if (!t) return;
            await api('/api/session/tag', { method: 'POST', body: JSON.stringify({ sessionId: id, tag: t, op: 'add' }) });
            break;
          }
          case 'untag':
            await api('/api/session/tag', { method: 'POST', body: JSON.stringify({ sessionId: id, tag: data.tag, op: 'remove' }) });
            break;
          case 'copy-continuation': {
            const r = await api('/api/session/continuation?session=' + encodeURIComponent(id));
            await copyToClipboard(r.text || '');
            flash('Continuation prompt copied');
            return;
          }
          case 'copy-path':
            await copyToClipboard(s.workDir || '');
            flash('Path copied');
            return;
          case 'copy-id':
            await copyToClipboard(s.id);
            flash('Session ID copied');
            return;
          case 'export':
            window.location.href = '/api/export?session=' + encodeURIComponent(id) + (token ? '&t=' + encodeURIComponent(token) : '');
            return;
          case 'export-json':
            window.location.href = '/api/export-json?session=' + encodeURIComponent(id) + (token ? '&t=' + encodeURIComponent(token) : '');
            return;
        }
        await refreshAll();
      } catch (e) {
        alert('Action failed: ' + e.message);
      }
    }

    async function copyToClipboard(text) {
      try {
        await navigator.clipboard.writeText(text);
      } catch {
        // Fallback for iOS Safari without clipboard permission.
        const ta = document.createElement('textarea');
        ta.value = text; ta.style.position = 'fixed'; ta.style.opacity = '0';
        document.body.appendChild(ta); ta.select();
        try { document.execCommand('copy'); } catch {}
        document.body.removeChild(ta);
      }
    }

    let flashTimer = null;
    function flash(msg) {
      let el = document.getElementById('flashToast');
      if (!el) {
        el = document.createElement('div');
        el.id = 'flashToast';
        el.style.cssText = 'position:fixed; bottom:20px; left:50%; transform:translateX(-50%); background:var(--surface-elevated); color:var(--text); border:1px solid var(--border); border-radius:8px; padding:8px 16px; font-size:12px; z-index:200; box-shadow:0 4px 12px rgba(0,0,0,0.4); opacity:0; transition:opacity 0.2s;';
        document.body.appendChild(el);
      }
      el.textContent = msg;
      el.style.opacity = '1';
      if (flashTimer) clearTimeout(flashTimer);
      flashTimer = setTimeout(() => { el.style.opacity = '0'; }, 1800);
    }

    // --- Theme / accent sync with the native app ---
    function applyServerAppearance(s) {
      if (!s) return;
      if (s.themeMode) {
        document.documentElement.setAttribute('data-theme', s.themeMode);
      }
      if (s.accentHex) {
        // Accent value arrives without "#" from the settings payload; accept
        // either form. The accent-muted variant derives with a fixed alpha.
        const hex = s.accentHex.startsWith('#') ? s.accentHex : '#' + s.accentHex;
        document.documentElement.style.setProperty('--accent', hex);
        document.documentElement.style.setProperty('--accent-muted', hex + '26'); // ~15%
      }
    }

    // --- Data loading ---
    async function refreshAll() {
      const data = await api('/api/state');
      state.sessions = data.sessions || [];
      state.activeId = data.activeSessionId;
      state.activeSession = state.sessions.find(s => s.id === state.activeId) || null;
      state.messages = data.messages || [];
      state.live = data.live || state.live;
      state.toolbar = data.toolbar || state.toolbar;
      state.usage = data.usage || state.usage;
      state.settings = { ...state.settings, ...(data.settings || {}) };
      state.models = data.models || [];
      applyServerAppearance(state.settings);
      try { state.remote = await api('/api/remote'); } catch {}
      render();
    }

    // Lightweight poll — only touches /api/status + messages
    async function pollLive() {
      try {
        const st = await api('/api/status');
        state.live = {
          isBusy: st.isBusy,
          streamingText: st.streamingText || '',
          thinkingText: st.thinkingText || '',
          activeToolCalls: st.activeToolCalls || [],
          lastError: st.lastError || null,
        };
        state.usage.inputTokens = st.inputTokens;
        state.usage.outputTokens = st.outputTokens;
        state.usage.totalCost = st.totalCost;
        const sid = state.activeId;
        if (sid) {
          const m = await api('/api/messages?session=' + encodeURIComponent(sid));
          const prevCount = state.messages.length;
          state.messages = m.messages || [];
          state.live = m.live || state.live;
          // If count changed or live changed, re-render main view
        }
        renderChatHeader();
        renderMessages();
        renderRightPanel();
      } catch (e) {}
    }

    // --- Composer ---
    async function sendMessage() {
      const ta = document.getElementById('composerInput');
      const text = ta.value.trim();
      if ((!text && !state.attachments.length) || state.live.isBusy) return;
      if (!state.activeId) { alert('No active session.'); return; }
      const attPaths = state.attachments.map(a => a.path);
      ta.value = '';
      state.attachments = [];
      renderAttachments();
      await api('/api/send', { method: 'POST', body: JSON.stringify({ text, sessionId: state.activeId, attachments: attPaths }) });
      setTimeout(pollLive, 200);
    }

    async function handleFiles(files) {
      for (const f of files) {
        // Browser-side files need to be uploaded. For now, we support path-based attach only via drag from native/native upload paths aren't available in browsers.
        // We read the file and send as base64 to /api/attach/upload which writes to tmp.
        const b64 = await new Promise(r => { const fr = new FileReader(); fr.onload = () => r(fr.result.split(',')[1]); fr.readAsDataURL(f); });
        const resp = await api('/api/attach/upload', { method: 'POST', body: JSON.stringify({ name: f.name, base64: b64 }) });
        if (resp && resp.path) {
          state.attachments.push({ path: resp.path, name: f.name });
        }
      }
      renderAttachments();
    }

    // --- Event wiring ---
    document.getElementById('composerInput').addEventListener('keydown', (e) => {
      if (e.key === 'Enter' && !e.shiftKey) { e.preventDefault(); sendMessage(); }
    });
    document.getElementById('sendBtn').onclick = sendMessage;
    document.getElementById('stopBtn').onclick = () => api('/api/interrupt', { method: 'POST' });
    document.getElementById('attachBtn').onclick = () => document.getElementById('fileInput').click();
    document.getElementById('fileInput').addEventListener('change', (e) => handleFiles(e.target.files));
    document.getElementById('retryBtn').onclick = () => api('/api/retry', { method: 'POST' });
    document.getElementById('exportBtn').onclick = () => {
      if (!state.activeId) return;
      window.location.href = '/api/export?session=' + encodeURIComponent(state.activeId) + (token ? '&t=' + encodeURIComponent(token) : '');
    };

    document.querySelectorAll('.sidebar-tab').forEach(b => b.onclick = () => {
      state.sidebarKind = b.dataset.kind;
      document.querySelectorAll('.sidebar-tab').forEach(x => x.classList.toggle('active', x === b));
      renderSessions();
      renderArchiveBar();
    });
    document.getElementById('sessionSearch').addEventListener('input', (e) => {
      state.search = e.target.value;
      renderSessions();
    });
    document.querySelectorAll('.right-tab').forEach(b => b.onclick = () => {
      state.rightTab = b.dataset.tab;
      document.querySelectorAll('.right-tab').forEach(x => x.classList.toggle('active', x === b));
      renderRightPanel();
    });

    // Drag-drop
    const main = document.getElementById('main');
    const overlay = document.getElementById('dropOverlay');
    main.addEventListener('dragover', (e) => { e.preventDefault(); overlay.classList.add('show'); });
    main.addEventListener('dragleave', (e) => { if (e.target === main) overlay.classList.remove('show'); });
    main.addEventListener('drop', (e) => {
      e.preventDefault();
      overlay.classList.remove('show');
      if (e.dataTransfer.files.length) handleFiles(e.dataTransfer.files);
    });
    // Paste images
    document.getElementById('composerInput').addEventListener('paste', (e) => {
      const items = e.clipboardData?.items || [];
      for (const it of items) {
        if (it.kind === 'file') {
          const f = it.getAsFile();
          if (f) handleFiles([f]);
        }
      }
    });

    // New Session modal
    document.getElementById('newSessionBtn').onclick = () => {
      const m = document.getElementById('modalContent');
      const modelsOpts = state.models.map(x => `<option value="${x.id}">${x.label} · ${x.full}</option>`).join('');
      m.innerHTML = `
        <h2>New Session</h2>
        <label>Kind</label>
        <select id="nsKind"><option value="code">⌨ Code</option><option value="chat">💬 Chat</option></select>
        <label>Working Directory</label>
        <input id="nsWorkDir" value="${escHTML(state.settings.defaultWorkDir || '~')}">
        <label>Model</label>
        <select id="nsModel">${modelsOpts}</select>
        <div class="row">
          <button class="btn" onclick="closeModal()">Cancel</button>
          <button class="btn primary" id="nsCreate">Create</button>
        </div>
      `;
      document.getElementById('nsKind').value = state.sidebarKind;
      document.getElementById('nsCreate').onclick = async () => {
        await api('/api/session', { method: 'POST', body: JSON.stringify({
          kind: document.getElementById('nsKind').value,
          workDir: document.getElementById('nsWorkDir').value,
          model: document.getElementById('nsModel').value,
        })});
        closeModal();
        await refreshAll();
      };
      document.getElementById('modalBg').classList.add('show');
    };

    // Settings modal (read-only view for now)
    document.getElementById('settingsBtn').onclick = async () => {
      const settings = await api('/api/settings');
      const r = state.remote || {};
      const m = document.getElementById('modalContent');
      const tq = token ? ('?t=' + encodeURIComponent(token)) : '';
      m.innerHTML = `
        <h2>Settings · Remote</h2>
        <div class="info-box"><span class="lbl">language</span>${escHTML(settings.language)}</div>
        <div class="info-box"><span class="lbl">default workdir</span>${escHTML(settings.defaultWorkDir)}</div>
        <div class="info-box"><span class="lbl">default model</span>${escHTML(settings.defaultModel)}</div>
        <h2 style="margin-top:20px; font-size:13px;">Remote access</h2>
        <div class="info-box"><span class="lbl">access level</span>${escHTML(r.accessLevel || '—')}</div>
        <div class="info-box"><span class="lbl">port</span>${r.port || '—'}</div>
        ${(r.urls && r.urls.tailscale) ? `<div class="info-box"><span class="lbl">tailscale</span>${escHTML(r.urls.tailscale)}</div>` : ''}
        ${(r.urls && r.urls.lan) ? `<div class="info-box"><span class="lbl">lan</span>${escHTML(r.urls.lan)}</div>` : ''}
        <h2 style="margin-top:20px; font-size:13px;">Backup</h2>
        <div class="row" style="gap:6px; flex-wrap:wrap;">
          <a class="btn" href="/api/settings/export${tq}" download>Export settings</a>
          <button class="btn" onclick="pickFileAndUpload('/api/settings/import','Settings imported')">Import settings…</button>
          <button class="btn" onclick="pickFileAndUpload('/api/session/import','Session imported', true)">Import session…</button>
        </div>
        <div class="row" style="margin-top:14px;"><button class="btn primary" onclick="closeModal()">Close</button></div>
      `;
      document.getElementById('modalBg').classList.add('show');
    };

    /// Prompt for a JSON file and POST its raw contents to `url`. If
    /// `refreshAfter` is true, re-pulls state so the new session shows up.
    window.pickFileAndUpload = function(url, okMsg, refreshAfter) {
      const inp = document.createElement('input');
      inp.type = 'file';
      inp.accept = 'application/json,.json';
      inp.onchange = async () => {
        const f = inp.files && inp.files[0];
        if (!f) return;
        try {
          const text = await f.text();
          const tq = token ? ('?t=' + encodeURIComponent(token)) : '';
          const res = await fetch(url + tq, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: text,
          });
          const j = await res.json().catch(() => ({}));
          if (!res.ok || j.error) throw new Error(j.error || ('HTTP ' + res.status));
          flash(okMsg || 'Imported');
          closeModal();
          if (refreshAfter) await refreshAll();
        } catch (e) {
          alert('Import failed: ' + e.message);
        }
      };
      inp.click();
    };
    function closeModal() { document.getElementById('modalBg').classList.remove('show'); }
    document.getElementById('modalBg').addEventListener('click', (e) => { if (e.target.id === 'modalBg') closeModal(); });
    window.closeModal = closeModal;

    // Init
    refreshAll();
    setInterval(pollLive, 1200);
    setInterval(refreshAll, 10000); // re-sync session list less often
    </script>
    </body>
    </html>
    """#
}

// MARK: - HTTP request/response

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]
    let body: Data

    var jsonBody: [String: Any]? {
        guard !body.isEmpty,
              let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return nil }
        return obj
    }

    static func parse(_ data: Data) -> HTTPRequest? {
        // Need at least one \r\n\r\n to have full headers.
        guard let bytes = String(data: data, encoding: .utf8) else { return nil }
        guard let headerEnd = bytes.range(of: "\r\n\r\n") else { return nil }

        let headerSection = String(bytes[..<headerEnd.lowerBound])
        var lines = headerSection.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }

        let requestLine = lines.removeFirst()
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0]).uppercased()
        let target = String(parts[1])

        let (path, query) = parseTarget(target)

        var headers: [String: String] = [:]
        for line in lines {
            if let sep = line.firstIndex(of: ":") {
                let k = line[..<sep].trimmingCharacters(in: .whitespaces).lowercased()
                let v = line[line.index(after: sep)...].trimmingCharacters(in: .whitespaces)
                headers[k] = v
            }
        }

        // Body size from Content-Length
        let contentLength = Int(headers["content-length"] ?? "") ?? 0
        let bodyStart = data.index(data.startIndex, offsetBy: headerEnd.upperBound.utf16Offset(in: bytes))
        let available = data.distance(from: bodyStart, to: data.endIndex)
        guard available >= contentLength else { return nil } // wait for more
        let body = contentLength > 0 ? data.subdata(in: bodyStart ..< data.index(bodyStart, offsetBy: contentLength)) : Data()

        return HTTPRequest(method: method, path: path, query: query, headers: headers, body: body)
    }

    private static func parseTarget(_ target: String) -> (String, [String: String]) {
        guard let q = target.firstIndex(of: "?") else { return (target, [:]) }
        let path = String(target[..<q])
        let qs = String(target[target.index(after: q)...])
        var dict: [String: String] = [:]
        for pair in qs.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 {
                dict[kv[0].removingPercentEncoding ?? kv[0]] = kv[1].removingPercentEncoding ?? kv[1]
            } else if kv.count == 1 {
                dict[kv[0]] = ""
            }
        }
        return (path, dict)
    }
}

struct HTTPResponse {
    var status: Int = 200
    var headers: [String: String] = ["Content-Type": "text/plain; charset=utf-8"]
    var body: Data = Data()

    static func text(_ s: String, status: Int = 200) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(s.utf8))
    }

    static func html(_ s: String, status: Int = 200) -> HTTPResponse {
        // Page is embedded in the binary; any change ships as a new build, so
        // tell the browser never to reuse a stale copy. Without this, Safari
        // and Chrome will happily serve yesterday's UI for hours.
        HTTPResponse(status: status, headers: [
            "Content-Type": "text/html; charset=utf-8",
            "Cache-Control": "no-store, no-cache, must-revalidate, max-age=0",
            "Pragma": "no-cache",
        ], body: Data(s.utf8))
    }

    static func json(_ obj: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.fragmentsAllowed])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: [
            "Content-Type": "application/json; charset=utf-8",
            "Access-Control-Allow-Origin": "*",
        ], body: data)
    }

    static var notFound: HTTPResponse { .text("not found", status: 404) }

    func serialize() -> Data {
        var out = "HTTP/1.1 \(status) \(statusPhrase(status))\r\n"
        var hs = headers
        hs["Content-Length"] = String(body.count)
        hs["Connection"] = "close"
        for (k, v) in hs { out += "\(k): \(v)\r\n" }
        out += "\r\n"
        var data = Data(out.utf8)
        data.append(body)
        return data
    }

    private func statusPhrase(_ code: Int) -> String {
        switch code {
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 500: "Internal Server Error"
        default: "OK"
        }
    }
}
