import Foundation
import SwiftUI
import AVFoundation

/// Central app state — owns sessions, drives UI, relays Claude events.
@MainActor
final class AppStore: ObservableObject {
    // MARK: - Published state

    @Published var sessions: [Session] = []
    @Published var activeSessionId: String? {
        didSet {
            // Clear "done" pulse when the user focuses the session.
            if let id = activeSessionId {
                recentlyCompleted.removeValue(forKey: id)
            }
        }
    }
    @Published var showNewSessionSheet = false
    @Published var showSessionTemplates = false
    @Published var showWhatsNew = false
    @Published var showSessionInfo = false
    @Published var showShortcutsOverlay = false
    /// First-run onboarding. Drives the OnboardingSheet overlay — walks
    /// through the welcome, checks for Claude Code, and helps install it
    /// if missing. Sticky: dismissing it writes `kiln.onboardingCompleted`
    /// to UserDefaults so it never pops up again.
    @Published var showOnboarding = false

    /// Session ids currently multi-selected in the sidebar. Empty means
    /// single-selection mode (the activeSessionId rules).
    @Published var selectedSessionIds: Set<String> = []

    func toggleSelect(_ sessionId: String) {
        if selectedSessionIds.contains(sessionId) {
            selectedSessionIds.remove(sessionId)
        } else {
            selectedSessionIds.insert(sessionId)
        }
    }

    func clearSelection() {
        selectedSessionIds.removeAll()
    }

    func bulkArchive() {
        for id in selectedSessionIds {
            if let idx = sessions.firstIndex(where: { $0.id == id }) {
                var s = sessions[idx]
                s.isArchived = true
                sessions[idx] = s
                Persistence.saveSession(s)
            }
        }
        selectedSessionIds.removeAll()
    }

    func bulkDelete() {
        for id in selectedSessionIds {
            deleteSession(id)
        }
        selectedSessionIds.removeAll()
    }

    func bulkAddTag(_ tag: String) {
        for id in selectedSessionIds {
            addTag(tag, to: id)
        }
    }

    /// Stamp a color label on every selected session. `nil` clears.
    func bulkColor(_ color: String?) {
        for id in selectedSessionIds {
            setSessionColor(id, color: color)
        }
    }

    /// Collapse every selected session into the oldest one, concatenating
    /// messages in chronological order and deleting the rest. The
    /// surviving session is activated. A no-op if fewer than two are
    /// selected — the user probably didn't mean it.
    @discardableResult
    func bulkMerge() -> String? {
        guard selectedSessionIds.count >= 2 else { return nil }
        let ids = Array(selectedSessionIds)
        var ordered: [Session] = []
        for id in ids {
            if let s = sessions.first(where: { $0.id == id }) { ordered.append(s) }
        }
        ordered.sort(by: { $0.createdAt < $1.createdAt })
        guard let primary = ordered.first else { return nil }
        guard let primaryIdx = sessions.firstIndex(where: { $0.id == primary.id }) else { return nil }
        var updated = sessions[primaryIdx]
        for s in ordered.dropFirst() {
            updated.messages.append(contentsOf: s.messages)
        }
        updated.messages.sort(by: { $0.timestamp < $1.timestamp })
        sessions[primaryIdx] = updated
        Persistence.saveSession(updated)
        for s in ordered.dropFirst() {
            deleteSession(s.id)
        }
        selectedSessionIds.removeAll()
        activeSessionId = primary.id
        return primary.id
    }

    /// Filter state for the sidebar — when set, only sessions carrying
    /// this color label render. `nil` = no filter. Lives on the store so
    /// it persists across sidebar tab flips without redrawing.
    @Published var sidebarColorFilter: String? = nil

    /// Build a `kiln://session/<id>` URL so another Kiln window (or the
    /// remote control server) can jump straight to this session.
    func sessionLink(_ id: String) -> String {
        "kiln://session/\(id)"
    }

    /// Copy the kiln:// link for a session onto the clipboard.
    func copySessionLink(_ id: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(sessionLink(id), forType: .string)
    }

    /// Re-read every session from disk. Useful when external tools (or
    /// the remote control API) mutate files and the window is stale.
    func reloadFromDisk() {
        let fresh = Persistence.loadSessions().map { $0.toSession() }
        sessions = fresh
    }
    @Published var showSettings = false
    @Published var selectedSidebarTab: SessionKind = .code

    // Overlays
    @Published var showCommandPalette = false
    @Published var showQuickOpen = false
    /// When non-nil, RightPanel's FileTreeView opens this absolute path
    /// as a tab. Cleared after consumption.
    @Published var quickOpenRequest: String?
    @Published var showGlobalSearch = false
    /// In-session find bar visibility (⌘F). Search text lives on ChatView.
    @Published var showInSessionFind = false

    /// Tool-approval requests awaiting the user. The ApprovalDialog sheet
    /// renders the first entry; the HTTP hook handler is blocked on a
    /// continuation stored in `approvalContinuations` until the user
    /// resolves it via `respondToApproval`.
    @Published var pendingApprovals: [PendingApproval] = []
    private var approvalContinuations: [String: CheckedContinuation<HookDecision, Never>] = [:]

    /// Called by RemoteControlServer when a PreToolUse hook fires.
    /// Suspends until the user decides — the continuation is resumed by
    /// `respondToApproval`.
    func awaitApproval(_ approval: PendingApproval) async -> HookDecision {
        await withCheckedContinuation { cont in
            approvalContinuations[approval.id] = cont
            pendingApprovals.append(approval)
        }
    }

    /// Resolve a pending approval. Clears UI state and wakes the hook.
    func respondToApproval(id: String, approve: Bool, reason: String? = nil) {
        guard let cont = approvalContinuations.removeValue(forKey: id) else { return }
        pendingApprovals.removeAll { $0.id == id }
        cont.resume(returning: HookDecision(approve: approve, reason: reason))
    }

    // When set, ChatView scrolls to this message and clears it
    @Published var pendingJumpMessageId: String?

    // Per-session streaming/runtime state. Keyed by sessionId. Enables
    // concurrent generation across multiple sessions — each has its own
    // buffers so switching sessions never cross-contaminates.
    @Published var runtimeStates: [String: SessionRuntimeState] = [:]

    /// Sessions that finished generating while not focused. The sidebar
    /// renders a small "done" pulse/badge for each; the entry clears when
    /// the user switches to that session. Value = completion timestamp.
    @Published var recentlyCompleted: [String: Date] = [:]

    /// Read-only accessor — returns an empty default if the session isn't
    /// currently generating.
    func runtime(_ sessionId: String?) -> SessionRuntimeState {
        guard let id = sessionId else { return SessionRuntimeState() }
        return runtimeStates[id] ?? SessionRuntimeState()
    }

    /// Active session's runtime — backs the convenience properties below.
    private var activeRuntime: SessionRuntimeState { runtime(activeSessionId) }

    /// Back-compat: view code still reads `store.streamingText` etc. These
    /// return the active session's runtime.
    var streamingText: String { activeRuntime.streamingText }
    var thinkingText: String { activeRuntime.thinkingText }
    var isBusy: Bool { activeRuntime.isBusy }
    var activeToolCalls: [ToolUseBlock] { activeRuntime.activeToolCalls }
    var lastError: String? { activeRuntime.lastError }

    /// Most-recently-started generating session — used as the interrupt
    /// target when the user hits ⌘. from outside the chat. When multiple
    /// sessions are generating, prefer the most recent.
    @Published var generatingSessionId: String?

    /// True iff the given session is currently generating.
    func isSessionBusy(_ sessionId: String?) -> Bool {
        guard let sessionId = sessionId else { return false }
        return runtimeStates[sessionId]?.isBusy == true
    }

    /// All sessions currently generating (may be empty, one, or many).
    var busySessionIds: [String] {
        runtimeStates.compactMap { $0.value.isBusy ? $0.key : nil }
    }

    private func mutateRuntime(_ sessionId: String, _ transform: (inout SessionRuntimeState) -> Void) {
        var s = runtimeStates[sessionId] ?? SessionRuntimeState()
        transform(&s)
        runtimeStates[sessionId] = s
    }

