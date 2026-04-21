import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct ComposerView: View {
    @EnvironmentObject var store: AppStore
    @State private var input = ""
    @FocusState private var isFocused: Bool
    @State private var dropHovering = false
    @State private var showSnippets = false
    @State private var showExpandedEditor = false
    /// When the user types `/` at the start of a line, we surface a
    /// command popup. Selection state lives here so arrow keys can navigate.
    @State private var slashSelectedIndex: Int = 0

    /// `@file` picker selection — mirrors slashSelectedIndex but for the
    /// file-reference popup. Reset to 0 whenever the query changes.
    @State private var atSelectedIndex: Int = 0

    /// Prompt history navigation: index into `PromptHistoryStore.entries`.
    /// -1 means "not browsing history"; 0 = most recent prompt.
    @State private var historyIndex: Int = -1
    /// Saves what the user had typed before they started browsing history,
    /// so they can escape back to it.
    @State private var savedDraft: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar row
            ComposerToolbar()

            // Undo-send banner (only when a send is pending)
            if let pending = store.pendingSend {
                UndoSendBanner(pending: pending) {
                    if let restored = store.cancelPendingSend() {
                        input = restored.text
                        store.composerAttachments = restored.attachments
                    }
                }
            }

            // Slash command popup — appears inline when the input starts with "/".
            if let matches = slashMatches, !matches.isEmpty {
                SlashCommandPopup(
                    matches: matches,
                    selected: $slashSelectedIndex,
                    onPick: { cmd in insertSlashCommand(cmd) }
                )
            }

            // @file picker — appears inline when the user types `@<query>`
            // anywhere in the input. Slash popup wins when both are active
            // (you can't start input with `/` and also have an `@` token,
            // so the conflict is theoretical, but be explicit).
            if slashMatches == nil, let atMatches = atMatches, !atMatches.isEmpty {
                AtFilePopup(
                    matches: atMatches,
                    selected: $atSelectedIndex,
                    onPick: { path in insertAtFile(path) }
                )
            }

            // Workdir activity chip — visible only when there are uncommitted
            // changes in the session's workdir. Click to see which files.
            WorkdirActivityChip()

            // Attachment chips
            if !store.composerAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(store.composerAttachments) { att in
                            AttachmentChip(attachment: att) {
                                store.removeAttachment(att.id)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                }
                .frame(height: 66)
            }

            // Input row
            HStack(alignment: .bottom, spacing: 10) {
                // Attach button
                Button {
                    pickFiles()
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.kilnTextSecondary)
                        .frame(width: 32, height: 32)
                        .background(Color.kilnSurface)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.kilnBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Attach files or images")

                // Snippets button
                Button {
                    showSnippets = true
                } label: {
                    Image(systemName: "text.alignleft")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.kilnTextSecondary)
                        .frame(width: 32, height: 32)
                        .background(Color.kilnSurface)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.kilnBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Snippets (⌘/)")
                .keyboardShortcut("/", modifiers: .command)

                // Expand to full editor — for long prompts
                Button {
                    showExpandedEditor = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.kilnTextSecondary)
                        .frame(width: 32, height: 32)
                        .background(Color.kilnSurface)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.kilnBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Expand editor")

                VStack(spacing: 0) {
                    TextField(placeholderText, text: $input, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13 * store.settings.fontScale.factor))
                        .foregroundStyle(Color.kilnText)
                        .lineLimit(1...8)
                        .focused($isFocused)
                        .onSubmit {
                            // If the slash popup is open and has a selection, Enter accepts that.
                            // Exception: if the user has typed the full label
                            // (e.g. `/timeline`), skip the re-insert dance and
                            // just execute it. Otherwise it takes two Enters
                            // to run a known command, which is maddening.
                            if let matches = slashMatches, !matches.isEmpty {
                                let typed = input.trimmingCharacters(in: .whitespaces).lowercased()
                                let pick = matches[min(slashSelectedIndex, matches.count - 1)]
                                if pick.label.lowercased() == typed {
                                    send()
                                } else {
                                    insertSlashCommand(pick)
                                }
                                return
                            }
                            // @file popup — Enter picks the highlighted path.
                            if let atMatchList = atMatches, !atMatchList.isEmpty {
                                insertAtFile(atMatchList[min(atSelectedIndex, atMatchList.count - 1)])
                                return
                            }
                            if store.settings.sendKey == .enter { send() }
                            else { input += "\n" }
                        }
                        .onAppear { isFocused = true }
                        .onChange(of: store.composerPrefill) { _, new in
                            // External prefill hook (e.g. "Ask Claude about
                            // this file"). Append with a separator if the
                            // user already has text typed; otherwise just
                            // drop it in. Always focus and clear the signal.
                            guard let text = new, !text.isEmpty else { return }
                            if input.isEmpty {
                                input = text
                            } else {
                                input += input.hasSuffix("\n") ? text : "\n" + text
                            }
                            isFocused = true
                            DispatchQueue.main.async { store.composerPrefill = nil }
                        }
                        .disableAutocorrection(!store.settings.spellCheck)
                        .onPasteCommand(of: [.image, .fileURL, .png, .jpeg, .tiff]) { providers in
                            handlePaste(providers)
                        }
                        .onChange(of: input) { _, _ in
                            slashSelectedIndex = 0
                            atSelectedIndex = 0
                        }
                        .onKeyPress(.upArrow) {
                            // Slash popup takes priority.
                            if let matches = slashMatches, !matches.isEmpty {
                                slashSelectedIndex = max(0, slashSelectedIndex - 1)
                                return .handled
                            }
                            // @file popup — up/down within the match list.
                            if let atMatchList = atMatches, !atMatchList.isEmpty {
                                atSelectedIndex = max(0, atSelectedIndex - 1)
                                return .handled
                            }
                            // History recall — only when input is empty or already browsing.
                            let entries = PromptHistoryStore.shared.entries
                            guard !entries.isEmpty else { return .ignored }
                            if historyIndex == -1 && input.isEmpty == false { return .ignored }
                            if historyIndex == -1 { savedDraft = input }
                            historyIndex = min(historyIndex + 1, entries.count - 1)
                            input = entries[historyIndex]
                            return .handled
                        }
                        .onKeyPress(.downArrow) {
                            if let matches = slashMatches, !matches.isEmpty {
                                slashSelectedIndex = min(matches.count - 1, slashSelectedIndex + 1)
                                return .handled
                            }
                            if let atMatchList = atMatches, !atMatchList.isEmpty {
                                atSelectedIndex = min(atMatchList.count - 1, atSelectedIndex + 1)
                                return .handled
                            }
                            guard historyIndex >= 0 else { return .ignored }
                            let entries = PromptHistoryStore.shared.entries
                            historyIndex -= 1
                            if historyIndex < 0 {
                                input = savedDraft
                                savedDraft = ""
                            } else {
                                input = entries[min(historyIndex, entries.count - 1)]
                            }
                            return .handled
                        }
                        .onKeyPress(.escape) {
                            // Clear the / at the front to dismiss the popup.
                            if slashMatches != nil { input = ""; return .handled }
                            // @file popup — escape removes the trailing
                            // `@query` token so the user drops back to
                            // normal typing without losing prior text.
                            if let token = AtTokenScanner.current(in: input),
                               atMatches != nil {
                                input = AtTokenScanner.replace(token, with: "", in: input)
                                    .replacingOccurrences(of: "@  ", with: " ")
                                    .trimmingCharacters(in: .whitespaces)
                                return .handled
                            }
                            // Exit history browse mode cleanly.
                            if historyIndex >= 0 {
                                input = savedDraft
                                savedDraft = ""
                                historyIndex = -1
                                return .handled
                            }
                            return .ignored
                        }
                        .onKeyPress(.tab) {
                            if let matches = slashMatches, !matches.isEmpty {
                                insertSlashCommand(matches[min(slashSelectedIndex, matches.count - 1)])
                                return .handled
                            }
                            if let atMatchList = atMatches, !atMatchList.isEmpty {
                                insertAtFile(atMatchList[min(atSelectedIndex, atMatchList.count - 1)])
                                return .handled
                            }
                            return .ignored
                        }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.kilnSurface)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(borderColor, lineWidth: dropHovering ? 2 : 1)
                )

                if store.isSessionBusy(store.activeSessionId) {
                    Button {
                        store.interrupt()
                    } label: {
                        Image(systemName: "stop.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(Color.kilnError)
                    }
                    .buttonStyle(KilnPressStyle())
                    .help("Stop generation (⌘.)")
                } else {
                    Button {
                        send()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(
                                canSend ? Color.kilnAccent : Color.kilnTextTertiary
                            )
                    }
                    .buttonStyle(KilnPressStyle())
                    .disabled(!canSend)
                    .help(store.settings.sendKey == .cmdEnter ? "Send (⌘⏎)" : "Send (⏎)")
                    .modifier(CmdEnterSendModifier(enabled: store.settings.sendKey == .cmdEnter))
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)

            // Keyboard hint strip — clickable. Mode controlled by settings.
            if shouldShowHintStrip {
                HStack(spacing: 8) {
                    let sendLabel = store.settings.sendKey == .cmdEnter ? "⌘⏎" : "⏎"
                    hintButton(sendLabel, "send") { send() }
                        .disabled(!canSend)
                    hintButton(store.settings.sendKey == .cmdEnter ? "⏎" : "⇧⏎", "newline") {
                        input += "\n"
                    }
                    hintButton("⌘/", "snippets") { showSnippets = true }
                    hintButton("⌘K", "commands") { store.showCommandPalette = true }
                    hintButton("⌘⇧F", "search") { store.showGlobalSearch = true }
                    if store.isSessionBusy(store.activeSessionId) {
                        hintButton("⌘.", "stop") { store.interrupt() }
                    }
                    Spacer()
                    if !input.isEmpty {
                        Button {
                            input = ""
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 9))
                                Text("clear")
                                    .font(.system(size: 9))
                            }
                            .foregroundStyle(Color.kilnTextTertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear the draft")

                        Text(composerCountLabel)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(Color.kilnTextTertiary)
                            .help("Characters, words, and a rough token estimate for the draft")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
        .background(Color.kilnBg)
        .onDrop(of: [.fileURL, .image], isTargeted: $dropHovering) { providers in
            handleDrop(providers)
        }
        .sheet(isPresented: $showSnippets) {
            SnippetsView(onInsert: { text in
                if input.isEmpty {
                    input = text
                } else {
                    input += (input.hasSuffix("\n") ? "" : "\n\n") + text
                }
                isFocused = true
            })
            .preferredColorScheme(Color.kilnPreferredColorScheme)
        }
        .sheet(isPresented: $showExpandedEditor) {
            ExpandedComposerEditor(text: $input, onSend: { send() })
                .preferredColorScheme(Color.kilnPreferredColorScheme)
        }
        .onChange(of: store.pendingComposerPrefill) { _, newValue in
            // Prefill hook used by edit-and-resend and similar flows.
            guard let text = newValue, !text.isEmpty else { return }
            input = text
            isFocused = true
            store.pendingComposerPrefill = nil
        }
    }

    @ViewBuilder
    private func hintButton(_ key: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text(key)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color.kilnTextSecondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.kilnSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                Text(label)
                    .font(.system(size: 9))
                    .foregroundStyle(Color.kilnTextTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(HintHoverStyle())
    }

    private var canSend: Bool {
        let hasText = !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasAttachments = !store.composerAttachments.isEmpty
        return (hasText || hasAttachments) && !store.isSessionBusy(store.activeSessionId)
    }

    /// Returns the current slash query (text after the leading `/`) or nil
    /// if we shouldn't be showing the popup.
    ///
    /// Ranking: exact label match first, then label-prefix, then label
    /// contains. Description is deliberately NOT matched — typing "t"
    /// shouldn't pull up every command that happens to have "t" in its
    /// description.
    private var slashMatches: [SlashCommand]? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        // Only fire while the input is a single word (no spaces yet).
        if trimmed.contains(" ") { return nil }
        let query = String(trimmed.dropFirst()).lowercased()
        let all = SlashCommands.all()
        if query.isEmpty { return all }
        var exact: [SlashCommand] = []
        var prefix: [SlashCommand] = []
        var contains: [SlashCommand] = []
        for c in all {
            let body = String(c.label.dropFirst()).lowercased()
            if body == query { exact.append(c) }
            else if body.hasPrefix(query) { prefix.append(c) }
            else if body.contains(query) { contains.append(c) }
        }
        return exact + prefix + contains
    }

    private func insertSlashCommand(_ cmd: SlashCommand) {
        input = cmd.label + " "
        slashSelectedIndex = 0
        isFocused = true
    }

    /// Fuzzy-matched file list for the in-progress `@` token, or nil if
    /// no `@` token is active. Pulls files from the active session's
    /// workdir — switching sessions picks up a new list on next keystroke.
    private var atMatches: [String]? {
        guard let token = AtTokenScanner.current(in: input) else { return nil }
        guard let session = store.activeSession else { return nil }
        let paths = WorkdirFileIndex.shared.paths(for: session.workDir)
        guard !paths.isEmpty else { return nil }
        let ranked = FuzzyScorer.rank(paths: paths, query: token.query, limit: 8)
        return ranked.isEmpty ? nil : ranked
    }

    /// Replace the in-progress `@query` token with `@path` and resume
    /// typing. Preserves the rest of the input (before and after the
    /// token) exactly. If the token scanner can't locate the token,
    /// fall back to appending — better than silently doing nothing.
    private func insertAtFile(_ path: String) {
        if let token = AtTokenScanner.current(in: input) {
            input = AtTokenScanner.replace(token, with: path, in: input)
        } else {
            input += "@" + path + " "
        }
        atSelectedIndex = 0
        isFocused = true
    }

    private var placeholderText: String {
        let custom = store.settings.composerPlaceholder
        return custom.isEmpty ? store.settings.language.ui.messagePlaceholder : custom
    }

    /// Formats the current draft's character + word count for the hint strip.
    /// Words are split on any whitespace run, which is good enough for a
    /// peripheral indicator — we're not writing WordCounter.app here.
    private var composerCountLabel: String {
        let chars = input.count
        let words = input
            .split(whereSeparator: { $0.isWhitespace })
            .count
        // Rough token estimate: ~4 chars per token. Not exact for code or
        // non-English text but close enough to gauge prompt cost at a glance.
        let toks = max(1, (chars + 3) / 4)
        return "\(chars) chars · \(words) words · ~\(toks) tok"
    }

    private var shouldShowHintStrip: Bool {
        switch store.settings.hintStripMode {
        case .always: return true
        case .focused: return isFocused
        case .never: return false
        }
    }

    private var borderColor: Color {
        if dropHovering { return Color.kilnAccent }
        if isFocused { return Color.kilnAccent.opacity(0.5) }
        return Color.kilnBorder
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSend else { return }

        // All slash commands are handled client-side. Claude Code's native
        // slash commands only work in interactive mode; we run --print.
        if text.hasPrefix("/") && !text.hasPrefix("//") && isRecognizedSlashCommand(text) {
            handleSlashCommand(text)
            return
        }

        let attached = store.composerAttachments
        PromptHistoryStore.shared.record(text)
        historyIndex = -1
        savedDraft = ""
        input = ""
        store.clearAttachments()
        store.queueSend(text, attachments: attached)
    }

    private func isRecognizedSlashCommand(_ raw: String) -> Bool {
        let cmd = raw.split(separator: " ").first?.lowercased() ?? ""
        return SlashCommands.all().contains { $0.label.lowercased() == cmd }
    }

    private func handleSlashCommand(_ raw: String) {
        let parts = raw.split(separator: " ", maxSplits: 1).map(String.init)
        let cmd = parts.first?.lowercased() ?? ""
        let arg = parts.count > 1 ? parts[1] : ""
        input = ""
        store.clearAttachments()

        switch cmd {
        case "/fork":
            if let sid = store.activeSessionId,
               let msg = store.activeSession?.messages.last {
                store.forkSession(fromSessionId: sid, atMessageId: msg.id)
            }
        case "/export":
            guard let id = store.activeSessionId else { return }
            let md = store.exportSessionMarkdown(id)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.plainText]
            panel.nameFieldStringValue = "\(store.activeSession?.name ?? "chat").md"
            if panel.runModal() == .OK, let url = panel.url {
                try? md.write(to: url, atomically: true, encoding: .utf8)
            }
        case "/retry":
            Task { await store.retryLastMessage() }
        case "/compact":
            Task { await store.compactSession() }
        case "/clear":
            if let id = store.activeSessionId { store.clearSession(id) }
        case "/model":
            store.cycleToNextModel()
        case "/compare":
            // Pick a model different from the current one — cycle forward by
            // one in allCases. User can re-run /compare to try more models.
            let current = store.activeSession?.model ?? .sonnet46
            let all = ClaudeModel.allCases
            let alt: ClaudeModel = {
                guard let i = all.firstIndex(of: current) else { return all.first ?? current }
                return all[(i + 1) % all.count]
            }()
            Task { await store.compareWithModel(alt) }
        case "/interrupt":
            store.interrupt()
        case "/instructions":
            // Route through the store so the chat header sheet can open it.
            store.requestOpenInstructions = true
        case "/title":
            Task { await store.generateSessionTitle() }
        case "/settings":
            store.showSettings = true
        case "/memory":
            // Engram's bundled web dashboard listens on 127.0.0.1:8420.
            // Works whether the user ran `engram serve --web` already or
            // not — if the server isn't up, the browser just shows a
            // connection error and the user knows to start it.
            if let url = URL(string: "http://127.0.0.1:8420") {
                NSWorkspace.shared.open(url)
            }
        case "/focus":
            store.toggleFocusMode()
        case "/reload":
            store.reloadFromDisk()
        case "/link":
            if let id = store.activeSessionId { store.copySessionLink(id) }
        case "/merge":
            _ = store.bulkMerge()
        case "/rename":
            let name = arg.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, let id = store.activeSessionId {
                store.renameSession(id, name: name)
            }
        case "/color":
            let name = arg.trimmingCharacters(in: .whitespaces).lowercased()
            guard let id = store.activeSessionId else { break }
            if name == "none" || name.isEmpty {
                store.setSessionColor(id, color: nil)
            } else if SessionColor.color(for: name) != nil {
                store.setSessionColor(id, color: name)
            }
        case "/search":
            let q = arg.trimmingCharacters(in: .whitespaces)
            if !q.isEmpty {
                // Seed the global-search view's query via a lightweight
                // notification — the receiver in ContentView clears it.
                store.pendingSearchQuery = q
            }
            store.showGlobalSearch = true
        case "/timeline":
            store.showToolTimeline = true
        case "/commit":
            // Stage everything and commit with the provided message. If
            // no message was given, fall back to a dated placeholder —
            // better than failing silently. Runs in the session's workdir.
            let msg = arg.trimmingCharacters(in: .whitespaces)
            let message = msg.isEmpty
                ? "wip: \(Date().formatted(date: .abbreviated, time: .shortened))"
                : msg
            if let dir = store.activeSession?.workDir {
                Task.detached {
                    let outcome = GitQuickCommit.run(workDir: dir, message: message)
                    await MainActor.run {
                        switch outcome {
                        case .committed(let short):
                            ToastCenter.shared.show("Committed \(short)", kind: .success)
                        case .nothingToCommit:
                            ToastCenter.shared.show("Nothing to commit", kind: .info)
                        case .failed(let reason):
                            ToastCenter.shared.show("Commit failed: \(reason)", kind: .error, duration: 3.5)
                        }
                    }
                }
            }
        case "/diff":
            if let dir = store.activeSession?.workDir {
                if let d = GitQuickCommit.diff(workDir: dir) {
                    store.diffSheetContent = d.isEmpty ? "# No changes — working tree is clean.\n" : d
                } else {
                    ToastCenter.shared.show("Not a git repo", kind: .error)
                }
            }
        case "/clone":
            if let id = store.activeSessionId {
                store.cloneSession(id)
                ToastCenter.shared.show("Cloned session", kind: .success)
            }
        case "/status":
            // Inject current git status as a plain user message so Claude
            // sees the working-tree state. Dead cheap, avoids asking
            // Claude to shell out.
            if let dir = store.activeSession?.workDir,
               let info = GitStatus.info(for: dir) {
                let note = "Current git status — branch `\(info.branch)`, \(info.dirtyCount) uncommitted change\(info.dirtyCount == 1 ? "" : "s")."
                Task { await store.sendMessage(note) }
            }
        case "/template", "/tmpl":
            let name = arg.trimmingCharacters(in: .whitespaces)
            if let t = PromptTemplateStore.shared.template(named: name) {
                input = t.body
                isFocused = true
            }
        case "/rewind":
            // /rewind N — drop the last N message pairs from the session.
            // Default N = 1. Capped at 50 so a typo can't nuke a long
            // session. Non-destructive on disk until saveSession runs.
            // Guard against rewinding mid-stream — the runtime would keep
            // appending to a message we've already removed, corrupting state.
            guard let id = store.activeSessionId else { break }
            if store.isSessionBusy(id) {
                ToastCenter.shared.show("Stop generation first", kind: .error)
                break
            }
            let parsed = Int(arg.trimmingCharacters(in: .whitespaces)) ?? 1
            let n = max(1, min(50, parsed))
            store.rewindSession(id, count: n)
            ToastCenter.shared.show("Rewound \(n) exchange\(n == 1 ? "" : "s")", kind: .info)
        // --- workdir / shell ---
        case "/pwd":
            if let dir = store.activeSession?.workDir {
                ToastCenter.shared.show(dir, kind: .info, duration: 3.5)
            }
        case "/open":
            if let dir = store.activeSession?.workDir {
                SlashHelpers.revealInFinder(dir)
            }
        case "/terminal":
            if let dir = store.activeSession?.workDir {
                SlashHelpers.openTerminal(at: dir)
            }
        case "/editor":
            if let dir = store.activeSession?.workDir {
                SlashHelpers.openInEditor(dir)
            }
        case "/cd":
            let path = arg.trimmingCharacters(in: .whitespaces)
            guard !path.isEmpty, let id = store.activeSessionId else {
                ToastCenter.shared.show("Usage: /cd /path/to/dir", kind: .error); break
            }
            let expanded = (path as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue else {
                ToastCenter.shared.show("Not a directory: \(expanded)", kind: .error); break
            }
            store.setWorkDir(id, workDir: expanded)
            ToastCenter.shared.show("Workdir → \(expanded)", kind: .success)

        // --- git wrappers ---
        case "/log":
            // Inject the last 5 commits as a user message — gives Claude
            // cheap orientation without having to shell out itself. Off
            // main: big histories in a heavy repo can take 100+ ms to
            // walk, which beachballs the composer.
            guard let dir = store.activeSession?.workDir else { break }
            Task.detached {
                let r = SlashHelpers.git(["log", "--oneline", "-n", "5"], in: dir)
                await MainActor.run {
                    if r.status == 0 {
                        Task { await store.sendMessage("Recent commits:\n```\n\(r.out)```") }
                    } else {
                        ToastCenter.shared.show("git log failed", kind: .error)
                    }
                }
            }
        case "/branch":
            let name = arg.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, let dir = store.activeSession?.workDir else {
                ToastCenter.shared.show("Usage: /branch name", kind: .error); break
            }
            Task.detached {
                let r = SlashHelpers.git(["checkout", "-b", name], in: dir)
                await MainActor.run {
                    ToastCenter.shared.show(
                        r.status == 0 ? "On branch \(name)" : "branch failed: \(r.err.trimmingCharacters(in: .whitespacesAndNewlines))",
                        kind: r.status == 0 ? .success : .error,
                        duration: r.status == 0 ? 2.0 : 3.5
                    )
                }
            }
        case "/checkout":
            let name = arg.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, let dir = store.activeSession?.workDir else {
                ToastCenter.shared.show("Usage: /checkout branch", kind: .error); break
            }
            Task.detached {
                let r = SlashHelpers.git(["checkout", name], in: dir)
                await MainActor.run {
                    ToastCenter.shared.show(
                        r.status == 0 ? "On branch \(name)" : "checkout failed",
                        kind: r.status == 0 ? .success : .error
                    )
                }
            }
        case "/stash":
            guard let dir = store.activeSession?.workDir else { break }
            Task.detached {
                let r = SlashHelpers.git(["stash", "push", "-u"], in: dir)
                await MainActor.run {
                    ToastCenter.shared.show(
                        r.status == 0 ? "Stashed" : "stash failed",
                        kind: r.status == 0 ? .success : .error
                    )
                }
            }
        case "/unstash":
            guard let dir = store.activeSession?.workDir else { break }
            Task.detached {
                let r = SlashHelpers.git(["stash", "pop"], in: dir)
                await MainActor.run {
                    ToastCenter.shared.show(
                        r.status == 0 ? "Stash popped" : "unstash failed",
                        kind: r.status == 0 ? .success : .error
                    )
                }
            }
        case "/pull":
            guard let dir = store.activeSession?.workDir else { break }
            // git can take a while — run detached so the UI stays live.
            Task.detached {
                let r = SlashHelpers.git(["pull"], in: dir)
                await MainActor.run {
                    ToastCenter.shared.show(
                        r.status == 0 ? "Pulled" : "pull failed: \(r.err.prefix(120))",
                        kind: r.status == 0 ? .success : .error,
                        duration: 3.5
                    )
                }
            }
        case "/push":
            guard let dir = store.activeSession?.workDir else { break }
            Task.detached {
                let r = SlashHelpers.git(["push"], in: dir)
                await MainActor.run {
                    ToastCenter.shared.show(
                        r.status == 0 ? "Pushed" : "push failed: \(r.err.prefix(120))",
                        kind: r.status == 0 ? .success : .error,
                        duration: 3.5
                    )
                }
            }
        case "/blame":
            let file = arg.trimmingCharacters(in: .whitespaces)
            guard !file.isEmpty, let dir = store.activeSession?.workDir else {
                ToastCenter.shared.show("Usage: /blame path/to/file", kind: .error); break
            }
            Task.detached {
                let r = SlashHelpers.git(["blame", "--date=short", file], in: dir)
                await MainActor.run {
                    if r.status == 0 {
                        // Cap at ~200 lines to avoid dumping a 5k-line file as context.
                        let lines = r.out.split(separator: "\n").prefix(200).joined(separator: "\n")
                        Task { await store.sendMessage("Blame for `\(file)`:\n```\n\(lines)\n```") }
                    } else {
                        ToastCenter.shared.show("blame failed: \(r.err.prefix(120))", kind: .error)
                    }
                }
            }

        // --- session metadata ---
        case "/pin":
            if let id = store.activeSessionId {
                store.togglePin(id)
                let pinned = store.sessions.first(where: { $0.id == id })?.isPinned == true
                ToastCenter.shared.show(pinned ? "Pinned" : "Unpinned", kind: .info)
            }
        case "/archive":
            if let id = store.activeSessionId {
                store.toggleArchiveSession(id)
                ToastCenter.shared.show("Archive toggled", kind: .info)
            }
        case "/tag":
            let name = arg.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, let id = store.activeSessionId else {
                ToastCenter.shared.show("Usage: /tag name", kind: .error); break
            }
            store.addTag(name, to: id)
            ToastCenter.shared.show("Tagged #\(name)", kind: .success)
        case "/untag":
            let name = arg.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, let id = store.activeSessionId else {
                ToastCenter.shared.show("Usage: /untag name", kind: .error); break
            }
            store.removeTag(name, from: id)
            ToastCenter.shared.show("Removed #\(name)", kind: .info)

        // --- content extraction ---
        case "/copy":
            if let text = SlashHelpers.lastAssistantText(in: store.activeSession) {
                SlashHelpers.copyToClipboard(text)
                ToastCenter.shared.show("Copied \(text.count) chars", kind: .success)
            } else {
                ToastCenter.shared.show("No assistant message yet", kind: .error)
            }
        case "/copycode":
            if let code = SlashHelpers.lastCodeBlock(in: store.activeSession) {
                SlashHelpers.copyToClipboard(code)
                ToastCenter.shared.show("Copied code (\(code.count) chars)", kind: .success)
            } else {
                ToastCenter.shared.show("No code block in last reply", kind: .error)
            }
        case "/save":
            let rel = arg.trimmingCharacters(in: .whitespaces)
            guard !rel.isEmpty, let dir = store.activeSession?.workDir else {
                ToastCenter.shared.show("Usage: /save path/to/file", kind: .error); break
            }
            guard let code = SlashHelpers.lastCodeBlock(in: store.activeSession) else {
                ToastCenter.shared.show("No code block in last reply", kind: .error); break
            }
            // Confine writes to the session's workdir. Absolute paths (`/…`
            // or `~/…`) used to silently escape the workdir — one assistant
            // message with a fenced shell script plus `/save ~/.zshrc` would
            // clobber a dotfile. Reject those paths; force the user to cd
            // into the dir via the workdir header if they want to write
            // elsewhere.
            if rel.hasPrefix("/") || rel.hasPrefix("~") {
                ToastCenter.shared.show("/save writes inside the session's workdir only — use a relative path", kind: .error)
                break
            }
            let target = (dir as NSString).appendingPathComponent(rel)
            // Canonicalise and re-check — a relative path with `..` can still
            // climb above the workdir. Compare standardised absolute paths.
            let resolvedTarget = URL(fileURLWithPath: target).standardizedFileURL.path
            let resolvedDir = URL(fileURLWithPath: dir).standardizedFileURL.path
            guard resolvedTarget == resolvedDir || resolvedTarget.hasPrefix(resolvedDir + "/") else {
                ToastCenter.shared.show("/save path escapes the workdir (\(rel))", kind: .error)
                break
            }
            do {
                // Make sure the parent dir exists — surfaces the common
                // "no such file or directory" error before the write fails.
                let parent = (resolvedTarget as NSString).deletingLastPathComponent
                try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
                try code.write(toFile: resolvedTarget, atomically: true, encoding: .utf8)
                ToastCenter.shared.show("Saved → \(resolvedTarget)", kind: .success, duration: 3.0)
            } catch {
                ToastCenter.shared.show("save failed: \(error.localizedDescription)", kind: .error)
            }
        case "/share":
            if let id = store.activeSessionId {
                let md = store.exportSessionMarkdown(id)
                SlashHelpers.copyToClipboard(md)
                ToastCenter.shared.show("Copied markdown (\(md.count) chars)", kind: .success)
            }
        case "/quote":
            if let text = SlashHelpers.lastAssistantText(in: store.activeSession) {
                // Prefix each line with "> " so Claude sees it as a quote.
                // Keeps the composer editable so the user can add their
                // follow-up question underneath.
                let quoted = text.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { "> \($0)" }.joined(separator: "\n")
                input = quoted + "\n\n"
                isFocused = true
            } else {
                ToastCenter.shared.show("No assistant message yet", kind: .error)
            }

        // --- info ---
        case "/stats":
            guard let s = store.activeSession else { break }
            let msgs = s.messages.count
            let words = SlashHelpers.wordCount(in: s)
            let toks = SlashHelpers.approximateTokens(in: s)
            ToastCenter.shared.show("\(msgs) msgs · \(words) words · ~\(toks) tok", kind: .info, duration: 3.5)
        case "/tokens":
            let toks = SlashHelpers.approximateTokens(in: store.activeSession)
            ToastCenter.shared.show("~\(toks) tokens", kind: .info)
        case "/env":
            if let s = store.activeSession {
                let line = "\(s.model.rawValue) · \(s.kind.rawValue) · \(s.workDir)"
                ToastCenter.shared.show(line, kind: .info, duration: 4.0)
            }

        // --- aliases / misc ---
        case "/undo":
            guard let id = store.activeSessionId else { break }
            if store.isSessionBusy(id) {
                ToastCenter.shared.show("Stop generation first", kind: .error); break
            }
            store.rewindSession(id, count: 1)
            ToastCenter.shared.show("Rewound 1 exchange", kind: .info)
        case "/resend":
            Task { await store.retryLastMessage() }
        case "/summary":
            // Reuse the title generator — it already asks Claude for a
            // short, dense phrase. Saves adding a parallel path.
            Task { await store.generateSessionTitle() }
        case "/todo":
            let line = arg.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, let dir = store.activeSession?.workDir else {
                ToastCenter.shared.show("Usage: /todo thing to do", kind: .error); break
            }
            let path = (dir as NSString).appendingPathComponent("TODO.md")
            let stamp = ISO8601DateFormatter().string(from: Date()).prefix(10)
            let entry = "- [ ] \(line)  _(\(stamp))_\n"
            do {
                if FileManager.default.fileExists(atPath: path) {
                    if let handle = FileHandle(forWritingAtPath: path) {
                        try handle.seekToEnd()
                        if let data = entry.data(using: .utf8) { try handle.write(contentsOf: data) }
                        try handle.close()
                    }
                } else {
                    try "# TODO\n\n\(entry)".write(toFile: path, atomically: true, encoding: .utf8)
                }
                ToastCenter.shared.show("Added to TODO.md", kind: .success)
            } catch {
                ToastCenter.shared.show("todo failed: \(error.localizedDescription)", kind: .error)
            }
        case "/notes":
            let path = (NSHomeDirectory() as NSString).appendingPathComponent("kiln-notes.md")
            if !FileManager.default.fileExists(atPath: path) {
                try? "# Kiln notes\n\n".write(toFile: path, atomically: true, encoding: .utf8)
            }
            SlashHelpers.openInEditor(path)
        case "/help":
            // Tiny surfacing — the real discoverability is the popup on `/`.
            // This just nudges people who typed /help expecting a page.
            ToastCenter.shared.show("Type / to browse all commands · ↑/↓ to navigate · Enter to run", kind: .info, duration: 5.0)

        // --- 1.7.0: workdir inspection ---
        case "/ls":
            if let dir = store.activeSession?.workDir {
                let listing = SlashHelpers.listDir(dir)
                Task { await store.sendMessage("Contents of `\(dir)`:\n```\n\(listing)\n```") }
            }
        case "/tree":
            if let dir = store.activeSession?.workDir {
                let t = SlashHelpers.tree(dir, depth: 2)
                Task { await store.sendMessage("Tree of `\(dir)`:\n```\n\(t)\n```") }
            }
        case "/grep":
            let pat = arg.trimmingCharacters(in: .whitespaces)
            guard !pat.isEmpty, let dir = store.activeSession?.workDir else {
                ToastCenter.shared.show("Usage: /grep pattern", kind: .error); break
            }
            Task.detached {
                // Prefer ripgrep if present — it's Git-aware and 10× faster
                // than grep on typical trees. Fall back to grep -r.
                let rgPaths = ["/opt/homebrew/bin/rg", "/usr/local/bin/rg"]
                let bin = rgPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
                let r: (status: Int32, out: String, err: String) = {
                    if let bin {
                        return SlashHelpers.run(bin, args: ["-n", "--no-heading", "-S", pat, dir])
                    }
                    return SlashHelpers.run("/usr/bin/grep", args: ["-rn", pat, dir])
                }()
                let lines = r.out.split(separator: "\n").prefix(80).joined(separator: "\n")
                let body = lines.isEmpty ? "(no matches)" : String(lines)
                await store.sendMessage("Matches for `\(pat)`:\n```\n\(body)\n```")
            }
        case "/find":
            let pat = arg.trimmingCharacters(in: .whitespaces)
            guard !pat.isEmpty, let dir = store.activeSession?.workDir else {
                ToastCenter.shared.show("Usage: /find *.swift", kind: .error); break
            }
            Task.detached {
                let r = SlashHelpers.run("/usr/bin/find", args: [dir, "-name", pat, "-not", "-path", "*/.*"])
                let lines = r.out.split(separator: "\n").prefix(80).joined(separator: "\n")
                let body = lines.isEmpty ? "(no matches)" : String(lines)
                await store.sendMessage("Files matching `\(pat)`:\n```\n\(body)\n```")
            }
        case "/cat":
            let rel = arg.trimmingCharacters(in: .whitespaces)
            guard !rel.isEmpty, let dir = store.activeSession?.workDir else {
                ToastCenter.shared.show("Usage: /cat path/to/file", kind: .error); break
            }
            let target: String = {
                if rel.hasPrefix("/") || rel.hasPrefix("~") {
                    return (rel as NSString).expandingTildeInPath
                }
                return (dir as NSString).appendingPathComponent(rel)
            }()
            guard let text = try? String(contentsOfFile: target, encoding: .utf8) else {
                ToastCenter.shared.show("Can't read \(rel)", kind: .error); break
            }
            // Cap at 400 lines — anything longer is better read via Claude's
            // file-read tool than jammed into the prompt.
            let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            let clipped = lines.prefix(400).joined(separator: "\n")
            let note = lines.count > 400 ? "\n(… truncated at 400 lines of \(lines.count))" : ""
            Task { await store.sendMessage("`\(rel)`:\n```\n\(clipped)\(note)\n```") }
        case "/recent":
            guard let dir = store.activeSession?.workDir else { break }
            // Files changed in the last day, minus junk dirs. `find` on a
            // big monorepo can take seconds — off main.
            Task.detached {
                let r = SlashHelpers.run("/usr/bin/find", args: [
                    dir, "-type", "f",
                    "-not", "-path", "*/.*",
                    "-not", "-path", "*/node_modules/*",
                    "-not", "-path", "*/.build/*",
                    "-mtime", "-1",
                ])
                let lines = r.out.split(separator: "\n").prefix(60).joined(separator: "\n")
                let body = lines.isEmpty ? "(nothing modified in the last 24h)" : String(lines)
                await store.sendMessage("Recently modified files:\n```\n\(body)\n```")
            }

        // --- git extras ---
        case "/repo":
            guard let dir = store.activeSession?.workDir else { break }
            Task.detached {
                let remote = SlashHelpers.git(["remote", "-v"], in: dir).out
                let upstream = SlashHelpers.git(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], in: dir).out
                let body = "remote:\n\(remote)\nupstream: \(upstream.trimmingCharacters(in: .whitespacesAndNewlines))"
                await store.sendMessage("Repo info:\n```\n\(body)\n```")
            }
        case "/diffstat":
            guard let dir = store.activeSession?.workDir else { break }
            Task.detached {
                let r = SlashHelpers.git(["diff", "HEAD", "--stat"], in: dir)
                await MainActor.run {
                    if r.status == 0 {
                        let body = r.out.isEmpty ? "(clean)" : r.out
                        Task { await store.sendMessage("```\n\(body)\n```") }
                    } else {
                        ToastCenter.shared.show("Not a git repo", kind: .error)
                    }
                }
            }
        case "/upstream":
            guard let dir = store.activeSession?.workDir else { break }
            Task.detached {
                let r = SlashHelpers.git(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"], in: dir)
                let up = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
                await MainActor.run {
                    ToastCenter.shared.show(up.isEmpty ? "No upstream" : "Upstream: \(up)", kind: .info, duration: 4.0)
                }
            }
        case "/changed":
            guard let dir = store.activeSession?.workDir else { break }
            Task.detached {
                let r = SlashHelpers.git(["status", "--porcelain"], in: dir)
                await MainActor.run {
                    if r.status == 0 {
                        let body = r.out.isEmpty ? "(clean)" : r.out
                        Task { await store.sendMessage("Uncommitted changes:\n```\n\(body)\n```") }
                    } else {
                        ToastCenter.shared.show("Not a git repo", kind: .error)
                    }
                }
            }

        // --- quick-inject into composer ---
        case "/now":
            let fmt = DateFormatter()
            fmt.dateStyle = .medium; fmt.timeStyle = .short
            input = fmt.string(from: Date())
            isFocused = true
        case "/date":
            let fmt = DateFormatter()
            fmt.dateStyle = .long
            input = fmt.string(from: Date())
            isFocused = true
        case "/clip":
            if let s = NSPasteboard.general.string(forType: .string) {
                input = s
                isFocused = true
            } else {
                ToastCenter.shared.show("Clipboard is empty", kind: .error)
            }
        case "/paste":
            if let s = NSPasteboard.general.string(forType: .string), !s.isEmpty {
                Task { await store.sendMessage(s) }
            } else {
                ToastCenter.shared.show("Clipboard is empty", kind: .error)
            }

        // --- app state / UI ---
        case "/expand":
            showExpandedEditor = true
        case "/killall":
            // Walk every busy session and interrupt it. The store's public
            // interrupt() only kills the active session, so we have to
            // iterate busySessionIds manually.
            let ids = store.busySessionIds
            let was = store.activeSessionId
            for id in ids {
                store.activeSessionId = id
                store.interrupt()
            }
            store.activeSessionId = was
            ToastCenter.shared.show("Interrupted \(ids.count) session\(ids.count == 1 ? "" : "s")", kind: .info)
        case "/readonly":
            guard let id = store.activeSessionId,
                  let idx = store.sessions.firstIndex(where: { $0.id == id }) else { break }
            store.sessions[idx].readOnly.toggle()
            ToastCenter.shared.show(store.sessions[idx].readOnly ? "Read-only on" : "Read-only off", kind: .info)
        case "/accent":
            // Accept #ffcc00 / ffcc00 / FFCC00. Validate hex chars so a typo
            // doesn't produce a silently-black accent that the user then
            // has to dig through settings to recover from.
            let raw = arg.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "#", with: "")
                .lowercased()
            let isHex = raw.count == 6 && raw.allSatisfy { "0123456789abcdef".contains($0) }
            guard isHex else {
                ToastCenter.shared.show("Usage: /accent f97316 (6-digit hex)", kind: .error); break
            }
            store.settings.accentHex = raw
            store.saveSettings()
            ToastCenter.shared.show("Accent → #\(raw)", kind: .success)

        // --- info toasts ---
        case "/version":
            let v = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "dev"
            let b = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
            ToastCenter.shared.show("Kiln \(v) (\(b))", kind: .info, duration: 3.0)
        case "/age":
            if let s = store.activeSession {
                let fmt = RelativeDateTimeFormatter()
                fmt.unitsStyle = .full
                let rel = fmt.localizedString(for: s.createdAt, relativeTo: Date())
                ToastCenter.shared.show("Session started \(rel)", kind: .info, duration: 3.5)
            }
        case "/count":
            if let s = store.activeSession {
                ToastCenter.shared.show("\(s.messages.count) message\(s.messages.count == 1 ? "" : "s")", kind: .info)
            }
        case "/sessions":
            let total = store.sessions.count
            let archived = store.sessions.filter { $0.isArchived }.count
            ToastCenter.shared.show("\(total) sessions · \(archived) archived", kind: .info, duration: 3.0)
        case "/busy":
            let n = store.busySessionIds.count
            ToastCenter.shared.show(n == 0 ? "No sessions busy" : "\(n) busy", kind: .info)
        case "/diag":
            let v = ProcessInfo.processInfo.operatingSystemVersion
            let arch: String = {
                #if arch(arm64)
                return "arm64"
                #else
                return "x86_64"
                #endif
            }()
            let cpu = ProcessInfo.processInfo.activeProcessorCount
            ToastCenter.shared.show("macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion) · \(arch) · \(cpu) cores", kind: .info, duration: 4.5)

        // --- navigation / browser ---
        case "/random":
            let pool = store.sessions.filter { !$0.isArchived && $0.id != store.activeSessionId }
            if let pick = pool.randomElement() {
                store.activeSessionId = pick.id
            } else {
                ToastCenter.shared.show("No other sessions", kind: .info)
            }
        case "/bugs":
            if let url = URL(string: "https://github.com/rayaio/kiln/issues") {
                NSWorkspace.shared.open(url)
            }

        // --- aliases ---
        case "/duplicate":
            if let id = store.activeSessionId {
                store.cloneSession(id)
                ToastCenter.shared.show("Cloned session", kind: .success)
            }
        case "/star":
            if let id = store.activeSessionId {
                store.togglePin(id)
                let pinned = store.sessions.first(where: { $0.id == id })?.isPinned == true
                ToastCenter.shared.show(pinned ? "Pinned" : "Unpinned", kind: .info)
            }
        case "/zen":
            store.toggleFocusMode()
        case "/repeat":
            Task { await store.retryLastMessage() }
        case "/compress":
            Task { await store.compactSession() }

        default:
            // Handle dynamic template aliases like `/t:review`.
            if cmd.hasPrefix("/t:") {
                let name = String(cmd.dropFirst(3))
                if let t = PromptTemplateStore.shared.template(named: name) {
                    // Preserve any trailing args as extra context appended
                    // after a newline — e.g. `/t:review look at auth.swift`.
                    let extra = arg.trimmingCharacters(in: .whitespaces)
                    input = extra.isEmpty ? t.body : "\(t.body)\n\n\(extra)"
                    isFocused = true
                    return
                }
            }
            // Unknown command — send as plain text so Claude can respond to it.
            Task { await store.sendMessage(raw) }
        }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK {
            for url in panel.urls {
                store.addAttachment(path: url.path, name: url.lastPathComponent)
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { data, _ in
                    var url: URL?
                    if let d = data as? Data {
                        url = URL(dataRepresentation: d, relativeTo: nil)
                    } else if let u = data as? URL {
                        url = u
                    }
                    guard let u = url else { return }
                    Task { @MainActor in
                        store.addAttachment(path: u.path, name: u.lastPathComponent)
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                handled = true
                _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.png.identifier) { data, _ in
                    guard let d = data else { return }
                    Task { @MainActor in
                        if let path = writePastedImage(d, ext: "png") {
                            store.addAttachment(path: path, name: "pasted.png")
                        }
                    }
                }
            }
        }
        return handled
    }

    private func handlePaste(_ providers: [NSItemProvider]) {
        _ = handleDrop(providers)
    }

    private func writePastedImage(_ data: Data, ext: String) -> String? {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-attachments", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("pasted-\(Int(Date().timeIntervalSince1970)).\(ext)")
        do {
            try data.write(to: file)
            return file.path
        } catch {
            return nil
        }
    }
}

// MARK: - Attachment Chip

struct AttachmentChip: View {
    let attachment: ComposerAttachment
    let onRemove: () -> Void
    @State private var hovering = false

    private var isImage: Bool {
        let ext = (attachment.name as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "webp", "tiff", "heic", "bmp"].contains(ext)
    }

    private var thumbnail: NSImage? {
        guard isImage, FileManager.default.fileExists(atPath: attachment.path) else { return nil }
        return NSImage(contentsOfFile: attachment.path)
    }

    var body: some View {
        HStack(spacing: 8) {
            if let thumb = thumbnail {
                Image(nsImage: thumb)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 42, height: 42)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.kilnBorder, lineWidth: 1))
            } else {
                Image(systemName: icon)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.kilnAccent)
                    .frame(width: 32, height: 32)
                    .background(Color.kilnBg)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(attachment.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.kilnText)
                    .lineLimit(1)
                Text(attachment.path)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(Color.kilnTextTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: 200, alignment: .leading)

            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.kilnTextSecondary)
                    .frame(width: 16, height: 16)
                    .background(hovering ? Color.kilnSurfaceHover : Color.clear)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.kilnSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.kilnBorder, lineWidth: 1))
        .help(attachment.path)
    }

    private var icon: String {
        let ext = (attachment.name as NSString).pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "gif", "webp", "tiff", "heic": return "photo"
        case "pdf": return "doc.richtext"
        case "mp4", "mov", "m4v", "webm": return "film"
        case "mp3", "wav", "m4a", "flac": return "waveform"
        default: return "doc"
        }
    }
}

