import SwiftUI
import MarkdownUI
import UniformTypeIdentifiers

struct ChatView: View {
    @EnvironmentObject var store: AppStore
    @State private var chatDropHovering = false
    @State private var showInstructionsEditor = false
    @State private var findQuery: String = ""
    @State private var findMatchIndex: Int = 0
    /// Message id to scroll into view — set by the find bar, cleared after
    /// ScrollViewReader proxy.scrollTo runs.
    @State private var scrollToMessageId: String?

    /// Message ids whose plain-text body contains the find query.
    private var findMatches: [String] {
        let q = findQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard q.count >= 2, let session = store.activeSession else { return [] }
        return session.messages.compactMap { msg in
            for block in msg.blocks {
                let text: String
                switch block {
                case .text(let t): text = t
                case .thinking(let t): text = t
                case .trace(let entries): text = entries.map { "\($0.phase) \($0.title) \($0.detail)" }.joined(separator: " ")
                default: continue
                }
                if text.lowercased().contains(q) { return msg.id }
            }
            return nil
        }
    }

    private var disclaimerURL: URL? {
        switch store.activeSession?.model.provider {
        case .opencode:
            return URL(string: "https://opencode.ai/docs/")
        case .codex:
            return URL(string: "https://help.openai.com/en/articles/8313428-chatgpt-accuracy-and-limitations")
        case .none:
            return nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ConversationHeader { showInstructionsEditor = true }
            .sheet(isPresented: $showInstructionsEditor) {
                SessionInstructionsEditor()
                    .environmentObject(store)
                    .preferredColorScheme(Color.kilnPreferredColorScheme)
            }
            .sheet(isPresented: $store.showToolTimeline) {
                if let s = store.activeSession {
                    ToolTimelineSheet(session: s)
                        .preferredColorScheme(Color.kilnPreferredColorScheme)
                }
            }
            .sheet(isPresented: Binding(
                get: { store.diffSheetContent != nil },
                set: { if !$0 { store.diffSheetContent = nil } }
            )) {
                DiffSheet(content: store.diffSheetContent ?? "")
                    .preferredColorScheme(Color.kilnPreferredColorScheme)
            }

            Rectangle().fill(Color.kilnBorder).frame(height: 1)

            // Pinned messages strip — collapsible, click to jump
            if let session = store.activeSession,
               session.messages.contains(where: { $0.isPinned }) {
                PinnedMessagesStrip()
            }

            // In-session find bar (⌘F)
            if store.showInSessionFind {
                InSessionFindBar(
                    query: $findQuery,
                    matchIndex: $findMatchIndex,
                    matches: findMatches,
                    onJump: { id in scrollToMessageId = id },
                    onClose: {
                        store.showInSessionFind = false
                        findQuery = ""
                    }
                )
            }

            ChatTranscriptView(jumpTarget: $scrollToMessageId)
                .id(store.activeSessionId)

            Rectangle().fill(Color.kilnBorder).frame(height: 1)

            // Composer — hidden for read-only briefing sessions
            if store.activeSession?.readOnly == true {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.kilnTextTertiary)
                    Text("Read-only briefing")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.kilnTextTertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.kilnSurface)
            } else {
                ComposerView().id(store.activeSessionId)
            }
        }
        .background(Color.kilnBg)
        .overlay {
            if chatDropHovering {
                ZStack {
                    Color.kilnAccent.opacity(0.08)
                    VStack(spacing: 8) {
                        Image(systemName: "tray.and.arrow.down.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(Color.kilnAccent)
                        Text("Drop to attach")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Color.kilnText)
                    }
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .onDrop(of: [UTType.fileURL.identifier, UTType.image.identifier], isTargeted: $chatDropHovering) { providers in
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
                }
            }
            return handled
        }
    }
}

// MARK: - Live Assistant Row (unified streaming container)

struct LiveAssistantRow: View {
    @EnvironmentObject var store: AppStore

    private var assistantName: String {
        store.activeSession?.model.assistantName ?? "Assistant"
    }

