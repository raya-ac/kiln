import SwiftUI
import MarkdownUI
import AppKit
import Observation

// MARK: - Agent Trace

struct AgentTraceRow: View {
    let entries: [AgentTraceEntry]
    var live: Bool = false
    @State private var expanded = false
    @State private var query = ""
    @State private var issuesOnly = false
    @State private var visibleCount = 40
    @Environment(\.transcriptDisclosureAction) private var onDisclosure

    private var filteredEntries: [AgentTraceEntry] {
        entries.filter { entry in
            (!issuesOnly || entry.level == .error || entry.level == .warning)
            && (query.isEmpty || "\(entry.title) \(entry.phase) \(entry.detail)".localizedCaseInsensitiveContains(query))
        }
    }

    private var visibleEntries: [AgentTraceEntry] {
        Array(filteredEntries.suffix(expanded ? visibleCount : 3))
    }

    private var errorCount: Int {
        entries.filter { $0.level == .error }.count
    }

    private var warningCount: Int {
        entries.filter { $0.level == .warning }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { onDisclosure(); expanded.toggle() } label: {
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
            .accessibilityLabel("Run log, \(entries.count) events")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")

            if expanded {
                HStack {
                    TextField("Filter run log", text: $query).textFieldStyle(.plain)
                    Toggle("Issues", isOn: $issuesOnly).toggleStyle(.checkbox)
                    Button {
                        let text = filteredEntries.map { "[\($0.level.rawValue)] \($0.title)\n\($0.detail)" }.joined(separator: "\n")
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    } label: { Image(systemName: "doc.on.doc") }
                    .help("Copy filtered log")
                }.font(.system(size: 11)).padding(.top, 10)
                if filteredEntries.count > visibleCount {
                    Button("Show earlier events") { visibleCount += 40 }
                        .buttonStyle(.borderless).font(.system(size: 11))
                }
            }
            if expanded || live {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(visibleEntries) { entry in
                            AgentTraceEntryRow(entry: entry)
                        }
                    }
                }
                .frame(height: expanded ? 240 : min(100, CGFloat(visibleEntries.count) * 44))
                .padding(.top, 8)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, expanded ? 10 : 0)
        .background(expanded ? Color.kilnSurface : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
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
    @State private var expanded = false

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
                if !entry.detail.isEmpty || !entry.metadata.isEmpty {
                    Button { expanded.toggle() } label: {
                        Label("Details", systemImage: expanded ? "chevron.down" : "chevron.right")
                    }
                    .buttonStyle(.plain).font(.system(size: 10))
                    .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                }
                if expanded && !entry.detail.isEmpty {
                    Text(ToolPresentation.preview(entry.detail))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.kilnTextTertiary)
                        .textSelection(.enabled)
                }
                if expanded && !entry.metadata.isEmpty {
                    Text(ToolPresentation.preview(entry.metadata.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "  ")))
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

// MARK: - Tool Activity

/// A disclosure is a reading action, not a request to follow streamed output.
private struct TranscriptDisclosureActionKey: EnvironmentKey {
    static let defaultValue: @MainActor @Sendable () -> Void = {}
}

@Observable
@MainActor
final class ToolDisclosureState {
    var groups: Set<String> = []
    var calls: Set<String> = []
    var outputs: Set<String> = []
}

private struct ToolDisclosureStateKey: EnvironmentKey {
    static let defaultValue: ToolDisclosureState? = nil
}

extension EnvironmentValues {
    var toolDisclosureState: ToolDisclosureState? {
        get { self[ToolDisclosureStateKey.self] }
        set { self[ToolDisclosureStateKey.self] = newValue }
    }

    var transcriptDisclosureAction: @MainActor @Sendable () -> Void {
        get { self[TranscriptDisclosureActionKey.self] }
        set { self[TranscriptDisclosureActionKey.self] = newValue }
    }
}

struct ToolActivityGroup: View {
    let tools: [ToolUseBlock]
    var live = false
    var namespace = ""
    @State private var localDisclosures = ToolDisclosureState()
    @State private var pageEnd: Int?
    @Environment(\.transcriptDisclosureAction) private var onDisclosure
    @Environment(\.toolDisclosureState) private var sharedDisclosures

