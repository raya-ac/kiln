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
///
/// Defaults point at the project-owned warden deployment (tunnel.cute.pm
/// over wss). Credential stays unset — user drops a bearer token or PSK
/// path in Settings once and the tunnel is live. Everything else is baked.
struct WardenConfig: Codable, Equatable, Sendable {
    /// Tunnel server hostname, e.g. "tunnel.example.com".
    var server: String = "tunnel.cute.pm"
    /// Public domain that subdomains are carved out of, e.g. "example.com".
    /// Only used for URL display — the server decides the actual hostname.
    var domain: String = "cute.pm"
    /// "ws" or "wss". Defaults to wss.
    var scheme: String = "wss"
    /// Path to a file containing the shared PSK (hex or raw). Resolved at
    /// tunnel-start time, not when the config is saved.
    var pskPath: String = ""
    /// Optional pre-formatted bearer token (`tok_…`). If set, takes
    /// precedence over `pskPath`.
    var bearerToken: String = ""
    /// Subdomain the current token was issued for. The token only lets
    /// us register this sub — the server rejects any other. Populated by
    /// `claimIfNeeded()` and used by the self-tunnel start path.
    var claimedSub: String = ""
    /// Allow self-signed TLS (local dev).
    var insecure: Bool = false

    var isConfigured: Bool {
        !server.isEmpty && (!pskPath.isEmpty || !bearerToken.isEmpty)
    }

    // Manual decoder so each field falls back to its default if the saved
    // JSON predates it. Synthesized Codable would throw keyNotFound on
    // missing keys, which silently collapses the whole config back to
    // defaults — blowing away the user's token.
    private enum CodingKeys: String, CodingKey {
        case server, domain, scheme, pskPath, bearerToken, claimedSub, insecure
    }
    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.server      = (try? c.decode(String.self, forKey: .server))      ?? "tunnel.cute.pm"
        self.domain      = (try? c.decode(String.self, forKey: .domain))      ?? "cute.pm"
        self.scheme      = (try? c.decode(String.self, forKey: .scheme))      ?? "wss"
        self.pskPath     = (try? c.decode(String.self, forKey: .pskPath))     ?? ""
        self.bearerToken = (try? c.decode(String.self, forKey: .bearerToken)) ?? ""
        self.claimedSub  = (try? c.decode(String.self, forKey: .claimedSub))  ?? ""
        self.insecure    = (try? c.decode(Bool.self,   forKey: .insecure))    ?? false
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

    /// Claim state surfaced to Settings so the UI can show progress while
    /// Kiln is fetching its bearer token from the tunnel server.
    @Published private(set) var claimInFlight: Bool = false
    @Published private(set) var claimError: String?

    init() {
        self.config = Self.loadConfig()
        // Persist the migrated config so backfilled fields (claimedSub,
        // baked-in defaults) survive future launches. Cheap — UserDefaults
        // write is synchronous but tiny.
        saveConfig()
        // Zero-config first launch: if the user hasn't configured a PSK or
        // bearer token, grab one from the baked-in tunnel server's public
        // /claim endpoint. The token is app-served — no filesystem PSK.
        if config.bearerToken.isEmpty && config.pskPath.isEmpty && !config.server.isEmpty {
            Task { [weak self] in await self?.claimIfNeeded() }
        }
    }

    // MARK: - Config persistence

    private static let configKey = "warden.config"

    static func loadConfig() -> WardenConfig {
        guard let data = UserDefaults.standard.data(forKey: configKey),
              var cfg = try? JSONDecoder().decode(WardenConfig.self, from: data)
        else { return WardenConfig() }
        // Migrate older saves from before auto-claim: fill in baked
        // defaults for any empty field, drop the now-obsolete pskPath
        // default that pointed at the warden CLI's location, and flip
        // insecure off (previous UI let users leave it on by accident).
        let fresh = WardenConfig()
        if cfg.server.isEmpty { cfg.server = fresh.server }
        if cfg.domain.isEmpty { cfg.domain = fresh.domain }
        if cfg.scheme.isEmpty || cfg.scheme == "ws" { cfg.scheme = fresh.scheme }
        if cfg.pskPath == "~/.config/warden/psk" { cfg.pskPath = "" }
        // Backfill claimedSub for tokens issued before we persisted it.
        // Token format is `tok_<sub>_<hex>`; splitting on "_" yields
        // ["tok", sub, hex], so the middle segment is the sub. This
        // matches how warden-tunnel-server builds the token.
        if cfg.claimedSub.isEmpty && cfg.bearerToken.hasPrefix("tok_") {
            let parts = cfg.bearerToken.split(separator: "_")
            if parts.count >= 3 { cfg.claimedSub = String(parts[1]) }
        }
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

    // MARK: - Token claim (app-served PSK)

    /// Hit the tunnel server's public `/claim` endpoint and stash the
    /// returned bearer token. Idempotent: returns immediately if a token
    /// is already configured or a claim is already in flight. Each Kiln
    /// install ends up with its own 7-day token, re-claimed on expiry.
    ///
    /// The server is resolved from `config.server`; if the response
    /// carries a `server` field we trust it (lets the server bounce
    /// callers to a different host). `sub` defaults to a random hex
    /// label so installs don't collide.
    func claimIfNeeded(sub: String? = nil) async {
        guard !claimInFlight else { return }
        guard config.bearerToken.isEmpty else { return }
        guard !config.server.isEmpty else {
            claimError = "no tunnel server configured"
            return
        }

        claimInFlight = true
        claimError = nil
        defer { claimInFlight = false }

        let wantedSub = (sub?.isEmpty == false ? sub! : TunnelSub.random(8))
        let scheme = config.scheme.isEmpty ? "https" : (config.scheme == "ws" ? "http" : "https")
        guard let url = URL(string: "\(scheme)://\(config.server)/claim") else {
            claimError = "invalid claim URL"
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = "sub=\(wantedSub)".data(using: .utf8)
        req.timeoutInterval = 15

        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let http = resp as? HTTPURLResponse
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if (http?.statusCode ?? 500) >= 400 {
                claimError = "claim: \(obj["error"] as? String ?? "HTTP \(http?.statusCode ?? 0)")"
                return
            }
            guard let token = obj["token"] as? String, !token.isEmpty else {
                claimError = "claim: server returned no token"
                return
            }
            // Server may rewrite sub (e.g. reserved names) or advertise a
            // different edge host — prefer whatever it sent us. Persist
            // the sub too: tokens only authorize the sub they were issued
            // for, so the tunnel-start path has to replay it exactly.
            config.bearerToken = token
            if let s = obj["server"] as? String, !s.isEmpty { config.server = s }
            if let s = obj["sub"] as? String, !s.isEmpty {
                config.claimedSub = s
            } else {
                config.claimedSub = wantedSub
            }
            saveConfig()
        } catch {
            claimError = "claim: \(error.localizedDescription)"
        }
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