    private var assistantBrand: ModelBrand {
        store.activeSession?.model.brand ?? .codex
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                // Avatar
                AssistantAvatar(brand: assistantBrand)

                VStack(alignment: .leading, spacing: 6) {
                    // Role label
                    Text(assistantName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.kilnAccent)

                    // Live thinking
                    if !store.thinkingText.isEmpty {
                        ThinkingRow(text: store.thinkingText, isStreaming: store.isBusy && store.streamingText.isEmpty)
                    }

                    if !store.traceEntries.isEmpty {
                        AgentTraceRow(entries: store.traceEntries, live: true)
                    }

                    // Live tool calls (rendered as proper ToolCallCards)
                    ForEach(store.activeToolCalls) { tool in
                        ToolCallCard(tool: tool)
                    }

                    // Streaming text. While tokens are arriving we render as
                    // plain Text — Markdown re-parses its whole content on
                    // every update which gets brutal for long replies. The
                    // finalized message (in MessageRow) uses Markdown.
                    if !store.streamingText.isEmpty {
                        Text(store.streamingText)
                            .font(.system(size: 13 * store.settings.fontScale.factor))
                            .foregroundStyle(Color.kilnText)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // Busy spinner when nothing else is showing
                    if store.isBusy && store.streamingText.isEmpty && store.activeToolCalls.isEmpty && store.thinkingText.isEmpty {
                        HStack(spacing: 8) {
                            ProgressView()
                                .scaleEffect(0.5)
                                .tint(Color.kilnAccent)
                            Text(store.settings.language.ui.thinking)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.kilnTextTertiary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12 * store.settings.density.padding)
        }
        .background(Color.kilnSurface.opacity(0.4))
    }
}

// MARK: - Thinking

// MARK: - Tool Call Card

struct ToolCallCard: View {
    let tool: ToolUseBlock
    @EnvironmentObject var store: AppStore
    @State private var expanded = false
    @State private var showResult = false

    private var statusColor: Color {
        if tool.isError { return Color.kilnError }
        if tool.isDone { return Color.kilnSuccess }
        return Color.kilnTextTertiary
    }

    private var toolIcon: String {
        let name = tool.name.lowercased()
        if name.contains("read") { return "doc.text.fill" }
        if name.contains("write") || name.contains("edit") { return "pencil" }
        if name.contains("bash") || name.contains("terminal") { return "terminal.fill" }
        if name.contains("glob") || name.contains("search") || name.contains("grep") { return "magnifyingglass" }
        if name.contains("web") { return "globe" }
        if name.contains("agent") { return "person.2.fill" }
        if name.contains("todo") { return "checklist" }
        return "wrench.and.screwdriver.fill"
    }

    private var inputJSONView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(store.settings.language.ui.input)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(Color.kilnTextTertiary)
                .tracking(0.5)
                .padding(.top, 8)
            ScrollView {
                Text(formatJSON(tool.input))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.kilnTextSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
            .padding(8)
            .background(Color.kilnBg)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            Button { expanded.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.kilnTextTertiary)
                        .frame(width: 12)
                    Image(systemName: toolIcon)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.kilnAccent)
                    Text(tool.name)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.kilnText)

                    // Show key param inline
                    if let summary = toolSummary {
                        Text(summary)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color.kilnTextTertiary)
                            .lineLimit(1)
                    }

                    Spacer()