    private var disclosures: ToolDisclosureState { sharedDisclosures ?? localDisclosures }
    private var groupID: String { key(tools.first?.id ?? "") }
    private func key(_ id: String) -> String { ToolPresentation.disclosureID(messageID: namespace, toolID: id) }
    private var expanded: Bool { disclosures.groups.contains(groupID) }

    private var calls: [ToolUseBlock] { ToolPresentation.uniqueCalls(tools) }
    private var failures: Int { calls.filter(\.isError).count }
    private var unconfirmed: Int {
        calls.filter { ToolPresentation(tool: $0, live: live).status == .unconfirmed }.count
    }
    private var active: ToolUseBlock? {
        calls.last { [.pending, .running].contains(ToolPresentation(tool: $0, live: live).status) }
    }

    var body: some View {
        let end = min(pageEnd ?? calls.count, calls.count)
        let start = max(0, end - ToolPresentation.pageSize)
        VStack(alignment: .leading, spacing: 6) {
            if calls.count == 1, let call = calls.first {
                activity(call)
            } else if !calls.isEmpty {
                Button {
                    onDisclosure()
                    if expanded { disclosures.groups.remove(groupID) } else { disclosures.groups.insert(groupID) }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right").frame(width: 12)
                        Image(systemName: "wrench.and.screwdriver")
                        Text("\(calls.count) tool calls")
                        if let active {
                            Text(active.name).lineLimit(1).foregroundStyle(Color.kilnTextTertiary)
                        }
                        Spacer(minLength: 4)
                        if failures > 0 {
                            Label("\(failures) failed", systemImage: "xmark.circle")
                                .foregroundStyle(Color.kilnError)
                        } else if unconfirmed > 0 {
                            Label("\(unconfirmed) unconfirmed", systemImage: "questionmark.circle")
                                .foregroundStyle(Color.kilnWarning)
                        }
                    }
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.kilnTextSecondary)
                    .frame(minHeight: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(expanded ? "Collapse tool activity" : "Expand tool activity")
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")

                if expanded {
                    if calls.count > ToolPresentation.pageSize {
                        HStack {
                            Button {
                                onDisclosure()
                                pageEnd = start
                            } label: { Image(systemName: "chevron.up") }
                            .disabled(start == 0).help("Earlier tool calls").accessibilityLabel("Earlier tool calls")
                            Text("\(start + 1)-\(end) of \(calls.count)").monospacedDigit()
                            Button {
                                onDisclosure()
                                let next = min(calls.count, end + ToolPresentation.pageSize)
                                pageEnd = next == calls.count ? nil : next
                            } label: { Image(systemName: "chevron.down") }
                            .disabled(end == calls.count).help("Later tool calls").accessibilityLabel("Later tool calls")
                            Spacer()
                        }
                        .font(.system(size: 10)).buttonStyle(.borderless)
                        .foregroundStyle(Color.kilnTextTertiary)
                    }
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(calls[start..<end])) { activity($0) }
                        }
                    }
                    .frame(height: calls[start..<end].contains { disclosures.calls.contains(key($0.id)) }
                           ? 288 : min(288, CGFloat(end - start) * 44))
                } else if let active {
                    activity(active)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func activity(_ tool: ToolUseBlock) -> some View {
        ToolActivityRow(presentation: .init(tool: tool, live: live), expanded: Binding(
            get: { disclosures.calls.contains(key(tool.id)) },
            set: { value in
                onDisclosure()
                if value { disclosures.calls.insert(key(tool.id)) } else { disclosures.calls.remove(key(tool.id)) }
            }), outputExpanded: Binding(
                get: { disclosures.outputs.contains(key(tool.id)) },
                set: { value in
                    if value { disclosures.outputs.insert(key(tool.id)) } else { disclosures.outputs.remove(key(tool.id)) }
                }))
    }
}

private struct ToolActivityRow: View {
    let presentation: ToolPresentation
    @Binding var expanded: Bool
    @Binding var outputExpanded: Bool
    @EnvironmentObject private var store: AppStore
    @Environment(\.transcriptDisclosureAction) private var onDisclosure