// MARK: - Composer Toolbar

struct ComposerToolbar: View {
    @EnvironmentObject var store: AppStore

    private var isChatSession: Bool {
        store.activeSession?.kind == .chat
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                if !isChatSession {
                    // Mode toggle: Plan / Build — code sessions only
                    ToolbarPill(
                        icon: store.sessionMode.icon,
                        label: store.sessionMode.label,
                        color: store.sessionMode == .plan ? .cyan : Color.kilnAccent,
                        active: true
                    ) {
                        store.sessionMode = store.sessionMode == .build ? .plan : .build
                    }
                    .help(store.sessionMode.description)

                    // Permissions — code sessions only
                    ToolbarPill(
                        icon: store.permissionMode.icon,
                        label: store.permissionMode.label,
                        color: permissionColor,
                        active: true
                    ) {
                        cyclePermissions()
                    }
                    .help(store.permissionMode.description)

                    // Max turns — code sessions only
                    ToolbarPill(
                        icon: "arrow.trianglehead.2.counterclockwise",
                        label: store.maxTurns.map { "\($0) \(store.settings.language.ui.turnsSuffix)" } ?? "∞ \(store.settings.language.ui.turnsSuffix)",
                        color: Color.kilnTextSecondary,
                        active: store.maxTurns != nil
                    ) {
                        cycleMaxTurns()
                    }
                    .help("Limit agentic turns")
                }

                // Thinking toggle
                ToolbarPill(
                    icon: "brain",
                    label: store.thinkingEnabled ? store.settings.language.ui.think : store.settings.language.ui.noThink,
                    color: store.thinkingEnabled ? .purple : Color.kilnTextSecondary,
                    active: store.thinkingEnabled
                ) {
                    store.thinkingEnabled.toggle()
                }
                .help("Extended thinking — lets Claude reason before responding")

                // Effort level — only meaningful with thinking on
                if store.thinkingEnabled {
                    ToolbarPill(
                        icon: "gauge.with.dots.needle.67percent",
                        label: localizedEffortLabel,
                        color: effortColor,
                        active: true
                    ) {
                        cycleEffort()
                    }
                    .help("Thinking effort: low / med / high / max")
                }

                // Extended context (only for Opus)
                if store.activeSession?.model.supportsExtendedContext == true {
                    ToolbarPill(
                        icon: "arrow.up.left.and.arrow.down.right",
                        label: store.extendedContext ? "1M ctx" : "200K ctx",
                        color: store.extendedContext ? .purple : Color.kilnTextSecondary,
                        active: store.extendedContext
                    ) {
                        store.extendedContext.toggle()
                    }
                    .help(store.extendedContext ? "1 million token context window" : "Standard 200K context window")
                }

                // Model picker lives in the chat header strip now —
                // duplicating it here made the composer toolbar noisy.

                Spacer()

                // Rate-limit meter — shows tokens-per-5min velocity
                RateLimitMeter()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
        }
    }

    private var permissionColor: Color {
        switch store.permissionMode {
        case .bypass: Color.kilnAccent
        case .ask: .blue
        case .deny: Color.kilnError
        }
    }

    private func cyclePermissions() {
        switch store.permissionMode {
        case .bypass: store.permissionMode = .ask
        case .ask: store.permissionMode = .deny
        case .deny: store.permissionMode = .bypass
        }
    }

    private var effortColor: Color {
        switch store.effortLevel {
        case .low: Color.kilnTextSecondary
        case .medium: .blue
        case .high: .purple
        case .max: Color(hex: 0xD97706)
        }
    }

    private var localizedEffortLabel: String {
        let ui = store.settings.language.ui
        switch store.effortLevel {
        case .low: return ui.effortLow
        case .medium: return ui.effortMed
        case .high: return ui.effortHigh
        case .max: return ui.effortMax
        }
    }

    private func cycleEffort() {
        switch store.effortLevel {
        case .low: store.effortLevel = .medium
        case .medium: store.effortLevel = .high
        case .high: store.effortLevel = .max
        case .max: store.effortLevel = .low
        }
    }

    private func cycleMaxTurns() {
        switch store.maxTurns {
        case nil: store.maxTurns = 5
        case 5: store.maxTurns = 10
        case 10: store.maxTurns = 25
        case 25: store.maxTurns = 50
        default: store.maxTurns = nil
        }
    }
}

