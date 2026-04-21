import Foundation

/// Fire-and-forget `git add -A && git commit -m …` in the session's
/// workdir. Deliberately minimal — we don't parse output or surface
/// errors to the chat, just run it. For anything fancier the user can
/// drop to a terminal.
enum GitQuickCommit {
    /// Result of a /commit run — reported back to the user via toast.
    /// We classify so the UI can pick an icon without re-parsing output.
    enum Outcome {
        case committed(short: String)
        case nothingToCommit
        case failed(String)
    }

    static func run(workDir: String, message: String) -> Outcome {
        guard !message.isEmpty else { return .failed("empty message") }
        _ = shell(["git", "-C", workDir, "add", "-A"])
        // Capture both stdout and stderr — `nothing to commit` writes to
        // stdout but non-zero exit writes to stderr. Distinguish by exit.
        let (code, out) = shellWithCode(["git", "-C", workDir, "commit", "-m", message])
        GitStatus.invalidate(workDir: workDir)
        if code == 0 {
            // Grab the short hash for the toast.
            let short = shell(["git", "-C", workDir, "rev-parse", "--short", "HEAD"])?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "HEAD"
            return .committed(short: short)
        }
        if out.contains("nothing to commit") || out.contains("no changes added") {
            return .nothingToCommit
        }
        return .failed(out.split(separator: "\n").first.map(String.init) ?? "unknown error")
    }

    /// Raw `git diff` output for the current worktree (staged + unstaged).
    /// Nil if not a repo or if git isn't reachable.
    static func diff(workDir: String) -> String? {
        let gitDir = (workDir as NSString).appendingPathComponent(".git")
        guard FileManager.default.fileExists(atPath: gitDir) else { return nil }
        let unstaged = shell(["git", "-C", workDir, "diff"]) ?? ""
        let staged = shell(["git", "-C", workDir, "diff", "--cached"]) ?? ""
        if unstaged.isEmpty && staged.isEmpty { return "" }
        var out = ""
        if !staged.isEmpty { out += "# Staged\n\n" + staged + "\n" }
        if !unstaged.isEmpty { out += "# Unstaged\n\n" + unstaged + "\n" }
        return out
    }

    private static func shellWithCode(_ args: [String]) -> (Int32, String) {
        let proc = Process()
        proc.launchPath = "/usr/bin/env"
        proc.arguments = args
        let out = Pipe(); let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do {
            try proc.run()
            let o = out.fileHandleForReading.readDataToEndOfFile()
            let e = err.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let combined = (String(data: o, encoding: .utf8) ?? "") +
                           (String(data: e, encoding: .utf8) ?? "")
            return (proc.terminationStatus, combined)
        } catch {
            return (-1, "\(error)")
        }
    }

    @discardableResult
    private static func shell(_ args: [String]) -> String? {
        let proc = Process()
        proc.launchPath = "/usr/bin/env"
        proc.arguments = args
        let out = Pipe(); let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do {
            try proc.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
