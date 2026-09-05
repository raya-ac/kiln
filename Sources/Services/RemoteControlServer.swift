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
        if let file = response.file {
            guard let transfer = try? HTTPFileTransfer(body: file, connection: conn) else {
                send(.notFound, on: conn)
                return
            }
            conn.send(content: response.serialize(), completion: .contentProcessed { error in
                if error != nil { conn.cancel() } else { transfer.sendNext() }
            })
            return
        }
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

        case ("GET", "/api/link-preview"):
            guard let sid = req.query["session"], let mediaID = req.query["id"],
                  let session = store.sessions.first(where: { $0.id == sid }),
                  let reference = session.messages.lazy.flatMap({ message in
                      message.blocks.flatMap { block -> [MediaReference] in
                          if case .text(let text) = block { return MediaMarkdown.references(text) }
                          return []
                      }
                  }).first(where: { $0.id == mediaID && $0.kind == .link }),
                  let link = RichLink.make(reference.source) else { return .notFound }
            let metadata = await LinkMetadataService.shared.metadata(for: link, refresh: req.query["refresh"] == "1")
            var payload: [String: Any] = ["title": metadata.title, "author": metadata.author,
                "unavailable": metadata.unavailable, "provider": link.provider.rawValue, "height": link.height]
            payload["thumbnail"] = metadata.thumbnail
            payload["embedURL"] = link.embedURL?.absoluteString
            if let post = metadata.post { payload["post"] = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(post)) }
            return .json(payload)

        case ("GET", "/api/media"), ("HEAD", "/api/media"):
            guard let sid = req.query["session"], let mediaID = req.query["id"],
                  let session = store.sessions.first(where: { $0.id == sid }) else { return .notFound }
            let media = session.messages.flatMap { message in
                message.blocks.flatMap { block -> [MediaReference] in
                    if case .text(let text) = block { return MediaMarkdown.references(text) }
                    if case .attachment(let file) = block {
                        return MediaReference.make(source: file.path, label: file.name).map { [$0] } ?? []
                    }
                    return []
                }
            }
            guard let reference = media.first(where: { $0.id == mediaID }),
                  let file = reference.permittedURL(workDir: session.workDir), file.isFileURL else { return .notFound }
            return (try? MediaHTTP.response(file: file, rangeHeader: req.headers["range"],
                download: req.query["download"] == "1", head: req.method == "HEAD")) ?? .notFound

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
                "autoCompactEnabled": store.settings.autoCompactEnabled,
                "sendKey": store.settings.sendKey.rawValue,
                "userDisplayName": store.settings.userDisplayName,
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

        case ("POST", "/api/session/new-here"):
            // Fresh session pointed at the same workdir as an existing one.
            // Mirrors the native "New session here" context-menu action.
            guard let body = req.jsonBody,
                  let sid = body["sessionId"] as? String,
                  let src = store.sessions.first(where: { $0.id == sid })
            else { return .json(["error": "missing sessionId"], status: 400) }
            store.createSession(workDir: src.workDir, model: src.model, kind: src.kind)
            return .json([
                "status": "created",
                "sessionId": store.activeSessionId as Any,
            ])

        case ("GET", "/api/remote"):
            return .json(remoteInfoJSON())

        case ("POST", "/api/send"):
            guard let body = req.jsonBody,
                  let text = body["text"] as? String
            else { return .json(["error": "missing text"], status: 400) }
            if let sid = body["sessionId"] as? String, sid != store.activeSessionId {
                guard store.sessions.contains(where: { $0.id == sid }) else { return .json(["error": "Session not found"], status: 404) }
                store.activeSessionId = sid
            }
            guard store.activeSession != nil else {
                return .json(["error": "no active session"], status: 400)
            }
            let paths = (body["attachments"] as? [String]) ?? []
            let attachments: [ComposerAttachment]
            do { attachments = try paths.map { try AttachmentImporter.file(URL(fileURLWithPath: $0)) } }
            catch { return .json(["error": "An attachment is unavailable."], status: 400) }
            let draft = store.drafts.draft(for: store.activeSessionId)
            if !draft.isEmpty && draft != ComposerDraft(text: text, attachments: attachments) {
                return .json(["error": "There is an unsent draft in the native client. Send or clear it first."], status: 409)
            }
            guard store.queueSend(text, attachments: attachments) else {
                return .json(["error": "Message could not be queued. Your draft has been kept."], status: 409)
            }
            return .json(["status": "queued"])

        case ("POST", "/api/models/refresh"):
            await store.refreshModelCatalog()
            return .json(Self.fullState(store: store))

        case ("POST", "/api/settings/chat"):
            guard let body = req.jsonBody else { return .json(["error": "Invalid settings"], status: 400) }
            if let enabled = body["autoCompactEnabled"] as? Bool { store.settings.autoCompactEnabled = enabled }
            store.saveSettings()
            return .json(["autoCompactEnabled": store.settings.autoCompactEnabled])

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
            let model = (body["model"] as? String).flatMap { AgentModel(rawValue: $0) }
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
                  let m = AgentModel(rawValue: name)
            else { return .json(["error": "invalid model"], status: 400) }
            if let sid = body["sessionId"] as? String, sid != store.activeSessionId {
                return .json(["error": "Conversation changed. Refresh and try again."], status: 409)
            }
            guard !store.isBusy else { return .json(["error": "Wait for the current response."], status: 409) }
            store.setModel(m)
            return .json(["status": "ok"])

        case ("POST", "/api/attach/upload"):
            guard let body = req.jsonBody,
                  let name = body["name"] as? String,
                  let b64 = body["base64"] as? String,
                  let data = Data(base64Encoded: b64)
            else { return .json(["error": "bad payload"], status: 400) }
            guard data.count <= 32 * 1024 * 1024 else { return .json(["error": "File exceeds 32 MB"], status: 413) }
            let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".kiln/attachments")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let safe = name.replacingOccurrences(of: "/", with: "_")
            let file = dir.appendingPathComponent("\(UUID().uuidString)-\(safe)")
            do {
                try data.write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                return .json(["status": "ok", "path": file.path, "name": safe])
            } catch {
                return .json(["error": "write failed: \(error.localizedDescription)"], status: 500)
            }

        case ("POST", "/api/toolbar"):
            let body = req.jsonBody ?? [:]
            if let sid = body["sessionId"] as? String, sid != store.activeSessionId {
                return .json(["error": "Conversation changed. Refresh and try again."], status: 409)
            }
            guard !store.isBusy else { return .json(["error": "Wait for the current response."], status: 409) }
            if let fast = body["openAIFastMode"] as? Bool { store.setOpenAIFastMode(fast) }
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
                "autoCompactEnabled": store.settings.autoCompactEnabled,
                "sendKey": store.settings.sendKey.rawValue,
                "userDisplayName": store.settings.userDisplayName,
            ],
            "models": AgentModel.allCases.map { ["id": $0.rawValue, "label": $0.label, "full": $0.fullId, "contextWindow": $0.contextWindow, "extended": $0.extendedContextWindow ?? 0, "efforts": $0.reasoningEfforts, "provider": $0.provider.rawValue, "older": AgentModel.olderModels.contains($0), "supportsFast": $0.supportsOpenAIFastMode, "brand": $0.brand == .chatgpt ? "openai" : "terminal"] as [String: Any] },
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
            "openAIFastMode": store.activeSession?.openAIFastMode ?? false,
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
            "readOnly": s.readOnly,
            "openAIFastMode": s.openAIFastMode,
        ]
    }

    private static func messageJSON(_ m: ChatMessage) -> [String: Any] {
        [
            "id": m.id,
            "role": m.role.rawValue,
            "timestamp": m.timestamp.timeIntervalSince1970,
            "model": m.model?.rawValue as Any,
            "assistantName": m.assistantName,
            "blocks": m.blocks.map(blockJSON),
        ]
    }

    private static func blockJSON(_ b: MessageBlock) -> [String: Any] {
        switch b {
        case .text(let s): return ["type": "text", "text": s, "media": MediaMarkdown.references(s).map(mediaJSON)]
        case .thinking(let s): return ["type": "thinking", "text": s]
        case .trace(let entries):
            return ["type": "trace", "entries": entries.map { entry in
                [
                    "id": entry.id,
                    "timestamp": entry.timestamp.timeIntervalSince1970,
                    "source": entry.source,
                    "level": entry.level.rawValue,
                    "phase": entry.phase,
                    "title": entry.title,
                    "detail": entry.detail,
                    "metadata": entry.metadata,
                ] as [String: Any]
            }]
        case .toolUse(let t): return ["type": "toolUse", "tool": toolUseJSON(t)]
        case .toolResult(let r): return ["type": "toolResult", "toolUseId": r.toolUseId, "content": r.content, "isError": r.isError]
        case .suggestions(let s):
            return ["type": "suggestions", "prompts": s.map { ["id": $0.id, "label": $0.label, "prompt": $0.prompt, "icon": $0.icon] }]
        case .attachment(let a):
            return ["type": "attachment", "name": a.name, "path": a.path,
                    "media": MediaReference.make(source: a.path, label: a.name).map { [mediaJSON($0)] } ?? []]
        }
    }

    private static func mediaJSON(_ media: MediaReference) -> [String: Any] {
        var data: [String: Any] = ["id": media.id, "source": media.source, "label": media.label, "kind": media.kind.rawValue]
        if let link = RichLink.make(media.source) { data["provider"] = link.provider.rawValue }
        return data
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
                        let ip = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
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

    static var indexHTML: String { RemoteWebAssets.page }

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
    var file: HTTPFileBody?

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
        if hs["Content-Length"] == nil { hs["Content-Length"] = String(file?.range.count ?? UInt64(body.count)) }
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
        case 206: "Partial Content"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 409: "Conflict"
        case 413: "Payload Too Large"
        case 416: "Range Not Satisfiable"
        case 500: "Internal Server Error"
        default: "OK"
        }
    }
}