// MARK: - Model Pill with Claude Icon

struct ModelPill: View {
    let model: ClaudeModel
    @EnvironmentObject var store: AppStore
    @State private var hovering = false

    private var selected: Bool {
        store.activeSession?.model == model
    }

    var body: some View {
        Button {
            store.setModel(model)
        } label: {
            HStack(spacing: 4) {
                // Claude sparkle icon
                ClaudeIcon(size: 10)
                    .foregroundStyle(selected ? Color.kilnBg : Color.kilnTextTertiary)
                Text(model.label)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
            }
            .foregroundStyle(selected ? Color.kilnBg : Color.kilnTextTertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(selected ? modelColor : (hovering ? Color.kilnSurfaceHover : Color.kilnSurface))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .help(model.fullId)
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(selected ? .clear : Color.kilnBorderSubtle, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var modelColor: Color {
        switch model {
        case .opus47: Color(hex: 0xD97706)   // deep amber
        case .sonnet46: Color.kilnAccent
        case .haiku45: Color(hex: 0x8B8B8E)  // muted gray
        }
    }
}

// MARK: - Claude Icon (sparkle shape)

struct ClaudeIcon: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "sparkle")
            .font(.system(size: size, weight: .semibold))
    }
}

// MARK: - Context Display

struct ContextDisplay: View {
    @EnvironmentObject var store: AppStore

