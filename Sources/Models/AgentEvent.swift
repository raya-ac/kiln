import Foundation

enum AgentEvent: Sendable {
    case sessionId(String)
    case messageStart
    case textDelta(String)
    case thinkingDelta(String)
    case trace(AgentTraceEntry)
    case toolStart(id: String, name: String, input: String)
    case toolInputDelta(String)
    case blockStop(index: Int)
    case messageStop
    case usage(inputTokens: Int, outputTokens: Int)
    case contextUsage(ContextUsage?)
    case toolResult(toolUseId: String, content: String, isError: Bool)
    case cost(Double)
    case error(String)
    case done
}
