import Foundation

/// A retry may replace the tail only after preflight, against the same transcript.
struct RetryRevision: Sendable {
    let messageIndex: Int
    let expectedMessageIDs: [String]

    func prefix(of messages: [ChatMessage]) -> [ChatMessage]? {
        guard messages.map(\.id) == expectedMessageIDs, messages.indices.contains(messageIndex),
              messages[messageIndex].role == .user else { return nil }
        return Array(messages.prefix(messageIndex))
    }
}
