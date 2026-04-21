import Foundation

/// Fire-and-forget `git add -A && git commit -m …` in the session's
/// workdir. Deliberately minimal — we don't parse output or surface
/// errors to the chat, just run it. For anything fancier the user can
/// drop to a terminal.
enum GitQuickCommit {
    static func run(workDir: String, message: String) {
        guard !message.isEmpty else { return }
        _ = shell(["git", "-C", workDir, "add", "-A"])
        _ = shell(["git", "-C", workDir, "commit", "-m", message])
        // Bust GitStatus caches so the branch badge refreshes soon.
        GitStatus.invalidate(workDir: workDir)
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
