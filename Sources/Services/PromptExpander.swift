import Foundation
import AppKit

/// Expands `{{var}}` tokens in prompt text before send. Supports:
///   {{clipboard}}       - current clipboard text
///   {{date}}            - today (ISO: YYYY-MM-DD)
///   {{time}}            - current local time (HH:mm)
///   {{datetime}}        - ISO-8601 datetime
///   {{workdir}}         - active session working directory
///   {{session}}         - active session name
///   {{model}}           - active session model id
///   {{file:<path>}}     - contents of a file (absolute or ~-expanded path)
///
/// Unrecognized tokens pass through unchanged. Errors (e.g. missing file)
/// substitute a tagged message so the user can see what failed without the
/// send breaking.
struct PromptExpander {
    struct Context {
        let workdir: String?
        let sessionName: String?
        let model: String?
    }

    static func expand(_ text: String, context: Context) -> String {
        // Token regex: {{ name }} or {{ name : arg }}
        let pattern = #"\{\{\s*([a-zA-Z_]+)(?:\s*:\s*([^}]+?))?\s*\}\}"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }

        var result = text
        // Walk backwards so range indices don't shift.
        for match in matches.reversed() {
            let full = ns.substring(with: match.range)
            let name = ns.substring(with: match.range(at: 1)).lowercased()
            let arg: String? = {
                let r = match.range(at: 2)
                return r.location == NSNotFound ? nil : ns.substring(with: r).trimmingCharacters(in: .whitespaces)
            }()

            let replacement = resolve(name: name, arg: arg, context: context) ?? full
            if let range = result.range(of: full) {
                result.replaceSubrange(range, with: replacement)
            }
        }
        return result
    }

    private static func resolve(name: String, arg: String?, context: Context) -> String? {
        let f = DateFormatter()
        switch name {
        case "clipboard":
            return NSPasteboard.general.string(forType: .string) ?? "[clipboard empty]"
        case "date":
            f.dateFormat = "yyyy-MM-dd"
            return f.string(from: Date())
        case "time":
            f.dateFormat = "HH:mm"
            return f.string(from: Date())
        case "datetime":
            f.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
            return f.string(from: Date())
        case "workdir":
            return context.workdir ?? "~"
        case "session":
            return context.sessionName ?? "(untitled)"
        case "model":
            return context.model ?? ""
        case "file":
            guard let path = arg else { return "[missing path]" }
            let expanded = (path as NSString).expandingTildeInPath
            if let data = try? String(contentsOfFile: expanded, encoding: .utf8) {
                return data
            }
            return "[file not found: \(path)]"
        default:
            return nil
        }
    }

    static var availableVariables: [(token: String, description: String)] {
        [
            ("{{clipboard}}", "Current clipboard text"),
            ("{{date}}", "Today's date (YYYY-MM-DD)"),
            ("{{time}}", "Current time (HH:mm)"),
            ("{{datetime}}", "ISO-8601 datetime"),
            ("{{workdir}}", "Active session working directory"),
            ("{{session}}", "Active session name"),
            ("{{model}}", "Active session model"),
            ("{{file:path}}", "Contents of a file"),
        ]
    }
}
