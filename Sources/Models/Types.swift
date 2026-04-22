import AppKit
import Foundation
import SwiftUI

// MARK: - Models

enum ModelProvider: String, Sendable, Codable {
    case claude
    case codex

    var assistantName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}

enum ClaudeModel: String, CaseIterable, Identifiable, Sendable, Codable {
    case opus47 = "claude-opus-4-7"
    case sonnet46 = "claude-sonnet-4-6"
    case haiku45 = "claude-haiku-4-5-20251001"
    case gpt54 = "gpt-5.4"
    case gpt54Mini = "gpt-5.4-mini"
    case gpt52 = "gpt-5.2"
    case gpt53CodexSpark = "gpt-5.3-codex-spark"

    var id: String { rawValue }

    var provider: ModelProvider {
        switch self {
        case .opus47, .sonnet46, .haiku45: .claude
        case .gpt54, .gpt54Mini, .gpt52, .gpt53CodexSpark: .codex
        }
    }

    /// Full CLI model ID (same as rawValue)
    var fullId: String { rawValue }

    var label: String {
        switch self {
        case .opus47: "Opus 4.7"
        case .sonnet46: "Sonnet 4.6"
        case .haiku45: "Haiku 4.5"
        case .gpt54: "GPT-5.4"
        case .gpt54Mini: "GPT-5.4 Mini"
        case .gpt52: "GPT-5.2"
        case .gpt53CodexSpark: "Codex Spark"
        }
    }

    var shortLabel: String {
        switch self {
        case .opus47: "Opus"
        case .sonnet46: "Sonnet"
        case .haiku45: "Haiku"
        case .gpt54: "5.4"
        case .gpt54Mini: "5.4 Mini"
        case .gpt52: "5.2"
        case .gpt53CodexSpark: "Spark"
        }
    }

    var tier: String {
        switch self {
        case .opus47: "Flagship"
        case .sonnet46: "Balanced"
        case .haiku45: "Fast"
        case .gpt54: "Frontier"
        case .gpt54Mini: "Efficient"
        case .gpt52: "Balanced"
        case .gpt53CodexSpark: "Fast"
        }
    }

    var assistantName: String { provider.assistantName }

    /// Standard context window in tokens
    var contextWindow: Int {
        switch self {
        case .opus47: 200_000
        case .sonnet46: 200_000
        case .haiku45: 200_000
        case .gpt54: 272_000
        case .gpt54Mini: 272_000
        case .gpt52: 272_000
        case .gpt53CodexSpark: 128_000
        }
    }

    /// Extended context (1M for Opus and Sonnet)
    var extendedContextWindow: Int? {
        switch self {
        case .opus47, .sonnet46: 1_000_000
        case .gpt54: 1_000_000
        default: nil
        }
    }

    var supportsExtendedContext: Bool {
        extendedContextWindow != nil
    }

    static var groupedByProvider: [(provider: ModelProvider, models: [ClaudeModel])] {
        [
            (.claude, allCases.filter { $0.provider == .claude }),
            (.codex, allCases.filter { $0.provider == .codex }),
        ]
    }
}

extension ModelProvider {
    var label: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        }
    }
}

// MARK: - Session Kind (Code vs Chat)

enum SessionKind: String, CaseIterable, Identifiable, Sendable, Codable {
    case code
    case chat

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .code: "chevron.left.forwardslash.chevron.right"
        case .chat: "bubble.left.and.bubble.right.fill"
        }
    }
}

// MARK: - Session Options

enum SessionMode: String, CaseIterable, Identifiable, Sendable, Codable {
    case build
    case plan

    var id: String { rawValue }

    var label: String {
        switch self {
        case .build: "Build"
        case .plan: "Plan"
        }
    }

    var icon: String {
        switch self {
        case .build: "hammer.fill"
        case .plan: "map.fill"
        }
    }

    var description: String {
        switch self {
        case .build: "Execute tools and make changes"
        case .plan: "Think and plan without executing"
        }
    }
}

enum PermissionMode: String, CaseIterable, Identifiable, Sendable, Codable {
    case bypass
    case ask
    case deny

    var id: String { rawValue }

    var label: String {
        switch self {
        case .bypass: "Bypass"
        case .ask: "Ask"
        case .deny: "Deny"
        }
    }

    var icon: String {
        switch self {
        case .bypass: "bolt.fill"
        case .ask: "hand.raised.fill"
        case .deny: "lock.fill"
        }
    }

    var description: String {
        switch self {
        case .bypass: "Skip all permission prompts"
        case .ask: "Ask before risky operations"
        case .deny: "Deny all tool use"
        }
    }
}

/// Options passed to each Claude CLI invocation
struct SendOptions: Sendable {
    var mode: SessionMode = .build
    var permissions: PermissionMode = .bypass
    var extendedContext: Bool = false // 1M context for Opus
    var maxTurns: Int? = nil       // --max-turns
    var systemPrompt: String? = nil // --system-prompt
    var allowedTools: [String]? = nil // --allowedTools
    var chatMode: Bool = false     // disables all tools, pure chat
    var thinkingEnabled: Bool = false // prepend think keyword + pass effort
    var effortLevel: EffortLevel? = nil // --effort <level>
    // PreToolUse hook target. Only used when permissions == .ask. The hook
    // script reads both from env vars at invocation time and POSTs tool
    // calls to http://127.0.0.1:<hookPort>/api/hooks/pretooluse with the
    // shared secret in X-Kiln-Hook-Secret.
    var hookPort: UInt16 = 8421
    var hookSecret: String = ""
}

// MARK: - PreToolUse approvals

/// A single pending tool-approval request surfaced by the PreToolUse
/// hook. The approval sheet renders one of these; the user's decision
/// resolves a `CheckedContinuation` held by the remote server so the
/// spawned `claude` subprocess unblocks and either runs the tool or
/// skips it.
struct PendingApproval: Identifiable, Sendable, Equatable {
    let id: String
    let kilnSessionId: String?   // nil if we can't map CC session → Kiln session
    let cliSessionId: String
    let toolName: String
    let toolInputJSON: String    // pretty-printed JSON of the tool input
    let createdAt: Date
}

/// Result passed back to the hook endpoint after the user decides.
struct HookDecision: Sendable {
    let approve: Bool
    let reason: String?
}

enum EffortLevel: String, CaseIterable, Identifiable, Sendable, Codable {
    case low, medium, high, max

    var id: String { rawValue }
    var label: String {
        switch self {
        case .low: "low"
        case .medium: "med"
        case .high: "high"
        case .max: "max"
        }
    }
    var cliValue: String { rawValue }
}

// MARK: - Messages

struct ChatMessage: Identifiable, Sendable {
    let id: String
    let role: MessageRole
    var blocks: [MessageBlock]
    let timestamp: Date
    var isPinned: Bool = false

    init(id: String = UUID().uuidString, role: MessageRole, blocks: [MessageBlock], timestamp: Date = .now, isPinned: Bool = false) {
        self.id = id
        self.role = role
        self.blocks = blocks
        self.timestamp = timestamp
        self.isPinned = isPinned
    }

    static func user(_ text: String) -> ChatMessage {
        ChatMessage(role: .user, blocks: [.text(text)])
    }
}

enum MessageRole: String, Sendable, Codable {
    case user
    case assistant
}

enum MessageBlock: Identifiable, Sendable {
    case text(String)
    case thinking(String)
    case toolUse(ToolUseBlock)
    case toolResult(ToolResultBlock)
    /// Clickable follow-up prompts. Each tap spawns a new code session with
    /// `prompt` as the first message. Used for briefing-style messages that
    /// invite follow-up research.
    case suggestions([SuggestionPrompt])
    /// A file/image the user attached. Rendered inline as a thumbnail card.
    case attachment(ComposerAttachment)

    var id: String {
        switch self {
        case .text(let t): "text-\(t.hashValue)"
        case .thinking(let t): "think-\(t.hashValue)"
        case .toolUse(let b): b.id
        case .toolResult(let b): b.toolUseId
        case .suggestions(let s): "suggestions-\(s.map(\.id).joined())"
        case .attachment(let a): "attachment-\(a.id)"
        }
    }
}

struct SuggestionPrompt: Identifiable, Sendable, Hashable, Codable {
    let id: String
    let label: String
    let prompt: String
    let icon: String

    init(id: String = UUID().uuidString, label: String, prompt: String, icon: String = "arrow.up.right") {
        self.id = id
        self.label = label
        self.prompt = prompt
        self.icon = icon
    }
}

struct ToolUseBlock: Identifiable, Sendable {
    let id: String
    let name: String
    var input: String // JSON string, streamed incrementally
    var isDone: Bool
    var result: String?
    var isError: Bool = false
    /// Wall-clock timestamp for when the CLI reported the tool starting.
    /// Nil on pre-1.4.4 persisted sessions — timeline skips those entries.
    var startedAt: Date? = nil
    /// Set when the matching tool_result lands. Nil while the call is in
    /// flight. `completedAt - startedAt` gives the duration rendered in
    /// the tool card and the session timeline.
    var completedAt: Date? = nil
}

/// Live generation state for a single session. Kept out of views so
/// multiple sessions can generate concurrently without stepping on each
/// other's buffers.
struct SessionRuntimeState: Sendable {
    var isBusy: Bool = false
    var streamingText: String = ""
    var thinkingText: String = ""
    var activeToolCalls: [ToolUseBlock] = []
    var currentToolId: String? = nil
    var lastError: String? = nil
    var inputTokens: Int = 0
    var outputTokens: Int = 0
}

struct ToolResultBlock: Sendable {
    let toolUseId: String
    let content: String
    let isError: Bool
}

// MARK: - Search

struct SearchResult: Identifiable, Sendable {
    let id = UUID()
    let sessionId: String
    let sessionName: String
    let sessionKind: SessionKind
    let messageId: String
    let role: MessageRole
    let timestamp: Date
    let snippet: String
}

// MARK: - Session

struct Session: Identifiable, Sendable {
    let id: String
    let workDir: String
    var name: String
    var model: ClaudeModel
    let createdAt: Date
    var messages: [ChatMessage]
    var isPinned: Bool
    var group: String?
    var forkedFrom: String? // source session ID if this is a fork
    var kind: SessionKind = .code
    var readOnly: Bool = false  // hides composer; one-shot briefing sessions
    var isArchived: Bool = false
    /// Per-session system prompt override. Prepended to the global system
    /// prompt for this session only. Empty string = no override.
    var sessionInstructions: String = ""
    /// Set true when a send starts; cleared on clean completion. If true on
    /// the next launch, we know the previous run was interrupted (app crash,
    /// `claude` crash, force-quit) and can offer a retry.
    var wasInterrupted: Bool = false
    /// Free-form cross-cutting tags. Lower-cased, deduped on write.
    var tags: [String] = []
    /// Local dev-server port to expose via warden tunnel when the session's
    /// tunnel is started. `nil` means no tunnel configured for this session.
    var tunnelPort: Int?
    /// Optional stable subdomain for this session's tunnel. Empty / nil →
    /// a fresh random subdomain is assigned each time the tunnel starts.
    var tunnelSub: String?
    /// Optional color label. Stored as a preset name ("red", "amber",
    /// "green", "blue", "purple", "pink") or `nil` for no label. Rendered
    /// as a small dot next to the session name in the sidebar.
    var colorLabel: String? = nil

