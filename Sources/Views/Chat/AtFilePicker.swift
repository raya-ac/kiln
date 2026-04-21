import SwiftUI

// MARK: - @file picker
//
// When the user types `@` in the composer, we surface a popup that lists
// files from the active session's workdir. Typing further filters the
// list fuzzy-style, arrow keys navigate, Return / Tab accepts, Esc
// dismisses. Selecting a file replaces the `@query` token with
// `@relative/path/to/file` — the leading `@` is preserved because Claude
// Code recognizes it as a file reference.
//
// Filesystem walk is cached per workdir. We re-walk if the cache is
// older than 10s so new files get picked up without the user restarting.
// The walker skips common noise directories (.git, node_modules, build
// outputs, virtualenvs) so a monorepo doesn't drown the picker.

/// Cached workdir file index. One entry per workdir — keyed by the
/// absolute expanded path. Re-walk happens on demand when the cache ages
/// past `staleAfter` seconds.
@MainActor
final class WorkdirFileIndex: ObservableObject {
    static let shared = WorkdirFileIndex()

    /// How long a walked list stays fresh. Short enough that a new file
    /// shows up within seconds, long enough that rapid keystrokes don't
    /// trigger redundant walks.
    private let staleAfter: TimeInterval = 10

    /// Max paths to retain per workdir. Keeps memory + match time bounded
    /// on large repos. Users can still type a more specific query to
    /// narrow down rare matches — we always include exact prefix hits.
    private let maxPaths = 5000

    private struct Entry {
        var paths: [String]            // relative paths, forward slashes
        var walkedAt: Date
    }

    private var cache: [String: Entry] = [:]

    /// Directory/file names we skip outright. Chosen to keep the common
    /// cases quick — users can still type the full path to reach anything
    /// matching these, but the picker shouldn't suggest build output.
    private static let skipDirs: Set<String> = [
        ".git", ".hg", ".svn", ".bzr",
        "node_modules", "bower_components", "vendor",
        ".venv", "venv", "env", "__pycache__", ".mypy_cache",
        ".pytest_cache", ".tox", ".nox",
        ".build", "build", "dist", "out", "target",
        "DerivedData", ".gradle", ".idea", ".vscode",
        "Pods", "Carthage",
        ".next", ".nuxt", ".svelte-kit", ".turbo", ".parcel-cache",
        ".cache", ".terraform"
    ]
    private static let skipFiles: Set<String> = [
        ".DS_Store", "Thumbs.db", ".gitignore-untracked"
    ]

    /// Return the cached path list for `workDir`, re-walking if stale.
    /// `workDir` is the Session.workDir value (may start with `~`).
    func paths(for workDir: String) -> [String] {
        let key = Self.expand(workDir)
        if let entry = cache[key],
           Date().timeIntervalSince(entry.walkedAt) < staleAfter {
            return entry.paths
        }
        let walked = Self.walk(root: key, limit: maxPaths)
        cache[key] = Entry(paths: walked, walkedAt: Date())
        return walked
    }

    /// Force a re-walk — useful when a session switches workdir.
    func invalidate(_ workDir: String) {
        cache.removeValue(forKey: Self.expand(workDir))
    }

    /// Tilde-expand a path. `Session.workDir` is stored as a raw string;
    /// the picker needs it expanded before filesystem access.
    private static func expand(_ path: String) -> String {
        if path.hasPrefix("~") {
            return (path as NSString).expandingTildeInPath
        }
        return path
    }

