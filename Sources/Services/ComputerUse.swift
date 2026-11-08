import Foundation
import Network
import AppKit

struct ComputerApproval: Identifiable, Sendable {
    let id: String
    let sessionID: String
    let model: String
    let action: ComputerAction
    let capture: ComputerCapture
    let expires: Date

    func originLabel(chatName: String?) -> String {
        let name = chatName?.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Chat: \(name.flatMap { $0.isEmpty ? nil : $0 } ?? "Unavailable chat") · \(sessionID)"
    }
}

struct ComputerTurn: Sendable {
    let token: String
    let port: UInt16
    var environment: [String: String] { ["KILN_COMPUTER_TOKEN": token, "KILN_COMPUTER_PORT": String(port)] }
}

@MainActor
struct ComputerDriver {
    let allowed: @MainActor () -> Bool
    let current: @MainActor (ComputerTarget) throws -> ComputerTarget
    let capture: @MainActor (ComputerTarget) async throws -> ComputerCapture
    let perform: @MainActor (ComputerAction, ComputerCapture, @MainActor () -> Bool) async throws -> Void
    static let live = Self(allowed: { ComputerPlatform.screenAllowed && ComputerPlatform.inputAllowed },
        current: ComputerPlatform.current, capture: ComputerPlatform.capture,
        perform: { action, capture, active in try await ComputerPlatform.perform(action, capture: capture, isActive: active) })
}

@MainActor
final class ComputerUse: ObservableObject {
    static let shared = ComputerUse()
    @Published private(set) var enabled: [String: ComputerTarget] = [:]
    private var enabledModels: [String: String] = [:]
    private var consentIDs: [String: UUID] = [:]
    @Published private(set) var pending: ComputerApproval?
    @Published private var previews: [String: ComputerCapture] = [:]
    @Published private var histories: [String: [String]] = [:]
    @Published var problem: String?
    private struct Grant {
        let session: String
        let model: String
        let target: ComputerTarget
        var capture: ComputerCapture?
    }
    private var grants: [String: Grant] = [:]
    private var continuation: CheckedContinuation<Bool, Never>?
    private var approvalTimeout: Task<Void, Never>?
    private var listener: NWListener?
    private var listenerPort: UInt16?
    private var pendingStarts: [UUID: String] = [:]
    private var listenerWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var listenerTimeouts: [UUID: Task<Void, Never>] = [:]
    private var readinessGeneration = UUID()
    private var connections: [UUID: ComputerLocalConnection] = [:]
    private let driver: ComputerDriver
    private let approvalLifetime: TimeInterval
    private let listenerReadyGate: @MainActor () async -> Void
    private let listenerStartupTimeout: TimeInterval
    var helperExecutable: String { Bundle.main.executableURL?.path ?? CommandLine.arguments[0] }

    init(driver: ComputerDriver = .live, approvalLifetime: TimeInterval = 55,
         listenerStartupTimeout: TimeInterval = 10,
         listenerReadyGate: @escaping @MainActor () async -> Void = {}) {
        self.driver = driver
        self.approvalLifetime = min(55, max(0.01, approvalLifetime))
        self.listenerReadyGate = listenerReadyGate
        self.listenerStartupTimeout = min(30, max(0.01, listenerStartupTimeout))
    }

    func preview(for sessionID: String?) -> ComputerCapture? { sessionID.flatMap { previews[$0] } }
    func history(for sessionID: String?) -> [String] { sessionID.flatMap { histories[$0] } ?? [] }
    var startingSessions: Set<String> { Set(pendingStarts.values) }

    func enable(sessionID: String, target: ComputerTarget, model: AgentModel) throws {
        guard driver.allowed() else { throw ComputerUseError.permissions }
        _ = try driver.current(target)
        stop(sessionID: sessionID)
        enabled[sessionID] = target
        enabledModels[sessionID] = model.rawValue
        consentIDs[sessionID] = UUID()
        problem = nil
    }