    // Composer options
    @Published var sessionMode: SessionMode = .build
    @Published var permissionMode: PermissionMode = .bypass
    @Published var extendedContext: Bool = false
    @Published var maxTurns: Int? = nil
    @Published var thinkingEnabled: Bool = false
    @Published var effortLevel: EffortLevel = .medium

    // Usage tracking — active session's values (back-compat). Per-session
    // counts live in `runtime(id).inputTokens` etc.
    var inputTokens: Int { activeRuntime.inputTokens }
    var outputTokens: Int { activeRuntime.outputTokens }

    /// Total cost is summed across all sessions — this is a running total
    /// for the whole app, not per-session.
    @Published var totalCost: Double = 0

    /// Cost for a single session by summing its entries in the global
    /// CostLog. Used by the sidebar row and chat header.
    func sessionCost(_ sessionId: String) -> Double {
        CostLog.shared.entries
            .filter { $0.sessionId == sessionId }
            .reduce(0) { $0 + $1.usd }
    }

    // Settings
    @Published var settings: KilnSettings = KilnSettings()

    // Composer attachments (files/images pending send)
    @Published var composerAttachments: [ComposerAttachment] = []

    // Pending send (undo-send window). When non-nil, the composer shows an
    // "Undo" banner and the actual send is delayed by `settings.undoSendWindow`
    // seconds. Clicking Undo cancels the task and restores the input.
    struct PendingSend: Equatable {
        let id: String
        let sessionId: String
        let text: String
        let attachments: [ComposerAttachment]
        let sentAt: Date
    }
    @Published var pendingSend: PendingSend?
    private var pendingSendTask: Task<Void, Never>?

    /// One-shot signal to prefill the composer input. Set from the
    /// file-tree "Ask Claude about this file" action (or anywhere else
    /// that wants to seed a prompt). ComposerView observes this, inserts
    /// the text at the current caret, focuses the field, and clears the
    /// signal so re-sending the same string fires again.
    @Published var composerPrefill: String?

    func cancelPendingSend() -> (text: String, attachments: [ComposerAttachment])? {
        guard let pending = pendingSend else { return nil }
        pendingSendTask?.cancel()
        pendingSendTask = nil
        pendingSend = nil
        return (pending.text, pending.attachments)
    }

    // Full-window video overlay (nil = nothing playing)
    @Published var playingVideo: URL? {
        didSet {
            if let url = playingVideo, playingVideo != oldValue {
                // (Re)create player when URL changes.
                if FileManager.default.fileExists(atPath: url.path) {
                    let p = AVPlayer(url: url)
                    videoPlayer = p
                    p.play()
                }
            } else if playingVideo == nil {
                videoPlayer?.pause()
                videoPlayer = nil
            }
        }
    }

    /// Shared player so fullscreen + mini views reference the same playback.
    @Published var videoPlayer: AVPlayer?

    func addAttachment(path: String, name: String) {
        // Dedup by path
        guard !composerAttachments.contains(where: { $0.path == path }) else { return }
        composerAttachments.append(ComposerAttachment(id: UUID().uuidString, path: path, name: name))
    }

    func removeAttachment(_ id: String) {
        composerAttachments.removeAll { $0.id == id }
    }

    func clearAttachments() {
        composerAttachments.removeAll()
    }

    // Groups (derived)
    var sessionGroups: [String] {
        Array(Set(sessions.compactMap { $0.group })).sorted()
    }

    // MARK: - Services

    let claude = ClaudeService()
    let wardenTunnels = WardenTunnelService()
    lazy var remoteServer: RemoteControlServer = RemoteControlServer(store: self)

    // MARK: - Init

    init() {
        Persistence.ensureDirectories()
        settings = Persistence.loadSettings()
        // Bypass is the only sensible default for a local dev tool — .ask
        // and .deny stall tool use (no web, no reads). If a prior version
        // persisted something more restrictive, reset it.
        if settings.defaultPermissions != .bypass {
            settings.defaultPermissions = .bypass
            Persistence.saveSettings(settings)
        }
        sessionMode = settings.defaultMode
        permissionMode = .bypass

        let stored = Persistence.loadSessions()
        sessions = stored.map { $0.toSession() }

        // Sweep stale interruption flags. The flag is set pre-emptively on
        // every send and cleared on clean completion — but if the app truly
        // crashed, the flag survives on disk. We only want to surface "just
        // crashed" sessions in the launch recovery banner, not anything the
        // user clearly moved on from. If a flagged session hasn't had
        // activity in the last 4 hours, assume the user closed the app
        // cleanly since the crash and clear the flag quietly.
        let staleCutoff: TimeInterval = 4 * 60 * 60
        let now = Date()
        for i in sessions.indices where sessions[i].wasInterrupted {
            let lastActivity = sessions[i].messages.last?.timestamp ?? sessions[i].createdAt
            if now.timeIntervalSince(lastActivity) > staleCutoff {
                sessions[i].wasInterrupted = false
                Persistence.saveSession(sessions[i])
            }
        }

        // Restore remote server config from UserDefaults and auto-start if enabled.
        let d = UserDefaults.standard
        remoteServer.port = UInt16(d.integer(forKey: "remote.port")) == 0 ? 8421 : UInt16(d.integer(forKey: "remote.port"))
        // Bearer token: prefer the user's override in UserDefaults; if absent,
        // fall back to the persistent auto-generated PSK at ~/.kiln/psk. This
        // means remote access is usable the very first time the user flips
        // the toggle — no "generate token" step required.
        let overrideToken = d.string(forKey: "remote.token") ?? ""
        remoteServer.token = overrideToken.isEmpty ? RemoteControlServer.loadOrCreatePersistentPSK() : overrideToken
        remoteServer.allowLAN = d.bool(forKey: "remote.allowLAN")
        if let lvl = d.string(forKey: "remote.accessLevel"),
           let parsed = RemoteAccessLevel(rawValue: lvl) {
            remoteServer.accessLevel = parsed
        } else if remoteServer.allowLAN {
            remoteServer.accessLevel = .lan
        }
        // The remote server always runs on loopback so the PreToolUse hook
        // script spawned by `claude` can POST approval requests back to us.
        // `accessLevel` controls whether we *also* bind LAN/Tailscale — if
        // the user didn't enable remote, we stay loopback-only and the
        // surface is invisible except to local processes.
        if !d.bool(forKey: "remote.enabled") && remoteServer.accessLevel != .loopback {
            remoteServer.accessLevel = .loopback
        }
        remoteServer.start()

        // Auto-start the warden tunnel for Kiln itself if the user had
        // "Tunnel Kiln" on last session. Requires warden to be configured;
        // silently stays idle otherwise (surface any failure in Settings).
        if d.bool(forKey: "warden.tunnelKiln") && wardenTunnels.config.isConfigured {
            // Tokens only authorize the sub they were issued for, so the
            // restore path uses the claimed sub — ignoring any stale
            // `warden.kilnSub` override from before auto-claim existed.
            let sub = wardenTunnels.config.claimedSub
            wardenTunnels.start(
                owner: .kilnSelf,
                target: "127.0.0.1:\(remoteServer.port)",
                sub: sub.isEmpty ? nil : sub
            )
        }

        // Auto-start any previously-running session tunnels. Whether a
        // session's tunnel was "on" is stored under a per-session key so
        // the restore is opt-in (toggling off in the UI clears the flag).
        if wardenTunnels.config.isConfigured {
            for s in sessions where s.tunnelPort != nil {
                let key = "warden.session.\(s.id).enabled"
                if d.bool(forKey: key) {
                    startSessionTunnel(sessionId: s.id)
                }
            }
        }

        // Seed UserDefaults so Theme.swift helpers (accent, color scheme)
        // pick up the user's choice even before they open settings.
        mirrorAppearanceToUserDefaults()

        // Load the user avatar (if any) so MessageRow can render it without
        // re-reading from disk on every frame.
        AvatarStore.shared.load(filename: settings.userAvatarFilename)

        // First-run onboarding. A missing key — not just `false` — is the
        // trigger, so users who complete it once never see it again even
        // if they later clear all sessions.
        if UserDefaults.standard.object(forKey: "kiln.onboardingCompleted") == nil {
            showOnboarding = true
        }
    }

