import SwiftUI

// MARK: - Parser
//
// Claude Code's Edit/Write/MultiEdit tools take JSON input with a known
// shape. We parse that JSON to extract before/after text so we can render
// a real diff instead of raw JSON. If anything fails, we return nil and
// the caller falls back to the JSON view.

struct EditHunk: Identifiable, Sendable {
    let id: String
    let filePath: String
    let before: String
    let after: String
}

struct ParsedEditDiff: Sendable {
    let kind: Kind
    let hunks: [EditHunk]

    enum Kind: Sendable { case edit, write, multiEdit }
}

enum EditDiffParser {
    /// Returns nil if the tool isn't an Edit/Write variant or the JSON can't
    /// be parsed — caller falls back to default rendering.
    static func parse(toolName: String, rawInput: String) -> ParsedEditDiff? {
        let data = Data(rawInput.utf8)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        let lower = toolName.lowercased()
        switch lower {
        case "edit":
            guard let path = json["file_path"] as? String,
                  let old = json["old_string"] as? String,
                  let new = json["new_string"] as? String else { return nil }
            return ParsedEditDiff(
                kind: .edit,
                hunks: [EditHunk(id: UUID().uuidString, filePath: path, before: old, after: new)]
            )

        case "write":
            guard let path = json["file_path"] as? String,
                  let content = json["content"] as? String else { return nil }
            return ParsedEditDiff(
                kind: .write,
                hunks: [EditHunk(id: UUID().uuidString, filePath: path, before: "", after: content)]
            )

        case "multiedit":
            guard let path = json["file_path"] as? String,
                  let edits = json["edits"] as? [[String: Any]] else { return nil }
            let hunks: [EditHunk] = edits.compactMap { edit in
                guard let old = edit["old_string"] as? String,
                      let new = edit["new_string"] as? String else { return nil }
                return EditHunk(id: UUID().uuidString, filePath: path, before: old, after: new)
            }
            guard !hunks.isEmpty else { return nil }
            return ParsedEditDiff(kind: .multiEdit, hunks: hunks)

        default:
            return nil
        }
    }
}

// MARK: - View

struct EditDiffView: View {
    let diff: ParsedEditDiff

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: kindIcon)
                    .font(.system(size: 10))
                    .foregroundStyle(Color.kilnAccent)
                Text(kindLabel)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.kilnTextTertiary)
                    .tracking(0.5)
                if let path = diff.hunks.first?.filePath {
                    Text(path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.kilnTextSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                if diff.hunks.count > 1 {
                    Text("\(diff.hunks.count) hunks")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.kilnTextTertiary)
                }
            }

            ForEach(diff.hunks) { hunk in
                HunkView(hunk: hunk, isWrite: diff.kind == .write)
            }
        }
    }

    private var kindIcon: String {
        switch diff.kind {
        case .edit: return "pencil.line"
        case .write: return "square.and.pencil"
        case .multiEdit: return "square.stack.3d.up"
        }
    }

    private var kindLabel: String {
        switch diff.kind {
        case .edit: return "EDIT"
        case .write: return "WRITE"
        case .multiEdit: return "MULTI-EDIT"
        }
    }
}

private struct HunkView: View {
    let hunk: EditHunk
    let isWrite: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isWrite {
                // Write: single "added" block
                DiffLines(text: hunk.after, kind: .added, label: "New file")
            } else {
                // Edit: before + after
                DiffLines(text: hunk.before, kind: .removed, label: "Before")
                DiffLines(text: hunk.after, kind: .added, label: "After")
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.kilnBorder, lineWidth: 1))
    }
}

private struct DiffLines: View {
    let text: String
    let kind: DiffKind
    let label: String

    enum DiffKind {
        case added, removed
        var sign: String { self == .added ? "+" : "-" }
        var bg: Color { self == .added ? Color.green.opacity(0.08) : Color.red.opacity(0.08) }
        var sideBar: Color { self == .added ? Color.green.opacity(0.7) : Color.red.opacity(0.7) }
        var signColor: Color { self == .added ? Color.green : Color.red.opacity(0.9) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(label)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.kilnTextTertiary)
                    .tracking(0.5)
                Spacer()
                Text("\(lineCount) line\(lineCount == 1 ? "" : "s")")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.kilnTextTertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.kilnSurface)

            ScrollView {
                HStack(alignment: .top, spacing: 0) {
                    // Gutter: + or -
                    VStack(alignment: .center, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, _ in
                            Text(kind.sign)
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .foregroundStyle(kind.signColor)
                                .frame(width: 18, height: 16)
                        }
                    }
                    .background(kind.sideBar.opacity(0.15))

                    // Content
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                            Text(line.isEmpty ? " " : line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color.kilnText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 6)
                                .frame(height: 16)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
            .frame(maxHeight: 220)
            .background(kind.bg)
        }
    }

    private var lines: [String] {
        text.isEmpty ? [""] : text.components(separatedBy: "\n")
    }

    private var lineCount: Int { lines.count }
}
