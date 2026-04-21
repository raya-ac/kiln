import SwiftUI

// MARK: - What's New popup
//
// On first launch after an update, surface the CHANGELOG section for the
// version we just booted into. We track "last seen" in UserDefaults so
// the popup only fires once per version. The CHANGELOG lives bundled as
// a Resource (make-app-bundle.sh copies it into Contents/Resources),
// and we scrape the `## [X.Y.Z] — date` header for the running version.
//
// Dev builds don't bundle the CHANGELOG, so we also look for it next to
// the executable (same walk-up trick as `versionString` in Settings).

enum WhatsNew {
    /// Short version from Info.plist, e.g. "1.3.2". Returns nil in dev
    /// runs where Info.plist isn't populated — we skip the popup there.
    static var currentVersion: String? {
        let info = Bundle.main.infoDictionary ?? [:]
        if let v = info["CFBundleShortVersionString"] as? String, !v.isEmpty {
            return v
        }
        return nil
    }

    /// Version we last showed "What's New" for. Nil on first ever launch
    /// — we still show the popup in that case so new users get context.
    static var lastSeenVersion: String? {
        UserDefaults.standard.string(forKey: "kiln.lastSeenVersion")
    }

    static func markSeen(_ version: String) {
        UserDefaults.standard.set(version, forKey: "kiln.lastSeenVersion")
    }

    /// Should the popup fire right now? True when we have a real version
    /// from the bundle and it differs from what we last stored.
    static var shouldShow: Bool {
        guard let current = currentVersion else { return false }
        return lastSeenVersion != current
    }

    /// Find the CHANGELOG — bundled as a Resource in release builds,
    /// next to the repo root in dev runs. Nil if neither exists.
    static func loadChangelog() -> String? {
        if let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
           let txt = try? String(contentsOf: url, encoding: .utf8) {
            return txt
        }
        let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: "/")
        var dir = exe.deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("CHANGELOG.md")
            if let txt = try? String(contentsOf: candidate, encoding: .utf8) {
                return txt
            }
            dir.deleteLastPathComponent()
        }
        return nil
    }

    /// Pull the body of a `## [X.Y.Z] — date` section out of the full
    /// CHANGELOG. Ends at the next top-level `## ` or EOF. Returns nil
    /// if the version header isn't found.
    static func sectionBody(for version: String, in changelog: String) -> String? {
        let lines = changelog.components(separatedBy: "\n")
        var start: Int?
        let headerPrefix = "## [\(version)]"
        for (i, line) in lines.enumerated() {
            if line.hasPrefix(headerPrefix) {
                start = i + 1
                break
            }
        }
        guard let s = start else { return nil }
        var end = lines.count
        for j in s..<lines.count where lines[j].hasPrefix("## ") {
            end = j
            break
        }
        // Trim leading/trailing blank lines for neater rendering.
        var body = Array(lines[s..<end])
        while body.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { body.removeFirst() }
        while body.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { body.removeLast() }
        return body.isEmpty ? nil : body.joined(separator: "\n")
    }
}

struct WhatsNewView: View {
    let version: String
    let notes: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.kilnAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("What's new in Kiln \(version)")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Here's what changed since your last launch.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)

            Divider()

            ScrollView {
                ChangelogMarkdown(text: notes)
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 260, maxHeight: 360)

            Divider()

            HStack {
                Spacer()
                Button("Got it") { onDismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 520)
    }
}

/// Minimal markdown renderer covering what our CHANGELOG actually uses:
/// `### Heading` subheads, `- ` bullets, and inline `code`. Anything else
/// is rendered as plain text. Kept hand-rolled so we don't pull
/// AttributedString markdown into a surface that just needs bullets.
private struct ChangelogMarkdown: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let s):
                    Text(s)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.top, 4)
                case .bullet(let s):
                    HStack(alignment: .top, spacing: 8) {
                        Text("•").foregroundStyle(.secondary)
                        Text(inline(s))
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case .paragraph(let s):
                    Text(inline(s))
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private enum Block { case heading(String), bullet(String), paragraph(String) }

    private var blocks: [Block] {
        var out: [Block] = []
        var pendingBullet: String?
        for raw in text.components(separatedBy: "\n") {
            let line = raw
            if line.hasPrefix("### ") {
                if let b = pendingBullet { out.append(.bullet(b)); pendingBullet = nil }
                out.append(.heading(String(line.dropFirst(4))))
            } else if line.hasPrefix("- ") {
                if let b = pendingBullet { out.append(.bullet(b)) }
                pendingBullet = String(line.dropFirst(2))
            } else if line.hasPrefix("  ") && pendingBullet != nil {
                // continuation of previous bullet
                pendingBullet = (pendingBullet ?? "") + " " + line.trimmingCharacters(in: .whitespaces)
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if let b = pendingBullet { out.append(.bullet(b)); pendingBullet = nil }
            } else {
                if let b = pendingBullet { out.append(.bullet(b)); pendingBullet = nil }
                out.append(.paragraph(line))
            }
        }
        if let b = pendingBullet { out.append(.bullet(b)) }
        return out
    }

    /// Render `inline code` as monospaced via AttributedString. Falls
    /// back to plain text on older OSes where parsing fails.
    private func inline(_ s: String) -> AttributedString {
        if let a = try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return a
        }
        return AttributedString(s)
    }
}