    private var contextWindow: Int {
        guard let model = store.activeSession?.model else { return 200_000 }
        if store.extendedContext, let ext = model.extendedContextWindow {
            return ext
        }
        return model.contextWindow
    }

    private var totalTokens: Int {
        store.inputTokens + store.outputTokens
    }

    private var usagePercent: Double {
        guard contextWindow > 0 else { return 0 }
        return Double(totalTokens) / Double(contextWindow)
    }

    private var usageColor: Color {
        if usagePercent > 0.9 { return Color.kilnError }
        if usagePercent > 0.75 { return Color(hex: 0xF59E0B) }
        if usagePercent > 0.5 { return Color.kilnAccent }
        return Color.kilnTextTertiary
    }

    /// Above 75%, show the Compact button inline so the user can shed tokens
    /// before hitting the cliff. Above 90% the whole bar flashes red.
    private var shouldSuggestCompact: Bool {
        usagePercent > 0.75
    }

    var body: some View {
        HStack(spacing: 8) {
            // Token count + context bar
            if totalTokens > 0 {
                HStack(spacing: 4) {
                    // Horizontal progress bar (replaces the ring — easier to read at a glance)
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.kilnBorder)
                            .frame(width: 48, height: 4)
                        Capsule()
                            .fill(usageColor)
                            .frame(width: CGFloat(min(usagePercent, 1.0)) * 48, height: 4)
                    }

                    Text(formatTokens(totalTokens))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(usageColor)

                    Text("/")
                        .font(.system(size: 8))
                        .foregroundStyle(Color.kilnTextTertiary)

                    Text(formatTokens(contextWindow))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.kilnTextTertiary)

                    // Percentage — only when meaningfully used
                    if usagePercent > 0.25 {
                        Text("\(Int(usagePercent * 100))%")
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundStyle(usageColor)
                    }
                }
                .help("\(store.inputTokens) input + \(store.outputTokens) output tokens · \(Int(usagePercent * 100))% of context")
            }

