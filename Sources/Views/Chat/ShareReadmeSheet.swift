import SwiftUI

/// Builds a public README from a conversation. Only user/assistant text is
/// included — tool calls, reasoning, attachments and file paths are stripped.
enum ReadmeBuilder {
    static func markdown(for session: Session) -> String {
        var lines = ["# " + (session.name.isEmpty ? "Shared chat" : session.name), ""]
        let date = session.createdAt.formatted(date: .abbreviated, time: .omitted)
        lines.append("_shared from kiln · \(session.model.label) · \(date)_")
        for message in session.messages {
            let text = message.blocks.compactMap { block -> String? in
                if case let .text(value) = block { return value }
                return nil
            }.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            lines.append("")
            lines.append("## " + (message.role == .user ? "you" : (message.model?.label.lowercased() ?? "assistant")))
            lines.append("")
            lines.append(text)
        }
        return lines.joined(separator: "\n")
    }
}

struct ShareReadmeSheet: View {
    let session: Session
    @ObservedObject var account: KilnAccountService = .shared
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var consented = false
    @State private var busy = false
    @State private var error: String?

    init(session: Session) {
        self.session = session
        _title = State(initialValue: session.name.isEmpty ? "Shared chat" : session.name)
    }

    private var markdown: String { ReadmeBuilder.markdown(for: session) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Share as README").font(.system(size: 14, weight: .semibold))
            TextField("Title", text: $title).textFieldStyle(.roundedBorder)
            ScrollView {
                Text(markdown)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 120, maxHeight: 200)
            .padding(10)
            .background(Color.kilnBg)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.kilnBorder, lineWidth: 1))
            warning
            if let error { Text(error).font(.system(size: 11)).foregroundStyle(Color.kilnError) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(busy ? "Sharing…" : "Share") { Task { await share() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(busy || !consented || account.account == nil
                              || title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 540)
        .background(Color.kilnSurface)
        .foregroundStyle(Color.kilnText)
    }

    private var warning: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Sharing puts this chat on kiln.raya.ac", systemImage: "exclamationmark.triangle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.kilnError)
            Text("Anyone with the link can read it. Tool calls, reasoning, attachments and file paths are removed. By sharing, you grant Kiln access to this chat data for Ash's training.")
                .font(.system(size: 11))
                .foregroundStyle(Color.kilnTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("I understand and consent to sharing this chat for Ash's training", isOn: $consented)
                .toggleStyle(.checkbox)
                .font(.system(size: 11))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.kilnBg)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.kilnBorder, lineWidth: 1))
    }

    private func share() async {
        busy = true
        error = nil
        let created = await account.createReadme(title: title.trimmingCharacters(in: .whitespaces),
                                                 body: markdown, sourceChatId: session.id)
        busy = false
        if created != nil {
            dismiss()
        } else {
            error = account.errorMessage ?? "Could not share this chat."
        }
    }
}
