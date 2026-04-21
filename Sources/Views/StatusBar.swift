import SwiftUI

// MARK: - Status bar
//
// Persistent one-line strip at the bottom of the window. Shows the
// active session's model, the workdir basename, whether Claude is
// busy, the engram toggle, and the last-turn token totals.
// Kept deliberately terse — it's peripheral, not content.

struct StatusBar: View {
    @EnvironmentObject var store: AppStore

    private var session: Session? { store.activeSession }
    private var runtime: SessionRuntimeState? {
        guard let id = store.activeSessionId else { return nil }
        return store.runtimeStates[id]
    }

    var body: some View {
        HStack(spacing: 14) {
            if let s = session {
                pill(icon: "cpu", text: s.model.shortLabel)
                    .help(s.model.label)

                pill(icon: "folder", text: (s.workDir as NSString).lastPathComponent)
                    .help(s.workDir)
                    .onTapGesture {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: s.workDir)])
                    }

                if let rt = runtime, rt.inputTokens + rt.outputTokens > 0 {
                    pill(
                        icon: "number.circle",
                        text: "\(compact(rt.inputTokens))↑ \(compact(rt.outputTokens))↓"
                    )
                    .help("Tokens this turn: \(rt.inputTokens) in / \(rt.outputTokens) out")
                }

                if store.isBusy {
                    HStack(spacing: 4) {
                        ProgressView().controlSize(.mini)
                        Text("Working")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.kilnAccent)
                    }
                }
            } else {
                Text("No active session")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.kilnTextTertiary)
            }

            Spacer()

            // Right side: engram indicator + session count. Click the
            // engram pill to jump straight into the setting.
            Button {
                store.showSettings = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: store.settings.useEngram ? "brain.head.profile" : "brain")
                        .font(.system(size: 10))
                    Text(store.settings.useEngram ? "engram on" : "engram off")
                        .font(.system(size: 10))
                }
                .foregroundStyle(store.settings.useEngram ? Color.kilnAccent : Color.kilnTextTertiary)
            }
            .buttonStyle(.plain)
            .help("Engram memory — click to open Settings")

            Text("\(store.sessions.count) sessions")
                .font(.system(size: 10))
                .foregroundStyle(Color.kilnTextTertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Color.kilnSurface)
        .overlay(Rectangle().fill(Color.kilnBorder).frame(height: 1), alignment: .top)
    }

    @ViewBuilder
    private func pill(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9))
                .foregroundStyle(Color.kilnTextTertiary)
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(Color.kilnTextSecondary)
                .lineLimit(1)
        }
    }

    /// Compact number formatter — 1234 → "1.2k", 1_234_567 → "1.2M". Saves
    /// horizontal space in the strip when token counts get large.
    private func compact(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        if n < 1_000_000 { return String(format: "%.1fk", Double(n) / 1000) }
        return String(format: "%.1fM", Double(n) / 1_000_000)
    }
}
