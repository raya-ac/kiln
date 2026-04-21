import Foundation

/// Saved prompt snippets the user can drop into the composer. Distinct
/// from `SessionTemplate` (which configures new sessions) — these are
/// just reusable pieces of prompt text invoked via `/template <name>`.
struct PromptTemplate: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var name: String        // short key used in /template <name>
    var body: String        // the actual prompt text
    var description: String // one-line hint shown in pickers

    init(id: String = UUID().uuidString, name: String, body: String, description: String = "") {
        self.id = id
        self.name = name
        self.body = body
        self.description = description
    }
}

@MainActor
final class PromptTemplateStore: ObservableObject {
    static let shared = PromptTemplateStore()
    private let key = "promptTemplates.v1"

    @Published var templates: [PromptTemplate] = []

    init() { load() }

    func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([PromptTemplate].self, from: data)
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

    func add(_ t: PromptTemplate) { templates.append(t); save() }
    func remove(_ id: String) { templates.removeAll { $0.id == id }; save() }
    func update(_ t: PromptTemplate) {
        if let i = templates.firstIndex(where: { $0.id == t.id }) {
            templates[i] = t
            save()
        }
    }

    /// Lookup by user-facing name (case-insensitive). Returns the first
    /// match — templates aren't guaranteed unique by name, but the
    /// picker sorts alphabetically so collisions are visible.
    func template(named name: String) -> PromptTemplate? {
        let needle = name.lowercased()
        return templates.first { $0.name.lowercased() == needle }
    }

    private static let seed: [PromptTemplate] = [
        PromptTemplate(
            name: "review",
            body: "Review the recent changes for correctness, edge cases, and readability. Flag anything surprising.",
            description: "Ask Claude to review recent changes"
        ),
        PromptTemplate(
            name: "explain",
            body: "Walk me through how this works, layer by layer. Don't skip the plumbing.",
            description: "Deep walk-through of the current file"
        ),
        PromptTemplate(
            name: "tests",
            body: "Write tests for the last thing we changed. Cover happy path, edge cases, and at least one failure mode.",
            description: "Generate tests for recent changes"
        ),
    ]
}