    /// Breadth-ish walk that collects relative file paths up to `limit`.
    /// We use `FileManager.enumerator` for speed; it handles symlinks
    /// conservatively. Skipped directories are pruned before descent.
    private static func walk(root: String, limit: Int) -> [String] {
        guard FileManager.default.fileExists(atPath: root) else { return [] }
        let rootURL = URL(fileURLWithPath: root)
        let keys: [URLResourceKey] = [.isDirectoryKey, .nameKey]
        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var out: [String] = []
        out.reserveCapacity(min(limit, 1024))
        let rootPath = rootURL.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"

        for case let url as URL in enumerator {
            if out.count >= limit { break }
            let name = url.lastPathComponent
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir {
                if skipDirs.contains(name) { enumerator.skipDescendants() }
                continue
            }
            if skipFiles.contains(name) { continue }
            // Relative path from root. `path` is always absolute so strip
            // the common prefix rather than fiddling with URL components.
            let full = url.path
            let rel: String
            if full.hasPrefix(rootPrefix) {
                rel = String(full.dropFirst(rootPrefix.count))
            } else {
                rel = full
            }
            out.append(rel)
        }
        // Shorter paths first — a root-level README beats a deeply nested
        // one of the same name. Within equal length, alphabetical.
        out.sort { a, b in
            if a.count != b.count { return a.count < b.count }
            return a < b
        }
        return out
    }
}

// MARK: - Fuzzy matching
//
// Classic subsequence match with a few bonuses: prefix / word-boundary /
// case match / match at end of path (the filename itself) all push score
// up. Score is used to rank; non-matching paths are excluded.
//
// We match against both the full relative path and the basename so that
// typing `readme` finds `README.md` anywhere, and typing `src/a` still
// prefers paths that start with `src/`.

enum FuzzyScorer {
    struct Scored { let path: String; let score: Int }

    /// Score `path` against `query`. Returns nil if there's no match.
    /// Higher is better. Query is expected lowercase; path is compared
    /// case-insensitively but case matches grant a small bonus.
    static func score(path: String, query: String) -> Int? {
        if query.isEmpty { return 0 }
        let qChars = Array(query)
        let pChars = Array(path)
        let pLower = Array(path.lowercased())
        let basenameStart = path.lastIndex(of: "/").map {
            path.distance(from: path.startIndex, to: path.index(after: $0))
        } ?? 0

        var qi = 0
        var score = 0
        var lastMatch = -2
        var previousWasSeparator = true

        for pi in 0..<pLower.count {
            guard qi < qChars.count else { break }
            let pc = pLower[pi]
            let qc = qChars[qi]
            if pc == qc {
                var bonus = 10
                if pi == 0 { bonus += 25 }                    // match at start
                if pi == basenameStart { bonus += 20 }         // start of filename
                if previousWasSeparator { bonus += 15 }        // word boundary
                if pi == lastMatch + 1 { bonus += 8 }          // consecutive
                if pChars[pi] == qChars[qi] { bonus += 2 }     // case preserved
                score += bonus
                lastMatch = pi
                qi += 1
            } else {
                score -= 1
            }
            previousWasSeparator = (pc == "/" || pc == "_" || pc == "-" || pc == ".")
        }
        if qi < qChars.count { return nil }
        // Shorter paths preferred at equal match quality.
        score -= path.count / 8
        return score
    }

    /// Rank `paths` by `query`. Returns top `limit` paths descending by score.
    static func rank(paths: [String], query: String, limit: Int) -> [String] {
        if query.isEmpty { return Array(paths.prefix(limit)) }
        let q = query.lowercased()
        var scored: [Scored] = []
        scored.reserveCapacity(min(paths.count, 256))
        for p in paths {
            if let s = score(path: p, query: q) {
                scored.append(Scored(path: p, score: s))
            }
        }
        scored.sort { $0.score > $1.score }
        return scored.prefix(limit).map { $0.path }
    }
}

// MARK: - @ token extraction

/// Represents an in-progress `@file` token inside the composer text.
/// Captures the range that should be replaced when the user picks a file.
struct AtToken {
    /// Character offset in the input where the `@` sits. Inclusive.
    let atOffset: Int
    /// Character offset one past the end of the current token. Exclusive.
    let endOffset: Int
    /// The query text (everything after the `@`, no leading `@`).
    let query: String
}