    init(id: String = UUID().uuidString, workDir: String, name: String = "New Session", model: ClaudeModel = .sonnet46, isPinned: Bool = false, group: String? = nil, forkedFrom: String? = nil, kind: SessionKind = .code, readOnly: Bool = false, isArchived: Bool = false, sessionInstructions: String = "", tags: [String] = [], tunnelPort: Int? = nil, tunnelSub: String? = nil, colorLabel: String? = nil, createdAt: Date = .now) {
        self.id = id
        self.workDir = workDir
        self.name = name
        self.model = model
        self.createdAt = createdAt
        self.messages = []
        self.isPinned = isPinned
        self.group = group
        self.kind = kind
        self.forkedFrom = forkedFrom
        self.readOnly = readOnly
        self.isArchived = isArchived
        self.sessionInstructions = sessionInstructions
        self.tags = tags
        self.tunnelPort = tunnelPort
        self.tunnelSub = tunnelSub
        self.colorLabel = colorLabel
    }
}

// MARK: - Settings

enum AppLanguage: String, CaseIterable, Identifiable, Sendable, Codable {
    case en = "en"
    case de = "de"
    case zh = "zh"
    case fr = "fr"
    case es = "es"
    case ja = "ja"
    case it = "it"
    case pt = "pt"
    case ru = "ru"
    case ko = "ko"
    case nl = "nl"
    case hi = "hi"
    case ar = "ar"
    case pl = "pl"
    case tr = "tr"
    case sv = "sv"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .en: "English"
        case .de: "Deutsch"
        case .zh: "中文"
        case .fr: "Français"
        case .es: "Español"
        case .ja: "日本語"
        case .it: "Italiano"
        case .pt: "Português"
        case .ru: "Русский"
        case .ko: "한국어"
        case .nl: "Nederlands"
        case .hi: "हिन्दी"
        case .ar: "العربية"
        case .pl: "Polski"
        case .tr: "Türkçe"
        case .sv: "Svenska"
        }
    }

    var flag: String {
        switch self {
        case .en: "🇦🇺"
        case .de: "🇩🇪"
        case .zh: "🇨🇳"
        case .fr: "🇫🇷"
        case .es: "🇪🇸"
        case .ja: "🇯🇵"
        case .it: "🇮🇹"
        case .pt: "🇵🇹"
        case .ru: "🇷🇺"
        case .ko: "🇰🇷"
        case .nl: "🇳🇱"
        case .hi: "🇮🇳"
        case .ar: "🇸🇦"
        case .pl: "🇵🇱"
        case .tr: "🇹🇷"
        case .sv: "🇸🇪"
        }
    }

    // Claude system prompt instruction. For languages without a full UI
    // translation we still steer Claude's *output* language — the chat is
    // where localisation matters most anyway.
    var claudeInstruction: String {
        switch self {
        case .en: return ""
        case .de: return "IMPORTANT: You MUST respond in German (Deutsch). All your responses should be in German."
        case .zh: return "IMPORTANT: You MUST respond in Chinese (中文). All your responses should be in Chinese."
        case .fr: return "IMPORTANT: You MUST respond in French (Français). All your responses should be in French."
        case .es: return "IMPORTANT: You MUST respond in Spanish (Español). All your responses should be in Spanish."
        case .ja: return "IMPORTANT: You MUST respond in Japanese (日本語). All your responses should be in Japanese."
        case .it: return "IMPORTANT: You MUST respond in Italian (Italiano). All your responses should be in Italian."
        case .pt: return "IMPORTANT: You MUST respond in Portuguese (Português). All your responses should be in Portuguese."
        case .ru: return "IMPORTANT: You MUST respond in Russian (Русский). All your responses should be in Russian."
        case .ko: return "IMPORTANT: You MUST respond in Korean (한국어). All your responses should be in Korean."
        case .nl: return "IMPORTANT: You MUST respond in Dutch (Nederlands). All your responses should be in Dutch."
        case .hi: return "IMPORTANT: You MUST respond in Hindi (हिन्दी). All your responses should be in Hindi."
        case .ar: return "IMPORTANT: You MUST respond in Arabic (العربية). All your responses should be in Arabic."
        case .pl: return "IMPORTANT: You MUST respond in Polish (Polski). All your responses should be in Polish."
        case .tr: return "IMPORTANT: You MUST respond in Turkish (Türkçe). All your responses should be in Turkish."
        case .sv: return "IMPORTANT: You MUST respond in Swedish (Svenska). All your responses should be in Swedish."
        }
    }

    // UI strings
    var ui: UIStrings {
        switch self {
        case .en:
            return UIStrings(
                newSession: "New Session", settings: "Settings", noSessions: "No sessions",
                messagePlaceholder: "Message assistant…", thinking: "Thinking…", working: "working…",
                writing: "writing…", disclaimer: "Kiln can make mistakes. Please double-check responses.",
                learnMore: "Learn more", send: "Send", stop: "Stop", selectFile: "Select a file",
                files: "Files", git: "Git", terminal: "Terminal", delete: "Delete", cancel: "Cancel",
                rename: "Rename", pin: "Pin", unpin: "Unpin", fork: "Fork", copy: "Copy",
                commit: "Commit", push: "Push", pull: "Pull", changes: "Changes",
                recentCommits: "Recent Commits", cleanTree: "Working tree clean",
                search: "Search sessions…", clearMessages: "Clear Messages",
                deleteConfirm: "Are you sure you want to delete", cantUndo: "This can't be undone."
            )
        case .de:
            var s = UIStrings(
                newSession: "Neue Sitzung", settings: "Einstellungen", noSessions: "Keine Sitzungen",
                messagePlaceholder: "Nachricht an Claude…", thinking: "Denkt nach…", working: "arbeitet…",
                writing: "schreibt…", disclaimer: "Kiln verwendet Claude und kann Fehler machen. Bitte überprüfen Sie die Antworten.",
                learnMore: "Mehr erfahren", send: "Senden", stop: "Stopp", selectFile: "Datei auswählen",
                files: "Dateien", git: "Git", terminal: "Terminal", delete: "Löschen", cancel: "Abbrechen",
                rename: "Umbenennen", pin: "Anheften", unpin: "Lösen", fork: "Abzweigen", copy: "Kopieren",
                commit: "Commit", push: "Push", pull: "Pull", changes: "Änderungen",
                recentCommits: "Letzte Commits", cleanTree: "Arbeitsverzeichnis sauber",
                search: "Sitzungen suchen…", clearMessages: "Nachrichten löschen",
                deleteConfirm: "Möchten Sie wirklich löschen", cantUndo: "Dies kann nicht rückgängig gemacht werden."
            )
            s.forked = "abgezweigt"; s.you = "Du"; s.save = "Speichern"; s.loading = "Lädt…"
            s.notGitRepo = "Kein Git-Repo"; s.commitMessage = "Commit-Nachricht…"
            s.browse = "Durchsuchen"; s.createSession = "Sitzung erstellen"
            s.workingDirectory = "ARBEITSVERZEICHNIS"; s.model = "MODELL"
            s.tagline = "Ein natives Zuhause für Agent-CLIs."
            s.defaults = "STANDARDS"; s.language = "SPRACHE"; s.memory = "SPEICHER (ENGRAM)"; s.about = "ÜBER"
            s.systemPrompt = "System-Prompt"; s.resetToDefault = "Zurücksetzen"; s.enableEngram = "Engram aktivieren"
            s.setGroup = "Gruppe festlegen…"; s.moveToGroup = "In Gruppe verschieben"
            s.removeFromGroup = "Aus Gruppe entfernen"; s.deleteSession = "Sitzung löschen"
            s.groupName = "Gruppenname"; s.set = "Festlegen"; s.removeGroup = "Gruppe entfernen"
            s.error = "Fehler"; s.done = "fertig"; s.running = "läuft…"
            s.input = "EINGABE"; s.output = "AUSGABE"
            s.justNow = "gerade eben"; s.yesterday = "gestern"
            s.mAgo = "Min."; s.hAgo = "Std."; s.dAgo = "T."; s.msgs = "Nachr."
            s.path = "Pfad"; s.permissionsLabel = "Berechtigungen"; s.workDir = "Arbeitsverz."
            s.modeLabel = "Modus"; s.modelLabel = "Modell"; s.languageLabel = "Sprache"
            s.langDescription = "Der aktive Assistent antwortet in der gewählten Sprache. UI-Beschriftungen werden ebenfalls aktualisiert."
            s.code = "Code"; s.chat = "Chat"
            s.chatModeHint = "Reiner Chat — keine Dateien, keine Tools, nur Unterhaltung."
            s.activity = "Aktivität"; s.noActivityYet = "Noch keine Aktivität"
            s.activityHint = "Code, den der Assistent schreibt, und Befehle, die er ausführt, erscheinen hier."
            s.callsSuffix = "Aufrufe"
            s.filterFiles = "Dateien filtern…"; s.noFilesMatch = "Keine Dateien passen zu"
            s.think = "denken"; s.noThink = "kein Denken"; s.turnsSuffix = "Züge"
            s.effortLow = "niedrig"; s.effortMed = "mittel"; s.effortHigh = "hoch"; s.effortMax = "max"
            s.stats = "Statistik"; s.statsMessages = "Nachrichten"; s.statsStreak = "Serie"
            s.statsActiveDays = "Aktive Tage"; s.statsSessions = "Sitzungen"; s.statsModels = "Modelle"
            s.thinkingLower = "denkt…"
            return s
        case .zh:
            var s = UIStrings(
                newSession: "新会话", settings: "设置", noSessions: "没有会话",
                messagePlaceholder: "发送消息给助手…", thinking: "思考中…", working: "工作中…",
                writing: "正在写…", disclaimer: "Kiln 可能会出错。请仔细检查回复。",
                learnMore: "了解更多", send: "发送", stop: "停止", selectFile: "选择文件",
                files: "文件", git: "Git", terminal: "终端", delete: "删除", cancel: "取消",
                rename: "重命名", pin: "置顶", unpin: "取消置顶", fork: "分叉", copy: "复制",
                commit: "提交", push: "推送", pull: "拉取", changes: "更改",
                recentCommits: "最近提交", cleanTree: "工作区干净",
                search: "搜索会话…", clearMessages: "清除消息",
                deleteConfirm: "确定要删除吗", cantUndo: "此操作无法撤消。"
            )
            s.forked = "已分叉"; s.you = "你"; s.save = "保存"; s.loading = "加载中…"
            s.notGitRepo = "非 Git 仓库"; s.commitMessage = "提交信息…"
            s.browse = "浏览"; s.createSession = "创建会话"
            s.workingDirectory = "工作目录"; s.model = "模型"
            s.tagline = "面向代理 CLI 的原生工作区。"
            s.defaults = "默认设置"; s.language = "语言"; s.memory = "记忆 (ENGRAM)"; s.about = "关于"
            s.systemPrompt = "系统提示"; s.resetToDefault = "重置默认"; s.enableEngram = "启用 Engram"
            s.setGroup = "设置分组…"; s.moveToGroup = "移至分组"
            s.removeFromGroup = "从分组移除"; s.deleteSession = "删除会话"
            s.groupName = "分组名称"; s.set = "设置"; s.removeGroup = "移除分组"
            s.error = "错误"; s.done = "完成"; s.running = "运行中…"
            s.input = "输入"; s.output = "输出"
            s.justNow = "刚刚"; s.yesterday = "昨天"
            s.mAgo = "分钟前"; s.hAgo = "小时前"; s.dAgo = "天前"; s.msgs = "条"
            s.path = "路径"; s.permissionsLabel = "权限"; s.workDir = "工作目录"
            s.modeLabel = "模式"; s.modelLabel = "模型"; s.languageLabel = "语言"
            s.langDescription = "当前助手将以所选语言回复。UI 标签也会更新。"
            s.code = "代码"; s.chat = "聊天"
            s.chatModeHint = "纯聊天 — 无文件、无工具，仅对话。"
            s.activity = "活动"; s.noActivityYet = "暂无活动"
            s.activityHint = "助手编写的代码和运行的命令会显示在这里。"
            s.callsSuffix = "次调用"
            s.filterFiles = "筛选文件…"; s.noFilesMatch = "没有文件匹配"
            s.think = "思考"; s.noThink = "不思考"; s.turnsSuffix = "轮"
            s.effortLow = "低"; s.effortMed = "中"; s.effortHigh = "高"; s.effortMax = "最高"
            s.stats = "统计"; s.statsMessages = "消息"; s.statsStreak = "连胜"
            s.statsActiveDays = "活跃天数"; s.statsSessions = "会话"; s.statsModels = "模型"
            s.thinkingLower = "思考中…"
            return s
        case .fr:
            var s = UIStrings(
                newSession: "Nouvelle session", settings: "Paramètres", noSessions: "Aucune session",
                messagePlaceholder: "Message à l’assistant…", thinking: "Réflexion…", working: "en cours…",
                writing: "écriture…", disclaimer: "Kiln peut faire des erreurs. Veuillez vérifier les réponses.",
                learnMore: "En savoir plus", send: "Envoyer", stop: "Arrêter", selectFile: "Sélectionner un fichier",
                files: "Fichiers", git: "Git", terminal: "Terminal", delete: "Supprimer", cancel: "Annuler",
                rename: "Renommer", pin: "Épingler", unpin: "Désépingler", fork: "Dupliquer", copy: "Copier",
                commit: "Commit", push: "Push", pull: "Pull", changes: "Modifications",
                recentCommits: "Commits récents", cleanTree: "Arbre de travail propre",
                search: "Rechercher des sessions…", clearMessages: "Effacer les messages",
                deleteConfirm: "Voulez-vous vraiment supprimer", cantUndo: "Cette action est irréversible."
            )
            s.forked = "dupliqué"; s.you = "Toi"; s.save = "Enregistrer"; s.loading = "Chargement…"
            s.notGitRepo = "Pas un dépôt Git"; s.commitMessage = "Message de commit…"
            s.browse = "Parcourir"; s.createSession = "Créer une session"
            s.workingDirectory = "RÉPERTOIRE DE TRAVAIL"; s.model = "MODÈLE"
            s.tagline = "Un foyer natif pour les CLI d’agents."
            s.defaults = "DÉFAUTS"; s.language = "LANGUE"; s.memory = "MÉMOIRE (ENGRAM)"; s.about = "À PROPOS"
            s.systemPrompt = "Prompt système"; s.resetToDefault = "Réinitialiser"; s.enableEngram = "Activer Engram"
            s.setGroup = "Définir le groupe…"; s.moveToGroup = "Déplacer vers le groupe"
            s.removeFromGroup = "Retirer du groupe"; s.deleteSession = "Supprimer la session"
            s.groupName = "Nom du groupe"; s.set = "Définir"; s.removeGroup = "Retirer le groupe"
            s.error = "erreur"; s.done = "terminé"; s.running = "en cours…"
            s.input = "ENTRÉE"; s.output = "SORTIE"
            s.justNow = "à l'instant"; s.yesterday = "hier"
            s.mAgo = "min"; s.hAgo = "h"; s.dAgo = "j"; s.msgs = "msgs"
            s.path = "Chemin"; s.permissionsLabel = "Permissions"; s.workDir = "Répertoire"
            s.modeLabel = "Mode"; s.modelLabel = "Modèle"; s.languageLabel = "Langue"
            s.langDescription = "L’assistant actif répondra dans la langue sélectionnée. Les libellés de l’interface seront également mis à jour."
            s.code = "Code"; s.chat = "Chat"
            s.chatModeHint = "Chat pur — pas de fichiers, pas d'outils, juste de la conversation."
            s.activity = "Activité"; s.noActivityYet = "Aucune activité pour l'instant"
            s.activityHint = "Le code écrit par l’assistant et les commandes qu’il exécute apparaîtront ici."
            s.callsSuffix = "appels"
            s.filterFiles = "Filtrer les fichiers…"; s.noFilesMatch = "Aucun fichier ne correspond à"
            s.think = "réfléchir"; s.noThink = "sans réflexion"; s.turnsSuffix = "tours"
            s.effortLow = "bas"; s.effortMed = "moy"; s.effortHigh = "haut"; s.effortMax = "max"
            s.stats = "Stats"; s.statsMessages = "Messages"; s.statsStreak = "Série"
            s.statsActiveDays = "Jours actifs"; s.statsSessions = "Sessions"; s.statsModels = "Modèles"
            s.thinkingLower = "réfléchit…"
            return s
        case .es:
            var s = UIStrings(
                newSession: "Nueva sesión", settings: "Configuración", noSessions: "Sin sesiones",
                messagePlaceholder: "Mensaje al asistente…", thinking: "Pensando…", working: "trabajando…",
                writing: "escribiendo…", disclaimer: "Kiln puede cometer errores. Verifique las respuestas.",
                learnMore: "Más información", send: "Enviar", stop: "Detener", selectFile: "Seleccionar archivo",
                files: "Archivos", git: "Git", terminal: "Terminal", delete: "Eliminar", cancel: "Cancelar",
                rename: "Renombrar", pin: "Fijar", unpin: "Desfijar", fork: "Bifurcar", copy: "Copiar",
                commit: "Commit", push: "Push", pull: "Pull", changes: "Cambios",
                recentCommits: "Commits recientes", cleanTree: "Árbol de trabajo limpio",
                search: "Buscar sesiones…", clearMessages: "Borrar mensajes",
                deleteConfirm: "¿Seguro que quieres eliminar", cantUndo: "Esto no se puede deshacer."
            )
            s.forked = "bifurcado"; s.you = "Tú"; s.save = "Guardar"; s.loading = "Cargando…"
            s.notGitRepo = "No es un repo Git"; s.commitMessage = "Mensaje del commit…"
            s.browse = "Examinar"; s.createSession = "Crear sesión"
            s.workingDirectory = "DIRECTORIO DE TRABAJO"; s.model = "MODELO"
            s.tagline = "Un hogar nativo para CLIs de agentes."
            s.defaults = "PREDETERMINADOS"; s.language = "IDIOMA"; s.memory = "MEMORIA (ENGRAM)"; s.about = "ACERCA DE"
            s.systemPrompt = "Prompt del sistema"; s.resetToDefault = "Restablecer"; s.enableEngram = "Activar Engram"
            s.setGroup = "Definir grupo…"; s.moveToGroup = "Mover al grupo"
            s.removeFromGroup = "Quitar del grupo"; s.deleteSession = "Eliminar sesión"
            s.groupName = "Nombre del grupo"; s.set = "Definir"; s.removeGroup = "Quitar grupo"
            s.error = "error"; s.done = "hecho"; s.running = "ejecutando…"
            s.input = "ENTRADA"; s.output = "SALIDA"
            s.justNow = "ahora"; s.yesterday = "ayer"
            s.mAgo = "min"; s.hAgo = "h"; s.dAgo = "d"; s.msgs = "msgs"
            s.path = "Ruta"; s.permissionsLabel = "Permisos"; s.workDir = "Directorio"
            s.modeLabel = "Modo"; s.modelLabel = "Modelo"; s.languageLabel = "Idioma"
            s.langDescription = "El asistente activo responderá en el idioma seleccionado. Las etiquetas de la interfaz también se actualizarán."
            s.code = "Código"; s.chat = "Chat"
            s.chatModeHint = "Chat puro — sin archivos, sin herramientas, solo conversación."
            s.activity = "Actividad"; s.noActivityYet = "Sin actividad todavía"
            s.activityHint = "El código que escribe el asistente y los comandos que ejecuta aparecerán aquí."
            s.callsSuffix = "llamadas"
            s.filterFiles = "Filtrar archivos…"; s.noFilesMatch = "Ningún archivo coincide con"
            s.think = "pensar"; s.noThink = "sin pensar"; s.turnsSuffix = "turnos"
            s.effortLow = "bajo"; s.effortMed = "med"; s.effortHigh = "alto"; s.effortMax = "máx"
            s.stats = "Estadísticas"; s.statsMessages = "Mensajes"; s.statsStreak = "Racha"
            s.statsActiveDays = "Días activos"; s.statsSessions = "Sesiones"; s.statsModels = "Modelos"
            s.thinkingLower = "pensando…"
            return s
        case .ja:
            var s = UIStrings(
                newSession: "新しいセッション", settings: "設定", noSessions: "セッションなし",
                messagePlaceholder: "アシスタントにメッセージ…", thinking: "考え中…", working: "作業中…",
                writing: "書いています…", disclaimer: "Kilnは間違うことがあります。回答をご確認ください。",
                learnMore: "詳細", send: "送信", stop: "停止", selectFile: "ファイルを選択",
                files: "ファイル", git: "Git", terminal: "ターミナル", delete: "削除", cancel: "キャンセル",
                rename: "名前変更", pin: "ピン留め", unpin: "ピン解除", fork: "フォーク", copy: "コピー",
                commit: "コミット", push: "プッシュ", pull: "プル", changes: "変更",
                recentCommits: "最近のコミット", cleanTree: "作業ツリーはクリーン",
                search: "セッションを検索…", clearMessages: "メッセージをクリア",
                deleteConfirm: "本当に削除しますか", cantUndo: "この操作は元に戻せません。"
            )
            s.forked = "フォーク済み"; s.you = "あなた"; s.save = "保存"; s.loading = "読み込み中…"
            s.notGitRepo = "Gitリポジトリではありません"; s.commitMessage = "コミットメッセージ…"
            s.browse = "参照"; s.createSession = "セッション作成"
            s.workingDirectory = "作業ディレクトリ"; s.model = "モデル"
            s.tagline = "エージェントCLIのためのネイティブな場所。"
            s.defaults = "デフォルト"; s.language = "言語"; s.memory = "メモリ (ENGRAM)"; s.about = "情報"
            s.systemPrompt = "システムプロンプト"; s.resetToDefault = "リセット"; s.enableEngram = "Engramを有効化"
            s.setGroup = "グループ設定…"; s.moveToGroup = "グループへ移動"
            s.removeFromGroup = "グループから削除"; s.deleteSession = "セッション削除"
            s.groupName = "グループ名"; s.set = "設定"; s.removeGroup = "グループ削除"
            s.error = "エラー"; s.done = "完了"; s.running = "実行中…"
            s.input = "入力"; s.output = "出力"
            s.justNow = "たった今"; s.yesterday = "昨日"
            s.mAgo = "分前"; s.hAgo = "時間前"; s.dAgo = "日前"; s.msgs = "件"
            s.path = "パス"; s.permissionsLabel = "権限"; s.workDir = "作業ディレクトリ"
            s.modeLabel = "モード"; s.modelLabel = "モデル"; s.languageLabel = "言語"
            s.langDescription = "現在のアシスタントは選択した言語で応答します。UIラベルも更新されます。"
            s.code = "コード"; s.chat = "チャット"
            s.chatModeHint = "純粋なチャット — ファイルやツールなし、会話のみ。"
            s.activity = "アクティビティ"; s.noActivityYet = "まだアクティビティがありません"
            s.activityHint = "アシスタントが書くコードと実行するコマンドがここに表示されます。"
            s.callsSuffix = "回"
            s.filterFiles = "ファイルを絞り込む…"; s.noFilesMatch = "一致するファイルがありません"
            s.think = "思考"; s.noThink = "思考なし"; s.turnsSuffix = "ターン"
            s.effortLow = "低"; s.effortMed = "中"; s.effortHigh = "高"; s.effortMax = "最大"
            s.stats = "統計"; s.statsMessages = "メッセージ"; s.statsStreak = "連続"
            s.statsActiveDays = "アクティブ日数"; s.statsSessions = "セッション"; s.statsModels = "モデル"
            s.thinkingLower = "思考中…"
            return s
        case .it:
            var s = UIStrings(
                newSession: "Nuova sessione", settings: "Impostazioni", noSessions: "Nessuna sessione",
                messagePlaceholder: "Scrivi all'assistente…", thinking: "Sta pensando…", working: "in corso…",
                writing: "sta scrivendo…", disclaimer: "Kiln può commettere errori. Ricontrolla sempre le risposte.",
                learnMore: "Scopri di più", send: "Invia", stop: "Stop", selectFile: "Seleziona un file",
                files: "File", git: "Git", terminal: "Terminale", delete: "Elimina", cancel: "Annulla",
                rename: "Rinomina", pin: "Fissa", unpin: "Sblocca", fork: "Fork", copy: "Copia",
                commit: "Commit", push: "Push", pull: "Pull", changes: "Modifiche",
                recentCommits: "Commit recenti", cleanTree: "Working tree pulito",
                search: "Cerca sessioni…", clearMessages: "Cancella messaggi",
                deleteConfirm: "Vuoi davvero eliminare", cantUndo: "L'operazione non è annullabile."
            )
            s.forked = "biforcato"; s.you = "Tu"; s.save = "Salva"; s.loading = "Caricamento…"
            s.notGitRepo = "Non è un repo git"; s.commitMessage = "Messaggio di commit…"
            s.browse = "Sfoglia"; s.createSession = "Crea sessione"
            s.workingDirectory = "CARTELLA DI LAVORO"; s.model = "MODELLO"
            s.tagline = "Un ambiente nativo per CLI agentiche."
            s.defaults = "PREDEFINITI"; s.language = "LINGUA"; s.memory = "MEMORIA (ENGRAM)"; s.about = "INFO"
            s.systemPrompt = "Prompt di sistema"; s.resetToDefault = "Ripristina"; s.enableEngram = "Abilita Engram"
            s.setGroup = "Imposta gruppo…"; s.moveToGroup = "Sposta nel gruppo"
            s.removeFromGroup = "Rimuovi dal gruppo"; s.deleteSession = "Elimina sessione"
            s.groupName = "Nome del gruppo"; s.set = "Imposta"; s.removeGroup = "Rimuovi gruppo"
            s.error = "errore"; s.done = "fatto"; s.running = "in esecuzione…"
            s.input = "INPUT"; s.output = "OUTPUT"
            s.justNow = "adesso"; s.yesterday = "ieri"
            s.mAgo = "min fa"; s.hAgo = "h fa"; s.dAgo = "g fa"; s.msgs = "msg"
            s.path = "Percorso"; s.permissionsLabel = "Permessi"; s.workDir = "Cartella"
            s.modeLabel = "Modalità"; s.modelLabel = "Modello"; s.languageLabel = "Lingua"
            s.langDescription = "L'assistente attivo risponderà nella lingua selezionata. Anche l'interfaccia verrà aggiornata."
            s.code = "Codice"; s.chat = "Chat"
            s.chatModeHint = "Chat pura — niente file, niente strumenti, solo conversazione."
            s.activity = "Attività"; s.noActivityYet = "Ancora nessuna attività"
            s.activityHint = "Il codice che scrive l'assistente e i comandi che esegue appariranno qui."
            s.callsSuffix = "chiamate"
            s.filterFiles = "Filtra file…"; s.noFilesMatch = "Nessun file corrisponde a"
            s.think = "pensa"; s.noThink = "non pensare"; s.turnsSuffix = "turni"
            s.effortLow = "basso"; s.effortMed = "medio"; s.effortHigh = "alto"; s.effortMax = "max"
            s.stats = "Statistiche"; s.statsMessages = "Messaggi"; s.statsStreak = "Serie"
            s.statsActiveDays = "Giorni attivi"; s.statsSessions = "Sessioni"; s.statsModels = "Modelli"
            s.thinkingLower = "sta pensando…"
            return s
        case .pt:
            var s = UIStrings(
                newSession: "Nova sessão", settings: "Definições", noSessions: "Sem sessões",
                messagePlaceholder: "Mensagem para o assistente…", thinking: "A pensar…", working: "a trabalhar…",
                writing: "a escrever…", disclaimer: "O Kiln pode cometer erros. Verifique sempre as respostas.",
                learnMore: "Saber mais", send: "Enviar", stop: "Parar", selectFile: "Selecionar ficheiro",
                files: "Ficheiros", git: "Git", terminal: "Terminal", delete: "Eliminar", cancel: "Cancelar",
                rename: "Renomear", pin: "Fixar", unpin: "Desafixar", fork: "Fork", copy: "Copiar",
                commit: "Commit", push: "Push", pull: "Pull", changes: "Alterações",
                recentCommits: "Commits recentes", cleanTree: "Working tree limpa",
                search: "Procurar sessões…", clearMessages: "Limpar mensagens",
                deleteConfirm: "Tem a certeza que quer eliminar", cantUndo: "Esta ação não pode ser desfeita."
            )
            s.forked = "bifurcado"; s.you = "Tu"; s.save = "Guardar"; s.loading = "A carregar…"
            s.notGitRepo = "Não é um repo git"; s.commitMessage = "Mensagem de commit…"
            s.browse = "Procurar"; s.createSession = "Criar sessão"
            s.workingDirectory = "DIRETÓRIO DE TRABALHO"; s.model = "MODELO"
            s.tagline = "Uma casa nativa para CLIs de agentes."
            s.defaults = "PREDEFINIÇÕES"; s.language = "IDIOMA"; s.memory = "MEMÓRIA (ENGRAM)"; s.about = "SOBRE"
            s.systemPrompt = "Prompt do sistema"; s.resetToDefault = "Repor"; s.enableEngram = "Ativar Engram"
            s.setGroup = "Definir grupo…"; s.moveToGroup = "Mover para grupo"
            s.removeFromGroup = "Remover do grupo"; s.deleteSession = "Eliminar sessão"
            s.groupName = "Nome do grupo"; s.set = "Definir"; s.removeGroup = "Remover grupo"
            s.error = "erro"; s.done = "concluído"; s.running = "a executar…"
            s.input = "ENTRADA"; s.output = "SAÍDA"
            s.justNow = "agora mesmo"; s.yesterday = "ontem"
            s.mAgo = "min"; s.hAgo = "h"; s.dAgo = "d"; s.msgs = "msgs"
            s.path = "Caminho"; s.permissionsLabel = "Permissões"; s.workDir = "Diretório"
            s.modeLabel = "Modo"; s.modelLabel = "Modelo"; s.languageLabel = "Idioma"
            s.langDescription = "O assistente ativo responderá no idioma selecionado. A interface também será atualizada."
            s.code = "Código"; s.chat = "Chat"
            s.chatModeHint = "Chat puro — sem ficheiros, sem ferramentas, apenas conversa."
            s.activity = "Atividade"; s.noActivityYet = "Ainda sem atividade"
            s.activityHint = "O código que o assistente escreve e os comandos que executa aparecerão aqui."
            s.callsSuffix = "chamadas"
            s.filterFiles = "Filtrar ficheiros…"; s.noFilesMatch = "Nenhum ficheiro corresponde a"
            s.think = "pensar"; s.noThink = "não pensar"; s.turnsSuffix = "turnos"
            s.effortLow = "baixo"; s.effortMed = "méd"; s.effortHigh = "alto"; s.effortMax = "máx"
            s.stats = "Estatísticas"; s.statsMessages = "Mensagens"; s.statsStreak = "Sequência"
            s.statsActiveDays = "Dias ativos"; s.statsSessions = "Sessões"; s.statsModels = "Modelos"
            s.thinkingLower = "a pensar…"
            return s
        case .ru:
            var s = UIStrings(
                newSession: "Новая сессия", settings: "Настройки", noSessions: "Нет сессий",
                messagePlaceholder: "Сообщение для ассистента…", thinking: "Думаю…", working: "работаю…",
                writing: "пишу…", disclaimer: "Kiln может ошибаться. Пожалуйста, перепроверяйте ответы.",
                learnMore: "Узнать больше", send: "Отправить", stop: "Стоп", selectFile: "Выберите файл",
                files: "Файлы", git: "Git", terminal: "Терминал", delete: "Удалить", cancel: "Отмена",
                rename: "Переименовать", pin: "Закрепить", unpin: "Открепить", fork: "Форк", copy: "Копировать",
                commit: "Коммит", push: "Пуш", pull: "Пул", changes: "Изменения",
                recentCommits: "Последние коммиты", cleanTree: "Рабочее дерево чисто",
                search: "Поиск сессий…", clearMessages: "Очистить сообщения",
                deleteConfirm: "Вы уверены, что хотите удалить", cantUndo: "Это действие нельзя отменить."
            )
            s.forked = "форк"; s.you = "Вы"; s.save = "Сохранить"; s.loading = "Загрузка…"
            s.notGitRepo = "Не git-репо"; s.commitMessage = "Сообщение коммита…"
            s.browse = "Обзор"; s.createSession = "Создать сессию"
            s.workingDirectory = "РАБОЧАЯ ПАПКА"; s.model = "МОДЕЛЬ"
            s.tagline = "Нативный дом для CLI-агентов."
            s.defaults = "ПО УМОЛЧАНИЮ"; s.language = "ЯЗЫК"; s.memory = "ПАМЯТЬ (ENGRAM)"; s.about = "О ПРОГРАММЕ"
            s.systemPrompt = "Системный промпт"; s.resetToDefault = "Сбросить"; s.enableEngram = "Включить Engram"
            s.setGroup = "Задать группу…"; s.moveToGroup = "Переместить в группу"
            s.removeFromGroup = "Убрать из группы"; s.deleteSession = "Удалить сессию"
            s.groupName = "Название группы"; s.set = "Задать"; s.removeGroup = "Удалить группу"
            s.error = "ошибка"; s.done = "готово"; s.running = "выполняется…"
            s.input = "ВХОД"; s.output = "ВЫХОД"
            s.justNow = "только что"; s.yesterday = "вчера"
            s.mAgo = "мин"; s.hAgo = "ч"; s.dAgo = "д"; s.msgs = "сообщ."
            s.path = "Путь"; s.permissionsLabel = "Разрешения"; s.workDir = "Папка"
            s.modeLabel = "Режим"; s.modelLabel = "Модель"; s.languageLabel = "Язык"
            s.langDescription = "Активный ассистент будет отвечать на выбранном языке. Интерфейс также обновится."
            s.code = "Код"; s.chat = "Чат"
            s.chatModeHint = "Чистый чат — без файлов, без инструментов, только беседа."
            s.activity = "Активность"; s.noActivityYet = "Активности пока нет"
            s.activityHint = "Здесь появится код, который пишет ассистент, и команды, которые он запускает."
            s.callsSuffix = "вызовов"
            s.filterFiles = "Фильтр файлов…"; s.noFilesMatch = "Нет файлов, соответствующих"
            s.think = "думать"; s.noThink = "не думать"; s.turnsSuffix = "ходов"
            s.effortLow = "низк."; s.effortMed = "ср."; s.effortHigh = "выс."; s.effortMax = "макс"
            s.stats = "Статистика"; s.statsMessages = "Сообщения"; s.statsStreak = "Серия"
            s.statsActiveDays = "Активных дней"; s.statsSessions = "Сессии"; s.statsModels = "Модели"
            s.thinkingLower = "думает…"
            return s
        case .ko:
            var s = UIStrings(
                newSession: "새 세션", settings: "설정", noSessions: "세션 없음",
                messagePlaceholder: "어시스턴트에게 메시지…", thinking: "생각 중…", working: "작업 중…",
                writing: "작성 중…", disclaimer: "Kiln은 실수할 수 있습니다. 응답을 꼭 확인해 주세요.",
                learnMore: "더 알아보기", send: "보내기", stop: "중지", selectFile: "파일 선택",
                files: "파일", git: "Git", terminal: "터미널", delete: "삭제", cancel: "취소",
                rename: "이름 변경", pin: "고정", unpin: "고정 해제", fork: "포크", copy: "복사",
                commit: "커밋", push: "푸시", pull: "풀", changes: "변경 사항",
                recentCommits: "최근 커밋", cleanTree: "작업 트리가 깨끗합니다",
                search: "세션 검색…", clearMessages: "메시지 지우기",
                deleteConfirm: "정말 삭제하시겠습니까", cantUndo: "이 작업은 되돌릴 수 없습니다."
            )
            s.forked = "포크됨"; s.you = "나"; s.save = "저장"; s.loading = "로딩 중…"
            s.notGitRepo = "git 저장소가 아님"; s.commitMessage = "커밋 메시지…"
            s.browse = "찾아보기"; s.createSession = "세션 만들기"
            s.workingDirectory = "작업 디렉터리"; s.model = "모델"
            s.tagline = "에이전트 CLI를 위한 네이티브 공간."
            s.defaults = "기본값"; s.language = "언어"; s.memory = "메모리 (ENGRAM)"; s.about = "정보"
            s.systemPrompt = "시스템 프롬프트"; s.resetToDefault = "기본값으로 재설정"; s.enableEngram = "Engram 활성화"
            s.setGroup = "그룹 설정…"; s.moveToGroup = "그룹으로 이동"
            s.removeFromGroup = "그룹에서 제거"; s.deleteSession = "세션 삭제"
            s.groupName = "그룹 이름"; s.set = "설정"; s.removeGroup = "그룹 제거"
            s.error = "오류"; s.done = "완료"; s.running = "실행 중…"
            s.input = "입력"; s.output = "출력"
            s.justNow = "방금"; s.yesterday = "어제"
            s.mAgo = "분 전"; s.hAgo = "시간 전"; s.dAgo = "일 전"; s.msgs = "메시지"
            s.path = "경로"; s.permissionsLabel = "권한"; s.workDir = "작업 디렉터리"
            s.modeLabel = "모드"; s.modelLabel = "모델"; s.languageLabel = "언어"
            s.langDescription = "현재 어시스턴트가 선택한 언어로 답변합니다. UI 레이블도 함께 업데이트됩니다."
            s.code = "코드"; s.chat = "채팅"
            s.chatModeHint = "순수 채팅 — 파일도 도구도 없이, 대화만."
            s.activity = "활동"; s.noActivityYet = "아직 활동이 없습니다"
            s.activityHint = "어시스턴트가 작성한 코드와 실행한 명령어가 여기에 표시됩니다."
            s.callsSuffix = "호출"
            s.filterFiles = "파일 필터…"; s.noFilesMatch = "일치하는 파일이 없습니다"
            s.think = "생각"; s.noThink = "생각 안 함"; s.turnsSuffix = "턴"
            s.effortLow = "낮음"; s.effortMed = "중간"; s.effortHigh = "높음"; s.effortMax = "최대"
            s.stats = "통계"; s.statsMessages = "메시지"; s.statsStreak = "연속"
            s.statsActiveDays = "활동 일수"; s.statsSessions = "세션"; s.statsModels = "모델"
            s.thinkingLower = "생각 중…"
            return s
        case .nl:
            var s = UIStrings(
                newSession: "Nieuwe sessie", settings: "Instellingen", noSessions: "Geen sessies",
                messagePlaceholder: "Bericht aan assistent…", thinking: "Denkt na…", working: "bezig…",
                writing: "schrijft…", disclaimer: "Kiln kan fouten maken. Controleer de antwoorden.",
                learnMore: "Meer info", send: "Verstuur", stop: "Stop", selectFile: "Kies een bestand",
                files: "Bestanden", git: "Git", terminal: "Terminal", delete: "Verwijderen", cancel: "Annuleer",
                rename: "Hernoemen", pin: "Vastzetten", unpin: "Losmaken", fork: "Fork", copy: "Kopiëren",
                commit: "Commit", push: "Push", pull: "Pull", changes: "Wijzigingen",
                recentCommits: "Recente commits", cleanTree: "Werkboom schoon",
                search: "Sessies zoeken…", clearMessages: "Berichten wissen",
                deleteConfirm: "Weet je zeker dat je wilt verwijderen", cantUndo: "Dit kan niet ongedaan worden gemaakt."
            )
            s.forked = "geforkt"; s.you = "Jij"; s.save = "Opslaan"; s.loading = "Laden…"
            s.notGitRepo = "Geen git-repo"; s.commitMessage = "Commitbericht…"
            s.browse = "Bladeren"; s.createSession = "Sessie maken"
            s.workingDirectory = "WERKMAP"; s.model = "MODEL"
            s.tagline = "Een native thuis voor agent-CLI's."
            s.defaults = "STANDAARDWAARDEN"; s.language = "TAAL"; s.memory = "GEHEUGEN (ENGRAM)"; s.about = "OVER"
            s.systemPrompt = "Systeemprompt"; s.resetToDefault = "Standaard herstellen"; s.enableEngram = "Engram inschakelen"
            s.setGroup = "Groep instellen…"; s.moveToGroup = "Naar groep verplaatsen"
            s.removeFromGroup = "Uit groep halen"; s.deleteSession = "Sessie verwijderen"
            s.groupName = "Groepsnaam"; s.set = "Instellen"; s.removeGroup = "Groep verwijderen"
            s.error = "fout"; s.done = "klaar"; s.running = "loopt…"
            s.input = "INVOER"; s.output = "UITVOER"
            s.justNow = "zojuist"; s.yesterday = "gisteren"
            s.mAgo = "min"; s.hAgo = "u"; s.dAgo = "d"; s.msgs = "berichten"
            s.path = "Pad"; s.permissionsLabel = "Rechten"; s.workDir = "Werkmap"
            s.modeLabel = "Modus"; s.modelLabel = "Model"; s.languageLabel = "Taal"
            s.langDescription = "De actieve assistent antwoordt in de gekozen taal. UI-labels worden ook bijgewerkt."
            s.code = "Code"; s.chat = "Chat"
            s.chatModeHint = "Pure chat — geen bestanden, geen tools, alleen gesprek."
            s.activity = "Activiteit"; s.noActivityYet = "Nog geen activiteit"
            s.activityHint = "Code die de assistent schrijft en commando's die die uitvoert verschijnen hier."
            s.callsSuffix = "aanroepen"
            s.filterFiles = "Bestanden filteren…"; s.noFilesMatch = "Geen bestanden komen overeen met"
            s.think = "denken"; s.noThink = "niet denken"; s.turnsSuffix = "beurten"
            s.effortLow = "laag"; s.effortMed = "mid"; s.effortHigh = "hoog"; s.effortMax = "max"
            s.stats = "Statistieken"; s.statsMessages = "Berichten"; s.statsStreak = "Reeks"
            s.statsActiveDays = "Actieve dagen"; s.statsSessions = "Sessies"; s.statsModels = "Modellen"
            s.thinkingLower = "denkt…"
            return s
        case .hi:
            var s = UIStrings(
                newSession: "नया सत्र", settings: "सेटिंग्स", noSessions: "कोई सत्र नहीं",
                messagePlaceholder: "असिस्टेंट को संदेश…", thinking: "सोच रहा है…", working: "काम कर रहा है…",
                writing: "लिख रहा है…", disclaimer: "Kiln गलतियाँ कर सकता है। कृपया उत्तरों की दोबारा जाँच करें।",
                learnMore: "और जानें", send: "भेजें", stop: "रोकें", selectFile: "फ़ाइल चुनें",
                files: "फ़ाइलें", git: "Git", terminal: "टर्मिनल", delete: "हटाएँ", cancel: "रद्द करें",
                rename: "नाम बदलें", pin: "पिन करें", unpin: "अनपिन", fork: "फ़ोर्क", copy: "कॉपी",
                commit: "कमिट", push: "पुश", pull: "पुल", changes: "परिवर्तन",
                recentCommits: "हाल के कमिट", cleanTree: "वर्किंग ट्री साफ़ है",
                search: "सत्र खोजें…", clearMessages: "संदेश साफ़ करें",
                deleteConfirm: "क्या आप वाकई हटाना चाहते हैं", cantUndo: "यह पूर्ववत नहीं किया जा सकता।"
            )
            s.forked = "फ़ोर्क किया गया"; s.you = "आप"; s.save = "सहेजें"; s.loading = "लोड हो रहा है…"
            s.notGitRepo = "git रेपो नहीं"; s.commitMessage = "कमिट संदेश…"
            s.browse = "ब्राउज़ करें"; s.createSession = "सत्र बनाएँ"
            s.workingDirectory = "कार्य निर्देशिका"; s.model = "मॉडल"
            s.tagline = "एजेंट CLI के लिए एक मूल घर।"
            s.defaults = "डिफ़ॉल्ट"; s.language = "भाषा"; s.memory = "मेमोरी (ENGRAM)"; s.about = "जानकारी"
            s.systemPrompt = "सिस्टम प्रॉम्प्ट"; s.resetToDefault = "डिफ़ॉल्ट पर रीसेट करें"; s.enableEngram = "Engram सक्षम करें"
            s.setGroup = "समूह सेट करें…"; s.moveToGroup = "समूह में ले जाएँ"
            s.removeFromGroup = "समूह से हटाएँ"; s.deleteSession = "सत्र हटाएँ"
            s.groupName = "समूह का नाम"; s.set = "सेट करें"; s.removeGroup = "समूह हटाएँ"
            s.error = "त्रुटि"; s.done = "पूर्ण"; s.running = "चल रहा है…"
            s.input = "इनपुट"; s.output = "आउटपुट"
            s.justNow = "अभी"; s.yesterday = "कल"
            s.mAgo = "मि पहले"; s.hAgo = "घं पहले"; s.dAgo = "दि पहले"; s.msgs = "संदेश"
            s.path = "पथ"; s.permissionsLabel = "अनुमतियाँ"; s.workDir = "कार्य निर्देशिका"
            s.modeLabel = "मोड"; s.modelLabel = "मॉडल"; s.languageLabel = "भाषा"
            s.langDescription = "सक्रिय असिस्टेंट चयनित भाषा में उत्तर देगा। UI लेबल भी अपडेट होंगे।"
            s.code = "कोड"; s.chat = "चैट"
            s.chatModeHint = "शुद्ध चैट — कोई फ़ाइल नहीं, कोई टूल नहीं, बस बातचीत।"
            s.activity = "गतिविधि"; s.noActivityYet = "अभी तक कोई गतिविधि नहीं"
            s.activityHint = "असिस्टेंट जो कोड लिखता है और जो कमांड चलाता है, वे यहाँ दिखेंगे।"
            s.callsSuffix = "कॉल"
            s.filterFiles = "फ़ाइलें फ़िल्टर करें…"; s.noFilesMatch = "कोई फ़ाइल मेल नहीं खाती"
            s.think = "सोचें"; s.noThink = "न सोचें"; s.turnsSuffix = "बारी"
            s.effortLow = "कम"; s.effortMed = "मध्यम"; s.effortHigh = "उच्च"; s.effortMax = "अधिकतम"
            s.stats = "आँकड़े"; s.statsMessages = "संदेश"; s.statsStreak = "स्ट्रीक"
            s.statsActiveDays = "सक्रिय दिन"; s.statsSessions = "सत्र"; s.statsModels = "मॉडल"
            s.thinkingLower = "सोच रहा है…"
            return s
        case .ar:
            var s = UIStrings(
                newSession: "جلسة جديدة", settings: "الإعدادات", noSessions: "لا توجد جلسات",
                messagePlaceholder: "رسالة إلى المساعد…", thinking: "يفكر…", working: "يعمل…",
                writing: "يكتب…", disclaimer: "قد يخطئ Kiln. يُرجى التحقق من الردود.",
                learnMore: "اعرف المزيد", send: "إرسال", stop: "إيقاف", selectFile: "اختر ملفًا",
                files: "الملفات", git: "Git", terminal: "الطرفية", delete: "حذف", cancel: "إلغاء",
                rename: "إعادة تسمية", pin: "تثبيت", unpin: "إلغاء التثبيت", fork: "تفريع", copy: "نسخ",
                commit: "إيداع", push: "دفع", pull: "سحب", changes: "التغييرات",
                recentCommits: "الإيداعات الأخيرة", cleanTree: "شجرة العمل نظيفة",
                search: "بحث في الجلسات…", clearMessages: "مسح الرسائل",
                deleteConfirm: "هل أنت متأكد من الحذف", cantUndo: "لا يمكن التراجع عن هذا."
            )
            s.forked = "متفرع"; s.you = "أنت"; s.save = "حفظ"; s.loading = "جارٍ التحميل…"
            s.notGitRepo = "ليس مستودع git"; s.commitMessage = "رسالة الإيداع…"
            s.browse = "استعراض"; s.createSession = "إنشاء جلسة"
            s.workingDirectory = "مجلد العمل"; s.model = "النموذج"
            s.tagline = "موطن أصلي لواجهات الوكلاء النصية."
            s.defaults = "الافتراضيات"; s.language = "اللغة"; s.memory = "الذاكرة (ENGRAM)"; s.about = "حول"
            s.systemPrompt = "موجّه النظام"; s.resetToDefault = "إعادة التعيين"; s.enableEngram = "تفعيل Engram"
            s.setGroup = "تعيين مجموعة…"; s.moveToGroup = "نقل إلى مجموعة"
            s.removeFromGroup = "إزالة من المجموعة"; s.deleteSession = "حذف الجلسة"
            s.groupName = "اسم المجموعة"; s.set = "تعيين"; s.removeGroup = "إزالة المجموعة"
            s.error = "خطأ"; s.done = "تم"; s.running = "قيد التشغيل…"
            s.input = "المدخلات"; s.output = "المخرجات"
            s.justNow = "الآن"; s.yesterday = "أمس"
            s.mAgo = "د"; s.hAgo = "س"; s.dAgo = "ي"; s.msgs = "رسائل"
            s.path = "المسار"; s.permissionsLabel = "الأذونات"; s.workDir = "مجلد العمل"
            s.modeLabel = "الوضع"; s.modelLabel = "النموذج"; s.languageLabel = "اللغة"
            s.langDescription = "سيرد المساعد النشط باللغة المختارة. ستُحدَّث تسميات الواجهة أيضًا."
            s.code = "كود"; s.chat = "دردشة"
            s.chatModeHint = "دردشة نقية — بلا ملفات ولا أدوات، مجرد محادثة."
            s.activity = "النشاط"; s.noActivityYet = "لا يوجد نشاط بعد"
            s.activityHint = "سيظهر هنا الكود الذي يكتبه المساعد والأوامر التي يشغّلها."
            s.callsSuffix = "استدعاءات"
            s.filterFiles = "تصفية الملفات…"; s.noFilesMatch = "لا توجد ملفات تطابق"
            s.think = "فكّر"; s.noThink = "لا تفكّر"; s.turnsSuffix = "أدوار"
            s.effortLow = "منخفض"; s.effortMed = "متوسط"; s.effortHigh = "مرتفع"; s.effortMax = "أقصى"
            s.stats = "إحصاءات"; s.statsMessages = "الرسائل"; s.statsStreak = "سلسلة"
            s.statsActiveDays = "أيام نشطة"; s.statsSessions = "الجلسات"; s.statsModels = "النماذج"
            s.thinkingLower = "يفكر…"
            return s
        case .pl:
            var s = UIStrings(
                newSession: "Nowa sesja", settings: "Ustawienia", noSessions: "Brak sesji",
                messagePlaceholder: "Wiadomość do asystenta…", thinking: "Myśli…", working: "pracuje…",
                writing: "pisze…", disclaimer: "Kiln może popełniać błędy. Prosimy o weryfikację odpowiedzi.",
                learnMore: "Dowiedz się więcej", send: "Wyślij", stop: "Zatrzymaj", selectFile: "Wybierz plik",
                files: "Pliki", git: "Git", terminal: "Terminal", delete: "Usuń", cancel: "Anuluj",
                rename: "Zmień nazwę", pin: "Przypnij", unpin: "Odepnij", fork: "Fork", copy: "Kopiuj",
                commit: "Commit", push: "Push", pull: "Pull", changes: "Zmiany",
                recentCommits: "Ostatnie commity", cleanTree: "Drzewo robocze czyste",
                search: "Szukaj sesji…", clearMessages: "Wyczyść wiadomości",
                deleteConfirm: "Czy na pewno chcesz usunąć", cantUndo: "Tego nie można cofnąć."
            )
            s.forked = "sforkowane"; s.you = "Ty"; s.save = "Zapisz"; s.loading = "Ładowanie…"
            s.notGitRepo = "To nie repozytorium git"; s.commitMessage = "Wiadomość commita…"
            s.browse = "Przeglądaj"; s.createSession = "Utwórz sesję"
            s.workingDirectory = "KATALOG ROBOCZY"; s.model = "MODEL"
            s.tagline = "Natywne środowisko dla agentowych CLI."
            s.defaults = "DOMYŚLNE"; s.language = "JĘZYK"; s.memory = "PAMIĘĆ (ENGRAM)"; s.about = "O PROGRAMIE"
            s.systemPrompt = "Prompt systemowy"; s.resetToDefault = "Przywróć domyślne"; s.enableEngram = "Włącz Engram"
            s.setGroup = "Ustaw grupę…"; s.moveToGroup = "Przenieś do grupy"
            s.removeFromGroup = "Usuń z grupy"; s.deleteSession = "Usuń sesję"
            s.groupName = "Nazwa grupy"; s.set = "Ustaw"; s.removeGroup = "Usuń grupę"
            s.error = "błąd"; s.done = "gotowe"; s.running = "uruchamia się…"
            s.input = "WEJŚCIE"; s.output = "WYJŚCIE"
            s.justNow = "przed chwilą"; s.yesterday = "wczoraj"
            s.mAgo = "min"; s.hAgo = "godz"; s.dAgo = "d"; s.msgs = "wiad."
            s.path = "Ścieżka"; s.permissionsLabel = "Uprawnienia"; s.workDir = "Katalog"
            s.modeLabel = "Tryb"; s.modelLabel = "Model"; s.languageLabel = "Język"
            s.langDescription = "Aktywny asystent odpowie w wybranym języku. Etykiety UI również zostaną zaktualizowane."
            s.code = "Kod"; s.chat = "Czat"
            s.chatModeHint = "Czysty czat — bez plików, bez narzędzi, tylko rozmowa."
            s.activity = "Aktywność"; s.noActivityYet = "Brak aktywności"
            s.activityHint = "Kod, który pisze asystent, i polecenia, które uruchamia, pojawią się tutaj."
            s.callsSuffix = "wywołań"
            s.filterFiles = "Filtruj pliki…"; s.noFilesMatch = "Brak plików pasujących do"
            s.think = "myśl"; s.noThink = "bez myślenia"; s.turnsSuffix = "tur"
            s.effortLow = "niski"; s.effortMed = "śr."; s.effortHigh = "wysoki"; s.effortMax = "max"
            s.stats = "Statystyki"; s.statsMessages = "Wiadomości"; s.statsStreak = "Passa"
            s.statsActiveDays = "Aktywne dni"; s.statsSessions = "Sesje"; s.statsModels = "Modele"
            s.thinkingLower = "myśli…"
            return s
        case .tr:
            var s = UIStrings(
                newSession: "Yeni oturum", settings: "Ayarlar", noSessions: "Oturum yok",
                messagePlaceholder: "Asistana mesaj…", thinking: "Düşünüyor…", working: "çalışıyor…",
                writing: "yazıyor…", disclaimer: "Kiln hata yapabilir. Lütfen yanıtları kontrol edin.",
                learnMore: "Daha fazla bilgi", send: "Gönder", stop: "Durdur", selectFile: "Dosya seç",
                files: "Dosyalar", git: "Git", terminal: "Terminal", delete: "Sil", cancel: "İptal",
                rename: "Yeniden adlandır", pin: "Sabitle", unpin: "Sabitlemeyi kaldır", fork: "Fork", copy: "Kopyala",
                commit: "Commit", push: "Push", pull: "Pull", changes: "Değişiklikler",
                recentCommits: "Son commit'ler", cleanTree: "Çalışma ağacı temiz",
                search: "Oturum ara…", clearMessages: "Mesajları temizle",
                deleteConfirm: "Silmek istediğinize emin misiniz", cantUndo: "Bu geri alınamaz."
            )
            s.forked = "forklandı"; s.you = "Sen"; s.save = "Kaydet"; s.loading = "Yükleniyor…"
            s.notGitRepo = "Git deposu değil"; s.commitMessage = "Commit mesajı…"
            s.browse = "Gözat"; s.createSession = "Oturum oluştur"
            s.workingDirectory = "ÇALIŞMA DİZİNİ"; s.model = "MODEL"
            s.tagline = "Ajan CLI'ları için yerel bir yuva."
            s.defaults = "VARSAYILANLAR"; s.language = "DİL"; s.memory = "BELLEK (ENGRAM)"; s.about = "HAKKINDA"
            s.systemPrompt = "Sistem istemi"; s.resetToDefault = "Varsayılana sıfırla"; s.enableEngram = "Engram'ı etkinleştir"
            s.setGroup = "Grup ayarla…"; s.moveToGroup = "Gruba taşı"
            s.removeFromGroup = "Gruptan çıkar"; s.deleteSession = "Oturumu sil"
            s.groupName = "Grup adı"; s.set = "Ayarla"; s.removeGroup = "Grubu kaldır"
            s.error = "hata"; s.done = "tamam"; s.running = "çalışıyor…"
            s.input = "GİRDİ"; s.output = "ÇIKTI"
            s.justNow = "az önce"; s.yesterday = "dün"
            s.mAgo = "dk"; s.hAgo = "sa"; s.dAgo = "g"; s.msgs = "mesaj"
            s.path = "Yol"; s.permissionsLabel = "İzinler"; s.workDir = "Dizin"
            s.modeLabel = "Mod"; s.modelLabel = "Model"; s.languageLabel = "Dil"
            s.langDescription = "Etkin asistan seçilen dilde yanıt verecek. Arayüz etiketleri de güncellenir."
            s.code = "Kod"; s.chat = "Sohbet"
            s.chatModeHint = "Saf sohbet — dosya yok, araç yok, sadece konuşma."
            s.activity = "Etkinlik"; s.noActivityYet = "Henüz etkinlik yok"
            s.activityHint = "Asistanın yazdığı kod ve çalıştırdığı komutlar burada görünür."
            s.callsSuffix = "çağrı"
            s.filterFiles = "Dosyaları filtrele…"; s.noFilesMatch = "Eşleşen dosya yok"
            s.think = "düşün"; s.noThink = "düşünme"; s.turnsSuffix = "tur"
            s.effortLow = "düşük"; s.effortMed = "orta"; s.effortHigh = "yüksek"; s.effortMax = "maks"
            s.stats = "İstatistik"; s.statsMessages = "Mesajlar"; s.statsStreak = "Seri"
            s.statsActiveDays = "Aktif günler"; s.statsSessions = "Oturumlar"; s.statsModels = "Modeller"
            s.thinkingLower = "düşünüyor…"
            return s
        case .sv:
            var s = UIStrings(
                newSession: "Ny session", settings: "Inställningar", noSessions: "Inga sessioner",
                messagePlaceholder: "Meddelande till assistenten…", thinking: "Tänker…", working: "arbetar…",
                writing: "skriver…", disclaimer: "Kiln kan göra misstag. Dubbelkolla alltid svaren.",
                learnMore: "Läs mer", send: "Skicka", stop: "Stopp", selectFile: "Välj en fil",
                files: "Filer", git: "Git", terminal: "Terminal", delete: "Radera", cancel: "Avbryt",
                rename: "Byt namn", pin: "Fäst", unpin: "Lossa", fork: "Forka", copy: "Kopiera",
                commit: "Commit", push: "Push", pull: "Pull", changes: "Ändringar",
                recentCommits: "Senaste commits", cleanTree: "Arbetsträd rent",
                search: "Sök sessioner…", clearMessages: "Rensa meddelanden",
                deleteConfirm: "Vill du verkligen radera", cantUndo: "Detta kan inte ångras."
            )
            s.forked = "forkad"; s.you = "Du"; s.save = "Spara"; s.loading = "Laddar…"
            s.notGitRepo = "Inte ett git-repo"; s.commitMessage = "Commit-meddelande…"
            s.browse = "Bläddra"; s.createSession = "Skapa session"
            s.workingDirectory = "ARBETSMAPP"; s.model = "MODELL"
            s.tagline = "Ett inbyggt hem för agent-CLI:er."
            s.defaults = "STANDARD"; s.language = "SPRÅK"; s.memory = "MINNE (ENGRAM)"; s.about = "OM"
            s.systemPrompt = "Systemprompt"; s.resetToDefault = "Återställ standard"; s.enableEngram = "Aktivera Engram"
            s.setGroup = "Ange grupp…"; s.moveToGroup = "Flytta till grupp"
            s.removeFromGroup = "Ta bort från grupp"; s.deleteSession = "Radera session"
            s.groupName = "Gruppnamn"; s.set = "Ange"; s.removeGroup = "Ta bort grupp"
            s.error = "fel"; s.done = "klar"; s.running = "körs…"
            s.input = "INDATA"; s.output = "UTDATA"
            s.justNow = "just nu"; s.yesterday = "igår"
            s.mAgo = "min"; s.hAgo = "h"; s.dAgo = "d"; s.msgs = "medd."
            s.path = "Sökväg"; s.permissionsLabel = "Behörigheter"; s.workDir = "Arbetsmapp"
            s.modeLabel = "Läge"; s.modelLabel = "Modell"; s.languageLabel = "Språk"
            s.langDescription = "Den aktiva assistenten svarar på det valda språket. UI-etiketter uppdateras också."
            s.code = "Kod"; s.chat = "Chatt"
            s.chatModeHint = "Ren chatt — inga filer, inga verktyg, bara samtal."
            s.activity = "Aktivitet"; s.noActivityYet = "Ingen aktivitet ännu"
            s.activityHint = "Kod som assistenten skriver och kommandon den kör visas här."
            s.callsSuffix = "anrop"
            s.filterFiles = "Filtrera filer…"; s.noFilesMatch = "Inga filer matchar"
            s.think = "tänk"; s.noThink = "tänk inte"; s.turnsSuffix = "turer"
            s.effortLow = "låg"; s.effortMed = "med"; s.effortHigh = "hög"; s.effortMax = "max"
            s.stats = "Statistik"; s.statsMessages = "Meddelanden"; s.statsStreak = "Svit"
            s.statsActiveDays = "Aktiva dagar"; s.statsSessions = "Sessioner"; s.statsModels = "Modeller"
            s.thinkingLower = "tänker…"
            return s
        }
    }
}

