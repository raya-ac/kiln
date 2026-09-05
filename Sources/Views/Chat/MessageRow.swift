import SwiftUI
import MarkdownUI
import AppKit

// MARK: - Message Row

struct MessageRow: View {
    let message: ChatMessage
    @EnvironmentObject var store: AppStore
    @State private var hovering = false

    private var isUser: Bool { message.role == .user }

    private var estimatedTokens: Int {
        let chars = message.blocks.map { block -> Int in
            switch block {
            case .text(let t): return t.count
            case .thinking(let t): return t.count
            case .trace(let entries): return entries.reduce(0) { $0 + $1.title.count + $1.detail.count }
            case .toolUse(let b): return b.input.count + (b.result?.count ?? 0)
            case .toolResult(let r): return r.content.count
            default: return 0
            }
        }.reduce(0, +)
        return max(1, chars / 4)
    }

    /// Gradient: cool (few tokens) → warm (many). Thresholds are intentionally
    /// crude; the absolute scale doesn't matter, the relative heat does.
    private var heatmapColor: Color {
        let t = Double(estimatedTokens)
        let ratio = min(1.0, log(max(1, t)) / log(10_000))  // 1 token → 0, 10k → 1
        // Interpolate from cool blue → orange accent
        let r = 0.2 + ratio * 0.77    // 0.2 → 0.97
        let g = 0.4 - ratio * 0.15    // 0.4 → 0.25
        let b = 0.8 - ratio * 0.7     // 0.8 → 0.1
        return Color(.sRGB, red: r, green: g, blue: b, opacity: 0.9)
    }

    /// Pull this message's plain-text body back into the composer and
    /// truncate the session from here onward, so a resend replays from
    /// this point. Classic chat "edit & resend" behavior.
    private func requestEdit() {
        guard isUser, let sid = store.activeSessionId else { return }
        let text = message.blocks.compactMap { block -> String? in
            if case .text(let t) = block { return t }
            return nil
        }.joined(separator: "\n\n")
        store.pendingComposerPrefill = text
        store.deleteMessageAndAfter(sessionId: sid, messageId: message.id)
    }

    /// User label — custom display name if set, otherwise the localized "You".
    private var userLabel: String {
        let custom = store.settings.userDisplayName.trimmingCharacters(in: .whitespaces)
        return custom.isEmpty ? store.settings.language.ui.you : custom
    }

    private var shouldShowTimestamp: Bool {
        switch store.settings.showTimestamps {
        case .never: return false
        case .always: return true
        case .hover: return hovering
        }
    }

