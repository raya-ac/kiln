import Foundation

enum AutoCompactionPolicy {
    static func shouldCompact(enabled: Bool, context: ContextUsage?) -> Bool {
        guard enabled, let context, context.isValid else { return false }
        return context.fraction >= 0.9
    }

    static func lastContext(in messages: [ChatMessage], modelID: String, threadID: String) -> ContextUsage? {
        guard let message = messages.last(where: { $0.role == .assistant }) else { return nil }
        for block in message.blocks.reversed() {
            guard case .trace(let entries) = block,
                  let entry = entries.last(where: { $0.phase == "context" }),
                  let used = entry.metadata["usedTokens"].flatMap(Int.init),
                  let window = entry.metadata["contextWindow"].flatMap(Int.init),
                  entry.metadata["model"] == modelID, entry.metadata["thread"] == threadID else { continue }
            let value = ContextUsage(usedTokens: used, window: window, modelID: modelID, threadID: threadID)
            return value.isValid ? value : nil
        }
        return nil
    }
}
