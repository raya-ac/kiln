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
        .init(id: "reload", label: "/reload", description: "Re-read all sessions from disk", kind: .kiln),
        .init(id: "color", label: "/color", description: "Set this session's color label — /color red|amber|green|blue|purple|pink|none", kind: .kiln),
        .init(id: "merge", label: "/merge", description: "Merge selected sessions into the oldest one", kind: .kiln),
        .init(id: "link", label: "/link", description: "Copy a kiln:// link to this session", kind: .kiln),
        .init(id: "rename", label: "/rename", description: "Rename this session — /rename new name here", kind: .kiln),
        .init(id: "timeline", label: "/timeline", description: "Show per-tool timing summary for this session", kind: .kiln),
        .init(id: "commit", label: "/commit", description: "Stage everything and commit — /commit message here", kind: .kiln),
        .init(id: "status", label: "/status", description: "Inject current git status as context", kind: .kiln),
        .init(id: "template", label: "/template", description: "Insert a saved prompt template — /template name", kind: .kiln),
        .init(id: "rewind", label: "/rewind", description: "Drop the last N message pairs — /rewind 3", kind: .kiln),
        .init(id: "diff", label: "/diff", description: "Show git diff for the session's workdir", kind: .kiln),
        .init(id: "clone", label: "/clone", description: "Duplicate this session's config (model, instructions, tags) with no messages", kind: .kiln),
        // --- 1.5.3+ additions: workdir / git / content / stats shortcuts ---
        .init(id: "pwd",       label: "/pwd",       description: "Show the session's working directory", kind: .kiln),
        .init(id: "open",      label: "/open",      description: "Reveal the session's workdir in Finder", kind: .kiln),
        .init(id: "terminal",  label: "/terminal",  description: "Open Terminal at the session's workdir", kind: .kiln),
        .init(id: "editor",    label: "/editor",    description: "Open the session's workdir in VS Code / Cursor / Zed", kind: .kiln),
        .init(id: "cd",        label: "/cd",        description: "Change the session's workdir — /cd ~/some/path", kind: .kiln),
        .init(id: "log",       label: "/log",       description: "Inject the last 5 git commits as context", kind: .kiln),
        .init(id: "branch",    label: "/branch",    description: "Create and check out a new git branch — /branch name", kind: .kiln),
        .init(id: "checkout",  label: "/checkout",  description: "Check out an existing git branch — /checkout name", kind: .kiln),
        .init(id: "stash",     label: "/stash",     description: "git stash push (including untracked)", kind: .kiln),
        .init(id: "unstash",   label: "/unstash",   description: "git stash pop", kind: .kiln),
        .init(id: "pull",      label: "/pull",      description: "git pull in the session's workdir", kind: .kiln),
        .init(id: "push",      label: "/push",      description: "git push in the session's workdir", kind: .kiln),
        .init(id: "blame",     label: "/blame",     description: "Inject git blame for a file — /blame path/to/file", kind: .kiln),
        .init(id: "pin",       label: "/pin",       description: "Toggle pin on this session in the sidebar", kind: .kiln),
        .init(id: "archive",   label: "/archive",   description: "Toggle archive on this session", kind: .kiln),
        .init(id: "tag",       label: "/tag",       description: "Add a tag to this session — /tag name", kind: .kiln),
        .init(id: "untag",     label: "/untag",     description: "Remove a tag from this session — /untag name", kind: .kiln),
        .init(id: "copy",      label: "/copy",      description: "Copy the last assistant message to the clipboard", kind: .kiln),
        .init(id: "copycode",  label: "/copycode",  description: "Copy the last fenced code block to the clipboard", kind: .kiln),
        .init(id: "save",      label: "/save",      description: "Save the last code block to a file — /save path/to/file", kind: .kiln),
        .init(id: "share",     label: "/share",     description: "Copy this session as markdown to the clipboard", kind: .kiln),
        .init(id: "quote",     label: "/quote",     description: "Quote the last assistant message into the composer", kind: .kiln),
        .init(id: "stats",     label: "/stats",     description: "Show message / word / rough-token counts for this session", kind: .kiln),
        .init(id: "tokens",    label: "/tokens",    description: "Show rough token count for this session", kind: .kiln),
        .init(id: "env",       label: "/env",       description: "Show this session's model, workdir and kind", kind: .kiln),
        .init(id: "undo",      label: "/undo",      description: "Alias for /rewind 1 — drop the last exchange", kind: .kiln),
        .init(id: "resend",    label: "/resend",    description: "Alias for /retry — re-fire the last user message", kind: .kiln),
        .init(id: "summary",   label: "/summary",   description: "Ask Claude for a short session title (same as /title)", kind: .kiln),
        .init(id: "todo",      label: "/todo",      description: "Append a line to TODO.md in the session workdir — /todo thing", kind: .kiln),
        .init(id: "notes",     label: "/notes",     description: "Open ~/kiln-notes.md in your editor", kind: .kiln),
        .init(id: "help",      label: "/help",      description: "Show what you can type — hint toast listing popular commands", kind: .kiln),
        // --- 1.7.0 batch: workdir inspection / git extras / quick inject / state ---
        .init(id: "ls",            label: "/ls",            description: "Inject a shallow directory listing of the workdir", kind: .kiln),
        .init(id: "tree",          label: "/tree",          description: "Inject a 2-level tree view of the workdir", kind: .kiln),
        .init(id: "grep",          label: "/grep",          description: "Ripgrep the workdir and inject top matches — /grep pattern", kind: .kiln),
        .init(id: "find",          label: "/find",          description: "Find filenames matching a pattern — /find *.swift", kind: .kiln),
        .init(id: "cat",           label: "/cat",           description: "Inject a file's contents (capped at 400 lines) — /cat path", kind: .kiln),
        .init(id: "recent",        label: "/recent",        description: "Inject files modified in the last 24h", kind: .kiln),
        .init(id: "repo",          label: "/repo",          description: "Inject git remote info (origin URL + upstream branch)", kind: .kiln),
        .init(id: "diffstat",      label: "/diffstat",      description: "Inject git diff --stat for unstaged + staged changes", kind: .kiln),
        .init(id: "upstream",      label: "/upstream",      description: "Toast the current branch's upstream", kind: .kiln),
        .init(id: "changed",       label: "/changed",       description: "Inject a list of uncommitted changed files", kind: .kiln),
        .init(id: "now",           label: "/now",           description: "Insert the current timestamp into the composer", kind: .kiln),
        .init(id: "date",          label: "/date",          description: "Insert today's date into the composer", kind: .kiln),
        .init(id: "clip",          label: "/clip",          description: "Paste clipboard text into the composer", kind: .kiln),
        .init(id: "paste",         label: "/paste",         description: "Send clipboard text as a new message immediately", kind: .kiln),
        .init(id: "expand",        label: "/expand",        description: "Open the expanded multi-line editor", kind: .kiln),
        .init(id: "killall",       label: "/killall",       description: "Interrupt every currently busy session", kind: .kiln),
        .init(id: "version",       label: "/version",       description: "Show the running Kiln version", kind: .kiln),
        .init(id: "age",           label: "/age",           description: "Show how long this session has existed", kind: .kiln),
        .init(id: "count",         label: "/count",         description: "Show the message count for this session", kind: .kiln),
        .init(id: "sessions",      label: "/sessions",      description: "Show total and archived session counts", kind: .kiln),
        .init(id: "busy",          label: "/busy",          description: "Show how many sessions are currently generating", kind: .kiln),
        .init(id: "readonly",      label: "/readonly",      description: "Toggle read-only on this session (hides the composer)", kind: .kiln),
        .init(id: "accent",        label: "/accent",        description: "Set accent color by hex — /accent f97316", kind: .kiln),
        .init(id: "random",        label: "/random",        description: "Jump to a random non-archived session", kind: .kiln),
        .init(id: "diag",          label: "/diag",          description: "Toast macOS version, arch and CPU count", kind: .kiln),
        .init(id: "bugs",          label: "/bugs",          description: "Open the Kiln issue tracker in your browser", kind: .kiln),
        .init(id: "duplicate",     label: "/duplicate",     description: "Alias for /clone", kind: .kiln),
        .init(id: "star",          label: "/star",          description: "Alias for /pin", kind: .kiln),
        .init(id: "zen",           label: "/zen",           description: "Alias for /focus", kind: .kiln),
        .init(id: "repeat",        label: "/repeat",        description: "Alias for /retry", kind: .kiln),
        .init(id: "compress",      label: "/compress",      description: "Alias for /compact", kind: .kiln),
    ]

    /// Expand the slash list with dynamic prompt templates so they show up
    /// in autocomplete as `/t:name`. Keeps the top-level namespace clean
    /// while still surfacing them.
    @MainActor
    static func promptTemplateCommands() -> [SlashCommand] {
        PromptTemplateStore.shared.templates
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
            .map { t in
                SlashCommand(
                    id: "tmpl.\(t.id)",
                    label: "/t:\(t.name)",
                    description: t.description.isEmpty ? "Insert template" : t.description,
                    kind: .kiln
                )
            }
    }

    /// No longer used — kept empty for source compat. Previously held `//`
    /// commands; everything is `/` now.
    static let kilnCommands: [SlashCommand] = []

    /// Scan `~/.claude/agents/` for `.md` files — each is an agent.
    /// Result is cached; the slash popup hits this on every keystroke so
    /// hammering FileManager on each draw was wasteful. 5-second TTL —
    /// long enough to avoid churn, short enough that new agent files
    /// show up without restarting Kiln.
    nonisolated(unsafe) private static var agentCache: (items: [SlashCommand], fetchedAt: Date)?
    private static let agentCacheTTL: TimeInterval = 5

    static func loadAgents() -> [SlashCommand] {
        if let c = agentCache, Date().timeIntervalSince(c.fetchedAt) < agentCacheTTL {
            return c.items
        }
        let dir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/agents")
        let items: [SlashCommand] = {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
            return files
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
        }()
        agentCache = (items, Date())
        return items
    }

    @MainActor
    static func all() -> [SlashCommand] {
        builtins + kilnCommands + promptTemplateCommands() + loadAgents()
    }
}
