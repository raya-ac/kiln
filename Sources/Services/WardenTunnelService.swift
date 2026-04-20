import Foundation
import SwiftUI
import Security

/// Identity of a single tunnel. Kiln always has at most one "self" tunnel
/// (exposing the remote server); project tunnels are keyed by session ID
/// so they follow the session around.
enum TunnelOwner: Hashable, Sendable {
    case kilnSelf                 // the remote-control server itself
    case session(String)          // a user session's dev server, keyed by session id

    var key: String {
        switch self {
        case .kilnSelf: return "self"
        case .session(let id): return "session:\(id)"
        }
    }
}

enum TunnelStatus: Sendable, Equatable {
    case idle
    case connecting
    case ready(url: String)
    case failed(String)
}

/// One managed tunnel's live state. Keeps a rolling log of the last ~100
/// request/error events so the Settings UI can show recent activity.
struct TunnelState: Identifiable, Sendable, Equatable {
    let id: String            // TunnelOwner.key
    var owner: TunnelOwner
    var sub: String
    var target: String
    var status: TunnelStatus
    var publicURL: String?
    var lastError: String?
    var requestCount: Int = 0
    var recent: [TunnelLogEntry] = []
}

struct TunnelLogEntry: Identifiable, Sendable, Equatable {
    let id: UUID = UUID()
    let at: Date
    let line: String
}

/// User-configured warden tunnel infrastructure. Persisted to UserDefaults.
/// Matches the fields of `~/.config/warden/config.toml` so the Go CLI and
/// Kiln can share one setup.
struct WardenConfig: Codable, Equatable, Sendable {
    /// Tunnel server hostname, e.g. "tunnel.example.com".
    var server: String = ""
    /// Public domain that subdomains are carved out of, e.g. "example.com".
    /// Only used for URL display — the server decides the actual hostname.
    var domain: String = ""
    /// "ws" or "wss". Defaults to wss.
    var scheme: String = "wss"
    /// Path to a file containing the shared PSK (hex or raw). Resolved at
    /// tunnel-start time, not when the config is saved.
    var pskPath: String = ""
    /// Optional pre-formatted bearer token (`tok_…`). If set, takes
    /// precedence over `pskPath`.
    var bearerToken: String = ""
    /// Allow self-signed TLS (local dev).
    var insecure: Bool = false

    var isConfigured: Bool {
        !server.isEmpty && (!pskPath.isEmpty || !bearerToken.isEmpty)
    }
}

/// Manages in-app warden tunnels. The tunnel client (`TunnelClient`) runs
/// as a Swift actor; this service is the main-actor face that SwiftUI
/// binds to. Multiple tunnels can run concurrently — one for Kiln's own
/// remote server, plus one per session for user dev servers.
@MainActor
final class WardenTunnelService: ObservableObject {
    @Published var config: WardenConfig
    @Published private(set) var tunnels: [String: TunnelState] = [:]

    /// Per-owner currently-running clients. Cancelled on stop().
    private var clients: [String: TunnelClient] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    /// Keys the user currently wants running. Start() adds, stop() removes.
    /// Distinguishes "server dropped us" (reconnect) from "user hit stop"
    /// (stay down) when a close event lands.
    private var wantsRunning: Set<String> = []

    /// Last-known start params per key, so we can reconnect with the same
    /// owner/target/sub after an unexpected disconnect.
    private struct StartParams {
        let owner: TunnelOwner
        let target: String
        let sub: String
    }
    private var lastParams: [String: StartParams] = [:]

    /// Exponential-backoff state per key. Resets to 1s on successful
    /// `.ready`. Cap at 30s.
    private var backoffSeconds: [String: Double] = [:]
    private var reconnectTasks: [String: Task<Void, Never>] = [:]

    init() {
        self.config = Self.loadConfig()
    }

    // MARK: - Config persistence

    private static let configKey = "warden.config"

    static func loadConfig() -> WardenConfig {
        guard let data = UserDefaults.standard.data(forKey: configKey),
              let cfg = try? JSONDecoder().decode(WardenConfig.self, from: data)
        else { return WardenConfig() }
        return cfg
    }