            // Cost moved out — the per-session cost in the chat header
            // already covers this, no need to show it twice.

            // Compact button — appears when context is 75%+ full
            if shouldSuggestCompact {
                Button {
                    let s = store
                    Task { await s.compact() }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "rectangle.compress.vertical")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Compact")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(Color.kilnBg)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(usageColor)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
                .help("Ask Claude to compact this session's history")
            }

        }
    }

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fK", Double(n) / 1_000) }
        return "\(n)"
    }
}

// MARK: - Toolbar Pill

struct ToolbarPill: View {
    let icon: String
    let label: String
    let color: Color
    let active: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(active ? color : Color.kilnTextTertiary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(hovering ? Color.kilnSurfaceHover : Color.kilnSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(active ? color.opacity(0.3) : Color.kilnBorderSubtle, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// Subtle hover effect for the composer hint buttons.
struct HintHoverStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : (hovering ? 1.0 : 0.75))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.1), value: hovering)
    }
}

private struct CmdEnterSendModifier: ViewModifier {
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            content.keyboardShortcut(.return, modifiers: .command)
        } else {
            content
        }
    }
}

// MARK: - Undo Send Banner
//
// Shows a countdown strip above the composer while a queued message is
// within its cancellation window. Click Undo to pull the message back
// into the input field unchanged.

