import Foundation

/// Tracks what's changed in a session's workdir relative to HEAD. Powers
/// the activity chip above the composer — click, see a list of files
/// Claude touched, click one for a diff.
///
/// We snapshot `git status --porcelain` on two events:
///   1. When a session first becomes active (baseline).
///   2. When a streaming response completes (`.done`).
///
/// No polling — git status on a large repo is cheap (tens of ms) but
/// not free, and polling while the user is just reading chat would be
/// wasteful. Event-driven refresh is accurate enough: files only change
/// when Claude's tools run, which ends with `.done`.
struct ChangedFile: Identifiable, Hashable, Sendable {
    let path: String
    let status: String   // "M", "A", "D", "??", "R" etc.
    var id: String { path }

    /// Short label for the status column in the popover. We collapse
    /// git's two-character XY codes (index/worktree) to whichever half
    /// is non-space, favoring the worktree side since that's what the
    /// user sees.
    var shortStatus: String {
        let trimmed = status.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "·" }
        if trimmed.count == 2 {
            let y = trimmed.last!
            if y != " " { return String(y) }
            return String(trimmed.first!)
        }
        return trimmed
    }
}

enum WorkdirActivity {
    /// Returns the current `git status --porcelain` for `workDir`, or
    /// nil if the directory isn't a git repo, doesn't exist, or git
    /// isn't installed.
    static func scan(_ workDir: String) -> [ChangedFile]? {
        // Guard against the dir being gone or unreadable — Process with a
        // non-existent currentDirectoryURL throws at launch on some macOS
        // versions, which is then only partially caught.
        var isDir: ObjCBool = false
        let expanded = (workDir as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        let r = SlashHelpers.git(["status", "--porcelain"], in: expanded)
        guard r.status == 0 else { return nil }
        var results: [ChangedFile] = []
        for line in r.out.split(separator: "\n") {
            // Porcelain v1 format: "XY PATH" or "XY ORIG -> PATH" for renames.
            // X = index status, Y = worktree status. First 2 chars are the
            // status, a space, then the path (which may contain spaces).
            guard line.count > 3 else { continue }
            let status = String(line.prefix(2))
            var path = String(line.dropFirst(3))
            // Renames show "OLD -> NEW" — we want the new path.
            if let arrow = path.range(of: " -> ") {
                path = String(path[arrow.upperBound...])
            }
            // Git sometimes quotes paths with unusual characters. Strip
            // surrounding quotes — we're showing this in UI, not shelling.
            if path.hasPrefix("\"") && path.hasSuffix("\"") {
                path = String(path.dropFirst().dropLast())
            }
            results.append(ChangedFile(path: path, status: status))
        }
        return results
    }

    /// Diff for a single file, suitable for the existing DiffSheet. Falls
    /// back to `git diff` without HEAD for untracked files.
    static func diff(_ workDir: String, file: String) -> String? {
        // Try HEAD-relative first — covers both staged and unstaged edits.
        let r = SlashHelpers.git(["diff", "HEAD", "--", file], in: workDir)
        if r.status == 0, !r.out.isEmpty { return r.out }
        // Untracked file — no HEAD-relative diff exists. Show "new file"
        // as a synthetic diff so the user sees *something* meaningful.
        let expanded = (workDir as NSString).appendingPathComponent(file)
        if let body = try? String(contentsOfFile: expanded, encoding: .utf8) {
            let header = "diff --git a/\(file) b/\(file)\nnew file\n--- /dev/null\n+++ b/\(file)\n"
            let numbered = body.split(separator: "\n", omittingEmptySubsequences: false)
                .map { "+\($0)" }
                .joined(separator: "\n")
            return header + numbered
        }
        return nil
    }
}
