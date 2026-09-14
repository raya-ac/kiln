import SwiftUI

struct ThinkingRow: View {
    let text: String
    var isStreaming = false
    @EnvironmentObject private var store: AppStore

    var body: some View {
        ReasoningDisclosure(text: text, isStreaming: isStreaming,
            initiallyExpanded: !store.settings.thinkingCollapsedByDefault)
    }
}

struct ReasoningDisclosure: View {
    let text: String
    let isStreaming: Bool
    @State private var expanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.transcriptDisclosureAction) private var onDisclosure

    init(text: String, isStreaming: Bool, initiallyExpanded: Bool) {
        self.text = text
        self.isStreaming = isStreaming
        _expanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    onDisclosure()
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .frame(width: 12, height: 18)
                        Text("Reasoning").font(.system(size: 12, weight: .medium))
                        Text(isStreaming ? "Working" : "Complete")
                            .font(.system(size: 10)).foregroundStyle(Color.kilnTextTertiary)
                    }
                    .foregroundStyle(Color.kilnTextSecondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(expanded ? "Collapse reasoning summary" : "Expand reasoning summary")
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
                if isStreaming { ProgressView().controlSize(.mini) }
                Spacer(minLength: 8)
            }
            if expanded {
                ToolTextOutput(title: "Reasoning", text: text)
                    .padding(.leading, 20)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(Color.kilnBorder).frame(width: 1).padding(.leading, 5)
                    }
            } else {
                Text(String(text.suffix(240)).split(separator: "\n").last.map(String.init) ?? "")
                    .font(.system(size: 11)).foregroundStyle(Color.kilnTextTertiary)
                    .lineLimit(1).padding(.leading, 20)
            }
        }
        .padding(.vertical, 8)
    }
}