                    // Duration badge — only shown once the call finished
                    // and we captured both timestamps. Kept deliberately
                    // subtle (tertiary) so it doesn't compete with the name.
                    if tool.isDone,
                       let started = tool.startedAt,
                       let finished = tool.completedAt {
                        Text(formatDuration(finished.timeIntervalSince(started)))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color.kilnTextTertiary)
                            .help("Elapsed: \(started.formatted(date: .omitted, time: .standard)) → \(finished.formatted(date: .omitted, time: .standard))")
                    }

                    // Status badge
                    if tool.isError {
                        HStack(spacing: 3) {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                            Text(store.settings.language.ui.error)
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(Color.kilnError)
                    } else if tool.isDone {
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .bold))
                            Text(store.settings.language.ui.done)
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(Color.kilnSuccess)
                    } else {
                        // Running — live elapsed timer.
                        ToolRunningIndicator()
                    }
                }
            }
            .buttonStyle(.plain)

            // Expanded content
            if expanded {
                Rectangle().fill(Color.kilnBorder).frame(height: 1)
                    .padding(.top, 8)

                // Diff viewer for Edit / Write / MultiEdit calls — render
                // before/after side-by-side instead of raw JSON soup.
                if let diff = EditDiffParser.parse(toolName: tool.name, rawInput: tool.input) {
                    EditDiffView(diff: diff)
                        .padding(.top, 8)
                } else {
                    inputJSONView
                }

                // Inline image preview — if Codex wrote or edited an
                // image file, show the result alongside the diff. Sniffs
                // file_path from the input JSON; only loads on-demand
                // once the tool has finished (to avoid thrashing disk
                // while Codex is mid-write). Relative paths are resolved
                // against the active session's workDir — NSImage(contentsOfFile:)
                // would otherwise use CWD and silently miss the file.
                if tool.isDone,
                   let imagePath = imagePathFromInput(tool.input),
                   let resolved = resolveToolPath(imagePath) {
                    ToolImagePreview(path: resolved, refreshKey: tool.completedAt)
                        .padding(.top, 8)
                }

                // Result section — collapsible. Long Bash output and file
                // reads were taking over the chat; default collapsed when
                // the result is bigger than 800 chars.
                if let result = tool.result, !result.isEmpty {
                    let isLong = result.count > 800
                    let isCollapsed = isLong && !showResult

                    VStack(alignment: .leading, spacing: 4) {
                        Button { showResult.toggle() } label: {
                            HStack(spacing: 4) {
                                if isLong {
                                    Image(systemName: showResult ? "chevron.down" : "chevron.right")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(Color.kilnTextTertiary)
                                }
                                Text(store.settings.language.ui.output)
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(tool.isError ? Color.kilnError : Color.kilnTextTertiary)
                                    .tracking(0.5)
                                Spacer()
                                Text("\(result.count) chars · \(lineCount(result)) lines")
                                    .font(.system(size: 9))
                                    .foregroundStyle(Color.kilnTextTertiary)
                                if isLong {
                                    Text(showResult ? "hide" : "show")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(Color.kilnAccent)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 6)
                        .disabled(!isLong)

                        if isCollapsed {
                            // Preview strip — first line so you know what's in there.
                            Text(firstLine(result))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color.kilnTextTertiary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.kilnBg.opacity(0.6))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        } else {
                            ScrollView {
                                Text(result)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(tool.isError ? Color.kilnError : Color.kilnTextSecondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 200)
                            .padding(8)
                            .background(tool.isError ? Color.kilnError.opacity(0.05) : Color.kilnBg)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(tool.isError ? Color.kilnError.opacity(0.2) : .clear, lineWidth: 1)
                            )
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(Color.kilnSurface)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(tool.isError ? Color.kilnError.opacity(0.3) : Color.kilnBorderSubtle, lineWidth: 1)
        )
    }

    /// Extract a short summary from the tool input for inline display
    private var toolSummary: String? {
        guard let data = tool.input.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }

        // Common patterns
        if let path = json["file_path"] as? String ?? json["path"] as? String {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        if let command = json["command"] as? String {
            return String(command.prefix(40))
        }
        if let pattern = json["pattern"] as? String {
            return "\"\(pattern)\""
        }
        if let query = json["query"] as? String {
            return String(query.prefix(30))
        }
        return nil
    }

    private func lineCount(_ s: String) -> Int {
        s.reduce(into: 1) { if $1 == "\n" { $0 += 1 } }
    }

    private func firstLine(_ s: String) -> String {
        s.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? s
    }

    /// Resolve a tool-supplied path against the active session's workdir.
    /// Codex commonly passes relative paths (`"logo.png"`, `"src/foo.ts"`);
    /// those need to be anchored to the session, not to Kiln's CWD.
    /// Absolute or tilde-prefixed paths are returned as-is (expanded).
    private func resolveToolPath(_ raw: String) -> String? {
        let expanded = (raw as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") { return expanded }
        guard let workDir = store.activeSession?.workDir else { return nil }
        return (workDir as NSString).appendingPathComponent(expanded)
    }

    /// Sniff a file_path/path key out of the tool input JSON and return
    /// it only if the extension looks like an image. We deliberately
    /// keep this narrow — png/jpg/gif/webp/heic/tiff/bmp/svg — so we
    /// don't try to render a 200MB tiff by accident later.
    private func imagePathFromInput(_ raw: String) -> String? {
        guard let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let path = (json["file_path"] as? String) ?? (json["path"] as? String)
        guard let p = path, !p.isEmpty else { return nil }
        let ext = (p as NSString).pathExtension.lowercased()
        let ok: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tiff", "tif", "bmp", "svg"]
        return ok.contains(ext) ? p : nil
    }

    /// Humanize a tool-call duration. Sub-second → ms; under a minute →
    /// seconds with one decimal; otherwise mm:ss. Keeps the header badge
    /// narrow no matter how slow a tool was.
    private func formatDuration(_ seconds: TimeInterval) -> String {
        if seconds < 0 { return "0ms" }
        if seconds < 1 { return "\(Int((seconds * 1000).rounded()))ms" }
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let m = Int(seconds) / 60
        let s = Int(seconds) % 60
        return String(format: "%d:%02d", m, s)
    }

    private func formatJSON(_ str: String) -> String {
        guard let data = str.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data),
              let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
              let result = String(data: pretty, encoding: .utf8)
        else { return str }
        return result
    }
}


// MARK: - Activity Badge (title bar)

struct ActivityBadge: View {
    @ObservedObject var store: AppStore

    private var activeTool: ToolUseBlock? {
        store.activeToolCalls.last(where: { !$0.isDone }) ?? store.activeToolCalls.last
    }

    private var label: String {
        if let tool = activeTool {
            let name = tool.name
            if let summary = toolSummaryFor(tool) {
                return "\(name) \(summary)"
            }
            return tool.isDone ? name : "\(name)…"
        }
        if !store.thinkingText.isEmpty { return store.settings.language.ui.thinkingLower }
        if !store.streamingText.isEmpty { return "writing…" }
        return "working…"
    }

    private var icon: String {
        if let tool = activeTool {
            let n = tool.name.lowercased()
            if n.contains("read") { return "doc.text" }
            if n.contains("write") || n.contains("edit") { return "pencil" }
            if n.contains("bash") { return "terminal" }
            if n.contains("grep") || n.contains("glob") || n.contains("search") { return "magnifyingglass" }
            if n.contains("web") { return "globe" }
            if n.contains("agent") { return "person.2" }
            return "wrench"
        }
        if !store.thinkingText.isEmpty { return "brain" }
        return "ellipsis"
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: icon)
                .font(.system(size: 8, weight: .semibold))
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .lineLimit(1)
            ProgressView()
                .scaleEffect(0.35)
                .tint(Color.kilnAccent)
        }
        .foregroundStyle(Color.kilnAccent)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.kilnAccent.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .animation(.easeInOut(duration: 0.15), value: label)
    }

    private func toolSummaryFor(_ tool: ToolUseBlock) -> String? {
        guard let data = tool.input.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let path = json["file_path"] as? String ?? json["path"] as? String {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        if let cmd = json["command"] as? String {
            return String(cmd.prefix(30))
        }
        if let pattern = json["pattern"] as? String {
            return "\"\(pattern.prefix(20))\""
        }
        return nil
    }
}

// MARK: - Error Row

struct ErrorRow: View {
    let error: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.kilnError)
            Text(error)
                .font(.system(size: 12))
                .foregroundStyle(Color.kilnError)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.kilnError.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.kilnError.opacity(0.2), lineWidth: 1))
    }
}

