import SwiftUI

// MARK: - Session Info sheet
//
// A compact "about this session" panel — message count, tool calls,
// created/last-active timestamps, workdir, git branch, and cumulative
// input/output tokens if the provider reported any. Triggered by ⌘I.

struct SessionInfoView: View {
    @EnvironmentObject var store: AppStore
    let session: Session
    let tokens: SessionRuntimeState?
    let onDismiss: () -> Void
    @State private var tagDraft: String = ""

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

                // Tag editor — chips for existing tags with a × to remove,
                // plus a free-text field that commits on Return. Tags are
                // freeform strings; the sidebar uses them for filtering.
                HStack(alignment: .top, spacing: 12) {
                    Text("Tags")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.kilnTextSecondary)
                        .frame(width: 130, alignment: .leading)
                    VStack(alignment: .leading, spacing: 6) {
                        if !session.tags.isEmpty {
                            TagFlow(tags: session.tags, onRemove: removeTag)
                        }
                        TextField("Add tag…", text: $tagDraft, onCommit: commitTag)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.kilnText)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.kilnSurface)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
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

    private func commitTag() {
        let t = tagDraft.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        store.addTag(t, to: session.id)
        tagDraft = ""
    }

    private func removeTag(_ tag: String) {
        store.removeTag(tag, from: session.id)
    }

    /// Minimal flow layout — left-packs subviews, wraps onto new rows
    /// when it runs out of width. Just enough for tag chips; not a
    /// general-purpose replacement.
    struct TagFlowLayout: Layout {
        var spacing: CGFloat = 4
        var runSpacing: CGFloat = 4

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            let width = proposal.width ?? .infinity
            let rows = computeRows(subviews: subviews, maxWidth: width)
            let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * runSpacing
            let widthUsed = rows.map(\.width).max() ?? 0
            return CGSize(width: min(width, widthUsed), height: height)
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            let rows = computeRows(subviews: subviews, maxWidth: bounds.width)
            var y = bounds.minY
            for row in rows {
                var x = bounds.minX
                for item in row.items {
                    let size = subviews[item].sizeThatFits(.unspecified)
                    subviews[item].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                    x += size.width + spacing
                }
                y += row.height + runSpacing
            }
        }

        private struct Row { var items: [Int]; var width: CGFloat; var height: CGFloat }

        private func computeRows(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
            var rows: [Row] = []
            var current = Row(items: [], width: 0, height: 0)
            for (idx, sv) in subviews.enumerated() {
                let size = sv.sizeThatFits(.unspecified)
                let additional = current.items.isEmpty ? size.width : size.width + spacing
                if current.width + additional > maxWidth, !current.items.isEmpty {
                    rows.append(current)
                    current = Row(items: [idx], width: size.width, height: size.height)
                } else {
                    current.items.append(idx)
                    current.width += additional
                    current.height = max(current.height, size.height)
                }
            }
            if !current.items.isEmpty { rows.append(current) }
            return rows
        }
    }

    private func formatted(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    /// Simple wrapping layout for tag chips. macOS 13 has SwiftUI.Layout
    /// but hand-rolling with ViewThatFits-style preferences pulls more
    /// code than this problem needs. Uses Layout protocol.
    struct TagFlow: View {
        let tags: [String]
        let onRemove: (String) -> Void

        var body: some View {
            TagFlowLayout(spacing: 4, runSpacing: 4) {
                ForEach(tags, id: \.self) { tag in
                    HStack(spacing: 3) {
                        Text(tag)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.kilnText)
                        Button { onRemove(tag) } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 7, weight: .bold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.kilnTextTertiary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.kilnSurface)
                    .clipShape(Capsule())
                }
            }
        }
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
