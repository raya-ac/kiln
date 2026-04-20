import SwiftUI

// MARK: - Keyboard Shortcuts Overlay (⌘?)
//
// Floating panel listing every bound shortcut. Renders grouped by area —
// navigation / chat / session / composer. Press Esc or ⌘? again to close.

struct ShortcutsOverlay: View {
    @EnvironmentObject var store: AppStore
    private func dismiss() { store.showShortcutsOverlay = false }

    private let groups: [(String, [(String, String)])] = [
        ("Navigation", [
            ("⌘K", "Command palette"),
            ("⌘⇧F", "Search all messages"),
            ("⌘F", "Find in current session"),
            ("⌘?", "This overlay"),
            ("⌘1", "Show code sessions"),
            ("⌘2", "Show chat sessions"),
            ("⌘[", "Previous session"),
            ("⌘]", "Next session"),
        ]),
        ("Session", [
            ("⌘N", "New session"),
            ("⌘⇧T", "Session templates"),
            ("⌘⇧E", "Export chat as markdown"),
            ("⌘W", "Close active session"),
        ]),
        ("Composer", [
            ("⌘/", "Snippets and clippings"),
            ("⏎ / ⌘⏎", "Send message"),
            ("⇧⏎", "Newline in input"),
            ("⌘Z", "Undo send (within window)"),
            ("⌘.", "Interrupt generation"),
            ("⌘⇧R", "Retry last message"),
        ]),
        ("Editor", [
            ("⌘S", "Save active file"),
            ("⌘⌥S", "Save all open files"),
            ("⌘⇧W", "Close active tab"),
            ("⌘⌥[", "Previous tab"),
            ("⌘⌥]", "Next tab"),
            ("⌘⇧B", "Toggle file tree"),
            ("⌘⌥R", "Reveal active file in Finder"),
        ]),
        ("Slash commands (client-side)", [
            ("/compact", "Summarize and reset history"),
            ("/clear", "Clear session messages"),
            ("/fork", "Fork from last message"),
            ("/retry", "Retry last user message"),
            ("/model", "Cycle to next model"),
            ("/title", "Ask Claude for a session title"),
            ("/instructions", "Edit per-session system prompt"),
            ("/interrupt", "Stop current generation"),
            ("/export", "Export chat as markdown"),
            ("/search <q>", "Open global search with query"),
            ("/settings", "Open settings"),
        ]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: "command")
                    .foregroundStyle(Color.kilnAccent)
                Text("Keyboard Shortcuts")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.kilnText)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.kilnTextSecondary)
                        .frame(width: 22, height: 22)
                        .background(Color.kilnSurface)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(20)

            Rectangle().fill(Color.kilnBorder).frame(height: 1)

            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 20), GridItem(.flexible(), spacing: 20)],
                    alignment: .leading,
                    spacing: 20
                ) {
                    ForEach(Array(groups.enumerated()), id: \.offset) { _, group in
                        groupColumn(title: group.0, rows: group.1)
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 700, height: 520)
        .background(Color.kilnBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.kilnBorder, lineWidth: 1))
        .shadow(color: Color.black.opacity(0.5), radius: 24, y: 8)
    }

    @ViewBuilder
    private func groupColumn(title: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.kilnTextTertiary)
                .tracking(0.8)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 10) {
                        Text(row.0)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.kilnText)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.kilnSurface)
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.kilnBorder, lineWidth: 1))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                            .frame(width: 100, alignment: .leading)
                        Text(row.1)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.kilnTextSecondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }
}
