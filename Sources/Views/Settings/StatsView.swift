import SwiftUI

// MARK: - Stats View

struct StatsView: View {
    @EnvironmentObject var store: AppStore

    private var stats: KilnStats { KilnStats.compute(from: store.sessions) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Hero: total time chatted
                HeroStatCard(
                    title: "Time in Kiln",
                    value: stats.formattedTotalHours,
                    subtitle: stats.totalSessions == 0 ? "no sessions yet" : "\(stats.totalSessions) sessions, \(stats.totalMessages) messages",
                    icon: "clock.fill",
                    tint: Color.kilnAccent
                )

                // Top row: quick stats
                HStack(spacing: 10) {
                    StatCard(
                        label: store.settings.language.ui.statsMessages,
                        value: "\(stats.totalMessages)",
                        hint: stats.totalSessions > 0 ? "avg \(stats.avgMessagesPerSession)/sess" : "—",
                        icon: "bubble.left.and.bubble.right.fill",
                        tint: .blue
                    )
                    StatCard(
                        label: store.settings.language.ui.statsStreak,
                        value: "\(stats.streakDays)d",
                        hint: stats.streakDays > 0 ? "keep it going" : "start today",
                        icon: "flame.fill",
                        tint: Color(hex: 0xF97316)
                    )
                    StatCard(
                        label: store.settings.language.ui.statsActiveDays,
                        value: "\(stats.activeDays)",
                        hint: stats.firstDate.map { "since \(Self.short.string(from: $0))" } ?? "—",
                        icon: "calendar",
                        tint: .purple
                    )
                }

                // Session breakdown
                SettingsSection(title: store.settings.language.ui.statsSessions) {
                    HStack(spacing: 14) {
                        MiniStat(label: "Code", value: "\(stats.codeSessions)", color: Color.kilnAccent)
                        Divider().frame(height: 22)
                        MiniStat(label: "Chat", value: "\(stats.chatSessions)", color: .blue)
                        Divider().frame(height: 22)
                        MiniStat(label: "Avg length", value: stats.avgSessionDuration, color: .purple)
                        Spacer()
                    }

                    // Bar: code vs chat ratio
                    if stats.totalSessions > 0 {
                        GeometryReader { geo in
                            let codeW = geo.size.width * Double(stats.codeSessions) / Double(stats.totalSessions)
                            HStack(spacing: 2) {
                                Rectangle()
                                    .fill(Color.kilnAccent)
                                    .frame(width: max(codeW, 0))
                                Rectangle()
                                    .fill(Color.blue)
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                        }
                        .frame(height: 6)
                    }
                }

                // Model usage
                if !stats.modelUsage.isEmpty {
                    SettingsSection(title: store.settings.language.ui.statsModels) {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(stats.modelUsage, id: \.model) { row in
                                ModelUsageRow(
                                    model: row.model,
                                    count: row.count,
                                    total: stats.totalSessions
                                )
                            }
                        }
                    }
                }

                // Current session live stats
                if store.totalCost > 0 || store.inputTokens + store.outputTokens > 0 {
                    SettingsSection(title: "This session") {
                        HStack(spacing: 14) {
                            MiniStat(label: "Input", value: formatTokens(store.inputTokens), color: Color.kilnTextSecondary)
                            Divider().frame(height: 22)
                            MiniStat(label: "Output", value: formatTokens(store.outputTokens), color: Color.kilnTextSecondary)
                            Divider().frame(height: 22)
                            MiniStat(label: "Cost", value: String(format: "$%.3f", store.totalCost), color: Color.kilnAccent)
                            Spacer()
                        }
                    }
                }

                // Spend dashboard — persistent per-session / per-day / per-model
                CostDashboardSection()

                // Achievements
                SettingsSection(title: "Milestones") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Milestone.all, id: \.title) { m in
                            MilestoneRow(
                                milestone: m,
                                progress: m.progress(stats),
                                achieved: m.achieved(stats)
                            )
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    private static let short: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }
}

