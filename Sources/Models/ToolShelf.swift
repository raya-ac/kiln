import Foundation

enum ToolShelfTab: String, CaseIterable, Identifiable {
    case tools = "Tools", calls = "Recent calls", computer = "Computer"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .tools: "square.grid.2x2"
        case .calls: "clock.arrow.circlepath"
        case .computer: "desktopcomputer"
        }
    }
}

struct IndexedToolCall: Identifiable, Sendable {
    let id: String
    let tool: ToolUseBlock
    let live: Bool
    var presentation: ToolPresentation { ToolPresentation(tool: tool, live: live) }

    static func collect(messages: [ChatMessage], active: [ToolUseBlock]) -> [Self] {
        let activeCalls = ToolPresentation.uniqueCalls(active).suffix(400)
        let activeIDs = Set(activeCalls.map(\.id))
        var output = activeCalls.reversed().map { Self(id: "live:" + $0.id, tool: $0, live: true) }
        if output.count >= 400 { return output }
        for message in messages.suffix(200).reversed() {
            for block in message.blocks.reversed() {
                if case .toolUse(let tool) = block, !activeIDs.contains(tool.id) {
                    output.append(Self(id: ToolPresentation.disclosureID(messageID: message.id, toolID: tool.id), tool: tool, live: false))
                    if output.count >= 400 { return output }
                }
            }
        }
        return output
    }

    func matches(_ query: String, failuresOnly: Bool) -> Bool {
        if failuresOnly, presentation.status != .failure { return false }
        let words = query.lowercased().split(whereSeparator: \.isWhitespace)
        let text = (tool.name + " " + presentation.summary + " " + String(tool.result?.prefix(4_000) ?? "") + " " + presentation.status.label).lowercased()
        return words.allSatisfy { text.contains($0) }
    }
}