    func saveConfig() {
        if let data = try? JSONEncoder().encode(config) {
            UserDefaults.standard.set(data, forKey: Self.configKey)
        }
    }

    // MARK: - Lifecycle

    /// Start a tunnel for `owner` pointing at `target` (host:port). If a
    /// tunnel with the same owner is already running, it's stopped first.
    /// `sub` defaults to a random 8-char hex label; pass a stable value
    /// for predictable URLs.
    func start(owner: TunnelOwner, target: String, sub: String? = nil) {
        guard config.isConfigured else {
            let key = owner.key
            var s = tunnels[key] ?? TunnelState(id: key, owner: owner, sub: sub ?? "", target: target, status: .idle)
            s.status = .failed("warden not configured — set server + psk in Settings")
            s.lastError = s.status == .failed("") ? nil : "warden not configured — set server + psk in Settings"
            tunnels[key] = s
            return
        }

        let finalSub = (sub?.isEmpty == false ? sub! : TunnelSub.random(8))
        let key = owner.key

        // Stop any prior tunnel for this owner (cancels old reconnect too).
        stop(owner: owner)

        // Record intent + params so a transient disconnect can auto-retry
        // without the user re-flipping the toggle.
        wantsRunning.insert(key)
        lastParams[key] = StartParams(owner: owner, target: target, sub: finalSub)

        var state = TunnelState(
            id: key,
            owner: owner,
            sub: finalSub,
            target: target,
            status: .connecting
        )
        tunnels[key] = state

        // Load credential.
        var psk: Data? = nil
        var bearer: String? = nil
        if !config.bearerToken.isEmpty {
            bearer = config.bearerToken
        } else {
            do {
                psk = try Self.loadPSKFile(path: config.pskPath)
            } catch {
                state.status = .failed("psk: \(error.localizedDescription)")
                state.lastError = error.localizedDescription
                tunnels[key] = state
                return
            }
        }

        let tcfg = TunnelConfig(
            server: config.server,
            scheme: config.scheme.isEmpty ? "wss" : config.scheme,
            sub: finalSub,
            target: target,
            psk: psk,
            bearerToken: bearer,
            insecure: config.insecure
        )

        let client = TunnelClient()
        clients[key] = client

        let task = Task { [weak self] in
            await client.start(tcfg) { event in
                self?.apply(event: event, ownerKey: key)
            }
        }
        tasks[key] = task
    }

    /// Stop the tunnel (if any) for this owner.
    func stop(owner: TunnelOwner) {
        let key = owner.key
        wantsRunning.remove(key)
        reconnectTasks.removeValue(forKey: key)?.cancel()
        backoffSeconds.removeValue(forKey: key)
        lastParams.removeValue(forKey: key)
        if let client = clients.removeValue(forKey: key) {
            Task { await client.stop() }
        }
        tasks.removeValue(forKey: key)?.cancel()
        if var s = tunnels[key] {
            s.status = .idle
            s.publicURL = nil
            tunnels[key] = s
        }
    }

    /// True if the user currently wants this owner's tunnel running. Used by
    /// Settings to decide whether a config edit should trigger a live restart.
    func isActive(owner: TunnelOwner) -> Bool {
        wantsRunning.contains(owner.key)
    }

    /// Stop all tunnels — invoked on quit / logout.
    func stopAll() {
        for key in Array(clients.keys) {
            stop(owner: keyOwner(key))
        }
    }

    // MARK: - Event wiring

