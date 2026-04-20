import SwiftUI

// MARK: - Prompt Snippets
//
// Reusable prompts the user can insert into the composer via ⌘/. Stored in
// UserDefaults as JSON — lightweight, no persistence framework needed.

struct PromptSnippet: Identifiable, Codable, Hashable {
    let id: String
    var title: String
    var body: String

    init(id: String = UUID().uuidString, title: String, body: String) {
        self.id = id
        self.title = title
        self.body = body
    }
}

@MainActor
final class SnippetStore: ObservableObject {
    static let shared = SnippetStore()
    private let key = "promptSnippets.v1"

    @Published var snippets: [PromptSnippet] = []

    init() { load() }

    func load() {
        let d = UserDefaults.standard
        guard let data = d.data(forKey: key),
              let decoded = try? JSONDecoder().decode([PromptSnippet].self, from: data)
        else {
            // Seed with a few defaults the first time through.
            snippets = Self.seedSnippets
            save()
            return
        }
        snippets = decoded
    }

    func save() {
        if let data = try? JSONEncoder().encode(snippets) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    func add(_ s: PromptSnippet) {
        snippets.append(s)
        save()
    }

    func remove(_ id: String) {
        snippets.removeAll { $0.id == id }
        save()
    }

    func update(_ s: PromptSnippet) {
        if let idx = snippets.firstIndex(where: { $0.id == s.id }) {
            snippets[idx] = s
            save()
        }
    }

    private static let seedSnippets: [PromptSnippet] = [
        PromptSnippet(title: "Explain this file", body: "Read the currently open file and explain what it does, its key responsibilities, and any non-obvious design choices. Keep it terse."),
        PromptSnippet(title: "Review this diff", body: "Run `git diff` and review the unstaged changes. Flag anything suspicious: performance hits, security issues, subtle correctness bugs, unused imports, dead branches."),
        PromptSnippet(title: "Write tests", body: "Write tests for the code I'll describe next. Use the project's existing test style. Focus on boundary conditions and failure modes, not happy-path sanity checks."),
        PromptSnippet(title: "Refactor for clarity", body: "Refactor the target code for clarity without changing behavior. Consolidate duplication, name things honestly, peel off accidental complexity. Don't add premature abstractions."),
        PromptSnippet(title: "Summarize this session", body: "Summarize what we've done in this session so far — decisions made, code shipped, open threads. Terse bullets."),
    ]
}

// MARK: - Snippets popover UI

struct SnippetsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: SnippetStore = .shared
    @ObservedObject var clippings: ClippingStore = .shared
    var onInsert: (String) -> Void
    @State private var query = ""
    @State private var selectedIndex = 0
    @State private var tab: SnippetTab = .snippets
    @State private var editing: PromptSnippet?
    @FocusState private var focused: Bool

    enum SnippetTab: String, CaseIterable { case snippets, clippings
        var label: String { self == .snippets ? "Snippets" : "Clippings" }
        var icon: String { self == .snippets ? "text.alignleft" : "bookmark.fill" }
    }

    private var filtered: [PromptSnippet] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let source = tab == .snippets
            ? store.snippets
            : clippings.items.map { PromptSnippet(id: $0.id, title: $0.title, body: $0.body) }
        if q.isEmpty { return source }
        return source.filter {
            $0.title.lowercased().contains(q) || $0.body.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar (snippets vs clippings)
            HStack(spacing: 4) {
                ForEach(SnippetTab.allCases, id: \.self) { t in
                    let selected = tab == t
                    Button { tab = t; selectedIndex = 0 } label: {
                        HStack(spacing: 5) {
                            Image(systemName: t.icon)
                                .font(.system(size: 10))
                            Text(t.label)
                                .font(.system(size: 11, weight: .medium))
                            if t == .clippings && !clippings.items.isEmpty {
                                Text("\(clippings.items.count)")
                                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                    .padding(.horizontal, 4)
                                    .background(Color.kilnSurface)
                                    .clipShape(Capsule())
                            }
                        }
                        .foregroundStyle(selected ? Color.kilnBg : Color.kilnTextSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(selected ? Color.kilnAccent : Color.kilnSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            // Search + new button
            HStack(spacing: 10) {
                Image(systemName: tab == .snippets ? "text.alignleft" : "bookmark.fill")
                    .foregroundStyle(Color.kilnTextTertiary)
                TextField(tab == .snippets ? "Search snippets…" : "Search clippings…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($focused)
                    .onSubmit { insert(filtered[safe: selectedIndex]) }
                Button {
                    editing = PromptSnippet(title: "", body: "")
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.kilnAccent)
                }
                .buttonStyle(.plain)
                .help("New snippet")
            }
            .padding(12)
            .background(Color.kilnSurface)

            Rectangle().fill(Color.kilnBorder).frame(height: 1)

            ScrollView {
                LazyVStack(spacing: 2) {
                    if filtered.isEmpty {
                        Text("No snippets yet.")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.kilnTextTertiary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 30)
                    } else {
                        ForEach(Array(filtered.enumerated()), id: \.element.id) { idx, snip in
                            snippetRow(snip, selected: idx == selectedIndex)
                                .onTapGesture { insert(snip) }
                        }
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 320)

            HStack(spacing: 12) {
                Text("⏎ insert  ·  ↑↓ navigate  ·  Esc close")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.kilnTextTertiary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.kilnSurface)
        }
        .frame(width: 540)
        .background(Color.kilnBg)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.kilnBorder, lineWidth: 1))
        .shadow(color: Color.black.opacity(0.5), radius: 24, y: 8)
        .onAppear { focused = true }
        .onKeyPress(.upArrow) {
            if selectedIndex > 0 { selectedIndex -= 1 }
            return .handled
        }
        .onKeyPress(.downArrow) {
            if selectedIndex < filtered.count - 1 { selectedIndex += 1 }
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
        .sheet(item: $editing) { snip in
            SnippetEditor(snippet: snip, onSave: { store.snippets.contains(where: { $0.id == snip.id }) ? store.update($0) : store.add($0) }, onDelete: {
                store.remove(snip.id)
            })
            .preferredColorScheme(.dark)
        }
    }

    @ViewBuilder
    private func snippetRow(_ s: PromptSnippet, selected: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(s.title.isEmpty ? "(untitled)" : s.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.kilnText)
                Text(s.body)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.kilnTextTertiary)
                    .lineLimit(2)
            }
            Spacer()
            Button {
                editing = s
            } label: {
                Image(systemName: "pencil")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.kilnTextTertiary)
                    .frame(width: 22, height: 22)
                    .background(Color.kilnSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .help("Edit")
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

    private func insert(_ s: PromptSnippet?) {
        guard let s = s else { return }
        onInsert(s.body)
        dismiss()
    }
}

struct SnippetEditor: View {
    @State var snippet: PromptSnippet
    let onSave: (PromptSnippet) -> Void
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Snippet")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.kilnText)

            TextField("Title", text: $snippet.title)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .padding(8)
                .background(Color.kilnSurface)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.kilnBorder, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            TextEditor(text: $snippet.body)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 160)
                .background(Color.kilnSurface)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.kilnBorder, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            HStack {
                Button("Delete", role: .destructive) {
                    onDelete()
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.kilnError)
                .font(.system(size: 12, weight: .medium))

                Spacer()

                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.kilnTextSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.kilnSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                Button("Save") {
                    onSave(snippet)
                    dismiss()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.kilnBg)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.kilnAccent)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .keyboardShortcut(.defaultAction)
                .disabled(snippet.title.isEmpty || snippet.body.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(Color.kilnBg)
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? {
        indices.contains(i) ? self[i] : nil
    }
}