// MARK: - Stats model

struct KilnStats {
    var totalSessions: Int = 0
    var codeSessions: Int = 0
    var chatSessions: Int = 0
    var totalMessages: Int = 0
    var totalHours: Double = 0
    var streakDays: Int = 0
    var activeDays: Int = 0
    var firstDate: Date?
    var avgSessionSeconds: Double = 0
    var modelUsage: [ModelUsageRowData] = []

    var avgMessagesPerSession: Int {
        totalSessions == 0 ? 0 : totalMessages / totalSessions
    }

    var formattedTotalHours: String {
        if totalHours >= 1 {
            return String(format: "%.1fh", totalHours)
        }
        let mins = Int(totalHours * 60)
        return "\(mins)m"
    }

    var avgSessionDuration: String {
        let secs = Int(avgSessionSeconds)
        if secs >= 3600 { return String(format: "%.1fh", Double(secs) / 3600) }
        if secs >= 60 { return "\(secs / 60)m" }
        return "\(secs)s"
    }

    static func compute(from sessions: [Session]) -> KilnStats {
        var s = KilnStats()
        s.totalSessions = sessions.count
        s.codeSessions = sessions.filter { $0.kind == .code }.count
        s.chatSessions = sessions.filter { $0.kind == .chat }.count

        var totalMsgs = 0
        var totalSpan: TimeInterval = 0
        var spansCounted = 0
        var activeDaySet = Set<DateComponents>()
        var earliest: Date?

        let cal = Calendar.current

        for session in sessions {
            totalMsgs += session.messages.count

            if let first = session.messages.first, let last = session.messages.last, first.id != last.id {
                let span = last.timestamp.timeIntervalSince(first.timestamp)
                if span > 0 {
                    totalSpan += span
                    spansCounted += 1
                }
            }

            for msg in session.messages {
                let dc = cal.dateComponents([.year, .month, .day], from: msg.timestamp)
                activeDaySet.insert(dc)
                if earliest == nil || msg.timestamp < earliest! {
                    earliest = msg.timestamp
                }
            }
            if earliest == nil || session.createdAt < (earliest ?? .distantFuture) {
                earliest = session.createdAt
            }
        }

        s.totalMessages = totalMsgs
        s.totalHours = totalSpan / 3600
        s.activeDays = activeDaySet.count
        s.firstDate = earliest
        if spansCounted > 0 {
            s.avgSessionSeconds = totalSpan / Double(spansCounted)
        }

        // Streak — consecutive days ending today (or yesterday) with activity
        s.streakDays = computeStreak(activeDays: activeDaySet, calendar: cal)

        // Model usage
        var modelCounts: [ClaudeModel: Int] = [:]
        for session in sessions {
            modelCounts[session.model, default: 0] += 1
        }
        s.modelUsage = modelCounts
            .map { ModelUsageRowData(model: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }

        return s
    }

    private static func computeStreak(activeDays: Set<DateComponents>, calendar: Calendar) -> Int {
        guard !activeDays.isEmpty else { return 0 }
        let today = calendar.dateComponents([.year, .month, .day], from: Date())
        var streak = 0
        var cursor = today
        // If today has no activity, allow starting from yesterday
        if !activeDays.contains(cursor) {
            if let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.date(from: cursor)!) {
                cursor = calendar.dateComponents([.year, .month, .day], from: yesterday)
                if !activeDays.contains(cursor) { return 0 }
            }
        }
        while activeDays.contains(cursor) {
            streak += 1
            guard let prev = calendar.date(byAdding: .day, value: -1, to: calendar.date(from: cursor)!) else { break }
            cursor = calendar.dateComponents([.year, .month, .day], from: prev)
        }
        return streak
    }
}

struct ModelUsageRowData: Equatable {
    let model: ClaudeModel
    let count: Int
}

// MARK: - Milestones

struct Milestone: @unchecked Sendable {
    let title: String
    let icon: String
    let tint: Color
    let target: Int
    let valueSelector: (KilnStats) -> Int