    func stop(sessionID: String? = nil) {
        let tokens = grants.filter { sessionID == nil || $0.value.session == sessionID }.map(\.key)
        for token in tokens { grants[token] = nil }
        if let sessionID { enabled[sessionID] = nil; enabledModels[sessionID] = nil; consentIDs[sessionID] = nil }
        else { enabled.removeAll(); enabledModels.removeAll(); consentIDs.removeAll() }
        if let pending, sessionID == nil || pending.sessionID == sessionID { decide(id: pending.id, allow: false) }
        if let sessionID { previews[sessionID] = nil; histories[sessionID] = nil }
        else { previews.removeAll(); histories.removeAll() }
        let starts = pendingStarts.filter { sessionID == nil || $0.value == sessionID }.map(\.key)
        for start in starts { cancelStart(start) }
        stopListenerIfUnused()
    }

    func endTurn(_ turn: ComputerTurn) {
        if let session = grants[turn.token]?.session, pending?.sessionID == session,
           let id = pending?.id { decide(id: id, allow: false) }
        grants[turn.token] = nil
        stopListenerIfUnused()
    }

    func startTurn(sessionID: String, model: AgentModel, options: SendOptions) async throws -> ComputerTurn? {
        guard options.computerUseAllowed else { return nil }
        guard let target = enabled[sessionID], let consentID = consentIDs[sessionID] else { return nil }
        guard enabledModels[sessionID] == model.rawValue else { stop(sessionID: sessionID); throw ComputerUseError.inactive }
        guard ComputerConnection.eligible(provider: model.provider, options: options) else { throw ComputerUseError.unsupported }
        guard driver.allowed() else { throw ComputerUseError.permissions }
        _ = try driver.current(target)
        try Task.checkCancellation()
        let start = UUID()
        pendingStarts[start] = sessionID
        defer { pendingStarts[start] = nil; stopListenerIfUnused() }
        try await withTaskCancellationHandler {
            try await waitForListener(start: start)
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelStart(start) }
        }
        try Task.checkCancellation()
        guard pendingStarts[start] == sessionID, consentIDs[sessionID] == consentID, enabled[sessionID] == target,
              enabledModels[sessionID] == model.rawValue, driver.allowed() else { throw ComputerUseError.inactive }
        _ = try driver.current(target)
        guard let port = listenerPort, let listener, case .ready = listener.state else { throw ComputerUseError.inactive }
        let token = UUID().uuidString + UUID().uuidString
        grants[token] = Grant(session: sessionID, model: model.label, target: target)
        return ComputerTurn(token: token, port: port)
    }

    func decide(id: String, allow: Bool) {
        guard pending?.id == id else { return }
        let current = continuation
        continuation = nil
        pending = nil
        approvalTimeout?.cancel()
        approvalTimeout = nil
        current?.resume(returning: allow)
    }

    private func cancelStart(_ start: UUID, error: Error = ComputerUseError.inactive) {
        pendingStarts[start] = nil
        listenerTimeouts.removeValue(forKey: start)?.cancel()
        listenerWaiters.removeValue(forKey: start)?.resume(throwing: error)
        stopListenerIfUnused()
    }

    private func stopListenerIfUnused() {
        guard grants.isEmpty, pendingStarts.isEmpty else { return }
        let old = listener
        listener = nil; listenerPort = nil
        readinessGeneration = UUID()
        finishListenerWaiters(.failure(ComputerUseError.inactive))
        old?.cancel()
    }

    private func finishListenerWaiters(_ result: Result<Void, Error>) {
        let waiters = listenerWaiters.values
        listenerWaiters.removeAll()
        for timeout in listenerTimeouts.values { timeout.cancel() }
        listenerTimeouts.removeAll()
        for waiter in waiters { waiter.resume(with: result) }
    }

    private func waitForListener(start: UUID) async throws {
        guard pendingStarts[start] != nil else { throw ComputerUseError.inactive }
        if listenerPort != nil, let listener, case .ready = listener.state { return }
        listenerPort = nil
        if listener == nil { try startListener() }
        try await withCheckedThrowingContinuation { (ready: CheckedContinuation<Void, Error>) in
            listenerWaiters[start] = ready
            listenerTimeouts[start] = Task { [weak self] in
                guard let timeout = self?.listenerStartupTimeout else { return }
                do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                self?.cancelStart(start, error: ComputerUseError.listenerTimeout)
            }
        }
    }

    private func startListener() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor in
                    guard let self, let listener, self.listener === listener else { return }
                    switch state {
                    case .ready:
                        let generation = self.readinessGeneration
                        await self.listenerReadyGate()
                        guard self.listener === listener, self.readinessGeneration == generation else { return }
                        guard let port = listener.port?.rawValue else {
                            self.listener = nil
                            listener.cancel()
                            self.finishListenerWaiters(.failure(ComputerUseError.inactive))
                            return
                        }
                        self.listenerPort = port
                        self.finishListenerWaiters(.success(()))
                    case .failed(let error):
                        self.listener = nil; self.listenerPort = nil; listener.cancel()
                        self.finishListenerWaiters(.failure(error))
                    case .cancelled:
                        self.listener = nil; self.listenerPort = nil
                        self.finishListenerWaiters(.failure(ComputerUseError.inactive))
                    case .waiting:
                        self.listenerPort = nil
                        self.readinessGeneration = UUID()
                    default: break
                    }
                }
            }
        listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard let self, self.connections.count < 8 else { connection.cancel(); return }
                    let id = UUID()
                    let client = ComputerLocalConnection(connection: connection) { [weak self] data, token in
                        guard let self else { return ComputerUse.failure(ComputerUseError.inactive) }
                        return await self.handle(data, token: token)
                    } onClose: { [weak self] in self?.connections[id] = nil }
                    self.connections[id] = client
                    client.start()
                }
            }
        listener.start(queue: DispatchQueue(label: "kiln.computer.listener"))
    }

    func handle(_ data: Data, token: String) async -> Data {
        guard var grant = grants[token], enabled[grant.session] == grant.target else { return Self.failure(ComputerUseError.inactive) }
        var attemptedCaptureID: String?
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = json["name"] as? String else { throw ComputerUseError.invalidAction }
            if name == "status" {
                return Self.result(["type": "text", "text": "Selected window: \(grant.target.label). Every input action requires approval in Kiln. Observe before acting."])
            }
            if name == "observe" {
                let capture = try await driver.capture(grant.target)
                guard driver.allowed(), grants[token] != nil, enabled[grant.session] == grant.target else { throw ComputerUseError.inactive }
                grant.capture = capture
                grants[token] = grant
                previews[grant.session] = capture
                return Self.encode(["content": [
                    ["type": "text", "text": "capture_id: \(capture.id)\nWindow: \(capture.target.label)\nImage coordinates: \(capture.width) x \(capture.height). Capture expires in 60 seconds; observe again after each action."],
                    ["type": "image", "mimeType": "image/jpeg", "data": capture.jpeg.base64EncodedString()]
                ]])
            }
            guard pending == nil else { return Self.failure(ComputerUseError.busy) }
            guard let capture = grant.capture else { throw ComputerUseError.staleCapture }
            let action = try ComputerAction(name: name, arguments: json["arguments"] as? [String: Any] ?? [:])
            attemptedCaptureID = action.captureID
            guard action.captureID == capture.id else { throw ComputerUseError.staleCapture }
            _ = try capture.point(x: action.x, y: action.y, current: driver.current(grant.target))
            let proposal = ComputerApproval(id: UUID().uuidString, sessionID: grant.session, model: grant.model,
                action: action, capture: capture, expires: Date().addingTimeInterval(approvalLifetime))
            let approved = await withCheckedContinuation { (reply: CheckedContinuation<Bool, Never>) in
                continuation = reply
                pending = proposal
                approvalTimeout = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(self?.approvalLifetime ?? 55))
                    guard !Task.isCancelled else { return }
                    self?.decide(id: proposal.id, allow: false)
                }
            }
            guard approved, grants[token] != nil, enabled[grant.session] == grant.target else { throw ComputerUseError.denied }
            guard driver.allowed() else { throw ComputerUseError.permissions }
            guard grants[token]?.capture?.id == capture.id else { throw ComputerUseError.staleCapture }
            _ = try capture.point(x: action.x, y: action.y, current: driver.current(grant.target))
            try await driver.perform(action, capture) { [weak self] in
                self?.grants[token]?.capture?.id == capture.id && self?.enabled[grant.session] == grant.target
            }
            // A capture is single-use for mutations, including a denied action.
            if grants[token]?.capture?.id == capture.id { grants[token]?.capture = nil }
            var history = histories[grant.session] ?? []
            history.insert(action.title + " - " + grant.target.app, at: 0)
            histories[grant.session] = Array(history.prefix(30))
            return Self.result(["type": "text", "text": "Approved input dispatched. Observe again to verify the outcome before the next action."])
        } catch {
            if let attemptedCaptureID, grants[token]?.capture?.id == attemptedCaptureID { grants[token]?.capture = nil }
            return Self.failure(error)
        }
    }

    nonisolated static func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
    nonisolated static func result(_ content: [String: Any]) -> Data { encode(["content": [content]]) }
    nonisolated static func failure(_ error: Error) -> Data {
        encode(["isError": true, "content": [["type": "text", "text": error.localizedDescription]]])
    }
}

