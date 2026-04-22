import SwiftUI

// MARK: - Global Search (⌘⇧F)
//
// Searches across every session's message content. Clicking a result jumps
// to that message in the chat view.

struct GlobalSearchView: View {
    @EnvironmentObject var store: AppStore
    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    @State private var results: [SearchResult] = []
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(Color.kilnTextTertiary)
                TextField("Search all messages…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.kilnText)
                    .focused($focused)
                    .onChange(of: query) { _, newValue in
                        results = store.searchMessages(newValue)
                        selectedIndex = 0
                    }
                    .onSubmit { open(results[safeIndex: selectedIndex]) }
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

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if query.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 {
                            Text("Type at least 2 characters to search.")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.kilnTextTertiary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 40)
                        } else if results.isEmpty {
                            Text("No matches")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.kilnTextTertiary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 40)
                        } else {
                            ForEach(Array(results.enumerated()), id: \.element.id) { idx, r in
                                resultRow(r, selected: idx == selectedIndex)
                                    .id(idx)
                                    .onTapGesture { open(r) }
                            }
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 420)
                .onChange(of: selectedIndex) { _, new in
                    withAnimation(.linear(duration: 0.08)) {
                        proxy.scrollTo(new, anchor: .center)
                    }
                }
            }

            // Footer
            HStack(spacing: 14) {
                Text("↑↓ to navigate")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.kilnTextTertiary)
                Text("⏎ to open")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.kilnTextTertiary)
                Text("Esc to close")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.kilnTextTertiary)
                Spacer()
                Text("\(results.count) result\(results.count == 1 ? "" : "s")")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.kilnTextTertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.kilnSurface)
        }
        .frame(width: 680)
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
            if selectedIndex < results.count - 1 { selectedIndex += 1 }
            return .handled
        }
        .onKeyPress(.escape) {
            store.showGlobalSearch = false
            return .handled
        }
    }

    @ViewBuilder
    private func resultRow(_ r: SearchResult, selected: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: r.sessionKind == .chat ? "bubble.left.fill" : "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 11))
                .foregroundStyle(selected ? Color.kilnAccent : Color.kilnTextTertiary)
                .frame(width: 20)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(r.sessionName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.kilnText)
                    Text("·")
                        .foregroundStyle(Color.kilnTextTertiary)
                    Text(r.role == .user ? "You" : (store.sessions.first(where: { $0.id == r.sessionId })?.model.assistantName ?? "Assistant"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(r.role == .user ? Color.kilnTextSecondary : Color.kilnAccent)
                    Text("·")
                        .foregroundStyle(Color.kilnTextTertiary)
                    Text(r.timestamp.formatted(.relative(presentation: .numeric)))
                        .font(.system(size: 10))
                        .foregroundStyle(Color.kilnTextTertiary)
                }
                Text(r.snippet)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.kilnTextSecondary)
                    .lineLimit(2)
            }
            Spacer()
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

    private func open(_ r: SearchResult?) {
        guard let r = r else { return }
        store.jumpTo(sessionId: r.sessionId, messageId: r.messageId)
    }
}

private extension Array {
    subscript(safeIndex i: Int) -> Element? {
        indices.contains(i) ? self[i] : nil
    }
}