    /// Mark onboarding as completed. Persists across launches.
    func completeOnboarding() {
        UserDefaults.standard.set(true, forKey: "kiln.onboardingCompleted")
        showOnboarding = false
    }

    /// Handle a `kiln://` URL — used by the URL scheme handler.
    func handleRemoteURL(_ url: URL) {
        guard url.scheme == "kiln" else { return }
        let host = url.host ?? ""
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.reduce(into: [String: String]()) { $0[$1.name] = $1.value ?? "" } ?? [:]
        switch host {
        case "send":
            if let text = query["text"], !text.isEmpty {
                if let sid = query["session"] { activeSessionId = sid }
                Task { await sendMessage(text) }
            }
        case "new":
            let wd = query["dir"] ?? settings.defaultWorkDir
            let kind: SessionKind = (query["kind"] == "chat") ? .chat : .code
            let model = query["model"].flatMap { ClaudeModel(rawValue: $0) }
            createSession(workDir: wd, model: model, kind: kind)
        case "interrupt":
            interrupt()
        case "select":
            if let sid = query["session"] { activeSessionId = sid }
        default:
            break
        }
    }

    // MARK: - Computed

    var activeSession: Session? {
        guard let id = activeSessionId else { return nil }
        return sessions.first { $0.id == id }
    }

    private var activeSessionIndex: Int? {
        guard let id = activeSessionId else { return nil }
        return sessions.firstIndex { $0.id == id }
    }

    /// How the sidebar orders sessions. Pinned always floats to the top;
    /// `sort` decides how the rest are arranged. Stored in UserDefaults
    /// so the pick persists across launches.
    enum SessionSort: String, CaseIterable { case manual, recent, name, created }

