import Foundation

/// A reusable starting point for new sessions — bundles up model, mode,
/// permissions, system-prompt override, tags, and workdir so you can spin
/// up consistently-configured sessions without re-picking everything.
struct SessionTemplate: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var name: String
    var icon: String   // SF Symbol name
    var model: String  // ClaudeModel rawValue
    var kind: String   // SessionKind rawValue
    var mode: String?  // SessionMode rawValue
    var permissions: String? // PermissionMode rawValue
    var workDir: String?
    var sessionInstructions: String
    var tags: [String]

    init(
        id: String = UUID().uuidString,
        name: String,
        icon: String = "square.grid.2x2",
        model: String,
        kind: String,
        mode: String? = nil,
        permissions: String? = nil,
        workDir: String? = nil,
        sessionInstructions: String = "",
        tags: [String] = []
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.model = model
        self.kind = kind
        self.mode = mode
        self.permissions = permissions
        self.workDir = workDir
        self.sessionInstructions = sessionInstructions
        self.tags = tags
    }
}

@MainActor
final class SessionTemplateStore: ObservableObject {
    static let shared = SessionTemplateStore()
    private let key = "sessionTemplates.v1"

    @Published var templates: [SessionTemplate] = []

    init() { load() }

    func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([SessionTemplate].self, from: data)
        else {
            templates = Self.seed
            save()
            return
        }
        templates = decoded
    }

    func save() {
        if let data = try? JSONEncoder().encode(templates) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func add(_ t: SessionTemplate) {
        templates.append(t)
        save()
    }

    func remove(_ id: String) {
        templates.removeAll { $0.id == id }
        save()
    }

    func update(_ t: SessionTemplate) {
        if let i = templates.firstIndex(where: { $0.id == t.id }) {
            templates[i] = t
            save()
        }
    }

    /// First-run seed — useful starting points.
    private static let seed: [SessionTemplate] = [
        SessionTemplate(
            name: "Quick question",
            icon: "bubble.left",
            model: "claude-haiku-4-5-20251001",
            kind: "chat"
        ),
        SessionTemplate(
            name: "Code review",
            icon: "checkmark.shield",
            model: "claude-sonnet-4-6",
            kind: "code",
            mode: "plan",
            permissions: "ask",
            sessionInstructions: "You're reviewing code. Focus on correctness, performance, security, and readability. Flag issues with severity. Don't make changes — just review."
        ),
        SessionTemplate(
            name: "Deep build",
            icon: "hammer",
            model: "claude-opus-4-6",
            kind: "code",
            mode: "build",
            permissions: "bypass"
        ),
    ]
}
