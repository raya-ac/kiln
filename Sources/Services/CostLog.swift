import Foundation

/// Rolling per-day + per-session spend log. Persisted to UserDefaults so it
/// survives restarts. Append-only from the AppStore's cost events; read by
/// the stats dashboard.
struct CostEntry: Codable, Hashable, Sendable {
    let date: Date
    let sessionId: String
    let sessionName: String
    let model: String
    let usd: Double
    let inputTokens: Int
    let outputTokens: Int
}

@MainActor
final class CostLog: ObservableObject {
    static let shared = CostLog()
    private let key = "costLog.v1"
    /// Hard cap — prevents unbounded growth. Oldest entries drop when we
    /// exceed this; matters for heavy users over months.
    private let maxEntries = 5000

    @Published private(set) var entries: [CostEntry] = []

    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([CostEntry].self, from: data) {
            entries = decoded
        }
    }

    func append(sessionId: String, sessionName: String, model: String, usd: Double, inputTokens: Int, outputTokens: Int) {
        guard usd > 0 else { return }
        let entry = CostEntry(
            date: .now,
            sessionId: sessionId,
            sessionName: sessionName,
            model: model,
            usd: usd,
            inputTokens: inputTokens,
            outputTokens: outputTokens
        )
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    /// Clear the entire log — shown in settings as a "reset" button.
    func clear() {
        entries.removeAll()
        save()
    }

    // MARK: - Derived

    /// Spend for the last `days` days, keyed by start-of-day. Zero-fills gaps.
    func dailySpend(days: Int = 30) -> [(date: Date, usd: Double)] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        guard let from = cal.date(byAdding: .day, value: -(days - 1), to: today) else { return [] }
        var buckets: [Date: Double] = [:]
        for entry in entries where entry.date >= from {
            let d = cal.startOfDay(for: entry.date)
            buckets[d, default: 0] += entry.usd
        }
        return (0..<days).compactMap { offset -> (Date, Double)? in
            guard let d = cal.date(byAdding: .day, value: offset, to: from) else { return nil }
            return (d, buckets[d] ?? 0)
        }
    }

    func totalSpend() -> Double {
        entries.reduce(0) { $0 + $1.usd }
    }

    func spendThisMonth() -> Double {
        let cal = Calendar.current
        let startOfMonth = cal.date(from: cal.dateComponents([.year, .month], from: .now)) ?? .now
        return entries.filter { $0.date >= startOfMonth }.reduce(0) { $0 + $1.usd }
    }

    func spendByModel() -> [(model: String, usd: Double)] {
        var buckets: [String: Double] = [:]
        for entry in entries { buckets[entry.model, default: 0] += entry.usd }
        return buckets.map { ($0.key, $0.value) }.sorted { $0.1 > $1.1 }
    }

    func spendBySession(limit: Int = 10) -> [(sessionName: String, usd: Double)] {
        var buckets: [String: (name: String, usd: Double)] = [:]
        for entry in entries {
            let cur = buckets[entry.sessionId] ?? (entry.sessionName, 0)
            buckets[entry.sessionId] = (entry.sessionName, cur.usd + entry.usd)
        }
        return buckets.values
            .map { ($0.name, $0.usd) }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { ($0.0, $0.1) }
    }
}