struct UndoSendBanner: View {
    let pending: AppStore.PendingSend
    let onUndo: () -> Void
    @EnvironmentObject var store: AppStore
    @State private var now: Date = .now

    private var remaining: Int {
        let total = store.settings.undoSendWindow
        let elapsed = Int(now.timeIntervalSince(pending.sentAt))
        return max(0, total - elapsed)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "paperplane.fill")
                .font(.system(size: 10))
                .foregroundStyle(Color.kilnAccent)
            Text("Sending in \(remaining)s")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.kilnText)
            Text("·")
                .foregroundStyle(Color.kilnTextTertiary)
            Text(String(pending.text.prefix(60)) + (pending.text.count > 60 ? "…" : ""))
                .font(.system(size: 11))
                .foregroundStyle(Color.kilnTextTertiary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            Button {
                onUndo()
            } label: {
                Text("Undo")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.kilnBg)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .background(Color.kilnAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("z", modifiers: .command)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.kilnSurface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.kilnAccent).frame(height: 2)
                .scaleEffect(x: CGFloat(remaining) / CGFloat(max(1, store.settings.undoSendWindow)), y: 1, anchor: .leading)
                .animation(.linear(duration: 0.1), value: remaining)
        }
        .onReceive(Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()) { _ in
            now = .now
        }
    }
}