    var sessionSort: SessionSort {
        get {
            let raw = UserDefaults.standard.string(forKey: "kiln.sessionSort") ?? "manual"
            return SessionSort(rawValue: raw) ?? .manual
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "kiln.sessionSort")
            objectWillChange.send()
        }
    }

    /// Sessions in display order: pinned first, then ordered per
    /// `sessionSort`. `manual` preserves whatever the user has dragged into
    /// place; the others re-derive on every read (cheap — just a sort).
    var sortedSessions: [Session] {
        let pinned = sessions.filter { $0.isPinned }
        let unpinned = sessions.filter { !$0.isPinned }
        let order = sessionSort
        let rest: [Session]
        switch order {
        case .manual:
            rest = unpinned
        case .recent:
            rest = unpinned.sorted { lastActivity($0) > lastActivity($1) }
        case .name:
            rest = unpinned.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .created:
            rest = unpinned.sorted { $0.createdAt > $1.createdAt }
        }
        return pinned + rest
    }

    private func lastActivity(_ s: Session) -> Date {
        s.messages.last?.timestamp ?? s.createdAt
    }

    /// Sessions grouped — preserves array order within each group
    var groupedSessions: [(group: String?, sessions: [Session])] {
        let ordered = sortedSessions
        let ungrouped = ordered.filter { $0.group == nil }
        let grouped = Dictionary(grouping: ordered.filter { $0.group != nil }, by: { $0.group! })

        var result: [(group: String?, sessions: [Session])] = []
        if !ungrouped.isEmpty {
            result.append((group: nil, sessions: ungrouped))
        }
        for group in sessionGroups {
            if let sessions = grouped[group] {
                result.append((group: group, sessions: sessions))
            }
        }
        return result
    }

    // MARK: - Session management

    /// Instantiate a session from a saved template. The template's defaults
    /// win except for workdir which falls back to the template's value or
    /// the global default.
    func createSessionFromTemplate(_ t: SessionTemplate) {
        let model = ClaudeModel(rawValue: t.model) ?? settings.defaultModel
        let kind = SessionKind(rawValue: t.kind) ?? .code
        let workDir = t.workDir?.isEmpty == false ? t.workDir! : settings.defaultWorkDir

        createSession(workDir: workDir, model: model, kind: kind, name: t.name)
        // Post-create: apply the non-default fields the base method ignored.
        if let sid = activeSessionId,
           let idx = sessions.firstIndex(where: { $0.id == sid }) {
            var s = sessions[idx]
            s.sessionInstructions = t.sessionInstructions
            s.tags = t.tags
            sessions[idx] = s
            Persistence.saveSession(s)
        }
        if let m = t.mode.flatMap(SessionMode.init(rawValue:)) { sessionMode = m }
        if let p = t.permissions.flatMap(PermissionMode.init(rawValue:)) { permissionMode = p }
    }

    /// Save the currently-active session's config as a new template.
    func saveActiveSessionAsTemplate(named name: String) {
        guard let s = activeSession else { return }
        let t = SessionTemplate(
            name: name,
            icon: s.kind == .chat ? "bubble.left" : "chevron.left.forwardslash.chevron.right",
            model: s.model.rawValue,
            kind: s.kind.rawValue,
            mode: sessionMode.rawValue,
            permissions: permissionMode.rawValue,
            workDir: s.workDir,
            sessionInstructions: s.sessionInstructions,
            tags: s.tags
        )
        SessionTemplateStore.shared.add(t)
    }

    func createSession(workDir: String, model: ClaudeModel? = nil, kind: SessionKind = .code, readOnly: Bool = false, name: String = "New Session") {
        // Workspace config — if the target dir has a .kiln/config.json, apply it.
        let ws = WorkspaceConfig.load(for: workDir)
        let resolvedModel = model
            ?? ws?.model.flatMap(ClaudeModel.init(rawValue:))
            ?? settings.defaultModel
        let sessionInstructions = ws?.systemPrompt ?? ""
        let session = Session(
            workDir: workDir,
            name: name,
            model: resolvedModel,
            kind: kind,
            readOnly: readOnly,
            sessionInstructions: sessionInstructions
        )
        _ = session  // keep compiler from complaining about the let rebind
        sessions.insert(session, at: 0)
        activeSessionId = session.id
        showNewSessionSheet = false
        selectedSidebarTab = kind

        // Apply workspace toolbar overrides to the active composer state
        if let sm = ws?.sessionMode, let m = SessionMode(rawValue: sm) { sessionMode = m }
        if let pm = ws?.permissionMode, let p = PermissionMode(rawValue: pm) { permissionMode = p }

        Persistence.saveSession(session)
    }

    func deleteSession(_ id: String) {
        claude.kill(sessionId: id)
        sessions.removeAll { $0.id == id }
        if activeSessionId == id {
            activeSessionId = sessions.first?.id
        }
        Persistence.deleteSession(id)
    }

    func renameSession(_ id: String, name: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].name = name
        Persistence.saveSession(sessions[idx])
    }

    func togglePin(_ id: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].isPinned.toggle()
        Persistence.saveSession(sessions[idx])
    }

    /// Focus mode: hide both side panels so just the chat column remains,
    /// restoring whatever was open when focus mode exits. Driven from the
    /// ⌘⌥F menu item in KilnApp.commands.
    func toggleFocusMode() {
        let defaults = UserDefaults.standard
        let inFocus = defaults.bool(forKey: "focusMode")
        if inFocus {
            // Leaving focus — restore snapshot.
            defaults.set(defaults.bool(forKey: "focusModePreSidebar"), forKey: "sidebarCollapsed")
            defaults.set(defaults.bool(forKey: "focusModePreRight"), forKey: "rightPanelCollapsed")
            defaults.set(false, forKey: "focusMode")
        } else {
            // Entering focus — stash current state, then hide both.
            defaults.set(defaults.bool(forKey: "sidebarCollapsed"), forKey: "focusModePreSidebar")
            defaults.set(defaults.bool(forKey: "rightPanelCollapsed"), forKey: "focusModePreRight")
            defaults.set(true, forKey: "sidebarCollapsed")
            defaults.set(true, forKey: "rightPanelCollapsed")
            defaults.set(true, forKey: "focusMode")
        }
    }

    /// Build a ready-to-paste continuation prompt from a session. Packs the
    /// transcript into a single "here's context, keep going" block so you
    /// can hand it off to a fresh session, a different model, or another
    /// tool entirely.
    func sessionAsContinuationPrompt(_ sessionId: String) -> String {
        guard let s = sessions.first(where: { $0.id == sessionId }) else { return "" }
        var body = "I'm continuing a prior Kiln conversation. Here's the relevant context.\n\n"
        body += "## Context\n"
        body += "- Workdir: \(s.workDir)\n"
        body += "- Model: \(s.model.fullId)\n"
        if !s.sessionInstructions.isEmpty {
            body += "- Session instructions: \(s.sessionInstructions)\n"
        }
        if !s.tags.isEmpty {
            body += "- Tags: \(s.tags.map { "#\($0)" }.joined(separator: " "))\n"
        }
        body += "\n## Transcript\n\n"
        for msg in s.messages {
            let role = msg.role == .user ? "User" : "Assistant"
            let text = Self.plainText(from: msg.blocks)
            guard !text.isEmpty else { continue }
            body += "### \(role)\n\(text)\n\n"
        }
        body += "---\n\nPick up from where we left off."
        return body
    }

    /// Export every session as a folder of markdown files, zipped up.
    /// Used by the "Export all" button in settings. Blocks while zipping
    /// which is fine — most users don't have thousands of sessions and
    /// `zip` is fast on small-file archives.
    func exportAllSessionsAsZip() -> URL? {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kiln-export-\(Int(Date().timeIntervalSince1970))", isDirectory: true)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        for s in sessions {
            let safeName = s.name.replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: ":", with: "-")
                .prefix(60)
            let filename = "\(s.id.prefix(8))-\(safeName).md"
            let path = tmpDir.appendingPathComponent(String(filename))
            let md = exportSessionMarkdown(s.id)
            try? md.write(to: path, atomically: true, encoding: .utf8)
        }

        // Run `zip -r` from the tmp dir.
        let zipPath = tmpDir.appendingPathExtension("zip")
        let proc = Process()
        proc.launchPath = "/usr/bin/env"
        proc.arguments = ["zip", "-r", "-q", zipPath.path, tmpDir.lastPathComponent]
        proc.currentDirectoryURL = tmpDir.deletingLastPathComponent()
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            return zipPath
        } catch {
            return nil
        }
    }

    /// Change a session's working directory. Future sends start in the new
    /// dir; any currently-running subprocess keeps its old cwd until it
    /// exits — Claude Code doesn't support chdir mid-run.
    func setWorkDir(_ id: String, workDir: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        let old = sessions[idx]
        var fresh = Session(
            id: old.id,
            workDir: workDir,
            name: old.name,
            model: old.model,
            isPinned: old.isPinned,
            group: old.group,
            forkedFrom: old.forkedFrom,
            kind: old.kind,
            readOnly: old.readOnly,
            isArchived: old.isArchived,
            sessionInstructions: old.sessionInstructions,
            tags: old.tags,
            createdAt: old.createdAt
        )
        fresh.messages = old.messages
        fresh.wasInterrupted = old.wasInterrupted
        sessions[idx] = fresh
        Persistence.saveSession(fresh)
    }

    func setGroup(_ id: String, group: String?) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].group = group
        Persistence.saveSession(sessions[idx])
    }

    /// Move a session to a new position in the sessions array
    func moveSession(_ id: String, toIndex: Int) {
        guard let fromIdx = sessions.firstIndex(where: { $0.id == id }) else { return }
        let session = sessions.remove(at: fromIdx)
        let clampedIdx = min(toIndex, sessions.count)
        sessions.insert(session, at: clampedIdx)
    }

    /// Move a session before another session
    func moveSession(_ id: String, before targetId: String) {
        guard let fromIdx = sessions.firstIndex(where: { $0.id == id }),
              var targetIdx = sessions.firstIndex(where: { $0.id == targetId }) else { return }
        let session = sessions.remove(at: fromIdx)
        // Adjust target index if the source was before target
        if fromIdx < targetIdx { targetIdx -= 1 }
        sessions.insert(session, at: targetIdx)
    }

    // MARK: - Session switching

    /// Jump to nth session in the current sidebar tab (1-indexed)
    func selectSession(number: Int) {
        let list = sortedSessions.filter { $0.kind == selectedSidebarTab }
        let idx = number - 1
        guard idx >= 0 && idx < list.count else { return }
        activeSessionId = list[idx].id
    }

    func selectNextSession() {
        let list = sortedSessions.filter { $0.kind == selectedSidebarTab }
        guard !list.isEmpty else { return }
        if let cur = activeSessionId, let i = list.firstIndex(where: { $0.id == cur }) {
            activeSessionId = list[(i + 1) % list.count].id
        } else {
            activeSessionId = list.first?.id
        }
    }

    func selectPreviousSession() {
        let list = sortedSessions.filter { $0.kind == selectedSidebarTab }
        guard !list.isEmpty else { return }
        if let cur = activeSessionId, let i = list.firstIndex(where: { $0.id == cur }) {
            activeSessionId = list[(i - 1 + list.count) % list.count].id
        } else {
            activeSessionId = list.first?.id
        }
    }

    func quickCreateChatSession() {
        createSession(workDir: settings.defaultWorkDir, kind: .chat)
    }

    func jumpTo(sessionId: String, messageId: String) {
        if let session = sessions.first(where: { $0.id == sessionId }) {
            selectedSidebarTab = session.kind
        }
        activeSessionId = sessionId
        pendingJumpMessageId = messageId
        showGlobalSearch = false
        showCommandPalette = false
    }

    // MARK: - Global search

    func searchMessages(_ query: String, limit: Int = 100) -> [SearchResult] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard q.count >= 2 else { return [] }
        var results: [SearchResult] = []
        for session in sessions {
            for msg in session.messages {
                for block in msg.blocks {
                    var haystack = ""
                    switch block {
                    case .text(let t): haystack = t
                    case .thinking(let t): haystack = t
                    case .toolUse(let b):
                        haystack = "\(b.name) \(b.input) \(b.result ?? "")"
                    case .toolResult(let b):
                        haystack = b.content
                    case .suggestions(let s):
                        haystack = s.map { "\($0.label) \($0.prompt)" }.joined(separator: " ")
                    case .attachment(let a):
                        haystack = "\(a.name) \(a.path)"
                    }
                    let lower = haystack.lowercased()
                    guard let range = lower.range(of: q) else { continue }
                    let snippet = Self.makeSnippet(haystack, around: range)
                    results.append(SearchResult(
                        sessionId: session.id,
                        sessionName: session.name,
                        sessionKind: session.kind,
                        messageId: msg.id,
                        role: msg.role,
                        timestamp: msg.timestamp,
                        snippet: snippet
                    ))
                    if results.count >= limit { return results }
                }
            }
        }
        return results
    }

    private static func makeSnippet(_ text: String, around range: Range<String.Index>, radius: Int = 60) -> String {
        // Offset-based trim around the match so we don't blow up on huge outputs
        let startDist = text.distance(from: text.startIndex, to: range.lowerBound)
        let endDist = text.distance(from: text.startIndex, to: range.upperBound)
        let lo = max(0, startDist - radius)
        let hi = min(text.count, endDist + radius)
        let loIdx = text.index(text.startIndex, offsetBy: lo)
        let hiIdx = text.index(text.startIndex, offsetBy: hi)
        var s = String(text[loIdx..<hiIdx]).replacingOccurrences(of: "\n", with: " ")
        if lo > 0 { s = "…" + s }
        if hi < text.count { s = s + "…" }
        return s
    }

    func setModel(_ model: ClaudeModel) {
        guard let idx = activeSessionIndex else { return }
        sessions[idx].model = model
        Persistence.saveSession(sessions[idx])
    }

    /// Mirror user-appearance choices (accent, theme) to UserDefaults so
    /// static Color helpers in Theme.swift can read them without needing the
    /// AppStore in environment (useful for views presented in sheets).
    private func mirrorAppearanceToUserDefaults() {
        UserDefaults.standard.set(settings.accentHex, forKey: "kiln.accentHex")
        UserDefaults.standard.set(settings.themeMode.rawValue, forKey: "kiln.themeMode")
        // Push the appearance to NSApp so window chrome (titlebar, traffic
        // lights, native controls) flips with the user's choice. Passing nil
        // means "follow system".
        NSApp.appearance = settings.themeMode.nsAppearance
    }

    func saveSettings() {
        Persistence.saveSettings(settings)
        mirrorAppearanceToUserDefaults()
        // Force a re-render so Color.kilnAccent / Color.kilnPreferredColorScheme
        // (which read UserDefaults) update immediately after a settings change.
        objectWillChange.send()
    }

    /// Retry the last user message in the active session
    func retryLastMessage() async {
        guard let idx = activeSessionIndex else { return }
        // Find last user message
        guard let lastUserMsg = sessions[idx].messages.last(where: { $0.role == .user }),
              case .text(let text) = lastUserMsg.blocks.first else { return }
        // Remove messages from last user message onward
        if let msgIdx = sessions[idx].messages.lastIndex(where: { $0.id == lastUserMsg.id }) {
            sessions[idx].messages.removeSubrange(msgIdx...)
        }
        Persistence.saveSession(sessions[idx])
        await sendMessage(text)
    }

    /// Clear all messages in a session
    func clearSession(_ id: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].messages.removeAll()
        Persistence.saveSession(sessions[idx])
    }

    /// Export session as markdown
    func exportSessionMarkdown(_ id: String) -> String {
        guard let session = sessions.first(where: { $0.id == id }) else { return "" }
        var md = "# \(session.name)\n"
        md += "**Model:** \(session.model.label) | **Dir:** \(session.workDir)\n"
        md += "**Date:** \(session.createdAt.formatted())\n\n---\n\n"

        for msg in session.messages {
            let role = msg.role == .user ? "**You**" : "**Claude**"
            md += "\(role)\n\n"
            for block in msg.blocks {
                switch block {
                case .text(let t):
                    md += "\(t)\n\n"
                case .thinking(let t):
                    md += "<details><summary>Thinking</summary>\n\n\(t)\n\n</details>\n\n"
                case .toolUse(let tool):
                    md += "> **\(tool.name)**\n> ```json\n> \(tool.input)\n> ```\n"
                    if let result = tool.result {
                        md += "> Output: \(result.prefix(200))\(result.count > 200 ? "…" : "")\n"
                    }
                    md += "\n"
                case .toolResult:
                    break
                case .suggestions(let s):
                    md += "Follow-ups:\n"
                    for p in s { md += "- \(p.label)\n" }
                    md += "\n"
                case .attachment(let a):
                    md += "📎 `\(a.path)`\n\n"
                }
            }
            md += "---\n\n"
        }
        return md
    }

    // MARK: - Import / Export (JSON)

    /// Serialize a session to JSON bytes. Callers write these to disk or stream
    /// them over HTTP. Returns nil if the id doesn't match a live session.
    func exportSessionJSONData(_ id: String) -> Data? {
        guard let s = sessions.first(where: { $0.id == id }) else { return nil }
        return Persistence.exportSessionJSONData(s)
    }

    /// Import a session from a previously-exported JSON blob. Assigns a fresh
    /// id, suffixes the name, and resets per-machine state (tunnel config,
    /// pinned/archived flags) so we never clobber existing sessions. Returns
    /// the new session id on success.
    @discardableResult
    func importSessionJSON(_ data: Data) -> String? {
        guard let sd = Persistence.decodeSessionData(data) else { return nil }
        let reconstructed = sd.toSession()
        var imported = Session(
            id: UUID().uuidString,
            workDir: reconstructed.workDir,
            name: reconstructed.name + " (imported)",
            model: reconstructed.model,
            isPinned: false,
            group: reconstructed.group,
            forkedFrom: nil,
            kind: reconstructed.kind,
            readOnly: reconstructed.readOnly,
            isArchived: false,
            sessionInstructions: reconstructed.sessionInstructions,
            tags: reconstructed.tags,
            tunnelPort: nil,
            tunnelSub: nil,
            createdAt: Date()
        )
        imported.messages = reconstructed.messages
        sessions.insert(imported, at: 0)
        activeSessionId = imported.id
        Persistence.saveSession(imported)
        return imported.id
    }

    /// Serialize full KilnSettings for backup.
    func exportSettingsJSONData() -> Data? {
        Persistence.exportSettingsJSONData(settings)
    }

    /// Replace the current settings with a backup. Persists to disk and
    /// mirrors appearance to NSApp. Returns false if the blob is malformed.
    @discardableResult
    func importSettingsJSON(_ data: Data) -> Bool {
        guard let incoming = Persistence.decodeSettingsData(data) else { return false }
        settings = incoming
        saveSettings()
        return true
    }

    /// Fork a session at a specific message, creating a new session with messages up to (and including) that message.
    func forkSession(fromSessionId: String, atMessageId: String) {
        guard let srcIdx = sessions.firstIndex(where: { $0.id == fromSessionId }) else { return }
        let src = sessions[srcIdx]

        // Find the message index to fork at
        guard let msgIdx = src.messages.firstIndex(where: { $0.id == atMessageId }) else { return }

        // Copy messages up to and including the fork point
        let forkedMessages = Array(src.messages[...msgIdx])

        // Build fork name
        let forkNum = sessions.filter { $0.forkedFrom == fromSessionId }.count + 1
        let name = "\(src.name) (fork \(forkNum))"

        var forked = Session(
            workDir: src.workDir,
            name: name,
            model: src.model,
            group: src.group
        )
        forked.messages = forkedMessages
        forked.forkedFrom = fromSessionId

        sessions.insert(forked, at: 0)
        activeSessionId = forked.id
        Persistence.saveSession(forked)
    }

    // MARK: - Chat

    /// Requested-open flag for session instructions sheet, toggled by the
    /// `/instructions` slash command.
    @Published var requestOpenInstructions: Bool = false

    /// Seed query for the global search modal. Consumed by GlobalSearchView
    /// on appear.
    @Published var pendingSearchQuery: String?

    /// Text to pre-fill the composer with on next appear. Used by
    /// "edit & resend" and similar flows.
    @Published var pendingComposerPrefill: String?

    /// Model comparison: duplicate the active session as a second session
    /// with a different model, then re-fire the most recent user message to
    /// both. Returns when the fan-out has started; streaming continues in
    /// both sessions concurrently so you can watch them side-by-side.
    func compareWithModel(_ altModel: ClaudeModel) async {
        guard let idx = activeSessionIndex else { return }
        let original = sessions[idx]
        // Pull the last user message text from the current session.
        let lastUserText = original.messages.last(where: { $0.role == .user })
            .flatMap { msg -> String? in
                msg.blocks.compactMap { block -> String? in
                    if case .text(let t) = block { return t }
                    return nil
                }.joined(separator: "\n")
            } ?? ""
        guard !lastUserText.isEmpty else { return }

        // Build a twin session — same workdir / kind / group / instructions,
        // different model. Empty messages so it runs cleanly from this turn.
        var twin = Session(
            workDir: original.workDir,
            name: "\(original.name) · \(altModel.label)",
            model: altModel,
            group: original.group,
            kind: original.kind,
            sessionInstructions: original.sessionInstructions,
            tags: original.tags + ["compare"]
        )
        twin.forkedFrom = original.id
        sessions.insert(twin, at: 0)
        Persistence.saveSession(twin)

        // Fire the prompt on the TWIN without switching the active session —
        // the original keeps streaming whatever it was doing.
        let twinId = twin.id
        let prevActive = activeSessionId
        activeSessionId = twinId
        await sendMessage(lastUserText)
        activeSessionId = prevActive
    }

    /// Cycle the active session to the next ClaudeModel in the allCases
    /// order. Used by `/model`.
    func cycleToNextModel() {
        guard let m = activeSession?.model else { return }
        let all = ClaudeModel.allCases
        guard let idx = all.firstIndex(of: m) else { return }
        let next = all[(idx + 1) % all.count]
        setModel(next)
    }

    /// Real compaction: ask Claude for a concise summary of the conversation
    /// so far, wipe the prior messages, keep the summary as context.
    func compactSession() async {
        guard let idx = activeSessionIndex else { return }
        let sessionId = sessions[idx].id

        // Snapshot the transcript so we can fold it into the summary prompt
        // for Claude even after we clear the history locally.
        let transcript = sessions[idx].messages.map { msg -> String in
            let body = msg.blocks.compactMap { block -> String? in
                switch block {
                case .text(let t): return t
                case .thinking: return nil
                case .toolUse(let t): return "[tool: \(t.name)]"
                case .toolResult: return nil
                case .suggestions: return nil
                case .attachment(let a): return "[attachment: \(a.name)]"
                }
            }.joined(separator: "\n")
            return "\(msg.role.rawValue.uppercased()):\n\(body)"
        }.joined(separator: "\n\n")

        guard !transcript.isEmpty else { return }

        // Replace history with a single compact marker so Claude has clean
        // context, then ask it to produce a summary.
        let marker = ChatMessage(role: .user, blocks: [.text("(session history compacted — see summary below)")])
        sessions[idx].messages = [marker]
        Persistence.saveSession(sessions[idx])

        let prompt = """
        Summarize the following Kiln session transcript into a compact briefing that captures decisions made, code changes, open threads, and any key context I'll need going forward. Keep it to 10–20 bullet points, terse. Do not address me directly — just the summary.

        TRANSCRIPT:
        \(transcript)
        """
        _ = sessionId
        await sendMessage(prompt)
    }

    /// Ask Claude for a short session title using the current transcript,
    /// then rename the session. Used by `/title` and for auto-titling.
    func generateSessionTitle() async {
        guard let sid = activeSessionId else { return }
        await generateSessionTitle(for: sid)
    }

    /// Title a specific session by id. Used by auto-titling on first-turn
    /// completion; doesn't require the session to be active.
    func generateSessionTitle(for sessionId: String) async {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionId }),
              !sessions[idx].messages.isEmpty else { return }

        // Build a tiny transcript excerpt — first user message + first
        // assistant response is usually plenty.
        let firstUser = sessions[idx].messages.first(where: { $0.role == .user })
            .flatMap { Self.plainText(from: $0.blocks) } ?? ""
        let firstAssistant = sessions[idx].messages.first(where: { $0.role == .assistant })
            .flatMap { Self.plainText(from: $0.blocks) } ?? ""
        let excerpt = [firstUser.prefix(500), firstAssistant.prefix(500)]
            .map { String($0) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n---\n")
        guard !excerpt.isEmpty else { return }

        // Fire a side-process call to `claude --print` with a titling prompt.
        // Doesn't touch the active session at all.
        let title = await Self.oneShotAsk(prompt: """
        Read this chat excerpt and reply with a terse 3–5 word title capturing the session's actual subject. No quotes, no punctuation at the end, no "Session about …" preamble. Just the title.

        \(excerpt)
        """, workDir: sessions[idx].workDir)
        guard let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else { return }
        renameSession(sessionId, name: String(title.prefix(60)))
    }

    /// Run `claude --print` once and return the full response text. Used
    /// for short helper calls (titling, etc.) that shouldn't clutter a
    /// real session.
    nonisolated static func oneShotAsk(prompt: String, workDir: String) async -> String? {
        await Task.detached { () -> String? in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = ["claude", "--print", "--output-format", "text"]
            proc.currentDirectoryURL = URL(fileURLWithPath: workDir)
            let stdin = Pipe()
            let stdout = Pipe()
            proc.standardInput = stdin
            proc.standardOutput = stdout
            proc.standardError = Pipe()
            do {
                try proc.run()
                stdin.fileHandleForWriting.write(prompt.data(using: .utf8) ?? Data())
                try? stdin.fileHandleForWriting.close()
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                return String(data: data, encoding: .utf8)
            } catch {
                return nil
            }
        }.value
    }

    /// Sessions that were interrupted before the app last closed. Used by
    /// the launch recovery banner.
    var interruptedSessions: [Session] {
        sessions.filter { $0.wasInterrupted }
    }

    /// Whether to suppress the launch-recovery banner for this app run
    /// (set when the user dismisses it from the banner).
    @Published var launchRecoveryDismissed: Bool = false

    /// Dismiss the interruption marker without resuming. User acknowledges
    /// the prior session was cut off and wants to keep going fresh.
    func dismissInterrupted(_ sessionId: String? = nil) {
        let id = sessionId ?? activeSessionId
        guard let id = id,
              let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].wasInterrupted = false
        Persistence.saveSession(sessions[idx])
    }

    /// Compact the active session's conversation history. Sends `/compact`
    /// which Claude Code interprets natively — it summarizes prior messages
    /// into a condensed form, then continues from there.
    func compact() async {
        guard activeSessionId != nil else { return }
        await sendMessage("/compact")
    }

    /// Clear the active session's conversation history via `/clear`. Claude
    /// Code treats this as a reset.
    func clearViaCommand() async {
        guard activeSessionId != nil else { return }
        await sendMessage("/clear")
    }

    /// Entry point from the composer. Honors the undo-send window setting;
    /// pending sends can be cancelled for the configured duration.
    func queueSend(_ text: String, attachments: [ComposerAttachment] = []) {
        guard let sid = activeSessionId else { return }
        pendingSendTask?.cancel()
        let window = settings.undoSendWindow
        if window <= 0 {
            Task { await sendMessage(text, attachments: attachments) }
            return
        }
        let pending = PendingSend(id: UUID().uuidString, sessionId: sid, text: text, attachments: attachments, sentAt: .now)
        pendingSend = pending
        pendingSendTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(window) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self, self.pendingSend?.id == pending.id else { return }
                self.pendingSend = nil
            }
            await self?.sendMessage(text, attachments: attachments)
        }
    }

    func sendMessage(_ text: String, attachments: [ComposerAttachment] = []) async {
        guard let idx = activeSessionIndex else { return }
        let sessionId = sessions[idx].id
        let model = sessions[idx].model
        let workDir = sessions[idx].workDir

        // Expand {{var}} tokens (clipboard, date, file contents, etc.)
        let expandedText = PromptExpander.expand(text, context: PromptExpander.Context(
            workdir: workDir,
            sessionName: sessions[idx].name,
            model: model.rawValue
        ))

        // Build the DISPLAY message: attachment cards first, then text.
        // Keeps the chat visually clean — no "Attached files: /path…" soup.
        var displayBlocks: [MessageBlock] = []
        for a in attachments { displayBlocks.append(.attachment(a)) }
        if !expandedText.isEmpty { displayBlocks.append(.text(expandedText)) }
        let userMessage = ChatMessage(role: .user, blocks: displayBlocks)
        sessions[idx].messages.append(userMessage)

        // Build the TRANSMISSION text for Claude — still includes paths so
        // Claude can Read them. The display in the UI uses the blocks above.
        let expanded: String
        if attachments.isEmpty {
            expanded = expandedText
        } else {
            let lines = attachments.map { "- \($0.path)" }.joined(separator: "\n")
            expanded = "Attached files:\n\(lines)\n\n" + expandedText
        }

        // Build options from current state
        var options = SendOptions()
        options.mode = sessionMode
        options.permissions = permissionMode
        options.extendedContext = extendedContext
        options.maxTurns = maxTurns
        options.chatMode = sessions[idx].kind == .chat
        options.thinkingEnabled = thinkingEnabled
        options.effortLevel = thinkingEnabled ? effortLevel : nil

        // Build system prompt from session override (if any) + settings + language
        var systemPrompt = ""
        if settings.useEngram && !settings.systemPrompt.isEmpty {
            systemPrompt = settings.systemPrompt
        }
        let langInstruction = settings.language.claudeInstruction
        if !langInstruction.isEmpty {
            systemPrompt = systemPrompt.isEmpty ? langInstruction : "\(systemPrompt)\n\n\(langInstruction)"
        }
        let sessionOverride = sessions[idx].sessionInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sessionOverride.isEmpty {
            // Session-level instructions take precedence — prepended.
            systemPrompt = systemPrompt.isEmpty ? sessionOverride : "\(sessionOverride)\n\n\(systemPrompt)"
        }
        if !systemPrompt.isEmpty {
            options.systemPrompt = systemPrompt
        }

        // Wire up the PreToolUse hook transport. The hook script we install
        // into the CLI's settings will POST approval requests to this port
        // with the shared secret — loopback-only, per-process rotation.
        options.hookPort = remoteServer.port
        options.hookSecret = remoteServer.hookSecret

        // Initialize THIS session's runtime — leaves any other concurrently
        // running sessions' runtimes untouched.
        runtimeStates[sessionId] = SessionRuntimeState(isBusy: true)
        generatingSessionId = sessionId

        // Mark the session as interrupted pre-emptively. If we complete
        // cleanly, finalizeAssistantMessage clears the flag; if the process
        // (or whole app) crashes mid-stream, the flag survives on disk and
        // the next launch can offer to resume.
        sessions[idx].wasInterrupted = true
        Persistence.saveSession(sessions[idx])

        await claude.sendMessage(
            sessionId: sessionId,
            message: expanded,
            model: model,
            workDir: workDir,
            options: options
        ) { [weak self] event in
            guard let self else { return }
            self.handleClaudeEvent(event, sessionId: sessionId)
        }
    }

    // MARK: - Per-session tunnels

    /// Update a session's tunnel config. Doesn't start/stop the tunnel —
    /// call `startSessionTunnel` / `stopSessionTunnel` for that.
    func setSessionTunnel(sessionId: String, port: Int?, sub: String?) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        sessions[idx].tunnelPort = port
        sessions[idx].tunnelSub = (sub?.isEmpty == true ? nil : sub)
        Persistence.saveSession(sessions[idx])
    }

    /// Spins up a warden tunnel pointing at the session's configured port.
    /// Safe to call while a tunnel is already running — the service stops
    /// the prior tunnel first.
    func startSessionTunnel(sessionId: String) {
        guard let s = sessions.first(where: { $0.id == sessionId }),
              let port = s.tunnelPort
        else { return }
        wardenTunnels.start(
            owner: .session(sessionId),
            target: "127.0.0.1:\(port)",
            sub: s.tunnelSub
        )
        UserDefaults.standard.set(true, forKey: "warden.session.\(sessionId).enabled")
    }

    func stopSessionTunnel(sessionId: String) {
        wardenTunnels.stop(owner: .session(sessionId))
        UserDefaults.standard.set(false, forKey: "warden.session.\(sessionId).enabled")
    }

    /// Create a new session with the same config as `id` but no messages.
    func duplicateSession(_ id: String) {
        guard let src = sessions.first(where: { $0.id == id }) else { return }
        var copy = Session(
            workDir: src.workDir,
            name: "\(src.name) (copy)",
            model: src.model,
            group: src.group,
            kind: src.kind,
            colorLabel: src.colorLabel
        )
        copy.messages = []
        sessions.insert(copy, at: 0)
        activeSessionId = copy.id
        Persistence.saveSession(copy)
    }

    /// Clone a session including its full message history. Useful for
    /// branching an exploration while keeping the original untouched.
    func duplicateSessionWithMessages(_ id: String) {
        guard let src = sessions.first(where: { $0.id == id }) else { return }
        var copy = Session(
            workDir: src.workDir,
            name: "\(src.name) (fork)",
            model: src.model,
            group: src.group,
            forkedFrom: src.id,
            kind: src.kind,
            sessionInstructions: src.sessionInstructions,
            tags: src.tags,
            colorLabel: src.colorLabel
        )
        copy.messages = src.messages
        sessions.insert(copy, at: 0)
        activeSessionId = copy.id
        Persistence.saveSession(copy)
    }

    /// Assign (or clear with `nil`) the color label of a session.
    func setSessionColor(_ id: String, color: String?) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].colorLabel = color
        Persistence.saveSession(sessions[idx])
        objectWillChange.send()
    }

    /// Cycle the active session's model to the next available one.
    /// Wired to ⌘⇧M — a fast way to retry the last prompt with a
    /// different model without hunting through the picker.
    func cycleActiveSessionModel() {
        guard let id = activeSessionId,
              let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        let models = ClaudeModel.allCases
        let cur = sessions[idx].model
        let curIdx = models.firstIndex(of: cur) ?? 0
        let next = models[(curIdx + 1) % models.count]
        sessions[idx].model = next
        Persistence.saveSession(sessions[idx])
        objectWillChange.send()
    }

    /// Switch to the next / previous session (in the current sidebar tab,
    /// wrapping at the ends). Used by ⌘[ and ⌘].
    /// Swap the `.chat` and `.tools` slots in the persisted panel order.
    /// When tools (the editor/right panel) sits in the middle slot it takes
    /// the flex-center position and chat docks to the side — the inverse
    /// of the default layout. Writes directly to UserDefaults so that the
    /// @AppStorage binding in ContentView picks it up.
    func toggleEditorAsMain() {
        let key = "panelOrder"
        let raw = UserDefaults.standard.string(forKey: key) ?? "sessions,chat,tools"
        var order = raw.split(separator: ",").map(String.init)
        guard let ci = order.firstIndex(of: "chat"),
              let ti = order.firstIndex(of: "tools") else { return }
        order.swapAt(ci, ti)
        UserDefaults.standard.set(order.joined(separator: ","), forKey: key)
    }

    func navigateSession(direction: Int) {
        let list = sortedSessions.filter { $0.kind == selectedSidebarTab && !$0.isArchived }
        guard !list.isEmpty else { return }
        if let cur = activeSessionId, let i = list.firstIndex(where: { $0.id == cur }) {
            let next = (i + direction + list.count) % list.count
            activeSessionId = list[next].id
        } else {
            activeSessionId = list.first?.id
        }
    }

    func toggleArchiveSession(_ id: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        sessions[idx].isArchived.toggle()
        // If archiving the active session, switch to another one (or nothing).
        if sessions[idx].isArchived && activeSessionId == id {
            if let next = sessions.first(where: { !$0.isArchived && $0.kind == selectedSidebarTab }) {
                activeSessionId = next.id
            } else {
                activeSessionId = nil
            }
        }
        Persistence.saveSession(sessions[idx])
    }

    /// Delete a message and everything after it in the session. Rewinds the
    /// conversation state — used when the user wants to prune a branch
    /// without forking.
    func deleteMessageAndAfter(sessionId: String, messageId: String) {
        guard let sIdx = sessions.firstIndex(where: { $0.id == sessionId }),
              let mIdx = sessions[sIdx].messages.firstIndex(where: { $0.id == messageId })
        else { return }
        sessions[sIdx].messages.removeSubrange(mIdx...)
        Persistence.saveSession(sessions[sIdx])
    }

    /// Delete a single message in place (no rewind). Leaves subsequent
    /// messages intact — may produce an inconsistent conversation when
    /// replayed, but sometimes that's what the user wants.
    func deleteMessage(sessionId: String, messageId: String) {
        guard let sIdx = sessions.firstIndex(where: { $0.id == sessionId }),
              let mIdx = sessions[sIdx].messages.firstIndex(where: { $0.id == messageId })
        else { return }
        sessions[sIdx].messages.remove(at: mIdx)
        Persistence.saveSession(sessions[sIdx])
    }

    /// Add a tag to the session (lowercased, deduped).
    func addTag(_ tag: String, to sessionId: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        let normalized = tag.trimmingCharacters(in: .whitespaces).lowercased()
        guard !normalized.isEmpty, !sessions[idx].tags.contains(normalized) else { return }
        sessions[idx].tags.append(normalized)
        Persistence.saveSession(sessions[idx])
    }

    func removeTag(_ tag: String, from sessionId: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }
        sessions[idx].tags.removeAll { $0 == tag.lowercased() }
        Persistence.saveSession(sessions[idx])
    }

    /// Every unique tag used across all sessions — for picker UIs.
    var allTags: [String] {
        Array(Set(sessions.flatMap(\.tags))).sorted()
    }

    func togglePinMessage(sessionId: String, messageId: String) {
        guard let sIdx = sessions.firstIndex(where: { $0.id == sessionId }),
              let mIdx = sessions[sIdx].messages.firstIndex(where: { $0.id == messageId })
        else { return }
        sessions[sIdx].messages[mIdx].isPinned.toggle()
        Persistence.saveSession(sessions[sIdx])
    }

    func interrupt() {
        // Prefer the session that's actually generating; fall back to active.
        let id = generatingSessionId ?? activeSessionId
        guard let id = id else { return }
        claude.interrupt(sessionId: id)
    }

    private func handleClaudeEvent(_ event: ClaudeEvent, sessionId: String) {
        mutateRuntime(sessionId) { state in
            switch event {
            case .messageStart:
                state.streamingText = ""
                state.thinkingText = ""

            case .textDelta(let text):
                state.streamingText += text

            case .thinkingDelta(let text):
                state.thinkingText += text

            case .toolStart(let id, let name, let input):
                if let idx = state.activeToolCalls.firstIndex(where: { $0.id == id }) {
                    if !input.isEmpty && input.count > state.activeToolCalls[idx].input.count {
                        state.activeToolCalls[idx].input = input
                    }
                } else {
                    state.activeToolCalls.append(ToolUseBlock(id: id, name: name, input: input, isDone: false))
                }
                state.currentToolId = id

            case .toolInputDelta(let json):
                if let toolId = state.currentToolId,
                   let idx = state.activeToolCalls.firstIndex(where: { $0.id == toolId }) {
                    state.activeToolCalls[idx].input += json
                }

            case .blockStop:
                if let toolId = state.currentToolId,
                   let idx = state.activeToolCalls.firstIndex(where: { $0.id == toolId }) {
                    state.activeToolCalls[idx].isDone = true
                }
                state.currentToolId = nil

            case .messageStop:
                break

            case .toolResult(let toolUseId, let content, let isError):
                if let idx = state.activeToolCalls.firstIndex(where: { $0.id == toolUseId }) {
                    state.activeToolCalls[idx].result = content
                    state.activeToolCalls[idx].isError = isError
                    state.activeToolCalls[idx].isDone = true
                }

            case .usage(let input, let output):
                state.inputTokens = input
                state.outputTokens = output
                // Feed the rate-limit tracker so the meter in the composer
                // reflects real usage velocity.
                RateLimitTracker.shared.recordUsage(inputTokens: input, outputTokens: output)

            case .cost, .error, .sessionId, .done:
                break // handled below (outside the mutate closure)
            }
        }

        // Events that affect store-level state, not per-session buffers.
        switch event {
        case .cost(let usd):
            totalCost += usd
            // Append to the persistent cost log for dashboard analysis.
            if let session = sessions.first(where: { $0.id == sessionId }) {
                let rt = runtimeStates[sessionId] ?? SessionRuntimeState()
                CostLog.shared.append(
                    sessionId: sessionId,
                    sessionName: session.name,
                    model: session.model.rawValue,
                    usd: usd,
                    inputTokens: rt.inputTokens,
                    outputTokens: rt.outputTokens
                )
            }
        case .error(let msg):
            mutateRuntime(sessionId) { $0.lastError = msg }
            RateLimitTracker.shared.observeError(msg)
        case .done:
            finalizeAssistantMessage(sessionId: sessionId)
            mutateRuntime(sessionId) { $0.isBusy = false }
            if generatingSessionId == sessionId {
                generatingSessionId = busySessionIds.first
            }
            // Mark "done" badge if user isn't currently viewing this session.
            if activeSessionId != sessionId {
                recentlyCompleted[sessionId] = Date()
            }
            // Fire the on-complete shell hook if configured.
            runCompletionHook(sessionId: sessionId)
        default:
            break
        }
    }

    // MARK: - Private

    /// Runs the configured on-completion shell command. Fire-and-forget.
    /// Shell receives env vars:
    ///   KILN_SESSION_ID, KILN_SESSION_NAME, KILN_WORKDIR,
    ///   KILN_LAST_USER_TEXT, KILN_LAST_ASSISTANT_TEXT
    private func runCompletionHook(sessionId: String) {
        let cmd = settings.onCompleteShellCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cmd.isEmpty,
              let session = sessions.first(where: { $0.id == sessionId }) else { return }
        let lastUser = session.messages.last(where: { $0.role == .user })
            .flatMap { Self.plainText(from: $0.blocks) } ?? ""
        let lastAssistant = session.messages.last(where: { $0.role == .assistant })
            .flatMap { Self.plainText(from: $0.blocks) } ?? ""
        var env = ProcessInfo.processInfo.environment
        env["KILN_SESSION_ID"] = session.id
        env["KILN_SESSION_NAME"] = session.name
        env["KILN_WORKDIR"] = session.workDir
        env["KILN_LAST_USER_TEXT"] = lastUser
        env["KILN_LAST_ASSISTANT_TEXT"] = lastAssistant
        Task.detached {
            let proc = Process()
            proc.launchPath = "/bin/sh"
            proc.arguments = ["-lc", cmd]
            proc.environment = env
            proc.currentDirectoryURL = URL(fileURLWithPath: session.workDir)
            proc.standardOutput = Pipe()
            proc.standardError = Pipe()
            try? proc.run()
        }
    }

    private static func plainText(from blocks: [MessageBlock]) -> String {
        blocks.compactMap { b -> String? in
            if case .text(let t) = b { return t }
            return nil
        }.joined(separator: "\n")
    }

    private func finalizeAssistantMessage(sessionId: String) {
        guard let idx = sessions.firstIndex(where: { $0.id == sessionId }) else { return }

        var blocks: [MessageBlock] = []

        let runtime = runtimeStates[sessionId] ?? SessionRuntimeState()

        if !runtime.streamingText.isEmpty {
            blocks.append(.text(runtime.streamingText))
        }

        for tool in runtime.activeToolCalls {
            blocks.append(.toolUse(tool))
        }

        if !blocks.isEmpty {
            let msg = ChatMessage(role: .assistant, blocks: blocks)
            sessions[idx].messages.append(msg)
        }

        // Clean completion — clear the interrupted marker so the UI stops
        // showing a "resume" banner on next launch / re-visit.
        sessions[idx].wasInterrupted = false

        // Auto-name session from first assistant response.
        // Strategy: drop a cheap first-line heuristic in immediately so the
        // sidebar isn't stuck on "New Session," then kick off a side call to
        // Claude asking for a 3-5 word title and replace when it returns.
        if sessions[idx].messages.count <= 2, sessions[idx].name == "New Session" {
            let preview = runtime.streamingText.prefix(50)
            if !preview.isEmpty {
                let name = String(preview.split(separator: "\n").first ?? preview.prefix(50))
                sessions[idx].name = name.count > 40 ? String(name.prefix(40)) + "…" : name
            }
            // Fire real AI-titled rename off to the side. Doesn't touch
            // the running session; uses its own `claude --print` call.
            let sid = sessionId
            Task { [weak self] in
                // Small delay so the session has at least one user + one
                // assistant message settled in before we grab the excerpt.
                try? await Task.sleep(nanoseconds: 500_000_000)
                await self?.generateSessionTitle(for: sid)
            }
        }

        // Persist
        Persistence.saveSession(sessions[idx])

        // Clear this session's stream buffers (retain tokens/cost).
        mutateRuntime(sessionId) { state in
            state.streamingText = ""
            state.thinkingText = ""
            state.activeToolCalls = []
            state.currentToolId = nil
        }
    }
}
