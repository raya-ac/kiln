import Foundation
import SwiftUI

// MARK: - Prompt History Store
//
// Keeps a rolling list of the last 50 user prompts. The composer recalls them
// with ↑/↓ when the input is empty (or when the user starts arrow-browsing).
// Backed by UserDefaults so history survives across launches.

@MainActor
final class PromptHistoryStore: ObservableObject {
    static let shared = PromptHistoryStore()

    @Published private(set) var entries: [String] = []

    private let key = "prompt.history.v1"
    private let maxEntries = 50

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let arr = try? JSONDecoder().decode([String].self, from: data) {
            entries = arr
        }
    }

    func record(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Deduplicate: if already present, move to front.
        entries.removeAll { $0 == trimmed }
        entries.insert(trimmed, at: 0)
        if entries.count > maxEntries { entries = Array(entries.prefix(maxEntries)) }
        persist()
    }

    func clear() {
        entries = []
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
