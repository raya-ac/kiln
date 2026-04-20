import Foundation

/// Detects and applies unified-diff patches embedded in assistant markdown.
/// Looks for ```diff / ```patch fenced code blocks; applies via `git apply`.
///
/// Deliberately conservative — if `git apply --check` fails, we don't
/// offer the button. Never silently modifies the tree; always requires a
/// user click.
struct DetectedPatch: Identifiable, Hashable, Sendable {
    let id: String
    let body: String        // the unified-diff text
    let fileCount: Int      // rough `+++ b/...` count
    let firstFile: String?

    static func detect(in markdown: String) -> [DetectedPatch] {
        var results: [DetectedPatch] = []
        // ```diff / ```patch fenced blocks
        let pattern = #"```(?:diff|patch)\s*\n([\s\S]*?)```"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = markdown as NSString
        for match in regex.matches(in: markdown, range: NSRange(location: 0, length: ns.length)) {
            let body = ns.substring(with: match.range(at: 1))
            // Heuristic: must contain at least one `--- ` or `+++ ` line.
            guard body.contains("--- ") || body.contains("+++ ") else { continue }
            let files = body
                .split(separator: "\n")
                .filter { $0.hasPrefix("+++ ") }
                .map { String($0.dropFirst(4)) }
            let firstFile = files.first.map {
                // Strip leading "a/" or "b/"
                $0.hasPrefix("a/") || $0.hasPrefix("b/") ? String($0.dropFirst(2)) : $0
            }
            results.append(DetectedPatch(
                id: UUID().uuidString,
                body: body,
                fileCount: files.count,
                firstFile: firstFile
            ))
        }
        return results
    }

    enum ApplyResult: Sendable {
        case ok
        case failed(String)
    }

    /// Apply the patch in `workDir` via `git apply`. Runs `--check` first.
    @discardableResult
    static func apply(_ patch: DetectedPatch, in workDir: String) -> ApplyResult {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiln-patch-\(patch.id).diff")
        do {
            try patch.body.write(to: tempURL, atomically: true, encoding: .utf8)
        } catch {
            return .failed("couldn't write temp patch: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // Check first
        let check = run(["/usr/bin/env", "git", "-C", workDir, "apply", "--check", tempURL.path])
        if check.status != 0 {
            return .failed(check.output.isEmpty ? "git apply --check failed" : check.output)
        }

        // Apply
        let result = run(["/usr/bin/env", "git", "-C", workDir, "apply", tempURL.path])
        if result.status != 0 {
            return .failed(result.output.isEmpty ? "git apply failed" : result.output)
        }
        return .ok
    }

    private static func run(_ args: [String]) -> (status: Int32, output: String) {
        let proc = Process()
        proc.launchPath = args[0]
        proc.arguments = Array(args.dropFirst())
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let out = String(data: data, encoding: .utf8) ?? ""
            return (proc.terminationStatus, out.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return (-1, error.localizedDescription)
        }
    }
}
