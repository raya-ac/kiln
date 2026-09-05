import SwiftUI
import AppKit

struct MessageActionMenu: View {
    @EnvironmentObject private var store: AppStore
    let message: ChatMessage
    let onEdit: () -> Void

    private var text: String {
        message.blocks.compactMap { block -> String? in
            switch block {
            case .text(let text), .thinking(let text): return text
            case .trace(let entries): return entries.map { "[\($0.level.rawValue)] \($0.phase): \($0.title)\n\($0.detail)" }.joined(separator: "\n")
            case .suggestions(let prompts): return prompts.map(\.label).joined(separator: "\n")
            default: return nil
            }
        }.joined(separator: "\n\n")
    }

    var body: some View {
        Menu {
            Button("Copy message", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            if message.role == .assistant {
                Button("Save as clipping", systemImage: "bookmark") {
                    let body = message.blocks.compactMap { if case .text(let text) = $0 { return text }; return nil }.joined(separator: "\n\n")
                    guard !body.isEmpty else { return }
                    ClippingStore.shared.add(Clipping(title: String(body.prefix(50).split(separator: "\n").first ?? "Clipping"), body: body,
                        sourceSessionId: store.activeSessionId, sourceMessageId: message.id))
                }
                Menu("Follow up") {
                    Button("Explain further") { store.pendingComposerPrefill = "Explain that in more depth." }
                    Button("Make it shorter") { store.pendingComposerPrefill = "Give me a much tighter version of that answer." }
                    Button("Give an example") { store.pendingComposerPrefill = "Show me a concrete example of that." }
                    Divider()
                    Button("Write tests") { store.pendingComposerPrefill = "Write tests covering the code you just produced." }
                    Button("Refactor for clarity") { store.pendingComposerPrefill = "Refactor that for clarity while preserving behavior." }
                    Button("Add error handling") { store.pendingComposerPrefill = "Add error handling at system boundaries in that code." }
                    Button("Find edge cases") { store.pendingComposerPrefill = "What edge cases might break that?" }
                    Button("Critique this") { store.pendingComposerPrefill = "Critique that response. What is weak or missing?" }
                }
            }
            Button(message.isPinned ? "Unpin" : "Pin", systemImage: "pin") {
                if let id = store.activeSessionId { store.togglePinMessage(sessionId: id, messageId: message.id) }
            }
            Button("Fork from here", systemImage: "arrow.triangle.branch") {
                if let id = store.activeSessionId { store.forkSession(fromSessionId: id, atMessageId: message.id) }
            }
            if message.role == .user {
                Button("Edit & resend", systemImage: "pencil", action: onEdit).disabled(store.isBusy)
            }
            Divider()
            Menu("Delete", systemImage: "trash") {
                Button("Delete this message", role: .destructive) {
                    if let id = store.activeSessionId { store.deleteMessage(sessionId: id, messageId: message.id) }
                }
                Button("Delete from here onwards", role: .destructive) {
                    if let id = store.activeSessionId { store.deleteMessageAndAfter(sessionId: id, messageId: message.id) }
                }
            }
        } label: {
            Image(systemName: "ellipsis").frame(width: 28, height: 28)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .foregroundStyle(Color.kilnTextTertiary)
        .help("Message actions").accessibilityLabel("Message actions")
    }
}