struct ComputerHTTPRequest {
    let token: String
    let body: Data
    static func parse(_ buffer: Data) throws -> Self? {
        guard let range = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            guard buffer.count <= 4096 else { throw ComputerUseError.invalidAction }
            return nil
        }
        guard range.lowerBound <= 4096, buffer.count <= 12_288,
              let header = String(data: buffer[..<range.lowerBound], encoding: .utf8) else { throw ComputerUseError.invalidAction }
        let lines = header.components(separatedBy: "\r\n")
        guard lines.first == "POST /computer HTTP/1.1" else { throw ComputerUseError.invalidAction }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, fields[parts[0].lowercased()] == nil else { throw ComputerUseError.invalidAction }
            fields[parts[0].lowercased()] = parts[1]
        }
        guard fields["origin"] == nil, fields["transfer-encoding"] == nil,
              fields["content-type"]?.lowercased().hasPrefix("application/json") == true,
              let length = fields["content-length"].flatMap(Int.init), length > 0, length <= 8192,
              let auth = fields["authorization"], auth.hasPrefix("Bearer "), auth.count <= 96 else { throw ComputerUseError.invalidAction }
        guard buffer.count >= range.upperBound + length else { return nil }
        guard buffer.count == range.upperBound + length else { throw ComputerUseError.invalidAction }
        return Self(token: String(auth.dropFirst(7)), body: buffer.subdata(in: range.upperBound..<buffer.count))
    }
}

private final class ComputerLocalConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let handler: @MainActor @Sendable (Data, String) async -> Data
    private let onClose: @MainActor @Sendable () -> Void
    private let queue = DispatchQueue(label: "kiln.computer.request")
    private var buffer = Data()
    private var closed = false
    init(connection: NWConnection, handler: @escaping @MainActor @Sendable (Data, String) async -> Data,
         onClose: @escaping @MainActor @Sendable () -> Void) {
        self.connection = connection; self.handler = handler; self.onClose = onClose
    }
    func start() {
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 120) { [weak self] in self?.close() }
        receive()
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 12_289) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let data { self.buffer.append(data) }
            do {
                if let request = try ComputerHTTPRequest.parse(self.buffer) {
                    Task { @MainActor in
                        let response = await self.handler(request.body, request.token)
                        self.queue.async { self.send(response) }
                    }
                } else if complete || error != nil { self.close() }
                else { self.receive() }
            } catch { self.send(ComputerUse.failure(error)) }
        }
    }
    private func send(_ data: Data) {
        guard !closed else { return }
        var response = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(data.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n".utf8)
        response.append(data)
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in self?.close() })
    }
    private func close() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        Task { @MainActor in onClose() }
    }
}