    private var tool: ToolUseBlock { presentation.tool }
    private var statusColor: Color {
        switch presentation.status {
        case .failure: Color.kilnError
        case .success: Color.kilnSuccess
        case .unconfirmed: Color.kilnWarning
        default: Color.kilnTextTertiary
        }
    }

    var body: some View {
        let summary = presentation.summary
        VStack(alignment: .leading, spacing: 6) {
            Button { expanded.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: presentation.symbol).frame(width: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(tool.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                        if !summary.isEmpty {
                            Text(summary).font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Color.kilnTextTertiary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 4)
                    if let duration = presentation.duration {
                        Text(String(format: "%.1fs", duration)).font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color.kilnTextTertiary)
                    }
                    Label(presentation.status.label, systemImage: presentation.status.symbol)
                        .font(.system(size: 10)).foregroundStyle(statusColor)
                        .fixedSize()
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9)).frame(width: 12)
                }
                .foregroundStyle(Color.kilnTextSecondary)
                .padding(.vertical, 5).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(tool.name), \(summary), \(presentation.status.label)")
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .help(expanded ? "Collapse tool details" : "Expand tool details")

            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    if !tool.input.isEmpty {
                        ToolTextOutput(title: "Input", text: tool.input)
                        if tool.input.utf8.count <= ToolPresentation.inputParseLimit,
                           let diff = EditDiffParser.parse(toolName: tool.name, rawInput: tool.input) {
                            ScrollView { EditDiffView(diff: diff) }.frame(height: 200)
                        }
                    }
                    if let path = presentation.imagePath, let media = MediaReference.make(source: path) {
                        InlineMediaView(media: media, workDir: store.activeSession?.workDir ?? NSHomeDirectory())
                            .id(tool.completedAt)
                    }
                    if let result = tool.result {
                        Button {
                            onDisclosure()
                            outputExpanded.toggle()
                        } label: {
                            Label("Output", systemImage: outputExpanded ? "chevron.down" : "chevron.right")
                        }
                        .font(.system(size: 11)).buttonStyle(.plain)
                        .accessibilityValue(outputExpanded ? "Expanded" : "Collapsed")
                        if outputExpanded { ToolTextOutput(title: "Output", text: result) }
                    } else {
                        Text(presentation.status == .unconfirmed ? "No completion result was recorded." : "Waiting for a result.")
                            .font(.system(size: 11)).foregroundStyle(Color.kilnTextTertiary)
                    }
                }
                .padding(.leading, 24)
                .padding(.bottom, 8)
            }
        }
    }
}

/// Rendering is capped, even for megabyte terminal output. Copy always retains the full receipt.
struct ToolTextOutput: View {
    let title: String
    let text: String
    @State private var limit = ToolPresentation.outputPageSize
    @Environment(\.transcriptDisclosureAction) private var onDisclosure

    var body: some View {
        let preview = ToolPresentation.preview(text, limit: limit)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.system(size: 10, weight: .medium))
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless).help("Copy full \(title.lowercased())")
                .accessibilityLabel("Copy full \(title.lowercased())")
            }
            ScrollView {
                Text(text.isEmpty ? "Empty output" : preview)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: min(200, max(44, CGFloat(preview.count / 72 + preview.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }) * 15)))
            if preview.utf8.count < text.utf8.count {
                HStack {
                    Text("Preview truncated").font(.system(size: 10))
                    if limit < ToolPresentation.maximumPreviewSize {
                        Button("Show more") { onDisclosure(); limit += ToolPresentation.outputPageSize }
                            .font(.system(size: 10)).buttonStyle(.borderless)
                    }
                }
            }
        }
        .foregroundStyle(Color.kilnTextSecondary)
        .padding(8).background(Color.kilnSurface)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
