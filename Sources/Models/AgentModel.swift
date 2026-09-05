import Foundation
import SwiftUI

enum ModelProvider: String, Sendable, Codable {
    case codex, opencode
    var assistantName: String { label }
    var label: String { self == .codex ? "Codex" : "OpenCode" }
}

enum ModelBrand: Sendable {
    case chatgpt, codex
}

/// Persist the model slug, while keeping the selectable catalog independent of releases.
struct AgentModel: RawRepresentable, Hashable, Sendable, Codable, Identifiable, CaseIterable {
    let rawValue: String

    init?(rawValue: String) {
        guard (rawValue.hasPrefix("gpt-") || rawValue.hasPrefix("opencode:") && rawValue.contains("/")),
              !rawValue.contains(where: { $0.isWhitespace }),
              !rawValue.localizedCaseInsensitiveContains("claude"),
              !rawValue.localizedCaseInsensitiveContains("anthropic") else { return nil }
        self.rawValue = rawValue
    }

    init(from decoder: Decoder) throws {
        let slug = try decoder.singleValueContainer().decode(String.self)
        self = Self(rawValue: slug) ?? .defaultModel
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    static let gpt6Astra = Self(rawValue: "gpt-6-astra")!
    static let gpt55 = Self(rawValue: "gpt-5.5")!
    static let gpt54 = Self(rawValue: "gpt-5.4")!
    static let gpt54Mini = Self(rawValue: "gpt-5.4-mini")!
    static let gpt53Codex = Self(rawValue: "gpt-5.3-codex")!
    static let gpt53CodexSpark = Self(rawValue: "gpt-5.3-codex-spark")!
    static let defaultModel = gpt6Astra
    static var allCases: [Self] { groupedByProvider.flatMap(\.models) }
    static let olderModels: [Self] = [.gpt54, .gpt53Codex, Self(rawValue: "gpt-5.2")!, Self(rawValue: "gpt-5.1-codex-max")!]
    struct Group: Identifiable {
        let id: String
        let label: String
        let provider: ModelProvider
        let models: [AgentModel]
    }
    static var groupedByProvider: [Group] {
        [
            Group(id: "current", label: "Codex", provider: .codex, models: ModelCatalog.shared.models.map(\.model)),
            Group(id: "older", label: "Older models", provider: .codex, models: olderModels.filter { old in !ModelCatalog.shared.models.contains { $0.model == old } }),
            Group(id: "opencode", label: "OpenCode", provider: .opencode, models: OpenCodeModels.shared.models)
        ].filter { !$0.models.isEmpty }
    }

    var id: String { rawValue }
    var fullId: String { rawValue }
    var provider: ModelProvider { rawValue.hasPrefix("opencode:") ? .opencode : .codex }
    var cliModel: String { provider == .opencode ? String(rawValue.dropFirst(9)) : rawValue }
    var brand: ModelBrand {
        let slug = cliModel.split(separator: "/").last.map(String.init) ?? cliModel
        return provider == .codex || cliModel.hasPrefix("openai/") || slug.hasPrefix("gpt-") ? .chatgpt : .codex
    }
    var assistantName: String { label }
    var providerDisplayName: String { provider.label }
    private var descriptor: ModelDescriptor? {
        (provider == .opencode ? OpenCodeModels.shared.descriptors : ModelCatalog.shared.models).first { $0.model == self }
    }
    var label: String { descriptor?.displayName ?? cliModel }
    var shortLabel: String { label.replacingOccurrences(of: "GPT-", with: "") }
    var tier: String { descriptor?.description ?? provider.label }
    var contextWindow: Int { descriptor?.contextWindow ?? 272_000 }
    var extendedContextWindow: Int? { nil }
    var supportsExtendedContext: Bool { false }
    var supportsOpenAIFastMode: Bool { false }
    var tint: Color { Color.kilnAccent }
    var reasoningEfforts: [String] { descriptor?.efforts ?? (provider == .opencode ? [] : ["low", "medium", "high", "xhigh"]) }
}

struct ModelDescriptor: Sendable {
    let model: AgentModel
    let displayName: String
    let description: String
    let contextWindow: Int
    let efforts: [String]
}

final class ModelCatalog: @unchecked Sendable {
    static let shared = ModelCatalog()
    private let lock = NSLock()
    private var snapshot: [ModelDescriptor] = []
    private(set) var loadedFromCache = false

    var models: [ModelDescriptor] {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }

    static var codexHome: URL {
        if let path = ProcessInfo.processInfo.environment["CODEX_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }

    init() { reload() }

    func reload() {
        let data = try? Data(contentsOf: Self.codexHome.appendingPathComponent("models_cache.json"))
        let parsed = data.flatMap(Self.parse) ?? []
        let fallback: [ModelDescriptor] = [
            .init(model: .gpt6Astra, displayName: "GPT-6 Astra", description: "Complex coding and reasoning", contextWindow: 272_000, efforts: ["low", "medium", "high", "xhigh", "max", "ultra"]),
            .init(model: .gpt55, displayName: "GPT-5.5", description: "Coding and general work", contextWindow: 272_000, efforts: ["low", "medium", "high", "xhigh"]),
            .init(model: .gpt54Mini, displayName: "GPT-5.4 Mini", description: "Smaller, faster tasks", contextWindow: 272_000, efforts: ["low", "medium", "high", "xhigh"])
        ]
        lock.lock()
        snapshot = parsed.isEmpty ? fallback : parsed
        loadedFromCache = !parsed.isEmpty
        lock.unlock()
    }

    static func parse(_ data: Data) -> [ModelDescriptor]? {
        struct Envelope: Decodable { let models: [Entry] }
        struct Entry: Decodable {
            let slug: String
            let display_name: String?
            let description: String?
            let visibility: String?
            let context_window: Int?
            let supported_reasoning_levels: [Effort]?
        }
        struct Effort: Decodable { let effort: String }
        guard let envelope = try? JSONDecoder().decode(Envelope.self, from: data) else { return nil }
        var seen = Set<String>()
        return envelope.models.compactMap { entry in
            guard entry.visibility == "list", let model = AgentModel(rawValue: entry.slug),
                  seen.insert(entry.slug).inserted else { return nil }
            return ModelDescriptor(model: model, displayName: entry.display_name ?? entry.slug,
                description: entry.description ?? "Codex model",
                contextWindow: max(1, entry.context_window ?? 272_000),
                efforts: entry.supported_reasoning_levels?.map(\.effort) ?? ["low", "medium", "high", "xhigh"])
        }
    }
}