// MARK: - Suggestion Chips

struct SuggestionChips: View {
    let prompts: [SuggestionPrompt]
    @EnvironmentObject var store: AppStore

    var body: some View {
        if !store.settings.showFollowUpChips {
            EmptyView()
        } else {
            chipGrid
        }
    }

    @ViewBuilder
    private var chipGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.kilnAccent)
                Text("Follow-up research")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.kilnTextTertiary)
                    .tracking(0.8)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 8)], alignment: .leading, spacing: 8) {
                ForEach(prompts) { p in
                    Button { launch(p) } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: p.icon)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.kilnAccent)
                                .frame(width: 16, height: 16)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(p.label)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.kilnText)
                                    .multilineTextAlignment(.leading)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color.kilnTextTertiary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.kilnSurface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.kilnBorder, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PlainHoverButtonStyle())
                    .help(p.prompt)
                }
            }
        }
        .padding(.top, 4)
    }

    private func launch(_ p: SuggestionPrompt) {
        // Spin up a fresh non-read-only code session with tools enabled and
        // fire the prompt.
        store.createSession(
            workDir: store.settings.defaultWorkDir,
            model: nil,
            kind: .code,
            readOnly: false,
            name: p.label
        )
        store.sessionMode = .build
        store.permissionMode = .bypass
        Task { await store.sendMessage(p.prompt) }
    }
}

private struct PlainHoverButtonStyle: ButtonStyle {
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .brightness(hovering ? 0.05 : 0)
            .onHover { hovering = $0 }
            .animation(.easeInOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Pinned Messages Strip

struct PinnedMessagesStrip: View {
    @EnvironmentObject var store: AppStore
    @State private var expanded: Bool = true

    private var pinned: [ChatMessage] {
        store.activeSession?.messages.filter { $0.isPinned } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.kilnAccent)
                    Text("Pinned")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.kilnTextTertiary)
                        .tracking(0.6)
                    Text("\(pinned.count)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.kilnTextTertiary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.kilnTextTertiary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 4) {
                        ForEach(pinned) { msg in
                            pinnedRow(msg)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
                .frame(maxHeight: 140)
            }
        }
        .background(Color.kilnSurface.opacity(0.7))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.kilnBorder).frame(height: 1)
        }
    }

    @ViewBuilder
    private func pinnedRow(_ msg: ChatMessage) -> some View {
        Button {
            if let sid = store.activeSessionId {
                store.jumpTo(sessionId: sid, messageId: msg.id)
            }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Text(msg.role == .user ? "You" : msg.assistantName)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(msg.role == .user ? Color.kilnTextSecondary : Color.kilnAccent)
                    .frame(width: 38, alignment: .leading)
                Text(previewText(msg))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.kilnText)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer()
                Button {
                    if let sid = store.activeSessionId {
                        store.togglePinMessage(sessionId: sid, messageId: msg.id)
                    }
                } label: {
                    Image(systemName: "pin.slash")
                        .font(.system(size: 9))
                        .foregroundStyle(Color.kilnTextTertiary)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help("Unpin")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.kilnBg.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.kilnBorder, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func previewText(_ msg: ChatMessage) -> String {
        for block in msg.blocks {
            if case .text(let t) = block {
                return t.replacingOccurrences(of: "\n", with: " ")
            }
        }
        return "(no text)"
    }
}

// MARK: - Attachment Preview (inline in chat)
//
// Rendered as part of a user message when an attachment was sent. Images get
// a proper thumbnail; non-images get a file-type icon card. Click opens in
// the OS default app; right-click reveals in Finder.

struct AttachmentPreview: View {
    let attachment: ComposerAttachment
    @State private var hovering = false

    private var isImage: Bool {
        let ext = (attachment.name as NSString).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "gif", "webp", "tiff", "heic", "bmp"].contains(ext)
    }

    private var image: NSImage? {
        guard isImage, FileManager.default.fileExists(atPath: attachment.path) else { return nil }
        return NSImage(contentsOfFile: attachment.path)
    }

    private var fileIcon: String {
        let ext = (attachment.name as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return "doc.richtext"
        case "mp4", "mov", "m4v", "webm": return "film"
        case "mp3", "wav", "m4a", "flac": return "waveform"
        case "zip", "tar", "gz", "7z": return "doc.zipper"
        case "md", "txt", "log": return "doc.plaintext"
        case "swift", "py", "js", "ts", "go", "rs", "rb", "c", "cpp", "h", "java": return "chevron.left.forwardslash.chevron.right"
        case "json", "yaml", "yml", "toml", "xml": return "curlybraces"
        default: return "doc"
        }
    }

    private var humanSize: String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: attachment.path),
              let size = attrs[.size] as? NSNumber else { return nil }
        let bytes = size.int64Value
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: bytes)
    }

    var body: some View {
        Button {
            NSWorkspace.shared.open(URL(fileURLWithPath: attachment.path))
        } label: {
            if let img = image {
                imageCard(img)
            } else {
                fileCard()
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: attachment.path)) }
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: attachment.path)])
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(attachment.path, forType: .string)
            }
        }
        .help(attachment.path)
    }

    @ViewBuilder
    private func imageCard(_ img: NSImage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(nsImage: img)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 360, maxHeight: 280)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.kilnBorder, lineWidth: 1)
                )
            HStack(spacing: 6) {
                Image(systemName: "photo")
                    .font(.system(size: 9))
                    .foregroundStyle(Color.kilnTextTertiary)
                Text(attachment.name)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.kilnTextSecondary)
                    .lineLimit(1)
                if let s = humanSize {
                    Text("· \(s)")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.kilnTextTertiary)
                }
            }
        }
        .padding(6)
        .background(Color.kilnSurface.opacity(hovering ? 0.8 : 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    @ViewBuilder
    private func fileCard() -> some View {
        HStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.kilnAccentMuted)
                    .frame(width: 36, height: 36)
                Image(systemName: fileIcon)
                    .font(.system(size: 14))
                    .foregroundStyle(Color.kilnAccent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.kilnText)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(attachment.path)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.kilnTextTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let s = humanSize {
                        Text("·")
                            .foregroundStyle(Color.kilnTextTertiary)
                        Text(s)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.kilnTextTertiary)
                    }
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right")
                .font(.system(size: 10))
                .foregroundStyle(Color.kilnTextTertiary)
                .opacity(hovering ? 1 : 0.4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.kilnSurface.opacity(hovering ? 0.9 : 0.6))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.kilnBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: 420, alignment: .leading)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

