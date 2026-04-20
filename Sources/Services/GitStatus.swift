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
    // NSLock rather than a serial DispatchQueue: previously `queue.sync`
    // wrapped `probe()`, which calls `Process.waitUntilExit()`. That spins
    // the current queue's runloop, which lets SwiftUI re-enter
    // `SessionRow.body` → `GitStatus.info` → `queue.sync` on the queue we
    // already own → libdispatch traps. A lock doesn't reenter-trap.
    private static let lock = NSLock()

    static func info(for workDir: String) -> Info? {
        lock.lock()
        if let (cached, date) = cache[workDir], Date().timeIntervalSince(date) < ttl {
            lock.unlock()
            return cached.isRepo ? cached : nil
        }
        lock.unlock()
        // Run the probe outside the lock — it shells out to git and can
        // take tens of ms; holding the lock across that would serialize
        // every sidebar row's refresh behind the slowest repo.
        let fresh = probe(workDir: workDir)
        lock.lock()
        cache[workDir] = (fresh, Date())
        lock.unlock()
        return fresh.isRepo ? fresh : nil
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
            // Read to EOF instead of `waitUntilExit()`. waitUntilExit
            // spins the current thread's runloop, which lets SwiftUI
            // observers fire and re-enter us mid-probe. readDataToEndOfFile
            // blocks on the pipe's file descriptor — no runloop work.
            // The child's stdout closes when it exits, so this returns
            // exactly when the process finishes.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