    private func apply(event: TunnelEvent, ownerKey: String) {
        guard var s = tunnels[ownerKey] else { return }
        switch event {
        case .connecting:
            s.status = .connecting
        case .ready(let url):
            s.status = .ready(url: url)
            s.publicURL = url
            s.lastError = nil
            s.recent.append(.init(at: Date(), line: "ready → \(url)"))
            // Successful connect resets the backoff timer for this owner.
            backoffSeconds[ownerKey] = nil
        case .request(let method, let path, let status, let durMs):
            s.requestCount += 1
            s.recent.append(.init(at: Date(), line: "\(method) \(path) → \(status) (\(durMs)ms)"))
        case .error(let msg):
            s.lastError = msg
            s.recent.append(.init(at: Date(), line: "error: \(msg)"))
        case .closed(let reason):
            s.status = .idle
            if let r = reason { s.recent.append(.init(at: Date(), line: "closed: \(r)")) }
            // Cap the log before the early return below.
            if s.recent.count > 100 { s.recent.removeFirst(s.recent.count - 100) }
            tunnels[ownerKey] = s
            // Auto-reconnect: if the user still wants this tunnel up and
            // we have the last params, schedule a retry with backoff.
            scheduleReconnectIfNeeded(ownerKey: ownerKey)
            return
        }
        // Cap the log.
        if s.recent.count > 100 {
            s.recent.removeFirst(s.recent.count - 100)
        }
        tunnels[ownerKey] = s
    }

    /// Kick off a delayed reconnect if the user hasn't stopped this tunnel.
    /// Backoff doubles on each consecutive failure; capped at 30s.
    /// A successful `.ready` resets the timer (see apply()).
    private func scheduleReconnectIfNeeded(ownerKey: String) {
        guard wantsRunning.contains(ownerKey),
              let params = lastParams[ownerKey]
        else { return }

        // Cancel any lingering task for this owner.
        reconnectTasks.removeValue(forKey: ownerKey)?.cancel()

        let prev = backoffSeconds[ownerKey] ?? 0.5
        let next = min(prev * 2, 30.0)
        backoffSeconds[ownerKey] = next

        // Surface the pending retry in the activity log so the user sees
        // why the tunnel is bouncing.
        if var s = tunnels[ownerKey] {
            s.recent.append(.init(at: Date(), line: String(format: "reconnecting in %.1fs", next)))
            if s.recent.count > 100 { s.recent.removeFirst(s.recent.count - 100) }
            tunnels[ownerKey] = s
        }

        let task = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(next * 1_000_000_000))
            guard let self = self else { return }
            // Guard again — user may have stopped during the sleep.
            guard self.wantsRunning.contains(ownerKey) else { return }
            self.start(owner: params.owner, target: params.target, sub: params.sub)
        }
        reconnectTasks[ownerKey] = task
    }

    private func keyOwner(_ key: String) -> TunnelOwner {
        if key == "self" { return .kilnSelf }
        if key.hasPrefix("session:") {
            return .session(String(key.dropFirst("session:".count)))
        }
        return .kilnSelf
    }

    // MARK: - Credential helpers

    enum PSKLoadError: LocalizedError {
        case missingPath
        case readFailed(String)
        case empty

        var errorDescription: String? {
            switch self {
            case .missingPath: return "no psk file configured"
            case .readFailed(let why): return "couldn't read psk file: \(why)"
            case .empty: return "psk file is empty"
            }
        }
    }

    /// Reads a PSK from a file path. Accepts hex / base64 / raw — same
    /// fallback order as warden-tunnel's Go loader. Tilde is expanded.
    static func loadPSKFile(path rawPath: String) throws -> Data {
        guard !rawPath.isEmpty else { throw PSKLoadError.missingPath }
        var path = rawPath
        if path.hasPrefix("~/") {
            path = NSHomeDirectory() + "/" + path.dropFirst(2)
        }
        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw PSKLoadError.readFailed(error.localizedDescription)
        }
        guard let text = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { throw PSKLoadError.empty }
        // hex?
        if let hex = Data(hexString: text), hex.count >= 16 {
            return hex
        }
        // base64?
        if let b64 = Data(base64Encoded: text), b64.count >= 16 {
            return b64
        }
        // raw fallback
        return Data(text.utf8)
    }
}

// MARK: - Hex decoding helper

private extension Data {
    init?(hexString: String) {
        let s = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        let len = s.count
        guard len % 2 == 0 else { return nil }
        var out = Data(capacity: len / 2)
        var idx = s.startIndex
        while idx < s.endIndex {
            let next = s.index(idx, offsetBy: 2)
            guard let byte = UInt8(s[idx..<next], radix: 16) else { return nil }
            out.append(byte)
            idx = next
        }
        self = out
    }
}