// MARK: - Session Instructions Editor
//
// Per-session system prompt override. Prepended to the global system prompt
// when Codex runs. Useful for "in this session, always respond in Korean"
// or "treat every file as TypeScript" without touching global settings.

struct SessionInstructionsEditor: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var text: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "text.badge.plus")
                    .foregroundStyle(Color.kilnAccent)
                Text("Session Instructions")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.kilnText)
                Spacer()
                if let s = store.activeSession {
                    Text(s.name)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.kilnTextTertiary)
                        .lineLimit(1)
                }
            }

            Text("Prepended to the global system prompt for this session only. Leave blank to use defaults.")
                .font(.system(size: 11))
                .foregroundStyle(Color.kilnTextTertiary)

            TextEditor(text: $text)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(minHeight: 200)
                .background(Color.kilnBg)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.kilnBorder, lineWidth: 1))

            HStack {
                Button("Clear", role: .destructive) {
                    text = ""
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.kilnError)
                .font(.system(size: 11, weight: .medium))
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.kilnTextSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.kilnSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                Button("Save") {
                    guard let sid = store.activeSessionId,
                          let idx = store.sessions.firstIndex(where: { $0.id == sid }) else {
                        dismiss(); return
                    }
                    store.sessions[idx].sessionInstructions = text
                    Persistence.saveSession(store.sessions[idx])
                    dismiss()
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.kilnBg)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.kilnAccent)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(Color.kilnBg)
        .onAppear {
            text = store.activeSession?.sessionInstructions ?? ""
        }
    }
}

// MARK: - Patch Apply Bar

struct PatchApplyBar: View {
    let patch: DetectedPatch
    @EnvironmentObject var store: AppStore
    @State private var status: Status = .idle

    enum Status: Equatable {
        case idle
        case applying
        case applied
        case failed(String)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 11))
                .foregroundStyle(Color.kilnAccent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Unified diff")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.kilnText)
                if let f = patch.firstFile {
                    Text(patch.fileCount > 1 ? "\(f) · +\(patch.fileCount - 1) more" : f)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.kilnTextTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            statusView
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.kilnSurface)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.kilnBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .idle:
            Button {
                apply()
            } label: {
                Text("Apply")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.kilnBg)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.kilnAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .help("git apply in \(store.activeSession?.workDir ?? "?")")
        case .applying:
            HStack(spacing: 4) {
                ProgressView().scaleEffect(0.5).tint(Color.kilnAccent)
                Text("Applying…").font(.system(size: 10)).foregroundStyle(Color.kilnTextTertiary)
            }
        case .applied:
            HStack(spacing: 4) {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                Text("Applied").font(.system(size: 10, weight: .semibold))
            }
            .foregroundStyle(Color.kilnSuccess)
        case .failed(let msg):
            HStack(spacing: 4) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                Text(msg).font(.system(size: 10)).lineLimit(1).truncationMode(.tail)
            }
            .foregroundStyle(Color.kilnError)
            .help(msg)
        }
    }

    private func apply() {
        guard let workDir = store.activeSession?.workDir else { return }
        status = .applying
        Task.detached {
            let result = DetectedPatch.apply(patch, in: workDir)
            await MainActor.run {
                switch result {
                case .ok: status = .applied
                case .failed(let msg): status = .failed(msg)
                }
            }
        }
    }
}

