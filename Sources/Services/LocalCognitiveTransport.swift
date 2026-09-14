import Foundation
import Darwin

enum CognitiveJSON: Codable, Sendable, Equatable {
    case object([String: CognitiveJSON]), array([CognitiveJSON]), string(String), number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let value = try? c.decode(Bool.self) { self = .bool(value) }
        else if let value = try? c.decode(String.self) { self = .string(value) }
        else if let value = try? c.decode(Double.self) { self = .number(value) }
        else if let value = try? c.decode([String: CognitiveJSON].self) { self = .object(value) }
        else { self = .array(try c.decode([CognitiveJSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let value): try c.encode(value)
        case .array(let value): try c.encode(value)
        case .string(let value): try c.encode(value)
        case .number(let value): try c.encode(value)
        case .bool(let value): try c.encode(value)
        case .null: try c.encodeNil()
        }
    }

    subscript(_ key: String) -> CognitiveJSON { if case .object(let value) = self { return value[key] ?? .null }; return .null }
    var string: String { if case .string(let value) = self { return value }; return "" }
    var array: [CognitiveJSON] { if case .array(let value) = self { return value }; return [] }
    var number: Double? { if case .number(let value) = self { return value }; return nil }
    var bool: Bool { if case .bool(let value) = self { return value }; return false }
    var formatted: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }
}

struct CognitiveLaunch: Codable, Equatable, Sendable {
    var executable: String
    var arguments: [String]
    var directory: String
}

enum CognitiveTransportError: LocalizedError {
    case configuration, timeout, disconnected, malformed, tooLarge, service(String)
    var errorDescription: String? {
        switch self {
        case .configuration: "Choose an existing executable and working directory in cognitive settings."
        case .timeout: "The local service timed out. No request was automatically retried."
        case .disconnected: "The local service disconnected. Reconnect to continue."
        case .malformed: "The local service returned an invalid or mismatched response."
        case .tooLarge: "The local service message exceeded its size limit."
        case .service(let code): "The local service rejected this operation (\(code))."
        }
    }
}

/// All process and pipe access stays on one serial queue, never the UI executor.
final class LocalCognitiveTransport: @unchecked Sendable {
    private let queue = DispatchQueue(label: "li.raya.kiln.cognitive-jsonl", qos: .userInitiated)
    private var process: Process?
    private var input: Pipe?
    private var output: Pipe?
    private var launch: CognitiveLaunch?
    private var buffer = Data()
    private let responseLimit = 4 * 1024 * 1024
    private let shutdownGrace: TimeInterval

    init(shutdownGrace: TimeInterval = 15) { self.shutdownGrace = max(0, shutdownGrace) }

