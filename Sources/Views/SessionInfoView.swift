import SwiftUI

// MARK: - Session Info sheet
//
// A compact "about this session" panel — message count, tool calls,
// created/last-active timestamps, workdir, git branch, and cumulative
// input/output tokens if the provider reported any. Triggered by ⌘I.

struct SessionInfoView: View {
    let session: Session
    let tokens: SessionRuntimeState?
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "info.circle")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.kilnAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.kilnText)
                    Text(session.kind == .code ? "Code session" : "Chat session")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.kilnTextSecondary)
                }
                Spacer()
            }
            .padding(16)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                row("Model", value: session.model.label)
                row("Working directory", value: session.workDir, mono: true)
                row("Messages", value: "\(session.messages.count)")
                row("Tool calls", value: "\(toolCallCount)")
                if let tokens {
                    row("Tokens this turn",
                        value: "\(tokens.inputTokens) in · \(tokens.outputTokens) out")
                }
                row("Created", value: formatted(session.createdAt))
                row("Last message",
                    value: session.messages.last.map { formatted($0.timestamp) } ?? "—")
                if let forkedFrom = session.forkedFrom {
                    row("Forked from", value: String(forkedFrom.prefix(8)), mono: true)
                }
                if !session.tags.isEmpty {
                    row("Tags", value: session.tags.joined(separator: ", "))
                }
            }
            .padding(16)

            Divider()

            HStack {
                Button("Copy Session ID") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(session.id, forType: .string)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Color.kilnTextSecondary)
                Spacer()
                Button("Done") { onDismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 460)
        .background(Color.kilnBg)
    }

    private var toolCallCount: Int {
        session.messages.reduce(0) { acc, msg in
            acc + msg.blocks.filter { if case .toolUse = $0 { return true } else { return false } }.count
        }
    }

    private func formatted(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    @ViewBuilder
    private func row(_ label: String, value: String, mono: Bool = false) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Color.kilnTextSecondary)
                .frame(width: 130, alignment: .leading)
            Text(value)
                .font(.system(size: 12, design: mono ? .monospaced : .default))
                .foregroundStyle(Color.kilnText)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