// MARK: - Resume Interrupted Banner
//
// Inline banner shown when a session's last send was cut off by a process
// crash, app crash, or force-quit. Offers a one-click retry of the last
// user message, or a dismiss to ignore.

struct ResumeInterruptedBanner: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.arrow.circlepath")
                .font(.system(size: 12))
                .foregroundStyle(Color(hex: 0xF59E0B))
            VStack(alignment: .leading, spacing: 2) {
                Text("This session was interrupted")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.kilnText)
                Text("\((store.activeSession?.model.assistantName ?? "Assistant")) didn't finish the previous message. Resume to retry the last prompt, or dismiss to continue fresh.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.kilnTextSecondary)
            }
            Spacer()
            Button {
                Task { await store.retryLastMessage() }
            } label: {
                Text("Resume")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.kilnBg)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color.kilnAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            Button {
                store.dismissInterrupted()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.kilnTextTertiary)
                    .frame(width: 22, height: 22)
                    .background(Color.kilnSurface)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
        }
        .padding(12)
        .background(Color(hex: 0xF59E0B).opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(hex: 0xF59E0B).opacity(0.3), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - In-Session Find Bar
//
// ⌘F overlay for searching within the current chat. Arrow keys / return
// cycle through matches, escape closes. Matches are message ids that
// contain the query — we scroll them into view; full-text highlighting
// lives further down the roadmap.

struct InSessionFindBar: View {
    @Binding var query: String
    @Binding var matchIndex: Int
    let matches: [String]
    let onJump: (String) -> Void
    let onClose: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Color.kilnTextTertiary)
            TextField("Find in session…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Color.kilnText)
                .focused($focused)
                .onSubmit { cycle(direction: 1) }
                .onChange(of: query) { _, _ in
                    matchIndex = 0
                    if let first = matches.first { onJump(first) }
                }
                .onKeyPress(.escape) { onClose(); return .handled }

            if !matches.isEmpty {
                Text("\(matchIndex + 1) of \(matches.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.kilnTextTertiary)
            } else if query.count >= 2 {
                Text("No matches")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.kilnTextTertiary)
            }

            Button { cycle(direction: -1) } label: {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.kilnTextSecondary)
                    .frame(width: 22, height: 22)
                    .background(Color.kilnSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(matches.isEmpty)

            Button { cycle(direction: 1) } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.kilnTextSecondary)
                    .frame(width: 22, height: 22)
                    .background(Color.kilnSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("g", modifiers: .command)
            .disabled(matches.isEmpty)

            Button { onClose() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.kilnTextTertiary)
                    .frame(width: 22, height: 22)
                    .background(Color.kilnSurface)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.kilnSurface)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.kilnBorder).frame(height: 1) }
        .onAppear { focused = true }
    }

    private func cycle(direction: Int) {
        guard !matches.isEmpty else { return }
        matchIndex = (matchIndex + direction + matches.count) % matches.count
        onJump(matches[matchIndex])
    }
}

// MARK: - User / Codex Avatar
//
// 26pt circle rendered on every message row. Codex's side shows the
// accent-tinted Codex starburst. The user's side shows a custom image
// when one is set (from AvatarStore), otherwise falls back to the
// person.fill icon. Reacts live when the user picks a new avatar.

struct UserAssistantAvatar: View {
    let isUser: Bool
    let brand: ModelBrand
    @ObservedObject private var avatars: AvatarStore = .shared

    var body: some View {
        ZStack {
            Circle()
                .fill(isUser ? Color.kilnSurfaceElevated : Color.kilnAccentMuted)
                .frame(width: 26, height: 26)

            if isUser, let img = avatars.avatar {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 26, height: 26)
                    .clipShape(Circle())
            } else if isUser {
                Image(systemName: "person.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.kilnTextSecondary)
            } else {
                AssistantAvatar(brand: brand)
            }
        }
        .overlay(Circle().stroke(Color.kilnBorder, lineWidth: isUser && avatars.avatar != nil ? 1 : 0))
    }
}

struct AssistantAvatar: View {
    let brand: ModelBrand

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.kilnAccentMuted)
                .frame(width: 26, height: 26)

            ModelBrandIcon(brand: brand, size: 16)
        }
    }
}

// MARK: - Tool Running Indicator
//
// Shown in place of a static "running" label while a tool call is in
// flight. Ticks a live elapsed timer — more informative than a spinner
// alone, especially for Bash commands that take a while.

struct ToolRunningIndicator: View {
    @State private var startedAt: Date = .now
    @State private var now: Date = .now
    @EnvironmentObject var store: AppStore