    func achieved(_ stats: KilnStats) -> Bool {
        valueSelector(stats) >= target
    }

    func progress(_ stats: KilnStats) -> Double {
        min(1.0, Double(valueSelector(stats)) / Double(target))
    }

    func currentValue(_ stats: KilnStats) -> Int {
        valueSelector(stats)
    }

    static let all: [Milestone] = [
        Milestone(title: "First chat", icon: "sparkles", tint: .purple, target: 1, valueSelector: { $0.totalSessions }),
        Milestone(title: "10 sessions", icon: "bolt.fill", tint: .blue, target: 10, valueSelector: { $0.totalSessions }),
        Milestone(title: "100 messages", icon: "bubble.left.fill", tint: Color.kilnAccent, target: 100, valueSelector: { $0.totalMessages }),
        Milestone(title: "1000 messages", icon: "bubbles.and.sparkles.fill", tint: .pink, target: 1000, valueSelector: { $0.totalMessages }),
        Milestone(title: "10 hour club", icon: "hourglass", tint: Color(hex: 0xF97316), target: 10, valueSelector: { Int($0.totalHours) }),
        Milestone(title: "7-day streak", icon: "flame.fill", tint: Color(hex: 0xFBBF24), target: 7, valueSelector: { $0.streakDays }),
        Milestone(title: "30 active days", icon: "calendar", tint: .green, target: 30, valueSelector: { $0.activeDays }),
    ]
}

// MARK: - Components

private struct HeroStatCard: View {
    let title: String
    let value: String
    let subtitle: String
    let icon: String
    let tint: Color

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(tint.opacity(0.15))
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.kilnTextTertiary)
                    .tracking(1)
                Text(value)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.kilnText)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.kilnTextSecondary)
            }
            Spacer()
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [tint.opacity(0.1), Color.kilnSurface],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(tint.opacity(0.25), lineWidth: 1))
    }
}

private struct StatCard: View {
    let label: String
    let value: String
    let hint: String
    let icon: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(tint)
                Text(label.uppercased())
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.kilnTextTertiary)
                    .tracking(0.8)
            }
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(Color.kilnText)
            Text(hint)
                .font(.system(size: 9))
                .foregroundStyle(Color.kilnTextTertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.kilnSurface)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.kilnBorder, lineWidth: 1))
    }
}

private struct MiniStat: View {
    let label: String
    let value: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Color.kilnTextTertiary)
                .tracking(0.8)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
        }
    }
}

private struct ModelUsageRow: View {
    let model: ClaudeModel
    let count: Int
    let total: Int

    private var fraction: Double {
        total == 0 ? 0 : Double(count) / Double(total)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(model.label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.kilnText)
                Spacer()
                Text("\(count)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.kilnTextSecondary)
                Text(String(format: "%.0f%%", fraction * 100))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.kilnTextTertiary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.kilnBg)
                    Rectangle().fill(Color.kilnAccent.opacity(0.8))
                        .frame(width: geo.size.width * fraction)
                }
                .clipShape(RoundedRectangle(cornerRadius: 2))
            }
            .frame(height: 4)
        }
    }
}

private struct MilestoneRow: View {
    let milestone: Milestone
    let progress: Double
    let achieved: Bool

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(achieved ? milestone.tint.opacity(0.2) : Color.kilnBg)
                Image(systemName: milestone.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(achieved ? milestone.tint : Color.kilnTextTertiary)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(milestone.title)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(achieved ? Color.kilnText : Color.kilnTextSecondary)
                    Spacer()
                    if achieved {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(milestone.tint)
                    } else {
                        Text("\(Int(progress * 100))%")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Color.kilnTextTertiary)
                    }
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.kilnBg)
                        Rectangle()
                            .fill(achieved ? milestone.tint : milestone.tint.opacity(0.6))
                            .frame(width: geo.size.width * progress)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 2))
                }
                .frame(height: 3)
            }
        }
    }
}

