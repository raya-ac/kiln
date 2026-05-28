import Foundation

/// Small file-backed audit trail for agent/runtime events. The UI trace is
/// per-session and transient while a turn runs; this log survives crashes.
final class AgentTraceLog: @unchecked Sendable {
    static let shared = AgentTraceLog()

    private let queue = DispatchQueue(label: "li.raya.kiln.agent-trace-log", qos: .utility)
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    var fileURL: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return base
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("Kiln", isDirectory: true)
            .appendingPathComponent("agent-trace.jsonl")
    }

    func append(_ entry: AgentTraceEntry, sessionId: String?, sessionName: String? = nil) {
        let record = AgentTraceRecord(sessionId: sessionId, sessionName: sessionName, entry: entry)
        append(record)
    }

    func appendLocal(
        level: AgentTraceLevel,
        phase: String,
        title: String,
        detail: String = "",
        metadata: [String: String] = [:]
    ) {
        append(AgentTraceRecord(
            sessionId: nil,
            sessionName: nil,
            entry: AgentTraceEntry(
                source: "kiln",
                level: level,
                phase: phase,
                title: title,
                detail: detail,
                metadata: metadata
            )
        ))
    }

    private func append(_ record: AgentTraceRecord) {
        let logURL = fileURL
        queue.async { [encoder, logURL] in
            do {
                try FileManager.default.createDirectory(
                    at: logURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                let data = try encoder.encode(record)
                let line = data + Data([0x0A])
                if FileManager.default.fileExists(atPath: logURL.path) {
                    let handle = try FileHandle(forWritingTo: logURL)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: line)
                    try handle.close()
                } else {
                    try line.write(to: logURL, options: [.atomic])
                }
            } catch {
                // Logging must never make the app less stable.
            }
        }
    }
}

private struct AgentTraceRecord: Encodable {
    let sessionId: String?
    let sessionName: String?
    let entry: AgentTraceEntry
}
