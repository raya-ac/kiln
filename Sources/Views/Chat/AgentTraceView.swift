import SwiftUI
import MarkdownUI
import AppKit

// MARK: - Agent Trace

struct AgentTraceRow: View {
    let entries: [AgentTraceEntry]
    var live: Bool = false
    @State private var expanded = false
    @State private var query = ""
    @State private var issuesOnly = false

    private var visibleEntries: [AgentTraceEntry] {
        let filtered = entries.filter { entry in
            (!issuesOnly || entry.level == .error || entry.level == .warning)
            && (query.isEmpty || "\(entry.title) \(entry.phase) \(entry.detail)".localizedCaseInsensitiveContains(query))
        }
        return expanded ? filtered : Array(filtered.suffix(5))
    }

    private var errorCount: Int {
        entries.filter { $0.level == .error }.count
    }

    private var warningCount: Int {
        entries.filter { $0.level == .warning }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.kilnTextTertiary)
                        .frame(width: 12)
                    Image(systemName: live ? "waveform.path.ecg" : "list.bullet.rectangle")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(headerColor)
                    Text("Run log")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.kilnTextSecondary)
                    Text("\(entries.count)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.kilnTextTertiary)
                    if warningCount > 0 {
                        TraceBadge(text: "\(warningCount) warn", color: Color.kilnWarning)
                    }
                    if errorCount > 0 {
                        TraceBadge(text: "\(errorCount) err", color: Color.kilnError)
                    }
                    Spacer()
                    if live {
                        Text("live")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.kilnAccent)
                    }
                }
            }
            .buttonStyle(.plain)

            if expanded {
                HStack {
                    TextField("Filter run log", text: $query).textFieldStyle(.plain)
                    Toggle("Issues", isOn: $issuesOnly).toggleStyle(.checkbox)
                    Button {
                        let text = visibleEntries.map { "[\($0.level.rawValue)] \($0.title)\n\($0.detail)" }.joined(separator: "\n")
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                    .help("Copy filtered log")
                }.font(.system(size: 11)).padding(.top, 10)
            }
            if expanded || live {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(visibleEntries) { entry in
                        AgentTraceEntryRow(entry: entry)
                    }
                }
                .padding(.top, 8)
            }
        }
        .padding(10)
        .background(Color.kilnSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.kilnBorderSubtle, lineWidth: 1))
    }

    private var headerColor: Color {
        if errorCount > 0 { return Color.kilnError }
        if warningCount > 0 { return Color.kilnWarning }
        return live ? Color.kilnAccent : Color.kilnTextTertiary
    }
}

private struct TraceBadge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

private struct AgentTraceEntryRow: View {
    let entry: AgentTraceEntry

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.phase)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(color)
                    Text(entry.title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.kilnTextSecondary)
                        .lineLimit(1)
                    Spacer()
                    Text(entry.timestamp.formatted(.dateTime.hour().minute().second()))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Color.kilnTextTertiary)
                }
                if !entry.detail.isEmpty {
                    Text(entry.detail)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.kilnTextTertiary)
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                if !entry.metadata.isEmpty {
                    Text(entry.metadata.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "  "))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Color.kilnTextTertiary.opacity(0.8))
                        .lineLimit(2)
                }
            }
        }
        .padding(7)
        .background(Color.kilnBg.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var icon: String {
        switch entry.level {
        case .debug: "ladybug"
        case .info: "info.circle"
        case .success: "checkmark.circle"
        case .warning: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }

    private var color: Color {
        switch entry.level {
        case .debug: Color.kilnTextTertiary
        case .info: Color.kilnAccent
        case .success: Color.kilnSuccess
        case .warning: Color.kilnWarning
        case .error: Color.kilnError
        }
    }
}
