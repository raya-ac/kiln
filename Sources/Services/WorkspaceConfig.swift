import Foundation

/// Per-project configuration loaded from `<workDir>/.kiln/config.json`.
///
/// Detected when a new session is created in a directory that contains a
/// `.kiln/` folder. Applies on top of the global settings for that session.
/// None of the fields are required.
struct WorkspaceConfig: Codable, Sendable {
    var model: String?            // e.g. "claude-sonnet-4-6"
    var systemPrompt: String?     // prepended to global system prompt
    var sessionMode: String?      // "build" | "plan"
    var permissionMode: String?   // "bypass" | "ask" | "deny"
    var snippets: [WorkspaceSnippet]?
    var hooks: WorkspaceHooks?

    struct WorkspaceHooks: Codable, Sendable {
        var onComplete: String?   // shell command
    }

    struct WorkspaceSnippet: Codable, Sendable {
        var title: String
        var body: String
    }

    static func load(for workDir: String) -> WorkspaceConfig? {
        let path = (workDir as NSString).appendingPathComponent(".kiln/config.json")
        guard FileManager.default.fileExists(atPath: path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path))
        else { return nil }
        return try? JSONDecoder().decode(WorkspaceConfig.self, from: data)
    }
}
