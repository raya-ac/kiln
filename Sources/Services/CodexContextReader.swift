import Foundation

/// Exec's turn.completed counters are aggregate usage. The matching rollout
/// carries the latest request's occupancy and the backend's effective limit.
actor CodexContextReader {
    static let shared = CodexContextReader()
    private var paths: [String: URL] = [:]
    private var snapshots: [String: (UInt64, Date?, String, ContextUsage?)] = [:]

    func read(threadID: String, modelID: String, home: URL) -> ContextUsage? {
        guard UUID(uuidString: threadID) != nil else { return nil }
        let key = home.path + "/" + threadID
        let root = home.appendingPathComponent("sessions")
        if paths[key] == nil {
            guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return nil }
            var count = 0
            while let url = entries.nextObject() as? URL {
                count += 1
                guard count <= 100_000 else { return nil }
                if url.lastPathComponent.hasSuffix("-" + threadID + ".jsonl") {
                    paths[key] = url
                    break
                }
            }
        }
        guard let url = paths[key],
              let file = try? FileHandle(forReadingFrom: url) else { paths[key] = nil; return nil }
        defer { try? file.close() }
        guard let size = try? file.seekToEnd() else { return nil }
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if let saved = snapshots[key], saved.0 == size, saved.1 == modified, saved.2 == modelID { return saved.3 }
        // Bounded tail only; if the model marker has fallen outside it, report
        // unknown instead of trusting a measurement from a different model.
        let start = size > 8_000_000 ? size - 8_000_000 : 0
        guard (try? file.seek(toOffset: start)) != nil,
              let data = try? file.read(upToCount: 8_000_000) else { return nil }
        let value = Self.parse(data, threadID: threadID, modelID: modelID)
        if snapshots.count > 1024 { snapshots.removeAll(); paths.removeAll() }
        snapshots[key] = (size, modified, modelID, value)
        return value
    }

    static func parse(_ data: Data, threadID: String, modelID: String) -> ContextUsage? {
        var currentModel: String?
        var result: ContextUsage?
        // Ignore an unfinished last line while the CLI is appending a record.
        let lines = data.split(separator: 10, omittingEmptySubsequences: false).dropLast()
        for line in lines {
            guard let json = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  let type = json["type"] as? String else { continue }
            let payload = json["payload"] as? [String: Any] ?? [:]
            if type == "session_meta", let id = payload["id"] as? String, id != threadID { return nil }
            if type == "turn_context" {
                currentModel = payload["model"] as? String
                result = nil
            }
            if type == "compacted" || (type == "event_msg" && payload["type"] as? String == "context_compacted") { result = nil }
            guard type == "event_msg", payload["type"] as? String == "token_count" else { continue }
            guard let info = payload["info"] as? [String: Any] else { continue } // rate-limit-only notification
            result = nil
            guard currentModel == modelID,
                  let last = info["last_token_usage"] as? [String: Any],
                  let used = last["total_tokens"] as? Int,
                  let window = info["model_context_window"] as? Int else { continue }
            let usage = ContextUsage(usedTokens: used, window: window, modelID: modelID, threadID: threadID)
            if usage.isValid { result = usage }
        }
        return result
    }
}
