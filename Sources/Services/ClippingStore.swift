import Foundation

/// User-curated clippings of assistant responses. Saved to disk so they
/// survive restarts. Can be recalled into the composer via the snippets
/// popover (they appear alongside regular snippets with a distinct icon).
struct Clipping: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var title: String
    var body: String
    let sourceSessionId: String?
    let sourceMessageId: String?
    let savedAt: Date

    init(id: String = UUID().uuidString, title: String, body: String, sourceSessionId: String? = nil, sourceMessageId: String? = nil, savedAt: Date = .now) {
        self.id = id
        self.title = title
        self.body = body
        self.sourceSessionId = sourceSessionId
        self.sourceMessageId = sourceMessageId
        self.savedAt = savedAt
    }
}

@MainActor
final class ClippingStore: ObservableObject {
    static let shared = ClippingStore()
    private let key = "clippings.v1"
    @Published var items: [Clipping] = []

    init() { load() }

    func load() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([Clipping].self, from: data) {
            items = decoded
        }
    }

    func save() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func add(_ c: Clipping) {
        items.insert(c, at: 0)
        save()
    }

    func remove(_ id: String) {
        items.removeAll { $0.id == id }
        save()
    }
}