// MARK: - Cost Dashboard
//
// Persistent spend analysis: this-month total, 30-day chart, top sessions
// and models by cost. Reads from CostLog.shared which is appended to by
// AppStore whenever a `.cost` stream event arrives.

struct CostDashboardSection: View {
    @ObservedObject private var log = CostLog.shared
    @State private var showClearConfirm = false

    var body: some View {
        if log.entries.isEmpty {
            EmptyView()
        } else {
            SettingsSection(title: "SPEND") {
                // Totals row
                HStack(spacing: 14) {
                    MiniStat(label: "This month", value: String(format: "$%.2f", log.spendThisMonth()), color: Color.kilnAccent)
                    Divider().frame(height: 22)
                    MiniStat(label: "All time", value: String(format: "$%.2f", log.totalSpend()), color: Color.kilnTextSecondary)
                    Divider().frame(height: 22)
                    MiniStat(label: "Events", value: "\(log.entries.count)", color: Color.kilnTextSecondary)
                    Spacer()
                    Button {
                        showClearConfirm = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.kilnTextTertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear spend log")
                }

                // 30-day chart
                VStack(alignment: .leading, spacing: 6) {
                    Text("Last 30 days")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.kilnTextTertiary)
                        .tracking(0.5)
                    DailySpendChart(data: log.dailySpend(days: 30))
                        .frame(height: 70)
                }

                // By model
                let models = log.spendByModel()
                if !models.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("By model")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.kilnTextTertiary)
                            .tracking(0.5)
                        ForEach(models, id: \.model) { row in
                            spendRow(label: row.model, usd: row.usd, total: log.totalSpend())
                        }
                    }
                }

                // By session
                let top = log.spendBySession(limit: 8)
                if !top.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Top sessions")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.kilnTextTertiary)
                            .tracking(0.5)
                        ForEach(Array(top.enumerated()), id: \.offset) { _, row in
                            spendRow(label: row.sessionName, usd: row.usd, total: log.totalSpend())
                        }
                    }
                }
            }
            .alert("Clear spend log?", isPresented: $showClearConfirm) {
                Button("Clear", role: .destructive) { log.clear() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Deletes all stored cost events. Your current-session counter is unaffected.")
            }
        }
    }

    @ViewBuilder
    private func spendRow(label: String, usd: Double, total: Double) -> some View {
        let ratio = total > 0 ? usd / total : 0
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Color.kilnTextSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 140, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.kilnBg)
                    Rectangle().fill(Color.kilnAccent)
                        .frame(width: max(2, geo.size.width * ratio))
                }
                .clipShape(RoundedRectangle(cornerRadius: 2))
            }
            .frame(height: 6)
            Text(String(format: "$%.2f", usd))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.kilnText)
                .frame(width: 60, alignment: .trailing)
        }
    }
}

// Pure-SwiftUI bar chart. Small enough that Charts framework would be overkill.
struct DailySpendChart: View {
    let data: [(date: Date, usd: Double)]

    var body: some View {
        GeometryReader { geo in
            let maxVal = max(0.01, data.map(\.usd).max() ?? 0.01)
            let barSpacing: CGFloat = 2
            let barCount = CGFloat(data.count)
            let barWidth = max(1, (geo.size.width - (barCount - 1) * barSpacing) / barCount)

            HStack(alignment: .bottom, spacing: barSpacing) {
                ForEach(Array(data.enumerated()), id: \.offset) { _, entry in
                    let h = geo.size.height * CGFloat(entry.usd / maxVal)
                    Rectangle()
                        .fill(entry.usd > 0 ? Color.kilnAccent : Color.kilnSurfaceElevated)
                        .frame(width: barWidth, height: max(2, h))
                        .clipShape(RoundedRectangle(cornerRadius: 1))
                        .help("\(Self.dayLabel.string(from: entry.date)) — $\(String(format: "%.2f", entry.usd))")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }

    static let dayLabel: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()
}
