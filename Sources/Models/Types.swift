import AppKit
import Foundation
import SwiftUI

// MARK: - Claude Models

enum ClaudeModel: String, CaseIterable, Identifiable, Sendable, Codable {
    case opus47 = "claude-opus-4-7"
    case sonnet46 = "claude-sonnet-4-6"
    case haiku45 = "claude-haiku-4-5-20251001"

    var id: String { rawValue }

    /// Full CLI model ID (same as rawValue)
    var fullId: String { rawValue }

    var label: String {
        switch self {
        case .opus47: "Opus 4.7"
        case .sonnet46: "Sonnet 4.6"
        case .haiku45: "Haiku 4.5"
        }
    }

    var shortLabel: String {
        switch self {
        case .opus47: "Opus"
        case .sonnet46: "Sonnet"
        case .haiku45: "Haiku"
        }
    }

    var tier: String {
        switch self {
        case .opus47: "Flagship"
        case .sonnet46: "Balanced"
        case .haiku45: "Fast"
        }
    }

    /// Standard context window in tokens
    var contextWindow: Int {
        switch self {
        case .opus47: 200_000
        case .sonnet46: 200_000
        case .haiku45: 200_000
        }
    }

    /// Extended context (1M for Opus and Sonnet)
    var extendedContextWindow: Int? {
        switch self {
        case .opus47, .sonnet46: 1_000_000
        default: nil
        }
    }

    var supportsExtendedContext: Bool {
        extendedContextWindow != nil
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
                messagePlaceholder: "Message Claude…", thinking: "Thinking…", working: "working…",
                writing: "writing…", disclaimer: "Kiln uses Claude and can make mistakes. Please double-check responses.",
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
            s.tagline = "Ein natives Zuhause für Claude."
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
            s.langDescription = "Claude antwortet in der gewählten Sprache. UI-Beschriftungen werden ebenfalls aktualisiert."
            s.code = "Code"; s.chat = "Chat"
            s.chatModeHint = "Reiner Chat — keine Dateien, keine Tools, nur Unterhaltung."
            s.activity = "Aktivität"; s.noActivityYet = "Noch keine Aktivität"
            s.activityHint = "Code, den Claude schreibt, und Befehle, die er ausführt, erscheinen hier."
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
                messagePlaceholder: "向 Claude 发送消息…", thinking: "思考中…", working: "工作中…",
                writing: "正在写…", disclaimer: "Kiln 使用 Claude，可能会出错。请仔细检查回复。",
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
            s.tagline = "Claude 的原生之家。"
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
            s.langDescription = "Claude 将以所选语言回复。UI 标签也会更新。"
            s.code = "代码"; s.chat = "聊天"
            s.chatModeHint = "纯聊天 — 无文件、无工具，仅对话。"
            s.activity = "活动"; s.noActivityYet = "暂无活动"
            s.activityHint = "Claude 编写的代码和运行的命令将显示在这里。"
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
                messagePlaceholder: "Message à Claude…", thinking: "Réflexion…", working: "en cours…",
                writing: "écriture…", disclaimer: "Kiln utilise Claude et peut faire des erreurs. Veuillez vérifier les réponses.",
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
            s.tagline = "Un foyer natif pour Claude."
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
            s.langDescription = "Claude répondra dans la langue sélectionnée. Les libellés de l'interface seront également mis à jour."
            s.code = "Code"; s.chat = "Chat"
            s.chatModeHint = "Chat pur — pas de fichiers, pas d'outils, juste de la conversation."
            s.activity = "Activité"; s.noActivityYet = "Aucune activité pour l'instant"
            s.activityHint = "Le code que Claude écrit et les commandes qu'il exécute apparaîtront ici."
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
                messagePlaceholder: "Mensaje a Claude…", thinking: "Pensando…", working: "trabajando…",
                writing: "escribiendo…", disclaimer: "Kiln usa Claude y puede cometer errores. Verifique las respuestas.",
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
            s.tagline = "Un hogar nativo para Claude."
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
            s.langDescription = "Claude responderá en el idioma seleccionado. Las etiquetas de la interfaz también se actualizarán."
            s.code = "Código"; s.chat = "Chat"
            s.chatModeHint = "Chat puro — sin archivos, sin herramientas, solo conversación."
            s.activity = "Actividad"; s.noActivityYet = "Sin actividad todavía"
            s.activityHint = "El código que Claude escribe y los comandos que ejecuta aparecerán aquí."
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
                messagePlaceholder: "Claudeにメッセージ…", thinking: "考え中…", working: "作業中…",
                writing: "書いています…", disclaimer: "KilnはClaudeを使用しており、間違いがある場合があります。回答をご確認ください。",
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
            s.tagline = "Claudeのためのネイティブな場所。"
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
            s.langDescription = "Claudeは選択した言語で応答します。UIラベルも更新されます。"
            s.code = "コード"; s.chat = "チャット"
            s.chatModeHint = "純粋なチャット — ファイルやツールなし、会話のみ。"
            s.activity = "アクティビティ"; s.noActivityYet = "まだアクティビティがありません"
            s.activityHint = "Claudeが書くコードと実行するコマンドがここに表示されます。"
            s.callsSuffix = "回"
            s.filterFiles = "ファイルを絞り込む…"; s.noFilesMatch = "一致するファイルがありません"
            s.think = "思考"; s.noThink = "思考なし"; s.turnsSuffix = "ターン"
            s.effortLow = "低"; s.effortMed = "中"; s.effortHigh = "高"; s.effortMax = "最大"
            s.stats = "統計"; s.statsMessages = "メッセージ"; s.statsStreak = "連続"
            s.statsActiveDays = "アクティブ日数"; s.statsSessions = "セッション"; s.statsModels = "モデル"
            s.thinkingLower = "思考中…"
            return s
        default:
            // Languages without a full UI translation fall back to English
            // strings. Claude's chat output still respects the choice via
            // claudeInstruction — the chat is where localisation matters
            // most anyway. langDescription is rewritten so the Settings
            // row doesn't falsely promise that UI labels change.
            var s = AppLanguage.en.ui
            s.langDescription = "Claude will respond in \(label). The Kiln UI stays in English for this language."
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
    var claude: String = "Claude"
    var save: String = "Save"
    var loading: String = "Loading…"
    var notGitRepo: String = "Not a git repo"
    var commitMessage: String = "Commit message…"
    var browse: String = "Browse"
    var createSession: String = "Create Session"
    var workingDirectory: String = "WORKING DIRECTORY"
    var model: String = "MODEL"
    var tagline: String = "A native home for Claude."
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
    var langDescription: String = "Claude will respond in the selected language. UI labels will also update."
    var code: String = "Code"
    var chat: String = "Chat"
    var chatModeHint: String = "Pure chat — no files, no tools, just conversation."
    // Activity tab
    var activity: String = "Activity"
    var noActivityYet: String = "No activity yet"
    var activityHint: String = "Code Claude writes and commands it runs will show here."
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
