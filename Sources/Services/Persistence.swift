import Foundation

/// Persists sessions and settings to ~/.kiln/
enum Persistence {
    private static let baseDir = NSHomeDirectory() + "/.kiln"
    private static let sessionsDir = baseDir + "/sessions"
    private static let settingsPath = baseDir + "/settings.json"

    // MARK: - Setup

    static func ensureDirectories() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: sessionsDir, withIntermediateDirectories: true)
    }

    // MARK: - Settings

    static func loadSettings() -> KilnSettings {
        guard let data = FileManager.default.contents(atPath: settingsPath),
              let settings = try? JSONDecoder().decode(KilnSettings.self, from: data)
        else { return KilnSettings() }
        return settings
    }

    static func saveSettings(_ settings: KilnSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        try? data.write(to: URL(fileURLWithPath: settingsPath))
    }

    // MARK: - Sessions

    static func loadSessions() -> [SessionData] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: sessionsDir) else { return [] }

        var sessions: [SessionData] = []
        for file in files where file.hasSuffix(".json") {
            let path = (sessionsDir as NSString).appendingPathComponent(file)
            guard let data = fm.contents(atPath: path),
                  let session = try? JSONDecoder().decode(SessionData.self, from: data)
            else { continue }
            sessions.append(session)
        }
        return sessions.sorted { $0.createdAt > $1.createdAt }
    }

    static func saveSession(_ session: Session) {
        let data = SessionData(from: session)
        guard let json = try? JSONEncoder().encode(data) else { return }
        let path = (sessionsDir as NSString).appendingPathComponent("\(session.id).json")
        try? json.write(to: URL(fileURLWithPath: path))
    }

    static func deleteSession(_ id: String) {
        let path = (sessionsDir as NSString).appendingPathComponent("\(id).json")
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: - Import / Export

    /// Encode a live session to JSON bytes using the same on-disk shape as
    /// `saveSession`, so exported files are round-trippable with `decodeSessionData`.
    static func exportSessionJSONData(_ session: Session) -> Data? {
        let data = SessionData(from: session)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? enc.encode(data)
    }

    /// Decode a previously-exported session JSON blob. Uses `SessionData`'s
    /// forgiving decoder so older/newer exports survive.
    static func decodeSessionData(_ data: Data) -> SessionData? {
        return try? JSONDecoder().decode(SessionData.self, from: data)
    }

    /// Encode the full KilnSettings to JSON bytes for backup.
    static func exportSettingsJSONData(_ settings: KilnSettings) -> Data? {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? enc.encode(settings)
    }

    /// Decode a settings-backup blob. Returns nil on malformed input.
    static func decodeSettingsData(_ data: Data) -> KilnSettings? {
        return try? JSONDecoder().decode(KilnSettings.self, from: data)
    }
}

// MARK: - Codable session data (messages stored separately for perf)

struct SessionData: Codable {
    let id: String
    let workDir: String
    var name: String
    var model: String // raw value
    let createdAt: Double // timeIntervalSince1970
    var isPinned: Bool
    var group: String?
    var forkedFrom: String?
    var kind: String = "code" // SessionKind raw value
    var readOnly: Bool = false
    var isArchived: Bool = false
    var sessionInstructions: String = ""
    var wasInterrupted: Bool = false
    var tags: [String] = []
    /// Per-session warden tunnel config — local port + optional stable sub.
    /// Both default-absent so old session files decode unchanged.
    var tunnelPort: Int? = nil
    var tunnelSub: String? = nil
    var colorLabel: String? = nil
    var messages: [MessageData]

    // Handle missing keys from older session files
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        workDir = try c.decode(String.self, forKey: .workDir)
        name = try c.decode(String.self, forKey: .name)
        model = try c.decode(String.self, forKey: .model)
        createdAt = try c.decode(Double.self, forKey: .createdAt)
        isPinned = (try? c.decode(Bool.self, forKey: .isPinned)) ?? false
        group = try? c.decode(String.self, forKey: .group)
        forkedFrom = try? c.decode(String.self, forKey: .forkedFrom)
        kind = (try? c.decode(String.self, forKey: .kind)) ?? "code"
        readOnly = (try? c.decode(Bool.self, forKey: .readOnly)) ?? false
        isArchived = (try? c.decode(Bool.self, forKey: .isArchived)) ?? false
        sessionInstructions = (try? c.decode(String.self, forKey: .sessionInstructions)) ?? ""
        wasInterrupted = (try? c.decode(Bool.self, forKey: .wasInterrupted)) ?? false
        tags = (try? c.decode([String].self, forKey: .tags)) ?? []
        tunnelPort = try? c.decode(Int.self, forKey: .tunnelPort)
        tunnelSub = try? c.decode(String.self, forKey: .tunnelSub)
        colorLabel = try? c.decode(String.self, forKey: .colorLabel)
        messages = (try? c.decode([MessageData].self, forKey: .messages)) ?? []
    }

    init(from session: Session) {
        self.id = session.id
        self.workDir = session.workDir
        self.name = session.name
        self.model = session.model.rawValue
        self.createdAt = session.createdAt.timeIntervalSince1970
        self.isPinned = session.isPinned
        self.group = session.group
        self.forkedFrom = session.forkedFrom
        self.kind = session.kind.rawValue
        self.readOnly = session.readOnly
        self.isArchived = session.isArchived
        self.sessionInstructions = session.sessionInstructions
        self.wasInterrupted = session.wasInterrupted
        self.tags = session.tags
        self.tunnelPort = session.tunnelPort
        self.tunnelSub = session.tunnelSub
        self.colorLabel = session.colorLabel
        self.messages = session.messages.map { MessageData(from: $0) }
    }

    func toSession() -> Session {
        var s = Session(
            id: id,
            workDir: workDir,
            name: name,
            model: ClaudeModel(rawValue: model) ?? .sonnet46,
            isPinned: isPinned,
            group: group,
            forkedFrom: forkedFrom,
            kind: SessionKind(rawValue: kind) ?? .code,
            readOnly: readOnly,
            isArchived: isArchived,
            sessionInstructions: sessionInstructions,
            tags: tags,
            tunnelPort: tunnelPort,
            tunnelSub: tunnelSub,
            colorLabel: colorLabel,
            createdAt: Date(timeIntervalSince1970: createdAt)
        )
        s.wasInterrupted = wasInterrupted
        s.messages = messages.map { $0.toChatMessage() }
        return s
    }
}