    private var assistantName: String {
        message.assistantName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                // Avatar — can be hidden via settings
                if store.settings.showAvatars {
                    UserAssistantAvatar(
                        isUser: isUser,
                        brand: message.model?.brand ?? .codex
                    )
                }

                VStack(alignment: .leading, spacing: 6) {
                    // Role label
                    HStack(spacing: 6) {
                        Text(isUser ? userLabel : assistantName)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(isUser ? Color.kilnTextSecondary : Color.kilnAccent)

                        if message.isPinned {
                            Image(systemName: "pin.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(Color.kilnAccent)
                                .help("Pinned")
                        }

                        // Timestamp display — respects settings (never/hover/always)
                        if shouldShowTimestamp {
                            Text(message.timestamp.formatted(.dateTime.hour().minute()))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(Color.kilnTextTertiary)
                        }

                        Spacer()

                        // Action buttons on hover
                        if hovering {
                            // Copy
                            Button {
                                let text = message.blocks.compactMap { block -> String? in
                                    switch block {
                                    case .text(let t): return t
                                    case .thinking(let t): return t
                                    case .trace(let entries): return entries.map { "[\($0.level.rawValue)] \($0.phase): \($0.title)\n\($0.detail)" }.joined(separator: "\n")
                                    case .suggestions(let s): return s.map(\.label).joined(separator: " · ")
                                    default: return nil
                                    }
                                }.joined(separator: "\n\n")
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(text, forType: .string)
                            } label: {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(Color.kilnTextTertiary)
                                    .frame(width: 24, height: 20)
                                    .background(Color.kilnSurfaceElevated)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                            .buttonStyle(.plain)
                            .help(store.settings.language.ui.copy)

                            // Fork
                            // Save clipping — only assistant messages
                            if message.role == .assistant {
                                Button {
                                    let text = message.blocks.compactMap { block -> String? in
                                        if case .text(let t) = block { return t }
                                        return nil
                                    }.joined(separator: "\n\n")
                                    guard !text.isEmpty else { return }
                                    let title = String(text.prefix(50).split(separator: "\n").first ?? "Clipping")
                                    ClippingStore.shared.add(Clipping(
                                        title: String(title),
                                        body: text,
                                        sourceSessionId: store.activeSessionId,
                                        sourceMessageId: message.id
                                    ))
                                } label: {
                                    Image(systemName: "bookmark")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(Color.kilnTextTertiary)
                                        .frame(width: 24, height: 20)
                                        .background(Color.kilnSurfaceElevated)
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                }
                                .buttonStyle(.plain)
                                .help("Save as clipping")
                            }

                            // Quick Actions — assistant messages only. Pre-fills
                            // the composer with a targeted follow-up prompt.
                            if message.role == .assistant {
                                Menu {
                                    Button("Explain further") {
                                        store.pendingComposerPrefill = "Explain that in more depth — what are the underlying mechanics?"
                                    }
                                    Button("Make it shorter") {
                                        store.pendingComposerPrefill = "Give me a much tighter version of that answer."
                                    }
                                    Button("Give an example") {
                                        store.pendingComposerPrefill = "Show me a concrete example of that."
                                    }
                                    Divider()
                                    Button("Write tests for this") {
                                        store.pendingComposerPrefill = "Write tests covering the code you just produced."
                                    }
                                    Button("Refactor for clarity") {
                                        store.pendingComposerPrefill = "Refactor that for clarity — preserve behavior, rename anything unclear, and explain what changed."
                                    }
                                    Button("Add error handling") {
                                        store.pendingComposerPrefill = "Add proper error handling to that code — only at system boundaries, no defensive noise."
                                    }
                                    Divider()
                                    Button("Find edge cases") {
                                        store.pendingComposerPrefill = "What edge cases might break that? List them concretely."
                                    }
                                    Button("Critique this") {
                                        store.pendingComposerPrefill = "Critique that response — what's weak, what did you miss?"
                                    }
                                } label: {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(Color.kilnTextTertiary)
                                        .frame(width: 24, height: 20)
                                        .background(Color.kilnSurfaceElevated)
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                }
                                .menuStyle(.borderlessButton)
                                .menuIndicator(.hidden)
                                .fixedSize()
                                .help("Quick actions")
                            }

                            // Pin / unpin
                            Button {
                                if let sessionId = store.activeSessionId {
                                    store.togglePinMessage(sessionId: sessionId, messageId: message.id)
                                }
                            } label: {
                                Image(systemName: message.isPinned ? "pin.fill" : "pin")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(message.isPinned ? Color.kilnAccent : Color.kilnTextTertiary)
                                    .frame(width: 24, height: 20)
                                    .background(Color.kilnSurfaceElevated)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                            .buttonStyle(.plain)
                            .help(message.isPinned ? "Unpin" : "Pin")

                            Button {
                                if let sessionId = store.activeSessionId {
                                    store.forkSession(fromSessionId: sessionId, atMessageId: message.id)
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.triangle.branch")
                                        .font(.system(size: 9, weight: .semibold))
                                    Text(store.settings.language.ui.fork)
                                        .font(.system(size: 10, weight: .medium))
                                }
                                .foregroundStyle(Color.kilnTextTertiary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.kilnSurfaceElevated)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                            .buttonStyle(.plain)

                            // Edit & resend (user messages only)
                            if isUser {
                                Button { requestEdit() } label: {
                                    Image(systemName: "pencil")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(Color.kilnTextTertiary)
                                        .frame(width: 24, height: 20)
                                        .background(Color.kilnSurfaceElevated)
                                        .clipShape(RoundedRectangle(cornerRadius: 4))
                                }
                                .buttonStyle(.plain)
                                .help("Edit & resend")
                            }

                            // Delete (with rewind to this point)
                            Menu {
                                Button("Delete this message only") {
                                    if let sid = store.activeSessionId {
                                        store.deleteMessage(sessionId: sid, messageId: message.id)
                                    }
                                }
                                Button("Delete from here onwards", role: .destructive) {
                                    if let sid = store.activeSessionId {
                                        store.deleteMessageAndAfter(sessionId: sid, messageId: message.id)
                                    }
                                }
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(Color.kilnTextTertiary)
                                    .frame(width: 24, height: 20)
                                    .background(Color.kilnSurfaceElevated)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .help("Delete…")
                        }
                    }
                    .frame(height: 24)

                    ForEach(message.transcriptBlocks) { row in
                        switch row.block {
                        case .text(let text):
                            Markdown(text)
                                .markdownTheme(.kilnScaled(store.settings.fontScale.factor))
                                .textSelection(.enabled)

                            // If the assistant embedded a unified diff in a
                            // ```diff / ```patch block, surface an Apply bar
                            // beneath the markdown. Only for assistant msgs.
                            if message.role == .assistant {
                                ForEach(DetectedPatch.detect(in: text)) { patch in
                                    PatchApplyBar(patch: patch)
                                }
                            }

                        case .thinking(let text):
                            ThinkingRow(text: text)

                        case .trace(let entries):
                            AgentTraceRow(entries: entries)

                        case .toolUse(let tool):
                            ToolCallCard(tool: tool)

                        case .toolResult:
                            EmptyView()

                        case .suggestions(let prompts):
                            SuggestionChips(prompts: prompts)

                        case .attachment(let a):
                            AttachmentPreview(attachment: a)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12 * store.settings.density.padding)
        }
        .background(isUser ? Color.clear : Color.kilnSurface.opacity(0.4))
        .overlay(alignment: .leading) {
            if message.isPinned {
                Rectangle()
                    .fill(Color.kilnAccent)
                    .frame(width: 3)
            } else if store.settings.showTokenHeatmap {
                // Token heatmap bar — warmer = more tokens. Rough estimate:
                // one token per ~4 characters of message text.
                Rectangle()
                    .fill(heatmapColor)
                    .frame(width: 3)
                    .help("~\(estimatedTokens) tokens")
            }
        }
        .onHover { hovering = $0 }
    }
}

// MARK: - Markdown Theme

extension MarkdownUI.Theme {
    @MainActor static let kiln: Theme = kilnScaled(1.0)

    /// Build a Markdown theme with font sizes scaled by `factor`. Lets the
    /// user's font-scale setting actually affect chat message text.
    @MainActor static func kilnScaled(_ factor: CGFloat) -> Theme {
        return Theme()
            .text {
                ForegroundColor(Color.kilnText)
                FontSize(13 * factor)
            }
            .code {
                FontFamilyVariant(.monospaced)
                FontSize(12 * factor)
                ForegroundColor(Color.kilnAccent)
            }
            .codeBlock { configuration in
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(configuration.language ?? "code")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color.kilnTextSecondary)
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(configuration.content, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .help("Copy code")
                    }.padding(10)
                    Divider()
                    ScrollView(.horizontal) {
                        configuration.label
                            .markdownTextStyle {
                                FontFamilyVariant(.monospaced)
                                FontSize(12 * factor)
                                ForegroundColor(Color.kilnText)
                            }
                            .fixedSize(horizontal: true, vertical: false)
                            .padding(12)
                    }
                }
                .background(Color.kilnSurface)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.kilnBorder, lineWidth: 1))
            }
            .link {
                ForegroundColor(Color.kilnAccent)
            }
            .heading1 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.bold)
                        FontSize(20 * factor)
                        ForegroundColor(Color.kilnText)
                    }
                    .markdownMargin(top: 16, bottom: 8)
            }
            .heading2 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(17 * factor)
                        ForegroundColor(Color.kilnText)
                    }
                    .markdownMargin(top: 12, bottom: 6)
            }
            .heading3 { configuration in
                configuration.label
                    .markdownTextStyle {
                        FontWeight(.semibold)
                        FontSize(15 * factor)
                        ForegroundColor(Color.kilnText)
                    }
                    .markdownMargin(top: 8, bottom: 4)
            }
            .paragraph { configuration in
                configuration.label
                    .markdownMargin(top: 0, bottom: 8)
            }
            .listItem { configuration in
                configuration.label
                    .markdownMargin(top: 2, bottom: 2)
            }
            .strong {
                FontWeight(.semibold)
            }
            .emphasis {
                FontStyle(.italic)
            }
    }
}
