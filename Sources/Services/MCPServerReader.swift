import Foundation

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
    static var settingsPath: String { ModelCatalog.codexHome.appendingPathComponent("config.toml").path }

    static func loadAll() async throws -> [MCPServerInfo] {
        let data = try await CodexCLI.output(["mcp", "list", "--json"])
        let servers = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] ?? []
        return servers.compactMap { server in
            guard let name = server["name"] as? String else { return nil }
            let transport = server["transport"] as? [String: Any] ?? [:]
            return MCPServerInfo(id: name, name: name, kind: transport["type"] as? String ?? "stdio",
                command: transport["command"] as? String, args: transport["args"] as? [String] ?? [],
                url: transport["url"] as? String, env: [:], disabled: !(server["enabled"] as? Bool ?? true))
        }.sorted { $0.name < $1.name }
    }
}