    func call(_ operation: String, params: [String: CognitiveJSON] = [:], launch: CognitiveLaunch,
              timeout: TimeInterval = 20) async throws -> CognitiveJSON {
        try Task.checkCancellation()
        let result: CognitiveJSON = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try self.request(operation, params: params, launch: launch, timeout: timeout)) }
                catch { self.shutdown(grace: 0); continuation.resume(throwing: error) }
            }
        }
        try Task.checkCancellation()
        return result
    }

    func disconnect() async {
        await withCheckedContinuation { continuation in
            queue.async { self.shutdown(); continuation.resume() }
        }
    }

    private func start(_ configuration: CognitiveLaunch) throws {
        if process?.isRunning == true, launch == configuration { return }
        shutdown()
        var directory: ObjCBool = false
        guard configuration.executable.hasPrefix("/"), configuration.directory.hasPrefix("/"),
              FileManager.default.isExecutableFile(atPath: configuration.executable),
              FileManager.default.fileExists(atPath: configuration.directory, isDirectory: &directory), directory.boolValue else {
            throw CognitiveTransportError.configuration
        }
        let child = Process(), stdin = Pipe(), stdout = Pipe()
        child.executableURL = URL(fileURLWithPath: configuration.executable)
        child.arguments = configuration.arguments
        child.currentDirectoryURL = URL(fileURLWithPath: configuration.directory)
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "PYTHONPATH")
        environment.removeValue(forKey: "PYTHONHOME")
        for key in ["ENGRAM_STORAGE_BACKEND", "ENGRAM_DB_PATH", "ENGRAM_POSTGRES_DSN"] { environment.removeValue(forKey: key) }
        environment["PYTHONUNBUFFERED"] = "1"
        environment["PYTHONDONTWRITEBYTECODE"] = "1"
        child.environment = environment
        try child.run()
        process = child; input = stdin; output = stdout; launch = configuration
        let fd = stdin.fileHandleForWriting.fileDescriptor
        guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0,
              fcntl(fd, F_SETNOSIGPIPE, 1) == 0 else { throw CognitiveTransportError.configuration }
    }

    private func request(_ operation: String, params: [String: CognitiveJSON], launch: CognitiveLaunch,
                         timeout: TimeInterval) throws -> CognitiveJSON {
        let id = UUID().uuidString
        let request = CognitiveJSON.object(["id": .string(id), "operation": .string(operation), "params": .object(params)])
        var bytes = try JSONEncoder().encode(request)
        bytes.append(10)
        guard bytes.count <= 65_536 else { throw CognitiveTransportError.tooLarge }
        try start(launch)
        guard let input, let output else { throw CognitiveTransportError.disconnected }
        let deadline = ProcessInfo.processInfo.systemUptime + max(0.05, timeout)
        try bytes.withUnsafeBytes { payload in
            guard let base = payload.baseAddress else { throw CognitiveTransportError.malformed }
            var written = 0
            while written < payload.count {
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                guard remaining > 0 else { throw CognitiveTransportError.timeout }
                var descriptor = pollfd(fd: input.fileHandleForWriting.fileDescriptor, events: Int16(POLLOUT), revents: 0)
                let ready = Darwin.poll(&descriptor, 1, Int32(min(remaining * 1000, 100)))
                if ready < 0 { if errno == EINTR { continue }; throw CognitiveTransportError.disconnected }
                if ready == 0 { continue }
                let count = Darwin.write(descriptor.fd, base.advanced(by: written), payload.count - written)
                if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard count > 0 else { throw CognitiveTransportError.disconnected }
                written += count
            }
        }
        while true {
            if let newline = buffer.firstIndex(of: 10) {
                let line = buffer.prefix(upTo: newline)
                buffer.removeSubrange(...newline)
                guard let response = try? JSONDecoder().decode(CognitiveJSON.self, from: line), response["id"].string == id else {
                    throw CognitiveTransportError.malformed
                }
                if response["error"] != .null {
                    let code = response["error"]["code"].string.isEmpty ? response["error"]["type"].string : response["error"]["code"].string
                    throw CognitiveTransportError.service(String(code.prefix(80)))
                }
                guard case .object(let fields) = response, let result = fields["result"] else { throw CognitiveTransportError.malformed }
                return result
            }
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw CognitiveTransportError.timeout }
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = Darwin.poll(&descriptor, 1, Int32(min(remaining * 1000, 100)))
            if ready < 0 { if errno == EINTR { continue }; throw CognitiveTransportError.disconnected }
            if ready == 0 { continue }
            var chunk = [UInt8](repeating: 0, count: 16_384)
            let count = Darwin.read(descriptor.fd, &chunk, chunk.count)
            guard count > 0 else { throw CognitiveTransportError.disconnected }
            buffer.append(contentsOf: chunk.prefix(count))
            guard buffer.count <= responseLimit else { throw CognitiveTransportError.tooLarge }
        }
    }

    private func shutdown(grace: TimeInterval? = nil) {
        try? input?.fileHandleForWriting.close()
        if let child = process, child.isRunning {
            let gracefulDeadline = ProcessInfo.processInfo.systemUptime + (grace ?? shutdownGrace)
            while child.isRunning && ProcessInfo.processInfo.systemUptime < gracefulDeadline { Thread.sleep(forTimeInterval: 0.01) }
            if child.isRunning { child.terminate() }
            let deadline = ProcessInfo.processInfo.systemUptime + 0.5
            while child.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
            if child.isRunning { Darwin.kill(child.processIdentifier, SIGKILL) }
        }
        try? output?.fileHandleForReading.close()
        process = nil; input = nil; output = nil; launch = nil; buffer.removeAll()
    }
}