struct UIStrings: Sendable {
    let newSession: String
    let settings: String
    let noSessions: String
    let messagePlaceholder: String
    let thinking: String
    let working: String
    let writing: String
    let disclaimer: String
    let learnMore: String
    let send: String
    let stop: String
    let selectFile: String
    let files: String
    let git: String
    let terminal: String
    let delete: String
    let cancel: String
    let rename: String
    let pin: String
    let unpin: String
    let fork: String
    let copy: String
    let commit: String
    let push: String
    let pull: String
    let changes: String
    let recentCommits: String
    let cleanTree: String
    let search: String
    let clearMessages: String
    let deleteConfirm: String
    let cantUndo: String
    // Additional UI strings
    var forked: String = "forked"
    var you: String = "You"
    var claude: String = "Assistant"
    var save: String = "Save"
    var loading: String = "Loading…"
    var notGitRepo: String = "Not a git repo"
    var commitMessage: String = "Commit message…"
    var browse: String = "Browse"
    var createSession: String = "Create Session"
    var workingDirectory: String = "WORKING DIRECTORY"
    var model: String = "MODEL"
    var tagline: String = "A native home for agent CLIs."
    var defaults: String = "DEFAULTS"
    var language: String = "LANGUAGE"
    var memory: String = "MEMORY (ENGRAM)"
    var about: String = "ABOUT"
    var systemPrompt: String = "System Prompt"
    var resetToDefault: String = "Reset to Default"
    var enableEngram: String = "Enable Engram"
    var setGroup: String = "Set Group…"
    var moveToGroup: String = "Move to Group"
    var removeFromGroup: String = "Remove from Group"
    var deleteSession: String = "Delete Session"
    var groupName: String = "Group name"
    var set: String = "Set"
    var removeGroup: String = "Remove Group"
    var error: String = "error"
    var done: String = "done"
    var running: String = "running…"
    var input: String = "INPUT"
    var output: String = "OUTPUT"
    var justNow: String = "just now"
    var yesterday: String = "yesterday"
    var mAgo: String = "m ago"
    var hAgo: String = "h ago"
    var dAgo: String = "d ago"
    var msgs: String = "msgs"
    var path: String = "Path"
    var permissionsLabel: String = "Permissions"
    var workDir: String = "Work Dir"
    var modeLabel: String = "Mode"
    var modelLabel: String = "Model"
    var languageLabel: String = "Language"
    var langDescription: String = "The active assistant will respond in the selected language. UI labels will also update."
    var code: String = "Code"
    var chat: String = "Chat"
    var chatModeHint: String = "Pure chat — no files, no tools, just conversation."
    // Activity tab
    var activity: String = "Activity"
    var noActivityYet: String = "No activity yet"
    var activityHint: String = "Code the assistant writes and commands it runs will show here."
    var callsSuffix: String = "calls"
    // Files tab
    var filterFiles: String = "Filter files…"
    var noFilesMatch: String = "No files match"
    // Composer toolbar
    var think: String = "think"
    var noThink: String = "no think"
    var turnsSuffix: String = "turns"
    // Effort levels
    var effortLow: String = "low"
    var effortMed: String = "med"
    var effortHigh: String = "high"
    var effortMax: String = "max"
    // Stats
    var stats: String = "Stats"
    var statsMessages: String = "Messages"
    var statsStreak: String = "Streak"
    var statsActiveDays: String = "Active Days"
    var statsSessions: String = "Sessions"
    var statsModels: String = "Models"
    // Chat
    var thinkingLower: String = "thinking…"
}

