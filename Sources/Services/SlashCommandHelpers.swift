import Foundation
import AppKit

/// Shared helpers used by the ~30 local slash commands in ComposerView.
/// These intentionally live outside the store — they're either pure shell
/// shims (git wrappers) or UI-level clipboard/open operations that don't
/// need to touch the session graph.
enum SlashHelpers {
    // MARK: - Shell

    /// Runs an argv-style command and captures stdout/stderr. Never invoked
    /// via /bin/sh — we pass a `launchPath` + args array so shell-meta in
    /// user input (filenames, commit messages, branch names) can't break out.
    ///
    /// Pipes are drained concurrently before `waitUntilExit`. This avoids
    /// the classic macOS deadlock: if a child process writes more than the
    /// pipe buffer (~64 KB) to stdout and we haven't read it, the child
    /// blocks on write while we block on wait — forever. `git status` in
    /// a dir with many untracked files blows past 64 KB easily.
    static func run(_ path: String, args: [String], in workDir: String? = nil) -> (status: Int32, out: String, err: String) {
        let p = Process()
        p.launchPath = path
        p.arguments = args
        if let workDir {
            p.currentDirectoryURL = URL(fileURLWithPath: workDir)
        }
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        do {
            try p.run()
        } catch {
            return (-1, "", "\(error)")
        }

        // Drain both pipes concurrently. readDataToEndOfFile returns when
        // the write end closes (process exits), so we use a DispatchGroup
        // to wait for both reads rather than relying on waitUntilExit.
        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        p.waitUntilExit()
        group.wait()

        let out = String(data: outData, encoding: .utf8) ?? ""
        let err = String(data: errData, encoding: .utf8) ?? ""
        return (p.terminationStatus, out, err)
    }

    /// Git shortcut — `/usr/bin/git` is on every stock macOS install via
    /// Xcode CLTs. We tolerate its absence by returning a failed status;
    /// the caller surfaces the error as a toast.
    @discardableResult
    static func git(_ args: [String], in workDir: String) -> (status: Int32, out: String, err: String) {
        run("/usr/bin/git", args: args, in: workDir)
    }

    // MARK: - Clipboard

    static func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: - Finder / Terminal / Editor

    static func revealInFinder(_ path: String) {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Opens Terminal.app at the given directory. Uses NSWorkspace.open
    /// with a URL — avoids AppleScript (which needs permissions) and works
    /// even if Terminal isn't the user's default shell app.
    static func openTerminal(at path: String) {
        let expanded = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded, isDirectory: true)
        let termURL = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        let cfg = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([url], withApplicationAt: termURL, configuration: cfg) { _, _ in }
    }

    /// Try a few common editor CLIs (VS Code, Cursor, Zed) before falling
    /// back to Finder. Probing with `which` keeps us honest about what's
    /// actually installed rather than shelling out blindly.
    static func openInEditor(_ path: String) {
        let expanded = (path as NSString).expandingTildeInPath
        for bin in ["/usr/local/bin/code", "/opt/homebrew/bin/code",
                    "/usr/local/bin/cursor", "/opt/homebrew/bin/cursor",
                    "/usr/local/bin/zed", "/opt/homebrew/bin/zed"] {
            if FileManager.default.isExecutableFile(atPath: bin) {
                let p = Process()
                p.launchPath = bin
                p.arguments = [expanded]
                try? p.run()
                return
            }
        }
        // Last resort — reveal in Finder rather than fail silently.
        revealInFinder(expanded)
    }

    // MARK: - Message content extraction

    /// The plain text of the last assistant message. Concatenates all text
    /// blocks (skipping tool calls/results) — that's what "the reply" is
    /// to the user, which is what they mean by `/copy`.
    static func lastAssistantText(in session: Session?) -> String? {
        guard let s = session else { return nil }
        guard let msg = s.messages.last(where: { $0.role == .assistant }) else { return nil }
        let parts: [String] = msg.blocks.compactMap { block in
            if case .text(let t) = block { return t }
            return nil
        }
        let joined = parts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return joined.isEmpty ? nil : joined
    }

    /// Extracts the last ``` fenced code block from the last assistant
    /// message. Useful for `/copycode` and `/save` where the user wants
    /// just the snippet, not the surrounding prose.
    static func lastCodeBlock(in session: Session?) -> String? {
        guard let text = lastAssistantText(in: session) else { return nil }
        // Scan for the last fenced block. We allow ``` with or without a
        // language tag and terminate on the next ``` at line start.
        let lines = text.components(separatedBy: "\n")
        var blocks: [[String]] = []
        var current: [String]? = nil
        for line in lines {
            if line.hasPrefix("```") {
                if current != nil {
                    blocks.append(current!)
                    current = nil
                } else {
                    current = []
                }
            } else if current != nil {
                current!.append(line)
            }
        }
        return blocks.last?.joined(separator: "\n")
    }

    // MARK: - Stats

    /// Rough word count across all text blocks in the session. Matches
    /// what the composer hint strip uses so numbers feel consistent.
    static func wordCount(in session: Session?) -> Int {
        guard let s = session else { return 0 }
        var count = 0
        for msg in s.messages {
            for block in msg.blocks {
                if case .text(let t) = block {
                    count += t.split(whereSeparator: { $0.isWhitespace }).count
                }
            }
        }
        return count
    }

    /// Shallow `ls` of a directory. Skips dotfiles to keep noise down
    /// and caps at 200 entries so `/ls` on `$HOME` doesn't dump a wall.
    static func listDir(_ path: String, maxEntries: Int = 200) -> String {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return "(unreadable)"
        }
        let filtered = entries.filter { !$0.hasPrefix(".") }.sorted()
        let clipped = filtered.prefix(maxEntries)
        let more = filtered.count > maxEntries ? "\n… (+\(filtered.count - maxEntries) more)" : ""
        return clipped.joined(separator: "\n") + more
    }

    /// A 2-level tree using `find` — available on every macOS, no brew
    /// `tree` required. Dotdirs (.git, node_modules/.cache, etc.) are
    /// pruned at the shell level so output stays readable.
    static func tree(_ path: String, depth: Int = 2) -> String {
        let r = run("/usr/bin/find", args: [
            path,
            "-maxdepth", String(depth),
            "-not", "-path", "*/.*",
            "-not", "-path", "*/node_modules/*",
            "-not", "-path", "*/.build/*",
            "-not", "-path", "*/dist/*",
        ])
        // Strip the path prefix to keep output locally-scoped.
        let lines = r.out.split(separator: "\n").map { line -> String in
            let s = String(line)
            if s == path { return "." }
            if s.hasPrefix(path + "/") { return String(s.dropFirst(path.count + 1)) }
            return s
        }
        return lines.prefix(300).joined(separator: "\n")
    }

    /// 4-chars-per-token heuristic. Not accurate for code or CJK but close
    /// enough to give the user a "am I about to blow context" read.
    static func approximateTokens(in session: Session?) -> Int {
        guard let s = session else { return 0 }
        var chars = 0
        for msg in s.messages {
            for block in msg.blocks {
                switch block {
                case .text(let t): chars += t.count
                case .thinking(let t): chars += t.count
                case .toolUse(let b): chars += b.input.count
                case .toolResult(let b): chars += b.content.count
                default: break
                }
            }
        }
        return max(1, (chars + 3) / 4)
    }
}
