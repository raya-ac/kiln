import Foundation

/// Lightweight git status probe. Reads HEAD + status in-process via `git`
/// from the user's PATH. Synchronous — callers should cache.
enum GitStatus {
    struct Info: Equatable, Sendable {
        let branch: String
        let dirtyCount: Int
        let isRepo: Bool
    }

    /// Per-file status drawn in the file tree. Condensed from porcelain
    /// output — the two-character XY code tells us both the index and
    /// worktree state, but the tree only needs to tell the user "something
    /// changed here" with a hint at what kind.
    enum FileState: Sendable {
        case modified    // M in either column
        case added       // A in index
        case deleted     // D in either column
        case untracked   // ??
        case renamed     // R in index
        case conflicted  // U or both-side changes

        var marker: String {
            switch self {
            case .modified: return "M"
            case .added: return "A"
            case .deleted: return "D"
            case .untracked: return "U"
            case .renamed: return "R"
            case .conflicted: return "!"
            }
        }
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

    /// Per-file status map keyed by absolute path. Used by the file tree
    /// to draw per-row status markers. Cached with a separate, shorter
    /// TTL than `info` — status churns fast while Claude edits, and the
    /// tree wants to feel live.
    private static let fileTTL: TimeInterval = 3
    nonisolated(unsafe) private static var fileCache: [String: ([String: FileState], Date)] = [:]

    static func fileStatuses(for workDir: String) -> [String: FileState] {
        lock.lock()
        if let (cached, date) = fileCache[workDir], Date().timeIntervalSince(date) < fileTTL {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let fresh = probeFiles(workDir: workDir)
        lock.lock()
        fileCache[workDir] = (fresh, Date())
        lock.unlock()
        return fresh
    }

    /// Force the next call to `fileStatuses` to refetch. Call after tool
    /// calls complete so the tree reflects Claude's edits immediately.
    static func invalidate(workDir: String) {
        lock.lock()
        fileCache.removeValue(forKey: workDir)
        cache.removeValue(forKey: workDir)
        lock.unlock()
    }

    private static func probeFiles(workDir: String) -> [String: FileState] {
        let gitDir = (workDir as NSString).appendingPathComponent(".git")
        guard FileManager.default.fileExists(atPath: gitDir) else { return [:] }
        let porcelain = run(["git", "-C", workDir, "status", "--porcelain=v1", "-uall"]) ?? ""
        var out: [String: FileState] = [:]
        for raw in porcelain.split(separator: "\n", omittingEmptySubsequences: true) {
            // Porcelain v1 lines: "XY path" where X is index state, Y is
            // worktree state. Either column can be a space. Renames show
            // as "R  old -> new" — we only care about the new path.
            let line = String(raw)
            guard line.count >= 3 else { continue }
            let xy = String(line.prefix(2))
            let rest = String(line.dropFirst(3))
            let path: String = {
                if xy.contains("R"), let arrow = rest.range(of: " -> ") {
                    return String(rest[arrow.upperBound...])
                }
                return rest
            }()
            let abs = (workDir as NSString).appendingPathComponent(path)
            let state: FileState
            if xy.contains("U") || xy == "AA" || xy == "DD" { state = .conflicted }
            else if xy == "??" { state = .untracked }
            else if xy.contains("R") { state = .renamed }
            else if xy.contains("A") { state = .added }
            else if xy.contains("D") { state = .deleted }
            else if xy.contains("M") { state = .modified }
            else { continue }
            out[abs] = state
        }
        return out
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