// MARK: - Customization enums

enum FontScale: String, CaseIterable, Codable, Sendable, Identifiable {
    case small, medium, large, huge
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    /// Multiplier applied to text sizes app-wide.
    var factor: CGFloat {
        switch self {
        case .small: 0.9
        case .medium: 1.0
        case .large: 1.1
        case .huge: 1.2
        }
    }
}

enum Density: String, CaseIterable, Codable, Sendable, Identifiable {
    case compact, comfortable, spacious
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    /// Vertical padding multiplier for rows / messages.
    var padding: CGFloat {
        switch self {
        case .compact: 0.7
        case .comfortable: 1.0
        case .spacious: 1.3
        }
    }
}

enum TimestampDisplay: String, CaseIterable, Codable, Sendable, Identifiable {
    case never, hover, always
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

enum SendKey: String, CaseIterable, Codable, Sendable, Identifiable {
    case enter
    case cmdEnter
    var id: String { rawValue }
    var label: String {
        switch self {
        case .enter: "⏎ Enter"
        case .cmdEnter: "⌘⏎ Cmd+Enter"
        }
    }
    var subtitle: String {
        switch self {
        case .enter: "Enter sends, Shift+Enter newline"
        case .cmdEnter: "Cmd+Enter sends, Enter newline"
        }
    }
}

enum HintStripMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case always, focused, never
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

/// Appearance mode. `.system` follows the macOS-wide setting.
/// Stored as the string rawValue on disk; the legacy `theme: String` field
/// accepted "dark" | "light" and is preserved as the same rawValues.
enum ThemeMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }
    /// SwiftUI scheme to apply, or `nil` to follow system.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
    /// NSAppearance for window-chrome sync. `nil` → follow system.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light:  return NSAppearance(named: .aqua)
        case .dark:   return NSAppearance(named: .darkAqua)
        }
    }
}

