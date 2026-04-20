import Foundation

/// Reads MCP server definitions from the user's Claude settings
/// (`~/.claude.json`) so Kiln can surface them in the UI.
///
/// Read-only by design — editing `~/.claude.json` is the user's job; this
/// just exposes what's there. Parsing is tolerant: malformed entries are
/// skipped, not errored.
struct MCPServerInfo: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let kind: String          // stdio | http | sse | ...
    let command: String?      // stdio only
    let args: [String]
    let url: String?          // http/sse only
    let env: [String: String]
    let disabled: Bool
}

enum MCPServerReader {
    static func loadAll() -> [MCPServerInfo] {
        let path = NSHomeDirectory() + "/.claude.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = json["mcpServers"] as? [String: Any]
        else { return [] }

        var out: [MCPServerInfo] = []
        for (name, value) in servers {
            guard let dict = value as? [String: Any] else { continue }
            let kind = (dict["type"] as? String) ?? "stdio"
            let command = dict["command"] as? String
            let args = (dict["args"] as? [String]) ?? []
            let url = dict["url"] as? String
            let env = (dict["env"] as? [String: String]) ?? [:]
            let disabled = (dict["disabled"] as? Bool) ?? false
            out.append(MCPServerInfo(
                id: name,
                name: name,
                kind: kind,
                command: command,
                args: args,
                url: url,
                env: env,
                disabled: disabled
            ))
        }
        return out.sorted { $0.name < $1.name }
    }

    static var claudeSettingsPath: String { NSHomeDirectory() + "/.claude.json" }
}
