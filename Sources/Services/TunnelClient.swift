import Foundation

// Swift port of warden's tunnel agent protocol. Single WebSocket, JSON
// frames, base64 bodies. Enough to run a warden-tunnel-server from inside
// Kiln without shelling out to the Go binary.
//
// Wire protocol (mirrors /Users/ari/projects/warden/internal/tunnel/proto.go):
//
//   agent  → server: {type:"register",   sub}
//   server → agent:  {type:"registered", url}    — or {type:"error", message}
//   server → agent:  {type:"req",   reqId, method, path, headers, body?}
//   agent  → server: {type:"head",  reqId, status, headers}
//   agent  → server: {type:"body",  reqId, body}   — repeats for streamed body
//   agent  → server: {type:"end",   reqId}
//   either → either: {type:"err",   reqId, message}

// MARK: - Wire frame

/// A single JSON frame on the WebSocket. Only the fields relevant to
/// `type` are populated; the rest are omitted. `body` carries base64 of
/// either the full inbound request body or one chunk of the streaming
/// response, depending on direction.
struct TunnelFrame: Codable {
    var type: String
    var sub: String?
    var url: String?
    var message: String?

    var reqId: String?
    var method: String?
    var path: String?
    var status: Int?
    var headers: [String: [String]]?
    var body: String?

    enum CodingKeys: String, CodingKey {
        case type, sub, url, message
        case reqId = "reqId"
        case method, path, status, headers, body
    }
}

// MARK: - Config

struct TunnelConfig: Sendable {
    /// Tunnel server hostname, e.g. "tunnel.example.com". No scheme.
    var server: String
    /// "ws" or "wss". Default wss.
    var scheme: String = "wss"
    /// Requested subdomain. Server may reject if already registered.
    var sub: String
    /// Local `host:port` to reverse-proxy to, e.g. "127.0.0.1:8421".
    var target: String
    /// Raw PSK bytes; the agent sends `Authorization: Bearer hex(psk)`.
    /// Mutually exclusive with `bearerToken`.
    var psk: Data?
    /// Pre-formatted bearer string (e.g. "tok_myapp_abc…"). Sent verbatim.
    /// Mutually exclusive with `psk`.
    var bearerToken: String?
    /// Allow self-signed TLS (dev only).
    var insecure: Bool = false
}

// MARK: - Events

/// Emitted as the tunnel progresses. Delivered on the main actor.
enum TunnelEvent: Sendable {
    case connecting
    case ready(url: String)
    case request(method: String, path: String, status: Int, durationMs: Int)
    case error(String)
    case closed(reason: String?)
}

// MARK: - Client