    var body: some View {
        HStack(spacing: 4) {
            ProgressView()
                .scaleEffect(0.4)
                .tint(Color.kilnAccent)
            Text(store.settings.language.ui.running)
                .font(.system(size: 10))
                .foregroundStyle(Color.kilnTextTertiary)
            Text(Self.elapsed(now.timeIntervalSince(startedAt)))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.kilnTextTertiary)
        }
        .onAppear { startedAt = .now; now = .now }
        .onReceive(Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()) { _ in
            now = .now
        }
    }

    private static func elapsed(_ s: TimeInterval) -> String {
        if s < 1 { return String(format: "%.1fs", s) }
        if s < 60 { return String(format: "%ds", Int(s)) }
        let mins = Int(s) / 60
        let secs = Int(s) % 60
        return "\(mins)m\(secs)s"
    }
}

// MARK: - Working Directory Button
//
// Compact chip in the chat header showing the current session's workdir
// basename. Click opens NSOpenPanel to change it — useful when you fork a
// session and want to point the copy at a different repo without creating
// a fresh session from scratch.

struct WorkDirButton: View {
    let session: Session
    @EnvironmentObject var store: AppStore
    @ObservedObject private var bookmarks = WorkspaceBookmarkStore.shared
    @State private var hovering = false

    private var basename: String {
        URL(fileURLWithPath: session.workDir).lastPathComponent
    }

    var body: some View {
        Menu {
            Section("Switch to") {
                ForEach(bookmarks.bookmarks) { bm in
                    Button {
                        store.setWorkDir(session.id, workDir: bm.path)
                    } label: {
                        Label(bm.name, systemImage: bm.icon)
                    }
                }
            }

            Divider()

            Button("Browse…") {
                let panel = NSOpenPanel()
                panel.canChooseDirectories = true
                panel.canChooseFiles = false
                panel.canCreateDirectories = true
                panel.directoryURL = URL(fileURLWithPath: session.workDir)
                panel.prompt = "Use directory"
                if panel.runModal() == .OK, let url = panel.url {
                    store.setWorkDir(session.id, workDir: url.path)
                }
            }

            Button("Bookmark current…") {
                let path = session.workDir
                bookmarks.add(path: path)
            }

            if bookmarks.bookmarks.contains(where: { $0.path == session.workDir }) {
                Button("Remove this bookmark") {
                    if let bm = bookmarks.bookmarks.first(where: { $0.path == session.workDir }) {
                        bookmarks.remove(bm.id)
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder")
                    .font(.system(size: 9))
                Text(basename)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .semibold))
                    .opacity(0.7)
            }
            .foregroundStyle(hovering ? Color.kilnAccent : Color.kilnTextSecondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.kilnSurfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help(session.workDir)
    }
}

// Small badge next to WorkDirButton showing current git branch + a dot
// for uncommitted changes. Renders nothing when the workdir isn't a
// repo. Ticks every 10s via a timer so it notices mid-session commits
// without requiring the user to click anything.
struct BranchBadge: View {
    let workDir: String
    @State private var info: GitStatus.Info?
    // Matches GitStatus.ttl so we don't re-probe needlessly.
    private let timer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if let i = info, i.isRepo {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9))
                    Text(i.branch)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if i.dirtyCount > 0 {
                        // Dirty dot — orange to match accent, no count so it
                        // doesn't grow unbounded on messy repos.
                        Circle()
                            .fill(Color.kilnAccent)
                            .frame(width: 5, height: 5)
                            .help("\(i.dirtyCount) uncommitted change\(i.dirtyCount == 1 ? "" : "s")")
                    }
                }
                .foregroundStyle(Color.kilnTextSecondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.kilnSurfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .help("Branch: \(i.branch)\n\(i.dirtyCount) uncommitted")
            }
        }
        .onAppear { info = GitStatus.info(for: workDir) }
        .onChange(of: workDir) { _, newDir in info = GitStatus.info(for: newDir) }
        .onReceive(timer) { _ in info = GitStatus.info(for: workDir) }
    }
}

// MARK: - Inline image preview for Write/Edit tool calls

/// Thumbnail-style preview of a file Codex just wrote. Reloads when
/// `refreshKey` changes so repeated edits to the same path bust the
/// NSImage cache. Capped at 240pt tall so a huge screenshot doesn't
/// blow out the chat. Failures are silent — no point showing a
/// placeholder if the file doesn't exist yet.
struct ToolImagePreview: View {
    let path: String
    let refreshKey: Date?
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let img = image {
                VStack(alignment: .leading, spacing: 4) {
                    Text("PREVIEW")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.kilnTextTertiary)
                        .tracking(0.5)
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: 240, alignment: .leading)
                        .background(Color.kilnBg)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color.kilnBorderSubtle, lineWidth: 1)
                        )
                        .onTapGesture(count: 2) {
                            NSWorkspace.shared.open(URL(fileURLWithPath: path))
                        }
                        .help("Double-click to open in default viewer")
                }
            }
        }
        .onAppear(perform: reload)
        .onChange(of: refreshKey) { _, _ in reload() }
    }

    private func reload() {
        let expanded = (path as NSString).expandingTildeInPath
        // Off-main-thread load to keep scrolling smooth. NSImage can
        // decode large files synchronously and would otherwise hitch.
        DispatchQueue.global(qos: .userInitiated).async {
            let loaded = NSImage(contentsOfFile: expanded)
            DispatchQueue.main.async { self.image = loaded }
        }
    }
}

