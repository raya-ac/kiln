import Foundation

enum TranscriptContext {
    /// Keep recent context on fresh threads, forks, and migrated conversations.
    static func text(from messages: [ChatMessage], characterLimit: Int) -> String {
        guard characterLimit > 0 else { return "" }
        var remaining = characterLimit
        var chunks: [String] = []
        for message in messages.reversed() {
            let body = message.blocks.compactMap { block -> String? in
                switch block {
                case .text(let text): return text
                case .attachment(let file): return "[Attachment: \(file.name)]"
                default: return nil
                }
            }.joined(separator: "\n")
            guard !body.isEmpty else { continue }
            let chunk = "\(message.role.rawValue):\n\(body)"
            chunks.append(String(chunk.suffix(remaining)))
            remaining -= min(remaining, chunk.count)
            if remaining <= 2 { break }
            remaining -= 2
        }
        return chunks.reversed().joined(separator: "\n\n")
    }
}

struct TranscriptBlock: Identifiable, Sendable {
    struct ID: Hashable, Sendable {
        let messageId: String
        let index: Int
    }
    let id: ID
    let block: MessageBlock
}

extension ChatMessage {
    /// Block position is stable within an immutable transcript message.
    /// Identical text and a tool use/result pair must still have different IDs.
    var transcriptBlocks: [TranscriptBlock] {
        blocks.enumerated().map { .init(id: .init(messageId: id, index: $0.offset), block: $0.element) }
    }
}