struct MessageData: Codable {
    let id: String
    let role: String
    let blocks: [BlockData]
    let timestamp: Double
    var isPinned: Bool?

    init(from msg: ChatMessage) {
        self.id = msg.id
        self.role = msg.role.rawValue
        self.blocks = msg.blocks.map { BlockData(from: $0) }
        self.timestamp = msg.timestamp.timeIntervalSince1970
        self.isPinned = msg.isPinned
    }

    func toChatMessage() -> ChatMessage {
        ChatMessage(
            id: id,
            role: MessageRole(rawValue: role) ?? .user,
            blocks: blocks.map { $0.toBlock() },
            timestamp: Date(timeIntervalSince1970: timestamp),
            isPinned: isPinned ?? false
        )
    }
}

struct BlockData: Codable {
    let type: String
    let text: String?
    let toolId: String?
    let toolName: String?
    let toolInput: String?
    let toolResult: String?
    let isError: Bool?
    let suggestions: [SuggestionPrompt]?
    let attachment: ComposerAttachment?
    /// Tool-call timing — optional so older session files still decode.
    /// Epoch seconds to keep JSON compact and tool-inspectable.
    let toolStartedAt: Double?
    let toolCompletedAt: Double?

    init(from block: MessageBlock) {
        self.toolId = {
            if case .toolUse(let t) = block { return t.id }
            if case .toolResult(let r) = block { return r.toolUseId }
            return nil
        }()
        switch block {
        case .text(let t):
            self.type = "text"
            self.text = t
            self.toolName = nil; self.toolInput = nil; self.toolResult = nil; self.isError = nil
            self.suggestions = nil; self.attachment = nil
            self.toolStartedAt = nil; self.toolCompletedAt = nil
        case .thinking(let t):
            self.type = "thinking"
            self.text = t
            self.toolName = nil; self.toolInput = nil; self.toolResult = nil; self.isError = nil
            self.suggestions = nil; self.attachment = nil
            self.toolStartedAt = nil; self.toolCompletedAt = nil
        case .toolUse(let tool):
            self.type = "tool_use"
            self.text = nil
            self.toolName = tool.name; self.toolInput = tool.input
            self.toolResult = tool.result; self.isError = tool.isError
            self.suggestions = nil; self.attachment = nil
            self.toolStartedAt = tool.startedAt?.timeIntervalSince1970
            self.toolCompletedAt = tool.completedAt?.timeIntervalSince1970
        case .toolResult(let r):
            self.type = "tool_result"
            self.text = r.content
            self.toolName = nil; self.toolInput = nil
            self.toolResult = nil; self.isError = r.isError
            self.suggestions = nil; self.attachment = nil
            self.toolStartedAt = nil; self.toolCompletedAt = nil
        case .suggestions(let s):
            self.type = "suggestions"
            self.text = nil
            self.toolName = nil; self.toolInput = nil; self.toolResult = nil; self.isError = nil
            self.suggestions = s; self.attachment = nil
            self.toolStartedAt = nil; self.toolCompletedAt = nil
        case .attachment(let a):
            self.type = "attachment"
            self.text = nil
            self.toolName = nil; self.toolInput = nil; self.toolResult = nil; self.isError = nil
            self.suggestions = nil; self.attachment = a
            self.toolStartedAt = nil; self.toolCompletedAt = nil
        }
    }

    func toBlock() -> MessageBlock {
        switch type {
        case "text":
            return .text(text ?? "")
        case "thinking":
            return .thinking(text ?? "")
        case "tool_use":
            return .toolUse(ToolUseBlock(
                id: toolId ?? UUID().uuidString,
                name: toolName ?? "unknown",
                input: toolInput ?? "{}",
                isDone: true,
                result: toolResult,
                isError: isError ?? false,
                startedAt: toolStartedAt.map { Date(timeIntervalSince1970: $0) },
                completedAt: toolCompletedAt.map { Date(timeIntervalSince1970: $0) }
            ))
        case "tool_result":
            return .toolResult(ToolResultBlock(
                toolUseId: toolId ?? "",
                content: text ?? "",
                isError: isError ?? false
            ))
        case "suggestions":
            return .suggestions(suggestions ?? [])
        case "attachment":
            if let a = attachment { return .attachment(a) }
            return .text(text ?? "")
        default:
            return .text(text ?? "")
        }
    }
}
