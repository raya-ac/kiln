import Foundation

/// Lightweight git status probe. Reads HEAD + status in-process via `git`
/// from the user's PATH. Synchronous — callers should cache.
enum GitStatus {
    struct Info: Equatable, Sendable {
        let branch: String
        let dirtyCount: Int
        let isRepo: Bool
    }

    /// Cache keyed by workdir → last probe. Avoids running git on every
    /// sidebar render. Invalidated after `ttl` seconds.
    private static let ttl: TimeInterval = 10
    nonisolated(unsafe) private static var cache: [String: (Info, Date)] = [:]
    private static let queue = DispatchQueue(label: "kiln.gitstatus", qos: .utility)

    static func info(for workDir: String) -> Info? {
        return queue.sync {
            if let (cached, date) = cache[workDir], Date().timeIntervalSince(date) < ttl {
                return cached.isRepo ? cached : nil
            }
            let fresh = probe(workDir: workDir)
            cache[workDir] = (fresh, Date())
            return fresh.isRepo ? fresh : nil
        }
    }

    private static func probe(workDir: String) -> Info {
        // Bail fast if no .git
        let gitDir = (workDir as NSString).appendingPathComponent(".git")
        guard FileManager.default.fileExists(atPath: gitDir) else {
            return Info(branch: "", dirtyCount: 0, isRepo: false)
        }
        let branch = run(["git", "-C", workDir, "rev-parse", "--abbrev-ref", "HEAD"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let statusOut = run(["git", "-C", workDir, "status", "--porcelain"]) ?? ""
        let dirty = statusOut
            .split(separator: "\n")
            .filter { !$0.isEmpty }
            .count
        return Info(branch: branch, dirtyCount: dirty, isRepo: !branch.isEmpty)
    }

    private static func run(_ args: [String]) -> String? {
        let proc = Process()
        proc.launchPath = "/usr/bin/env"
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
