import Foundation

enum AutoCompactionPolicy {
    static func shouldCompact(enabled: Bool, inputTokens: Int, outputTokens: Int, contextWindow: Int) -> Bool {
        guard enabled, contextWindow > 0 else { return false }
        return Double(max(0, inputTokens)) + Double(max(0, outputTokens)) >= Double(contextWindow) * 0.9
    }

    static func lastUsage(in messages: [ChatMessage]) -> (input: Int, output: Int) {
        for message in messages.reversed() {
            for block in message.blocks.reversed() {
                if case .trace(let entries) = block,
                   let usage = entries.last(where: { $0.phase == "usage" }),
                   let input = usage.metadata["inputTokens"].flatMap(Int.init),
                   let output = usage.metadata["outputTokens"].flatMap(Int.init) {
                    return (input, output)
                }
            }
        }
        return (0, 0)
    }
}
