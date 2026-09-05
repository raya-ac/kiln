import Foundation

struct ContextUsage: Codable, Equatable, Sendable {
    let usedTokens: Int
    let window: Int
    let modelID: String
    let threadID: String

    var isValid: Bool { usedTokens >= 0 && window > 0 && !modelID.isEmpty && !threadID.isEmpty }
    var fraction: Double { isValid ? Double(usedTokens) / Double(window) : 0 }
    var trace: AgentTraceEntry {
        AgentTraceEntry(source: "context", phase: "context", title: "Current context", metadata: [
            "usedTokens": String(usedTokens), "contextWindow": String(window), "model": modelID, "thread": threadID,
        ])
    }
}