struct KilnSettings: Codable, Sendable, Equatable {
    var defaultModel: ClaudeModel = .sonnet46
    var defaultWorkDir: String = NSHomeDirectory()
    var systemPrompt: String = KilnSettings.defaultSystemPrompt
    // Off by default — new users get a clean slate and can opt in from
    // onboarding or Settings. Existing installs with a settings file keep
    // whatever they had (the decoder fallback below preserves the old
    // `true` behavior if the key was never written).
    var useEngram: Bool = false
    /// Optional manual override for the `engram` binary location. Empty
    /// means "auto-detect on PATH / common install locations." Set via
    /// Onboarding's "Pick path…" or Settings → Memory when the binary
    /// lives somewhere unusual (custom venv, mise shim, dev checkout).
    var engramPath: String = ""
    var useAutoMemory: Bool = false
    var defaultPermissions: PermissionMode = .bypass
    var defaultMode: SessionMode = .build
    /// Legacy field — accepted "dark" | "light". Kept for Codable back-compat
    /// so older preference files keep loading. New code should read/write
    /// `themeMode` instead.
    var theme: String = "dark"
    /// Appearance mode — what the Settings picker drives. Migrated from
    /// `theme` when an older preferences file is decoded.
    var themeMode: ThemeMode = .system
    var language: AppLanguage = .en

