import Foundation

/// Native presentation adapted from T3 Code's work groups. See docs/t3-parity.md.
/// This is a read-only projection; it never authorizes or dispatches a tool.
struct ToolPresentation: Identifiable, Sendable {
    enum Status: String, CaseIterable, Sendable {
        case pending, running, success, failure, unconfirmed

        var label: String {
            switch self {
            case .pending: "Pending"
            case .running: "Running"
            case .success: "Complete"
            case .failure: "Failed"
            case .unconfirmed: "Unconfirmed"
            }
        }

        var symbol: String {
            switch self {
            case .pending: "clock"
            case .running: "arrow.triangle.2.circlepath"
            case .success: "checkmark.circle"
            case .failure: "xmark.circle"
            case .unconfirmed: "questionmark.circle"
            }
        }
    }

    static let pageSize = 40
    static let outputPageSize = 8_000
    static let maximumPreviewSize = 32_000
    static let inputParseLimit = 65_536

    static func assistantMessageID(userID: String) -> String { "assistant:" + userID }
    static func disclosureID(messageID: String, toolID: String) -> String {
        "\(messageID.utf8.count):\(messageID)\(toolID)"
    }

    let tool: ToolUseBlock
    let status: Status
    var id: String { tool.id }

    init(tool: ToolUseBlock, live: Bool) {
        self.tool = tool
        // blockStop also sets isDone. It is not an execution completion receipt.
        if tool.isError {
            status = .failure
        } else if tool.result != nil || tool.completedAt != nil {
            status = .success
        } else if !live {
            status = .unconfirmed
        } else {
            status = tool.startedAt == nil ? .pending : .running
        }
    }

    var duration: TimeInterval? {
        guard let start = tool.startedAt, let end = tool.completedAt, end >= start else { return nil }
        return end.timeIntervalSince(start)
    }

    var inputObject: [String: Any]? {
        guard tool.input.utf8.count <= Self.inputParseLimit,
              let data = tool.input.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    var summary: String {
        guard let object = inputObject else { return "" }
        for key in ["command", "cmd", "file_path", "path", "pattern", "query", "url", "description"] {
            if let value = object[key] as? String {
                return String(value.prefix(180)).replacingOccurrences(of: "\n", with: " ")
            }
        }
        return ""
    }

    var symbol: String {
        let name = tool.name.lowercased()
        if name.contains("bash") || name.contains("exec") || name.contains("terminal") { return "terminal" }
        if name.contains("search") || name.contains("grep") || name.contains("glob") { return "magnifyingglass" }
        if name.contains("write") || name.contains("edit") || name.contains("patch") { return "pencil" }
        if name.contains("read") { return "doc.text" }
        if name.contains("web") || name.contains("fetch") { return "globe" }
        return "wrench.and.screwdriver"
    }

    var imagePath: String? {
        guard status == .success, let object = inputObject,
              let path = object["file_path"] as? String ?? object["path"] as? String else { return nil }
        let extensions = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "tif", "bmp", "svg"]
        return extensions.contains((path as NSString).pathExtension.lowercased()) ? path : nil
    }

    static func preview(_ text: String, limit: Int = outputPageSize) -> String {
        String(text.prefix(max(0, min(limit, maximumPreviewSize))))
    }

    /// Providers can update a call with the same ID; preserve its original position.
    static func uniqueCalls(_ tools: [ToolUseBlock]) -> [ToolUseBlock] {
        var indices: [String: Int] = [:]
        var result: [ToolUseBlock] = []
        for tool in tools {
            if let index = indices[tool.id] { result[index] = tool }
            else { indices[tool.id] = result.count; result.append(tool) }
        }
        return result
    }
}

struct ToolTranscriptRow: Identifiable, Sendable {
    enum Content: Sendable {
        case block(MessageBlock)
        case tools([ToolUseBlock])
    }

    let id: TranscriptBlock.ID
    let content: Content

    /// Only adjacent tool activity is grouped. Prose, reasoning and media keep their order.
    static func rows(for message: ChatMessage) -> [Self] {
        var results: [String: ToolResultBlock] = [:]
        var callIDs: Set<String> = []
        for block in message.blocks {
            if case .toolResult(let result) = block { results[result.toolUseId] = result }
            if case .toolUse(let tool) = block { callIDs.insert(tool.id) }
        }
        var rows: [Self] = []
        var calls: [ToolUseBlock] = []
        var groupIndex = 0
        func flush() {
            guard !calls.isEmpty else { return }
            rows.append(.init(id: .init(messageId: message.id, index: groupIndex),
                              content: .tools(ToolPresentation.uniqueCalls(calls))))
            calls.removeAll(keepingCapacity: true)
        }
        for (index, block) in message.blocks.enumerated() {
            switch block {
            case .toolUse(var tool):
                if calls.isEmpty { groupIndex = index }
                if let result = results[tool.id] {
                    tool.result = result.content
                    tool.isError = result.isError
                }
                calls.append(tool)
            case .toolResult(let result):
                guard !callIDs.contains(result.toolUseId) else { continue }
                if calls.isEmpty { groupIndex = index }
                calls.append(.init(id: result.toolUseId, name: "Tool result", input: "",
                                   isDone: true, result: result.content, isError: result.isError))
            default:
                flush()
                rows.append(.init(id: .init(messageId: message.id, index: index), content: .block(block)))
            }
        }
        flush()
        return rows
    }
}
