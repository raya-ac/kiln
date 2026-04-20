import SwiftUI
import AppKit

// MARK: - Quick Open (⌘P)
//
// Fuzzy file finder across the active session's work directory. Walks the
// tree up to a depth cap, skips the usual noise (.git, node_modules,
// .build, dist, etc.), and ranks by a simple subsequence-with-bonus
// scorer: consecutive matches and matches at word boundaries score
// higher, so "rvm" finds "ResolverManager.swift" quickly.

struct QuickOpenView: View {
    @EnvironmentObject var store: AppStore
    @State private var query: String = ""
    @State private var entries: [QuickOpenEntry] = []
    @State private var selected: Int = 0
    @FocusState private var fieldFocused: Bool

    private var matches: [QuickOpenEntry] {
        if query.isEmpty { return Array(entries.prefix(100)) }
        let q = query.lowercased()
        return entries
            .compactMap { e -> (QuickOpenEntry, Int)? in
                guard let s = Self.score(q, e.name.lowercased(), full: e.relativePath.lowercased()) else { return nil }
                return (e, s)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(100)
            .map { $0.0 }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.kilnTextSecondary)
                TextField("Go to file…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.kilnText)
                    .focused($fieldFocused)
                    .onSubmit(openSelected)
                    .onChange(of: query) { _, _ in selected = 0 }
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.kilnTextTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.kilnSurface)

            Rectangle().fill(Color.kilnBorder).frame(height: 1)

            if matches.isEmpty {
                VStack(spacing: 6) {
                    Text(entries.isEmpty ? "Scanning…" : "No matches")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.kilnTextTertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(matches.enumerated()), id: \.element.id) { idx, entry in
                                QuickOpenRow(entry: entry, isSelected: idx == selected)
                                    .id(entry.id)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        selected = idx
                                        openSelected()
                                    }
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: selected) { _, new in
                        guard matches.indices.contains(new) else { return }
                        withAnimation(.linear(duration: 0.05)) {
                            proxy.scrollTo(matches[new].id, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(width: 560, height: 440)
        .background(Color.kilnBg)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.kilnBorder, lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 20, y: 8)
        .task { await loadEntries() }
        .onAppear { fieldFocused = true }
        .background(keyboardShortcuts)
    }

    @ViewBuilder
    private var keyboardShortcuts: some View {
        ZStack {
            Button("") { moveSelection(by: 1) }.keyboardShortcut(.downArrow, modifiers: [])
            Button("") { moveSelection(by: -1) }.keyboardShortcut(.upArrow, modifiers: [])
            Button("") { moveSelection(by: 1) }.keyboardShortcut("n", modifiers: .control)
            Button("") { moveSelection(by: -1) }.keyboardShortcut("p", modifiers: .control)
            Button("") { store.showQuickOpen = false }.keyboardShortcut(.escape, modifiers: [])
        }
        .opacity(0).frame(width: 0, height: 0)
    }

    private func moveSelection(by delta: Int) {
        let n = matches.count
        guard n > 0 else { return }
        selected = ((selected + delta) % n + n) % n
    }

    private func openSelected() {
        guard matches.indices.contains(selected) else { return }
        store.quickOpenRequest = matches[selected].absolutePath
        store.showQuickOpen = false
    }

    // MARK: Scanning

    private func loadEntries() async {
        let root = resolvedWorkDir(store.activeSession?.workDir ?? NSHomeDirectory())
        let scanned = await Task.detached(priority: .userInitiated) {
            Self.scan(root: root)
        }.value
        entries = scanned
    }

    private func resolvedWorkDir(_ raw: String) -> String {
        if raw.hasPrefix("~") {
            return raw.replacingOccurrences(of: "~", with: NSHomeDirectory(), range: raw.range(of: "~"))
        }
        return raw
    }

    /// Walk the tree BFS, capped by file count and depth. Skips well-known
    /// noise directories. Returns entries with their path relative to root.
    nonisolated static func scan(root: String) -> [QuickOpenEntry] {
        let skip: Set<String> = [
            ".git", "node_modules", ".build", "build", "dist", ".next",
            ".venv", "venv", "__pycache__", ".DS_Store", ".swiftpm",
            "Pods", "DerivedData", "target", ".idea", ".vscode"
        ]
        let maxDepth = 8
        let maxFiles = 10_000
        let fm = FileManager.default
        var out: [QuickOpenEntry] = []
        var queue: [(path: String, depth: Int)] = [(root, 0)]
        while !queue.isEmpty && out.count < maxFiles {
            let (dir, depth) = queue.removeFirst()
            guard let contents = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in contents {
                if name.hasPrefix(".") && name != ".env" && name != ".gitignore" { continue }
                if skip.contains(name) { continue }
                let full = (dir as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                fm.fileExists(atPath: full, isDirectory: &isDir)
                if isDir.boolValue {
                    if depth < maxDepth { queue.append((full, depth + 1)) }
                } else {
                    let rel = full.hasPrefix(root + "/")
                        ? String(full.dropFirst(root.count + 1))
                        : full
                    out.append(QuickOpenEntry(name: name, relativePath: rel, absolutePath: full))
                    if out.count >= maxFiles { break }
                }
            }
        }
        return out
    }

    // MARK: Scoring

    /// Returns nil if `query` isn't a subsequence of `name` (or `full`).
    /// Higher score = better match. Favors: exact prefix, contiguous runs,
    /// matches on word boundaries, shorter paths.
    static func score(_ query: String, _ name: String, full: String) -> Int? {
        // Try name first, fall back to full relative path.
        if let s = subsequenceScore(query, name) { return s + max(0, 40 - full.count / 2) }
        if let s = subsequenceScore(query, full) { return s / 2 }
        return nil
    }

    private static func subsequenceScore(_ query: String, _ target: String) -> Int? {
        if query.isEmpty { return 0 }
        let q = Array(query), t = Array(target)
        var score = 0, streak = 0
        var qi = 0
        var prev: Character = "/"
        for i in 0..<t.count {
            guard qi < q.count else { break }
            if t[i] == q[qi] {
                score += 10
                if prev == "/" || prev == "." || prev == "_" || prev == "-" { score += 8 }
                streak += 1
                score += streak * 2
                qi += 1
            } else {
                streak = 0
            }
            prev = t[i]
        }
        if qi < q.count { return nil }
        // Exact prefix bonus.
        if target.hasPrefix(query) { score += 25 }
        // Shorter target preferred.
        score -= t.count / 4
        return score
    }
}

struct QuickOpenEntry: Identifiable, Equatable {
    let id = UUID()
    let name: String
    let relativePath: String
    let absolutePath: String
}

struct QuickOpenRow: View {
    let entry: QuickOpenEntry
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconForFile(entry.name))
                .font(.system(size: 11))
                .foregroundStyle(Color.kilnTextTertiary)
                .frame(width: 14)
            Text(entry.name)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isSelected ? Color.kilnBg : Color.kilnText)
            Text(entry.relativePath.replacingOccurrences(of: "/" + entry.name, with: ""))
                .font(.system(size: 10))
                .foregroundStyle(isSelected ? Color.kilnBg.opacity(0.7) : Color.kilnTextTertiary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? Color.kilnAccent : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}