// MARK: - Slash Command Popup
//
// Inline autocomplete that appears when the composer input starts with "/".
// Arrow keys navigate, Tab/Return accept, Escape dismisses. Clicking a row
// also accepts.

struct SlashCommandPopup: View {
    let matches: [SlashCommand]
    @Binding var selected: Int
    let onPick: (SlashCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Image(systemName: "command")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.kilnTextTertiary)
                Text("Slash command")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color.kilnTextTertiary)
                    .tracking(0.6)
                Spacer()
                Text("↑↓ navigate · ⏎ pick · esc close")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.kilnTextTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 1) {
                        // Identity by positional index so SwiftUI rebuilds
                        // each row's body when `matches` changes (shrinking
                        // the list used to leave stale rows cached under
                        // `.id(idx)` while ForEach tracked element.id —
                        // two conflicting identities). One signal only.
                        ForEach(Array(matches.enumerated()), id: \.offset) { idx, cmd in
                            SlashCommandRow(cmd: cmd, selected: idx == selected)
                                .id(idx)
                                .onTapGesture { onPick(cmd) }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 6)
                }
                .frame(maxHeight: 220)
                .onChange(of: selected) { _, newValue in
                    withAnimation(.linear(duration: 0.08)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
        }
        .background(Color.kilnSurface)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.kilnBorder).frame(height: 1)
        }
    }
}