enum AtTokenScanner {
    /// Find the @-token under / immediately before the end of `input`.
    /// We treat "end of input" as the cursor — SwiftUI doesn't give us
    /// a direct cursor position for a multi-line TextField, but the
    /// common case (typing at the end) is what matters.
    static func current(in input: String) -> AtToken? {
        guard !input.isEmpty else { return nil }
        let chars = Array(input)
        var i = chars.count - 1
        // Walk back from the end until we hit whitespace or an `@`.
        // Anything in-between is the in-progress query.
        while i >= 0 {
            let c = chars[i]
            if c == "@" {
                // The `@` must be at input start or preceded by whitespace —
                // otherwise it's an email address or similar, not a trigger.
                let isTrigger = (i == 0) || chars[i - 1].isWhitespace
                guard isTrigger else { return nil }
                let query = String(chars[(i + 1)..<chars.count])
                // Bail if the query contains whitespace — that means the
                // user has moved past the `@foo` token.
                if query.contains(where: { $0.isWhitespace }) { return nil }
                return AtToken(atOffset: i, endOffset: chars.count, query: query)
            }
            if c.isWhitespace { return nil }
            i -= 1
        }
        return nil
    }

    /// Replace `token` in `input` with `@path` (keeping the leading `@`
    /// and adding a trailing space so the user can keep typing).
    static func replace(_ token: AtToken, with path: String, in input: String) -> String {
        let chars = Array(input)
        let prefix = String(chars[0..<token.atOffset])
        let suffix = String(chars[token.endOffset..<chars.count])
        return prefix + "@" + path + " " + suffix
    }
}

// MARK: - Popup view

struct AtFilePopup: View {
    let matches: [String]
    @Binding var selected: Int
    let onPick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Image(systemName: "doc.text")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.kilnTextTertiary)
                Text("File reference")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.kilnTextTertiary)
                    .tracking(0.6)
                Spacer()
                Text("↑↓ navigate · ⏎ pick · esc close")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.kilnTextTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(Array(matches.prefix(8).enumerated()), id: \.offset) { idx, path in
                            AtFileRow(path: path, selected: idx == selected)
                                .id(idx)
                                .onTapGesture { onPick(path) }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                }
                .frame(maxHeight: 220)
                .onChange(of: selected) { _, newValue in
                    withAnimation(.linear(duration: 0.08)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
        }
        .background(Color.kilnSurface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.kilnBorder).frame(height: 1)
        }
    }
}

/// Single row: monospaced filename first, dimmed directory after. Icon
/// picked from the filename extension so common file types feel
/// recognizable at a glance without going full IDE-chrome.
private struct AtFileRow: View {
    let path: String
    let selected: Bool

    private var components: (name: String, dir: String) {
        if let slash = path.lastIndex(of: "/") {
            let name = String(path[path.index(after: slash)...])
            let dir = String(path[..<slash])
            return (name, dir)
        }
        return (path, "")
    }

    private var icon: String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "swift", "js", "ts", "jsx", "tsx", "py", "rb", "go", "rs", "c", "cpp", "h", "java", "kt":
            return "chevron.left.forwardslash.chevron.right"
        case "md", "markdown", "txt", "rst":
            return "text.alignleft"
        case "json", "yaml", "yml", "toml", "xml", "plist":
            return "curlybraces"
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "svg":
            return "photo"
        case "pdf":
            return "doc.richtext"
        case "zip", "tar", "gz", "dmg":
            return "archivebox"
        default:
            return "doc"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(selected ? Color.kilnAccent : Color.kilnTextTertiary)
                .frame(width: 14)
            let c = components
            Text(c.name)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(selected ? Color.kilnText : Color.kilnText.opacity(0.9))
                .lineLimit(1)
                .truncationMode(.middle)
            if !c.dir.isEmpty {
                Text(c.dir)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.kilnTextTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 6)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(selected ? Color.kilnAccent.opacity(0.12) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