// MARK: - Tool-call timeline sheet

/// Summary of every tool call in the active session — name, count, total
/// duration, mean. Lets you see where time went in a long session at a
/// glance. Invoked via `/timeline`.
struct ToolTimelineSheet: View {
    let session: Session
    @Environment(\.dismiss) private var dismiss

    private struct Row: Identifiable {
        let id = UUID()
        let name: String
        let count: Int
        let total: TimeInterval
        let mean: TimeInterval
        let errors: Int
    }

    private var rows: [Row] {
        var buckets: [String: (count: Int, total: TimeInterval, errors: Int)] = [:]
        for msg in session.messages {
            for block in msg.blocks {
                guard case .toolUse(let t) = block else { continue }
                let dur: TimeInterval = {
                    guard let s = t.startedAt, let e = t.completedAt else { return 0 }
                    return max(0, e.timeIntervalSince(s))
                }()
                var entry = buckets[t.name] ?? (0, 0, 0)
                entry.count += 1
                entry.total += dur
                if t.isError { entry.errors += 1 }
                buckets[t.name] = entry
            }
        }
        return buckets.map { name, v in
            Row(name: name, count: v.count, total: v.total,
                mean: v.count > 0 ? v.total / Double(v.count) : 0,
                errors: v.errors)
        }
        .sorted { $0.total > $1.total }
    }

    private var grandTotal: TimeInterval {
        rows.reduce(0) { $0 + $1.total }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Tool timeline").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()

            if rows.isEmpty {
                Text("No tool calls in this session yet.")
                    .foregroundStyle(Color.kilnTextTertiary)
                    .padding(24)
                    .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(rows) { row in
                            HStack(spacing: 8) {
                                Text(row.name)
                                    .font(.system(size: 12, design: .monospaced))
                                    .frame(width: 140, alignment: .leading)
                                Text("\(row.count)×")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Color.kilnTextSecondary)
                                    .frame(width: 40, alignment: .trailing)
                                // Bar scaled against the largest total.
                                GeometryReader { geo in
                                    let w = grandTotal > 0
                                        ? geo.size.width * (row.total / grandTotal)
                                        : 0
                                    Rectangle()
                                        .fill(row.errors > 0 ? Color.kilnError.opacity(0.4) : Color.kilnAccent.opacity(0.35))
                                        .frame(width: max(1, w))
                                        .frame(maxHeight: .infinity, alignment: .leading)
                                }
                                .frame(height: 14)
                                Text(formatDur(row.total))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Color.kilnTextSecondary)
                                    .frame(width: 60, alignment: .trailing)
                                Text("avg \(formatDur(row.mean))")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Color.kilnTextTertiary)
                                    .frame(width: 70, alignment: .trailing)
                                if row.errors > 0 {
                                    Text("\(row.errors) err")
                                        .font(.system(size: 10))
                                        .foregroundStyle(Color.kilnError)
                                        .frame(width: 50, alignment: .trailing)
                                } else {
                                    Spacer().frame(width: 50)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            Divider()
                        }
                    }
                }
                HStack {
                    Spacer()
                    Text("Total: \(formatDur(grandTotal))")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.kilnTextSecondary)
                }
                .padding(12)
            }
        }
        .frame(width: 580, height: 420)
    }

    private func formatDur(_ s: TimeInterval) -> String {
        if s < 1 { return "\(Int((s * 1000).rounded()))ms" }
        if s < 60 { return String(format: "%.1fs", s) }
        let m = Int(s) / 60
        let r = Int(s) % 60
        return String(format: "%d:%02d", m, r)
    }
}

// MARK: - Git diff sheet

/// Plain-text diff viewer — no syntax highlighting yet, just a
/// monospace dump with simple line coloring for +/-. Good enough to
/// confirm what's about to be committed without leaving Kiln.
struct DiffSheet: View {
    let content: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Git diff").font(.system(size: 14, weight: .semibold))
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(content, forType: .string)
                    ToastCenter.shared.show("Diff copied", kind: .success)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .help("Copy diff to clipboard")
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            ScrollView {
                // LazyVStack so a 10k-line diff doesn't blow out the
                // view hierarchy up front — only the visible rows get
                // materialized.
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(content.split(separator: "\n", omittingEmptySubsequences: false).enumerated()), id: \.offset) { _, line in
                        Text(String(line).isEmpty ? " " : String(line))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(color(for: String(line)))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                }
                .padding(12)
            }
            .background(Color.kilnBg)
        }
        .frame(width: 780, height: 560)
    }

    private func color(for line: String) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return Color.kilnTextSecondary }
        if line.hasPrefix("+") { return Color.kilnSuccess }
        if line.hasPrefix("-") { return Color.kilnError }
        if line.hasPrefix("@@") { return Color.kilnAccent }
        if line.hasPrefix("#") { return Color.kilnTextTertiary }
        return Color.kilnText
    }
}