/// Runs a single tunnel to completion. Call `start()` once; `stop()` to
/// cancel. All `onEvent` callbacks land on the MainActor.
///
/// Swift's `URLSessionWebSocketTask` gives us text-frame JSON natively;
/// we serialize writes behind an actor.
actor TunnelClient {
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var onEvent: (@Sendable @MainActor (TunnelEvent) -> Void)?
    private var config: TunnelConfig?
    private var running = false

    func start(_ config: TunnelConfig, onEvent: @escaping @Sendable @MainActor (TunnelEvent) -> Void) async {
        self.config = config
        self.onEvent = onEvent
        self.running = true

        await emit(.connecting)

        let scheme = config.scheme.isEmpty ? "wss" : config.scheme
        guard let url = URL(string: "\(scheme)://\(config.server)/ws") else {
            await emit(.error("invalid server URL: \(scheme)://\(config.server)/ws"))
            await emit(.closed(reason: "invalid url"))
            return
        }

        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        if let token = config.bearerToken, !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else if let psk = config.psk, !psk.isEmpty {
            let hex = psk.map { String(format: "%02x", $0) }.joined()
            req.setValue("Bearer \(hex)", forHTTPHeaderField: "Authorization")
        } else {
            await emit(.error("tunnel: missing psk/token"))
            await emit(.closed(reason: "no credential"))
            return
        }

        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        let delegate = config.insecure ? TunnelInsecureDelegate() : nil
        let session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
        self.session = session

        let task = session.webSocketTask(with: req)
        self.task = task
        task.resume()

        // Register.
        let reg = TunnelFrame(type: "register", sub: config.sub)
        do {
            try await send(reg)
        } catch {
            await emit(.error("register write: \(error.localizedDescription)"))
            await close(reason: "register failed")
            return
        }

        // Await registration reply.
        do {
            let reply = try await receiveFrame()
            switch reply.type {
            case "registered":
                await emit(.ready(url: reply.url ?? ""))
            case "error":
                await emit(.error("server: \(reply.message ?? "unknown")"))
                await close(reason: reply.message)
                return
            default:
                await emit(.error("unexpected reply: \(reply.type)"))
                await close(reason: "unexpected reply")
                return
            }
        } catch {
            await emit(.error("register reply: \(error.localizedDescription)"))
            await close(reason: "register reply failed")
            return
        }

        // Read loop. Any fatal error closes the tunnel.
        while running {
            let frame: TunnelFrame
            do {
                frame = try await receiveFrame()
            } catch {
                if running {
                    await emit(.error("ws read: \(error.localizedDescription)"))
                }
                break
            }
            if frame.type == "req" {
                // Spawn per-request proxy task so slow upstreams don't
                // block the read loop.
                Task.detached { [weak self] in
                    await self?.handleRequest(frame)
                }
            }
            // Other control frames (err, etc.) are ignored on the agent
            // side for now — server-side errors at register time were
            // already handled above.
        }
        await close(reason: nil)
    }

    func stop() async {
        running = false
        task?.cancel(with: .goingAway, reason: nil)
    }

    // MARK: - Per-request proxying

    private func handleRequest(_ fr: TunnelFrame) async {
        let start = Date()
        guard let cfg = config, let reqId = fr.reqId else { return }

        let method = fr.method ?? "GET"
        let path = fr.path ?? "/"
        let localURLString = "http://\(cfg.target)\(path)"
        guard let localURL = URL(string: localURLString) else {
            _ = try? await send(TunnelFrame(type: "err", message: "bad local url: \(localURLString)", reqId: reqId))
            await emit(.error("bad local url: \(localURLString)"))
            return
        }

        var urlReq = URLRequest(url: localURL)
        urlReq.httpMethod = method
        // Copy headers, skipping hop-by-hop.
        if let headers = fr.headers {
            for (k, values) in headers where !Self.isHopHeader(k) {
                for v in values {
                    urlReq.addValue(v, forHTTPHeaderField: k)
                }
            }
        }
        if let b64 = fr.body, !b64.isEmpty,
           let data = Data(base64Encoded: b64) {
            urlReq.httpBody = data
        }

        // Hit the local target. Use the shared ephemeral session — we're
        // calling loopback or localhost, not going through the proxied
        // URLSession the tunnel uses.
        do {
            let (data, resp) = try await URLSession.shared.data(for: urlReq)
            let httpResp = resp as? HTTPURLResponse
            let status = httpResp?.statusCode ?? 0

            // Build response headers back into [String:[String]]
            var respHeaders: [String: [String]] = [:]
            if let http = httpResp {
                for (k, v) in http.allHeaderFields {
                    guard let key = k as? String, let val = v as? String else { continue }
                    respHeaders[key, default: []].append(val)
                }
            }
            _ = try? await send(TunnelFrame(
                type: "head",
                reqId: reqId,
                status: status,
                headers: respHeaders
            ))

            // Chunk the body at 32KB. URLSession's in-memory body is
            // already fully buffered, but the chunking keeps the wire
            // protocol consistent with the Go agent.
            let chunkSize = 32 * 1024
            var offset = 0
            while offset < data.count {
                let end = min(offset + chunkSize, data.count)
                let slice = data.subdata(in: offset..<end)
                let b64 = slice.base64EncodedString()
                _ = try? await send(TunnelFrame(type: "body", reqId: reqId, body: b64))
                offset = end
            }
            _ = try? await send(TunnelFrame(type: "end", reqId: reqId))

            let durMs = Int(Date().timeIntervalSince(start) * 1000)
            await emit(.request(method: method, path: path, status: status, durationMs: durMs))
        } catch {
            _ = try? await send(TunnelFrame(type: "err", message: "upstream: \(error.localizedDescription)", reqId: reqId))
            await emit(.error("\(method) \(path): \(error.localizedDescription)"))
        }
    }

    // MARK: - WS I/O

    private func send(_ frame: TunnelFrame) async throws {
        guard let task = task else { throw TunnelError.notConnected }
        let data = try JSONEncoder().encode(frame)
        guard let text = String(data: data, encoding: .utf8) else {
            throw TunnelError.encoding
        }
        try await task.send(.string(text))
    }

    private func receiveFrame() async throws -> TunnelFrame {
        guard let task = task else { throw TunnelError.notConnected }
        let msg = try await task.receive()
        switch msg {
        case .string(let s):
            guard let data = s.data(using: .utf8) else {
                throw TunnelError.decoding
            }
            return try JSONDecoder().decode(TunnelFrame.self, from: data)
        case .data(let data):
            return try JSONDecoder().decode(TunnelFrame.self, from: data)
        @unknown default:
            throw TunnelError.decoding
        }
    }

    private func close(reason: String?) async {
        running = false
        task?.cancel(with: .normalClosure, reason: nil)
        session?.invalidateAndCancel()
        task = nil
        session = nil
        await emit(.closed(reason: reason))
    }

    private func emit(_ event: TunnelEvent) async {
        guard let onEvent = onEvent else { return }
        await MainActor.run { onEvent(event) }
    }

    // MARK: - Hop-by-hop header filter

    private static func isHopHeader(_ name: String) -> Bool {
        switch name.lowercased() {
        case "connection", "keep-alive", "proxy-authenticate",
             "proxy-authorization", "te", "trailers",
             "transfer-encoding", "upgrade":
            return true
        default:
            return false
        }
    }

    enum TunnelError: Error {
        case notConnected
        case encoding
        case decoding
    }
}

// MARK: - Insecure TLS delegate

/// URLSessionWebSocketDelegate that accepts any server certificate.
/// Used only when `TunnelConfig.insecure == true` (local dev).
final class TunnelInsecureDelegate: NSObject, URLSessionDelegate, URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

// MARK: - Random subdomain helper

enum TunnelSub {
    /// Returns a short hex string suitable for a DNS label. Matches the
    /// Go `tunnel.RandomSub` function (`warden/internal/tunnel/random.go`).
    static func random(_ n: Int = 8) -> String {
        var bytes = [UInt8](repeating: 0, count: max(1, n))
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return bytes.map { String(format: "%02x", $0) }.joined().prefix(max(1, n)).lowercased()
    }
}
