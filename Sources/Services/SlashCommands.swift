import Foundation

/// Claude Code slash commands exposed in the composer via `/` autocomplete.
/// Includes built-ins shipped by Claude Code plus any user-defined agents
/// discovered in `~/.claude/agents/`.
struct SlashCommand: Identifiable, Hashable, Sendable {
    let id: String        // e.g. "compact"
    let label: String     // "/compact"
    let description: String
    let kind: Kind

    enum Kind: Sendable { case builtin, agent, kiln }
}

enum SlashCommands {
    /// Every slash command is handled client-side. Claude Code's own
    /// slash commands only work in interactive mode; Kiln uses `--print`
    /// where they'd be treated as plain text, so we intercept and perform
    /// the operation locally instead of sending the slash command to Claude.
    static let builtins: [SlashCommand] = [
        .init(id: "compact", label: "/compact", description: "Ask Claude to summarize this session, then reset to the summary", kind: .kiln),
        .init(id: "clear", label: "/clear", description: "Clear all messages in this session", kind: .kiln),
        .init(id: "fork", label: "/fork", description: "Fork this session from the last message", kind: .kiln),
        .init(id: "export", label: "/export", description: "Export this chat as markdown", kind: .kiln),
        .init(id: "retry", label: "/retry", description: "Retry the last user message", kind: .kiln),
        .init(id: "model", label: "/model", description: "Cycle to the next model", kind: .kiln),
        .init(id: "compare", label: "/compare", description: "Re-fire last message in a twin session with a different model", kind: .kiln),
        .init(id: "interrupt", label: "/interrupt", description: "Stop the current generation", kind: .kiln),
        .init(id: "instructions", label: "/instructions", description: "Edit per-session system prompt", kind: .kiln),
        .init(id: "title", label: "/title", description: "Ask Claude for a short title, rename the session", kind: .kiln),
        .init(id: "settings", label: "/settings", description: "Open app settings", kind: .kiln),
        .init(id: "search", label: "/search", description: "Search all messages across sessions", kind: .kiln),
        .init(id: "memory", label: "/memory", description: "Open the engram dashboard in your browser", kind: .kiln),
        .init(id: "focus", label: "/focus", description: "Toggle focus mode (hide side panels)", kind: .kiln),
    ]

    /// No longer used — kept empty for source compat. Previously held `//`
    /// commands; everything is `/` now.
    static let kilnCommands: [SlashCommand] = []

    /// Scan `~/.claude/agents/` for `.md` files — each is an agent.
    static func loadAgents() -> [SlashCommand] {
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/agents")
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return items
            .filter { $0.hasSuffix(".md") }
            .map { String($0.dropLast(3)) }
            .sorted()
            .map { name in
                SlashCommand(
                    id: "agent.\(name)",
                    label: "/\(name)",
                    description: "Agent from ~/.claude/agents/\(name).md",
                    kind: .agent
                )
            }
    }

    static func all() -> [SlashCommand] {
        builtins + kilnCommands + loadAgents()
    }
}
