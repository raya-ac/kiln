import SwiftUI

// MARK: - Command Palette (⌘K)
//
// Fuzzy-searchable list of sessions and actions. First N hits are keyboard-
// navigable with ↑/↓; Return activates the selection; Esc dismisses.

struct CommandPaletteView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    @FocusState private var focused: Bool

    // MARK: - Item model

    enum PaletteItem: Identifiable {
        case session(Session)
        case action(PaletteAction)

        var id: String {
            switch self {
            case .session(let s): return "session-\(s.id)"
            case .action(let a): return "action-\(a.id)"
            }
        }

        var title: String {
            switch self {
            case .session(let s): return s.name
            case .action(let a): return a.title
            }
        }

        var subtitle: String {
            switch self {
            case .session(let s):
                let dir = URL(fileURLWithPath: s.workDir).lastPathComponent
                return "\(s.kind.rawValue) · \(s.model.label) · \(dir) · \(s.messages.count) msg"
            case .action(let a): return a.subtitle
            }
        }

        var icon: String {
            switch self {
            case .session(let s): return s.kind == .chat ? "bubble.left.fill" : "chevron.left.forwardslash.chevron.right"
            case .action(let a): return a.icon
            }
        }

        var shortcut: String? {
            switch self {
            case .session: return nil
            case .action(let a): return a.shortcut
            }
        }
    }

    struct PaletteAction: Identifiable, Hashable {
        let id: String
        let title: String
        let subtitle: String
        let icon: String
        let shortcut: String?
        let perform: @MainActor () -> Void

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    // MARK: - Data source

    private var actions: [PaletteAction] {
        [
            PaletteAction(id: "new-code", title: "New Code Session", subtitle: "Start a new code session", icon: "plus.square", shortcut: "⌘N") {
                store.showNewSessionSheet = true
                store.showCommandPalette = false
            },
            PaletteAction(id: "new-chat", title: "New Chat Session", subtitle: "Start a new chat", icon: "bubble.left.and.bubble.right", shortcut: nil) {
                store.quickCreateChatSession()
                store.showCommandPalette = false
            },
            PaletteAction(id: "search", title: "Search Messages…", subtitle: "Search all conversations", icon: "magnifyingglass", shortcut: "⌘⇧F") {
                store.showCommandPalette = false
                store.showGlobalSearch = true
            },
            PaletteAction(id: "settings", title: "Settings", subtitle: "Open app settings", icon: "gear", shortcut: "⌘,") {
                store.showCommandPalette = false
                store.showSettings = true
            },
            PaletteAction(id: "export", title: "Export Chat", subtitle: "Save the current session as markdown", icon: "square.and.arrow.up", shortcut: "⌘⇧E") {
                guard let id = store.activeSessionId else { return }
                let md = store.exportSessionMarkdown(id)
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.plainText]
                panel.nameFieldStringValue = "\(store.activeSession?.name ?? "chat").md"
                if panel.runModal() == .OK, let url = panel.url {
                    try? md.write(to: url, atomically: true, encoding: .utf8)
                }
                store.showCommandPalette = false
            },
            PaletteAction(id: "retry", title: "Retry Last Message", subtitle: "Re-run the most recent user message", icon: "arrow.clockwise", shortcut: "⌘⇧R") {
                store.showCommandPalette = false
                Task { await store.retryLastMessage() }
            },
            PaletteAction(id: "interrupt", title: "Interrupt", subtitle: "Stop the current generation", icon: "stop.circle", shortcut: "⌘.") {
                store.interrupt()
                store.showCommandPalette = false
            },
            PaletteAction(id: "tab-code", title: "Show Code Sessions", subtitle: "Switch the sidebar to code sessions", icon: "chevron.left.forwardslash.chevron.right", shortcut: "⌘1") {
                store.selectedSidebarTab = .code
                store.showCommandPalette = false
            },
            PaletteAction(id: "tab-chat", title: "Show Chat Sessions", subtitle: "Switch the sidebar to chat sessions", icon: "bubble.left", shortcut: "⌘2") {
                store.selectedSidebarTab = .chat
                store.showCommandPalette = false
            },
        ]
    }

    private var items: [PaletteItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allSessions = store.sortedSessions.map { PaletteItem.session($0) }
        let allActions = actions.map { PaletteItem.action($0) }
        let all = allSessions + allActions
        if q.isEmpty {
            // Default ordering: actions first, then sessions, capped.
            return allActions + Array(allSessions.prefix(8))
        }
        return all.filter { item in
            Self.fuzzyMatch(haystack: item.title.lowercased(), needle: q)
            || Self.fuzzyMatch(haystack: item.subtitle.lowercased(), needle: q)
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color.kilnTextTertiary)
                TextField("Type a command or search sessions…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.kilnText)
                    .focused($focused)
                    .onSubmit { activate(items[safe: selectedIndex]) }
                    .onChange(of: query) { _, _ in selectedIndex = 0 }
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(Color.kilnTextTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
            .background(Color.kilnSurface)

            Rectangle().fill(Color.kilnBorder).frame(height: 1)

            // Results
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        let list = items
                        if list.isEmpty {
                            Text("No matches")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.kilnTextTertiary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 40)
                        } else {
                            ForEach(Array(list.enumerated()), id: \.element.id) { idx, item in
                                paletteRow(item: item, selected: idx == selectedIndex)
                                    .id(idx)
                                    .onTapGesture { activate(item) }
                            }
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 360)
                .onChange(of: selectedIndex) { _, new in
                    withAnimation(.linear(duration: 0.08)) {
                        proxy.scrollTo(new, anchor: .center)
                    }
                }
            }

            // Footer hint
            HStack(spacing: 14) {
                keyHint("↑↓", "Navigate")
                keyHint("⏎", "Open")
                keyHint("Esc", "Close")
                Spacer()
                Text("\(items.count) result\(items.count == 1 ? "" : "s")")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.kilnTextTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.kilnSurface)
        }
        .frame(width: 620)
        .background(Color.kilnBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.kilnBorder, lineWidth: 1))
        .shadow(color: Color.black.opacity(0.5), radius: 30, y: 10)
        .onAppear { focused = true }
        .onKeyPress(.upArrow) {
            if selectedIndex > 0 { selectedIndex -= 1 }
            return .handled
        }
        .onKeyPress(.downArrow) {
            if selectedIndex < items.count - 1 { selectedIndex += 1 }
            return .handled
        }
        .onKeyPress(.escape) {
            store.showCommandPalette = false
            return .handled
        }
    }

    @ViewBuilder
    private func paletteRow(item: PaletteItem, selected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon)
                .font(.system(size: 13))
                .foregroundStyle(selected ? Color.kilnAccent : Color.kilnTextSecondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.kilnText)
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.kilnTextTertiary)
                    .lineLimit(1)
            }
            Spacer()
            if let shortcut = item.shortcut {
                Text(shortcut)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.kilnTextTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.kilnSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(selected ? Color.kilnAccentMuted : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(selected ? Color.kilnAccent.opacity(0.3) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func keyHint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.kilnTextSecondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.kilnSurfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: 3))
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(Color.kilnTextTertiary)
        }
    }

    private func activate(_ item: PaletteItem?) {
        guard let item = item else { return }
        switch item {
        case .session(let s):
            store.activeSessionId = s.id
            store.selectedSidebarTab = s.kind
            store.showCommandPalette = false
        case .action(let a):
            a.perform()
        }
    }

    // Simple fuzzy match: every char of the needle appears in order in the haystack.
    static func fuzzyMatch(haystack: String, needle: String) -> Bool {
        var hi = haystack.startIndex
        for n in needle {
            guard let found = haystack[hi...].firstIndex(of: n) else { return false }
            hi = haystack.index(after: found)
        }
        return true
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? {
        indices.contains(i) ? self[i] : nil
    }
}