private struct SlashCommandRow: View {
    let cmd: SlashCommand
    let selected: Bool

    private var kindTag: (label: String, color: Color)? {
        switch cmd.kind {
        case .builtin: return nil
        case .agent: return ("AGENT", Color.purple)
        case .kiln: return ("KILN", Color.kilnAccent)
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(cmd.label)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.kilnAccent)
                .frame(width: 110, alignment: .leading)
            Text(cmd.description)
                .font(.system(size: 11))
                .foregroundStyle(Color.kilnTextSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            if let tag = kindTag {
                Text(tag.label)
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(tag.color)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(tag.color.opacity(0.5), lineWidth: 1)
                    )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selected ? Color.kilnAccentMuted : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(selected ? Color.kilnAccent.opacity(0.3) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }
}

// MARK: - Expanded Composer Editor
//
// Full-size modal for writing long prompts. Opens when the composer's
// expand button is pressed. ⌘⏎ sends and dismisses.

struct ExpandedComposerEditor: View {
    @Binding var text: String
    let onSend: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "square.and.pencil")
                    .foregroundStyle(Color.kilnAccent)
                Text("Compose")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.kilnText)
                Spacer()
                Text("\(text.count) chars · \(text.split(separator: " ").count) words")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.kilnTextTertiary)
            }

            TextEditor(text: $text)
                .font(.system(size: 13))
                .foregroundStyle(Color.kilnText)
                .scrollContentBackground(.hidden)
                .padding(10)
                .frame(minHeight: 360, idealHeight: 420)
                .background(Color.kilnSurface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.kilnBorder, lineWidth: 1))

            HStack {
                Text("⌘⏎ send · Esc close")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.kilnTextTertiary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.kilnTextSecondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color.kilnSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .keyboardShortcut(.cancelAction)
                Button {
                    dismiss()
                    onSend()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 12))
                        Text("Send")
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.kilnBg)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Color.kilnAccent)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 520)
        .background(Color.kilnBg)
    }
}

// MARK: - Rate Limit Meter
//
// A compact indicator in the composer toolbar that tracks tokens-per-5min
// against a user-configurable soft cap. Turns amber at 70%, red when
// throttled. Tooltip explains what it's measuring.

struct RateLimitMeter: View {
    @ObservedObject private var tracker: RateLimitTracker = .shared
    @State private var now: Date = .now

    private var color: Color {
        if tracker.isRateLimited { return Color.kilnError }
        let r = tracker.usageRatio
        if r >= 1.0 { return Color.kilnError }
        if r >= 0.7 { return Color(hex: 0xF59E0B) }
        return Color.kilnTextTertiary
    }

    private var label: String {
        if tracker.isRateLimited {
            if let remaining = tracker.cooldownRemaining {
                return "cooling \(remaining)s"
            }
            return "rate limited"
        }
        let pct = Int(tracker.usageRatio * 100)
        return "\(pct)%"
    }

    private var shouldShow: Bool {
        tracker.isRateLimited || tracker.tokensLastFiveMin > 0
    }

    var body: some View {
        if shouldShow {
            HStack(spacing: 4) {
                Image(systemName: tracker.isRateLimited ? "exclamationmark.triangle.fill" : "gauge.with.dots.needle.67percent")
                    .font(.system(size: 9))
                    .foregroundStyle(color)
                Text(label)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundStyle(color)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(tracker.isRateLimited ? Color.kilnError.opacity(0.12) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .help(helpText)
            .onReceive(Timer.publish(every: 1.0, on: .main, in: .common).autoconnect()) { _ in
                // Force a redraw so the cooldown counter ticks.
                now = .now
            }
            .onTapGesture {
                if tracker.isRateLimited { tracker.clearRateLimited() }
            }
        }
    }

    private var helpText: String {
        if tracker.isRateLimited {
            return "Claude returned a rate-limit error recently. Click to dismiss."
        }
        let used = tracker.tokensLastFiveMin
        let cap = tracker.softCapTokensPerFiveMin
        return "Rate meter: \(used.formatted()) / \(cap.formatted()) tokens in the last 5 minutes. Configurable in settings."
    }
}