    // Appearance
    var accentHex: String = "f97316"
    var fontScale: FontScale = .medium
    var density: Density = .comfortable

    // Chat
    var showAvatars: Bool = true
    var showTimestamps: TimestampDisplay = .hover
    var autoScroll: Bool = true
    var thinkingCollapsedByDefault: Bool = false
    var showFollowUpChips: Bool = true

    // Composer
    var sendKey: SendKey = .enter
    var hintStripMode: HintStripMode = .always
    var spellCheck: Bool = true
    var composerPlaceholder: String = ""  // empty => use language default

    // Notifications
    var notifyOnCompletion: Bool = true
    var notifySound: Bool = true

    // Advanced
    var undoSendWindow: Int = 0  // seconds; 0 disables
    var onCompleteShellCommand: String = ""  // run on session completion
    var enableRepoAwareness: Bool = true

    // Identity — shown in chat messages and the sidebar
    /// Display name for user messages. Empty = fall back to the localized
    /// "You" label.
    var userDisplayName: String = ""
    /// Filename (not path) of the user avatar image stored in Application
    /// Support. Empty = default person.fill icon.
    var userAvatarFilename: String = ""
    var showTokenHeatmap: Bool = false

    // Custom decoder to handle missing keys from older settings files
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        defaultModel = (try? c.decode(ClaudeModel.self, forKey: .defaultModel)) ?? .sonnet46
        defaultWorkDir = (try? c.decode(String.self, forKey: .defaultWorkDir)) ?? NSHomeDirectory()
        systemPrompt = (try? c.decode(String.self, forKey: .systemPrompt)) ?? KilnSettings.defaultSystemPrompt
        useEngram = (try? c.decode(Bool.self, forKey: .useEngram)) ?? true
        engramPath = (try? c.decode(String.self, forKey: .engramPath)) ?? ""
        useAutoMemory = (try? c.decode(Bool.self, forKey: .useAutoMemory)) ?? false
        defaultPermissions = (try? c.decode(PermissionMode.self, forKey: .defaultPermissions)) ?? .bypass
        defaultMode = (try? c.decode(SessionMode.self, forKey: .defaultMode)) ?? .build
        theme = (try? c.decode(String.self, forKey: .theme)) ?? "dark"
        // Migrate the old String theme into the new enum when no explicit
        // themeMode is stored. Fresh installs default to `.system`.
        if let explicit = try? c.decode(ThemeMode.self, forKey: .themeMode) {
            themeMode = explicit
        } else {
            themeMode = ThemeMode(rawValue: theme) ?? .system
        }
        language = (try? c.decode(AppLanguage.self, forKey: .language)) ?? .en
        accentHex = (try? c.decode(String.self, forKey: .accentHex)) ?? "f97316"
        fontScale = (try? c.decode(FontScale.self, forKey: .fontScale)) ?? .medium
        density = (try? c.decode(Density.self, forKey: .density)) ?? .comfortable
        showAvatars = (try? c.decode(Bool.self, forKey: .showAvatars)) ?? true
        showTimestamps = (try? c.decode(TimestampDisplay.self, forKey: .showTimestamps)) ?? .hover
        autoScroll = (try? c.decode(Bool.self, forKey: .autoScroll)) ?? true
        thinkingCollapsedByDefault = (try? c.decode(Bool.self, forKey: .thinkingCollapsedByDefault)) ?? false
        showFollowUpChips = (try? c.decode(Bool.self, forKey: .showFollowUpChips)) ?? true
        sendKey = (try? c.decode(SendKey.self, forKey: .sendKey)) ?? .enter
        hintStripMode = (try? c.decode(HintStripMode.self, forKey: .hintStripMode)) ?? .always
        spellCheck = (try? c.decode(Bool.self, forKey: .spellCheck)) ?? true
        composerPlaceholder = (try? c.decode(String.self, forKey: .composerPlaceholder)) ?? ""
        notifyOnCompletion = (try? c.decode(Bool.self, forKey: .notifyOnCompletion)) ?? true
        notifySound = (try? c.decode(Bool.self, forKey: .notifySound)) ?? true
        undoSendWindow = (try? c.decode(Int.self, forKey: .undoSendWindow)) ?? 0
        onCompleteShellCommand = (try? c.decode(String.self, forKey: .onCompleteShellCommand)) ?? ""
        enableRepoAwareness = (try? c.decode(Bool.self, forKey: .enableRepoAwareness)) ?? true
        showTokenHeatmap = (try? c.decode(Bool.self, forKey: .showTokenHeatmap)) ?? false
        userDisplayName = (try? c.decode(String.self, forKey: .userDisplayName)) ?? ""
        userAvatarFilename = (try? c.decode(String.self, forKey: .userAvatarFilename)) ?? ""
    }

    init(defaultModel: ClaudeModel = .sonnet46, defaultWorkDir: String = NSHomeDirectory(),
         systemPrompt: String = KilnSettings.defaultSystemPrompt, useEngram: Bool = false,
         useAutoMemory: Bool = false, defaultPermissions: PermissionMode = .bypass,
         defaultMode: SessionMode = .build, theme: String = "dark", language: AppLanguage = .en) {
        self.defaultModel = defaultModel; self.defaultWorkDir = defaultWorkDir
        self.systemPrompt = systemPrompt; self.useEngram = useEngram
        self.useAutoMemory = useAutoMemory; self.defaultPermissions = defaultPermissions
        self.defaultMode = defaultMode; self.theme = theme; self.language = language
    }

    // Ship with an empty system prompt by default — users add their own
    // from Settings. The engram block below is only applied when the user
    // opts into engram during onboarding (or toggles it on later).
    static let defaultSystemPrompt = ""

    /// System prompt snippet applied when the user enables engram. Written
    /// into `systemPrompt` on opt-in so Claude knows the tools exist.
    static let engramSystemPrompt = """
    You have access to engram, a cognitive memory system. Use it for ALL memory operations:
    - Use `recall` before starting work to load relevant context
    - Use `remember` after learning something worth keeping
    - Use `remember_decision` for decisions with rationale
    - Use `remember_error` for error patterns
    - Use `recall_hints` for lightweight recognition triggers

    Engram is the canonical memory store. Prefer it over flat file memory systems.
    """

    static let empty = KilnSettings(systemPrompt: "", useEngram: false)
}

// MARK: - File tree

struct ComposerAttachment: Identifiable, Sendable, Equatable, Codable, Hashable {
    let id: String
    let path: String
    let name: String
}

struct FileEntry: Identifiable, Sendable {
    let id: String
    let name: String
    let path: String
    let isDirectory: Bool
    var children: [FileEntry]?
    var isExpanded: Bool

    init(name: String, path: String, isDirectory: Bool) {
        self.id = path
        self.name = name
        self.path = path
        self.isDirectory = isDirectory
        self.children = isDirectory ? nil : nil // loaded lazily
        self.isExpanded = false
    }
}
