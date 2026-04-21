import SwiftUI
import SwiftTerm

struct RightPanel: View {
    @State private var selectedTab: RightTab = .files
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar — indicator lives inside each tab so it aligns with
            // the tab's actual width (tabs have different natural widths).
            HStack(spacing: 1) {
                ForEach(RightTab.allCases) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        VStack(spacing: 4) {
                            HStack(spacing: 4) {
                                Image(systemName: tab.icon)
                                    .font(.system(size: 10))
                                Text(tab.localizedLabel(store.settings.language.ui))
                                    .font(.system(size: 11, weight: .medium))
                                    .fixedSize()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                            .foregroundStyle(selectedTab == tab ? Color.kilnAccent : Color.kilnTextTertiary)

                            Rectangle()
                                .fill(selectedTab == tab ? Color.kilnAccent : Color.clear)
                                .frame(height: 2)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("\(tab.label) panel")
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 6)
            .padding(.top, 4)
            .background(Color.kilnSurface)

            Rectangle().fill(Color.kilnBorder).frame(height: 1)

            // Content
            switch selectedTab {
            case .files:
                FileTreeView()
            case .git:
                GitPanelView()
            case .terminal:
                TerminalPanelView()
            case .activity:
                ActivityPanelView()
            case .tunnel:
                SessionTunnelPanel()
            }
        }
        .background(Color.kilnBg)
    }
}

enum RightTab: String, CaseIterable, Identifiable {
    case files
    case git
    case terminal
    case activity
    case tunnel

    var id: String { rawValue }

    var label: String {
        switch self {
        case .files: return "Files"
        case .git: return "Git"
        case .terminal: return "Terminal"
        case .activity: return "Activity"
        case .tunnel: return "Tunnel"
        }
    }

    func localizedLabel(_ ui: UIStrings) -> String {
        switch self {
        case .files: return ui.files
        case .git: return ui.git
        case .terminal: return ui.terminal
        case .activity: return ui.activity
        // No localized string yet — fall back to the English label.
        case .tunnel: return "Tunnel"
        }
    }

    var icon: String {
        switch self {
        case .files: "folder.fill"
        case .git: "arrow.triangle.branch"
        case .terminal: "terminal.fill"
        case .activity: "sparkles"
        case .tunnel: "network"
        }
    }
}

// MARK: - File Tree

/// One open buffer in the editor. Holds both the live `content` (what the
/// user is editing) and the `originalContent` (what was on disk when we
/// last read it) so we can compute a dirty flag and support Revert without
/// another disk hit.
struct OpenFile: Identifiable, Equatable {
    let id: String            // absolute path — paths are unique, so they double as ids
    var path: String
    var content: String
    var originalContent: String
    var isDirty: Bool { content != originalContent }

    init(path: String, content: String) {
        self.id = path
        self.path = path
        self.content = content
        self.originalContent = content
    }
}

struct FileTreeView: View {
    @EnvironmentObject var store: AppStore
    @State private var entries: [FileEntry] = []
    @State private var filter: String = ""

    // Multi-file editing state.
    //
    // `openFiles` is the ordered tab strip. `activeIndex` selects which one
    // the editor is showing. `showTree` lets the user jump back to the tree
    // view without closing their open files — the tabs survive the visit.
    @State private var openFiles: [OpenFile] = []
    @State private var activeIndex: Int?
    @State private var showTree: Bool = true

    // Real-time sync with Claude's edits. We track:
    //   - `syncedToolIds`: tool-use IDs we've already pulled into the
    //     editor, so we don't re-read the same file on every view update.
    //   - `claudeEditing`: paths currently being edited by an in-flight
    //     Edit/Write/MultiEdit — drives the pulse on matching tabs.
    //   - `externalConflict`: paths where Claude wrote while the user had
    //     unsaved edits. We don't clobber the buffer; we show a warning.
    @State private var syncedToolIds: Set<String> = []
    @State private var claudeEditing: Set<String> = []
    @State private var externalConflict: Set<String> = []
    // Pre-edit snapshot of each path Claude is about to touch. Captured on
    // the first in-flight Edit/Write/MultiEdit for that path, preserved
    // across subsequent edits, and cleared when the user Accepts or Reverts.
    @State private var preEditSnapshot: [String: String] = [:]
    // Paths with a pending Accept/Revert decision after Claude's tool chain
    // completed. Drives the banner in the editor header.
    @State private var pendingClaudeEdit: Set<String> = []
    // Paths currently shown in diff-view mode. Toggled from the banner.
    @State private var diffViewing: Set<String> = []
    // Per-file git status map for the current workdir. Refreshed whenever
    // the tree reloads or a Claude tool call finishes. Keyed by absolute
    // path so FileRow lookups are cheap.
    @State private var gitStatuses: [String: GitStatus.FileState] = [:]
    // Non-nil while a git-diff sheet is presented. The view reads both
    // sides lazily on sheet appearance so we don't pay for disk + shell-out
    // on every tree render.
    @State private var gitDiffPath: String?

    private var currentWorkDir: String {
        let dir = store.activeSession?.workDir ?? NSHomeDirectory()
        return dir.hasPrefix("~")
            ? dir.replacingOccurrences(of: "~", with: NSHomeDirectory(), range: dir.range(of: "~"))
            : dir
    }

    private var filteredEntries: [FileEntry] {
        if filter.isEmpty { return entries }
        let q = filter.lowercased()
        return entries.filter { $0.name.lowercased().contains(q) }
    }

    /// True when we have at least one file open AND the user isn't
    /// explicitly viewing the tree. Drives which of the two bodies renders.
    private var showingEditor: Bool {
        !showTree && activeIndex != nil && openFiles.indices.contains(activeIndex ?? -1)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab strip is pinned whenever any file is open, even while the
            // user is browsing the tree — it's the only way back to the
            // editor without losing their place.
            if !openFiles.isEmpty {
                EditorTabStrip(
                    openFiles: openFiles,
                    activeIndex: activeIndex,
                    showingTree: showTree,
                    editingPaths: claudeEditing,
                    conflictPaths: externalConflict,
                    onSelect: { idx in
                        activeIndex = idx
                        showTree = false
                    },
                    onClose: { idx in closeFile(at: idx) },
                    onToggleTree: { showTree.toggle() }
                )
                Rectangle().fill(Color.kilnBorder).frame(height: 1)
            }

            if showingEditor, let idx = activeIndex {
                let path = openFiles[idx].path

                // Header strip (breadcrumbs, dirty dot, save, language badge).
                HStack(spacing: 6) {
                    Image(systemName: iconForFile(URL(fileURLWithPath: path).lastPathComponent))
                        .font(.system(size: 10))
                        .foregroundStyle(Color.kilnAccent)
                    EditorBreadcrumbs(path: path, workDir: currentWorkDir)
                    if openFiles[idx].isDirty {
                        Circle()
                            .fill(Color.kilnAccent)
                            .frame(width: 6, height: 6)
                    }
                    Spacer()
                    if openFiles[idx].isDirty {
                        Button { saveActive() } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "square.and.arrow.down")
                                    .font(.system(size: 9))
                                Text(store.settings.language.ui.save)
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .foregroundStyle(Color.kilnAccent)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.kilnAccentMuted)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                        .help("\(store.settings.language.ui.save) (⌘S)")
                    }
                    Text(languageForFile(path))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.kilnTextTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.kilnSurfaceElevated)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.kilnSurface)
                .contextMenu { editorFileContextMenu(path: path) }

                if pendingClaudeEdit.contains(path) {
                    ClaudeEditBanner(
                        path: path,
                        hasSnapshot: preEditSnapshot[path] != nil,
                        isDiffing: diffViewing.contains(path),
                        onAccept: { acceptClaudeEdit(path: path) },
                        onRevert: { revertClaudeEdit(path: path) },
                        onToggleDiff: {
                            if diffViewing.contains(path) {
                                diffViewing.remove(path)
                            } else {
                                diffViewing.insert(path)
                            }
                        }
                    )
                }

                Rectangle().fill(Color.kilnBorder).frame(height: 1)

                if diffViewing.contains(path), let before = preEditSnapshot[path] {
                    DiffView(before: before, after: openFiles[idx].content)
                } else {
                // Editor — binding mutates openFiles[idx].content directly
                // so the dirty flag updates live and survives tab switches.
                CodeEditorView(
                    text: Binding(
                        get: { openFiles[idx].content },
                        set: { newValue in
                            guard openFiles.indices.contains(idx) else { return }
                            openFiles[idx].content = newValue
                        }
                    ),
                    language: languageForFile(path),
                    isEditable: true,
                    accentHex: store.settings.accentHex,
                    onSave: { saveActive() }
                )
                // ID the editor per-path so Monaco resets its buffer when
                // the user flips to a different tab. Without this, switching
                // tabs leaves the old text onscreen for a frame while the
                // binding catches up.
                .id(path)
                .contextMenu { editorFileContextMenu(path: path) }
                }
            } else {
                // Workdir header
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.kilnAccent)
                    Text(displayPath(currentWorkDir))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color.kilnText)
                        .lineLimit(1)
                        .truncationMode(.head)
                    if let gitInfo = GitStatus.info(for: currentWorkDir) {
                        // Branch + dirty count. Tiny pill so it reads at a
                        // glance without eating the workdir path width.
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.triangle.branch")
                                .font(.system(size: 8, weight: .semibold))
                            Text(gitInfo.branch)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                            if gitInfo.dirtyCount > 0 {
                                Text("·\(gitInfo.dirtyCount)")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundStyle(Color.kilnAccent)
                            }
                        }
                        .foregroundStyle(Color.kilnTextSecondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.kilnSurfaceElevated)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    Spacer()
                    Button {
                        Task { await loadDirectory() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.kilnTextSecondary)
                            .frame(width: 20, height: 20)
                            .background(Color.kilnSurfaceElevated)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.kilnSurface)

                // Filter
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.kilnTextTertiary)
                    TextField(store.settings.language.ui.filterFiles, text: $filter)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.kilnText)
                    if !filter.isEmpty {
                        Button { filter = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.kilnTextTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.kilnBg)
                .overlay(
                    Rectangle()
                        .fill(Color.kilnBorder)
                        .frame(height: 1), alignment: .bottom
                )

                // File tree
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if entries.isEmpty {
                            Text(store.settings.language.ui.loading)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.kilnTextTertiary)
                                .padding(12)
                        } else if filteredEntries.isEmpty {
                            Text("\(store.settings.language.ui.noFilesMatch) \"\(filter)\"")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.kilnTextTertiary)
                                .padding(12)
                        } else {
                            ForEach(filteredEntries) { entry in
                                FileRow(
                                    entry: entry,
                                    activePath: activeIndex.flatMap { openFiles.indices.contains($0) ? openFiles[$0].path : nil },
                                    gitStatuses: gitStatuses,
                                    onOpen: { path in openFile(at: path) },
                                    onShowGitDiff: { path in gitDiffPath = path },
                                    onPathRenamed: { old, new in renameOpenFile(from: old, to: new) },
                                    onPathDeleted: { path in closeOpenFile(at: path) },
                                    onSiblingsChanged: { Task { await loadDirectory() } },
                                    depth: 0
                                )
                            }
                        }
                    }
                    .padding(4)
                }
                .background(Color.kilnSurface)
            }
        }
        .task(id: currentWorkDir) {
            await loadDirectory()
        }
        // Live sync: any Edit/MultiEdit/Write against a path we've got open
        // pulses its tab while streaming, streams Write content into the
        // editor buffer live, and re-reads from disk when the tool call
        // finishes. We re-run on every render — cheap, and guarantees we
        // pick up streamed-input updates that don't shift the (id,isDone)
        // tuple.
        .onChange(of: toolCallSignature) { _, _ in syncWithActiveToolCalls() }
        .onChange(of: liveInputSignature) { _, _ in syncLiveWriteContent() }
        .onChange(of: store.quickOpenRequest) { _, new in
            // Quick Open hands us an absolute path through the store; open it
            // here, then clear the request so re-selecting the same file fires
            // onChange again.
            guard let path = new else { return }
            openFile(at: path)
            DispatchQueue.main.async { store.quickOpenRequest = nil }
        }
        .onAppear {
            syncWithActiveToolCalls()
            syncLiveWriteContent()
        }
        .background(editorShortcuts)
        .sheet(item: Binding(
            get: { gitDiffPath.map(GitDiffTarget.init) },
            set: { gitDiffPath = $0?.path }
        )) { target in
            GitDiffSheet(path: target.path, workDir: currentWorkDir)
        }
    }

    /// Hidden buttons that register editor-local keyboard shortcuts.
    /// Live in .background so they don't affect layout but stay in the
    /// responder chain whenever the editor view is on screen.
    @ViewBuilder
    private var editorShortcuts: some View {
        ZStack {
            Button("Close Tab") { closeActiveTab() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
            Button("Next Tab") { navigateTab(by: 1) }
                .keyboardShortcut("]", modifiers: [.command, .option])
            Button("Previous Tab") { navigateTab(by: -1) }
                .keyboardShortcut("[", modifiers: [.command, .option])
            Button("Toggle File Tree") { showTree.toggle() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Button("Save All") { saveAll() }
                .keyboardShortcut("s", modifiers: [.command, .option])
            Button("Reveal Active In Finder") { revealActiveInFinder() }
                .keyboardShortcut("r", modifiers: [.command, .option])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func closeActiveTab() {
        guard let idx = activeIndex else { return }
        closeFile(at: idx)
    }

    private func navigateTab(by delta: Int) {
        guard !openFiles.isEmpty, let idx = activeIndex else { return }
        let n = openFiles.count
        let next = ((idx + delta) % n + n) % n
        activeIndex = next
        showTree = false
    }

    private func saveAll() {
        for i in openFiles.indices where openFiles[i].isDirty {
            let f = openFiles[i]
            do {
                try f.content.write(toFile: f.path, atomically: true, encoding: .utf8)
                openFiles[i].originalContent = f.content
                pendingClaudeEdit.remove(f.path)
                preEditSnapshot.removeValue(forKey: f.path)
            } catch {
                print("Failed to save \(f.path): \(error)")
            }
        }
    }

    private func revealActiveInFinder() {
        guard let idx = activeIndex, openFiles.indices.contains(idx) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: openFiles[idx].path)])
    }

    /// Changes whenever a tool call is added/removed or flips isDone.
    private var toolCallSignature: String {
        store.activeToolCalls
            .map { "\($0.id):\($0.isDone ? 1 : 0)" }
            .joined(separator: ",")
    }

    /// Changes whenever streamed input length changes — lets us push
    /// partial Write content into the editor as it streams in.
    private var liveInputSignature: String {
        store.activeToolCalls
            .filter { $0.name == "Write" && !$0.isDone }
            .map { "\($0.id):\($0.input.count)" }
            .joined(separator: ",")
    }

    /// Walk the currently-running tool calls, find any Edit / MultiEdit / Write
    /// that targets a file we have open, and reflect its state in the editor.
    /// In-flight → pulse the tab. Finished → re-read the file (if the buffer
    /// is clean) or flag a conflict (if the user was editing the same file).
    private func syncWithActiveToolCalls() {
        var nowEditing: Set<String> = []
        var anyCompleted = false
        for call in store.activeToolCalls {
            guard call.name == "Edit" || call.name == "MultiEdit" || call.name == "Write" else { continue }
            // Use the strict parse — mid-stream we may only have a partial
            // path prefix, which would mis-flag siblings or spawn phantom tabs.
            guard let path = filePathIfComplete(fromToolInput: call.input) else { continue }

            // Snapshot the pre-edit content the first time we see a tool
            // call targeting this path (whether in-flight or already
            // complete). Preserved across subsequent edits so Revert takes
            // the user all the way back to the original.
            if preEditSnapshot[path] == nil {
                if let existing = openFiles.first(where: { $0.path == path }) {
                    preEditSnapshot[path] = existing.originalContent
                } else if call.name == "Write" && call.isDone {
                    // The tool already ran before we got a chance to
                    // observe it, so reading from disk would give us the
                    // post-write content — which would render as
                    // "identical before/after" in the diff viewer.
                    // For Write specifically, missing the window almost
                    // always means a new file, so "" is the right
                    // pre-edit state. If it was actually an overwrite we
                    // can't recover the old bytes, but the diff is still
                    // more honest as an all-additions hunk than as a
                    // silent no-op.
                    preEditSnapshot[path] = ""
                } else {
                    preEditSnapshot[path] = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
                }
            }

            if !call.isDone {
                nowEditing.insert(path)
                continue
            }

            if syncedToolIds.contains(call.id) { continue }
            syncedToolIds.insert(call.id)
            anyCompleted = true
            // Surface the Accept/Revert banner now that Claude committed
            // a change to this path.
            pendingClaudeEdit.insert(path)

            // Auto-open the file if the user didn't already have it open — so
            // the user sees what Claude just did without having to hunt for it.
            if !openFiles.contains(where: { $0.path == path }) {
                let content = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
                openFiles.append(OpenFile(path: path, content: content))
                if activeIndex == nil { activeIndex = openFiles.count - 1 }
                externalConflict.remove(path)
                continue
            }

            guard let idx = openFiles.firstIndex(where: { $0.path == path }) else { continue }
            if openFiles[idx].isDirty && openFiles[idx].content != openFiles[idx].originalContent {
                // True conflict: the user has unsaved edits that diverge from
                // both disk and Claude's stream. Flag it; don't clobber.
                externalConflict.insert(path)
            } else if let fresh = try? String(contentsOfFile: path, encoding: .utf8) {
                openFiles[idx].content = fresh
                openFiles[idx].originalContent = fresh
                externalConflict.remove(path)
            }
        }
        claudeEditing = nowEditing
        if anyCompleted {
            // Refresh the file tree so new files / renames / deletes show up.
            Task { await loadDirectory() }
        }
    }

    /// Stream Write tool `content` directly into the editor buffer as Claude
    /// emits it — so the user literally watches the file fill in. Skipped
    /// when the user has unsaved edits (we'd be fighting their typing).
    private func syncLiveWriteContent() {
        for call in store.activeToolCalls where call.name == "Write" && !call.isDone {
            // Only use the path once it's fully terminated — otherwise we'd
            // spawn a tab per character as the path itself streams in.
            guard let path = filePathIfComplete(fromToolInput: call.input) else { continue }
            // Auto-open the target so the stream is visible. For brand-new
            // files there's nothing on disk yet, so start with an empty buffer.
            let idx: Int
            if let existing = openFiles.firstIndex(where: { $0.path == path }) {
                idx = existing
            } else {
                let initial = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
                // Capture the pre-edit state NOW, before the stream below
                // overwrites originalContent. Otherwise the diff viewer's
                // before/after both end up pointing at Claude's post-write
                // content and render as identical. For a brand-new file
                // `initial` is "" — exactly the "all additions" hunk we
                // want the diff to show.
                if preEditSnapshot[path] == nil {
                    preEditSnapshot[path] = initial
                }
                openFiles.append(OpenFile(path: path, content: initial))
                idx = openFiles.count - 1
                if activeIndex == nil { activeIndex = idx }
                showTree = false
            }
            // If the buffer is in the middle of user edits, don't touch it.
            if openFiles[idx].isDirty && openFiles[idx].originalContent != openFiles[idx].content {
                // Only skip if the divergence is something we haven't streamed.
                // In practice claudeEditing flagging catches this visually.
                continue
            }
            if let content = streamedField("content", from: call.input) {
                if openFiles[idx].content != content {
                    openFiles[idx].content = content
                    // Keep originalContent tracking the streaming view so the
                    // dirty-dot doesn't flash on during streaming. It'll be
                    // reset to the disk version on completion anyway.
                    openFiles[idx].originalContent = content
                }
            }
        }
    }

    /// Best-effort extract of `file_path` from a streamed tool-input JSON.
    private func filePath(fromToolInput input: String) -> String? {
        if let data = input.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let p = obj["file_path"] as? String {
            return p
        }
        return streamedField("file_path", from: input)
    }

    /// Strict variant — only returns once the `file_path` quoted value is
    /// fully terminated. Used for auto-open decisions so we don't spawn a
    /// new tab per character while the path is still streaming.
    private func filePathIfComplete(fromToolInput input: String) -> String? {
        // Complete JSON parse — ideal case.
        if let data = input.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let p = obj["file_path"] as? String {
            return p
        }
        // Partial JSON: check that `"file_path":"..."` has its closing quote.
        guard let keyRange = input.range(of: "\"file_path\"") else { return nil }
        var i = keyRange.upperBound
        while i < input.endIndex, input[i].isWhitespace { i = input.index(after: i) }
        guard i < input.endIndex, input[i] == ":" else { return nil }
        i = input.index(after: i)
        while i < input.endIndex, input[i].isWhitespace { i = input.index(after: i) }
        guard i < input.endIndex, input[i] == "\"" else { return nil }
        i = input.index(after: i)
        while i < input.endIndex {
            let c = input[i]
            if c == "\\" {
                let n = input.index(after: i)
                guard n < input.endIndex else { return nil }
                i = input.index(after: n)
                continue
            }
            if c == "\"" {
                // Fully terminated — pull the value via the streaming walker.
                return streamedField("file_path", from: input)
            }
            i = input.index(after: i)
        }
        return nil
    }

    /// Pull a string field out of a JSON-ish input that may still be
    /// streaming. Handles the common case where the JSON is incomplete but
    /// the field we want is already fully emitted.
    private func streamedField(_ name: String, from input: String) -> String? {
        // Fast path: complete JSON.
        if let data = input.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let v = obj[name] as? String {
            return v
        }
        // Slow path: walk the string looking for `"name":"..."` accounting
        // for \" escapes and \n / \t / \\. Stops at the closing quote or at
        // end of string (whichever comes first), returning what we've got —
        // partial content is fine for live preview.
        let key = "\"\(name)\""
        guard let keyRange = input.range(of: key) else { return nil }
        var i = keyRange.upperBound
        // Skip whitespace and colon.
        while i < input.endIndex, input[i].isWhitespace { i = input.index(after: i) }
        guard i < input.endIndex, input[i] == ":" else { return nil }
        i = input.index(after: i)
        while i < input.endIndex, input[i].isWhitespace { i = input.index(after: i) }
        guard i < input.endIndex, input[i] == "\"" else { return nil }
        i = input.index(after: i)

        var out = ""
        while i < input.endIndex {
            let c = input[i]
            if c == "\\" {
                let n = input.index(after: i)
                guard n < input.endIndex else { break }
                switch input[n] {
                case "n": out.append("\n")
                case "t": out.append("\t")
                case "r": out.append("\r")
                case "\"": out.append("\"")
                case "\\": out.append("\\")
                case "/": out.append("/")
                default: out.append(input[n])
                }
                i = input.index(after: n)
                continue
            }
            if c == "\"" { break }
            out.append(c)
            i = input.index(after: i)
        }
        return out.isEmpty ? nil : out
    }

    private func displayPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    // MARK: - Multi-file operations
    //
    // `openFile` is the single entry point for "the user wants to open this
    // path." If it's already open, we focus it; if not, we read it off
    // disk and append a tab. Failures don't pop a dialog — the error text
    // lives in the buffer, which is arguably a debug feature.

    /// Update any open tab whose path is (a) the renamed path, or (b) a file
    /// nested under a renamed directory.
    private func renameOpenFile(from old: String, to new: String) {
        for i in openFiles.indices {
            let p = openFiles[i].path
            if p == old {
                openFiles[i].path = new
            } else if p.hasPrefix(old + "/") {
                openFiles[i].path = new + p.dropFirst(old.count)
            }
        }
    }

    /// Close any open tab whose path was deleted (or was inside a deleted dir).
    private func closeOpenFile(at path: String) {
        var i = openFiles.count - 1
        while i >= 0 {
            let p = openFiles[i].path
            if p == path || p.hasPrefix(path + "/") {
                closeFile(at: i)
            }
            i -= 1
        }
    }

    /// Dismiss the Claude-edit banner for this path. No content changes —
    /// the user is happy with what's on disk.
    private func acceptClaudeEdit(path: String) {
        pendingClaudeEdit.remove(path)
        preEditSnapshot.removeValue(forKey: path)
    }

    /// Restore the pre-edit snapshot to both the buffer and disk. If the
    /// file was empty-before (Claude created it), Revert deletes the file.
    private func revertClaudeEdit(path: String) {
        guard let original = preEditSnapshot[path] else {
            pendingClaudeEdit.remove(path)
            return
        }
        let fm = FileManager.default
        // If the path didn't exist pre-edit (Claude created it from nothing)
        // the best revert is to remove it. We detect that by checking if the
        // snapshot is empty AND the file existed only because Claude wrote
        // it — but we can't reliably distinguish "empty file" from "no
        // file", so we just write the snapshot back unconditionally and
        // trust the user to delete if wanted. Simpler and predictable.
        do {
            try original.write(toFile: path, atomically: true, encoding: .utf8)
        } catch {
            presentRevertError(error)
            return
        }
        if let idx = openFiles.firstIndex(where: { $0.path == path }) {
            openFiles[idx].content = original
            openFiles[idx].originalContent = original
        }
        externalConflict.remove(path)
        pendingClaudeEdit.remove(path)
        preEditSnapshot.removeValue(forKey: path)
        Task { await loadDirectory() }
    }

    private func presentRevertError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Revert failed"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func openFile(at path: String) {
        if let idx = openFiles.firstIndex(where: { $0.path == path }) {
            activeIndex = idx
            showTree = false
            return
        }
        let content: String
        do {
            content = try String(contentsOfFile: path, encoding: .utf8)
        } catch {
            content = "Failed to read: \(error.localizedDescription)"
        }
        openFiles.append(OpenFile(path: path, content: content))
        activeIndex = openFiles.count - 1
        showTree = false
    }

    private func closeFile(at idx: Int) {
        guard openFiles.indices.contains(idx) else { return }
        openFiles.remove(at: idx)
        if openFiles.isEmpty {
            activeIndex = nil
            showTree = true
            return
        }
        if let cur = activeIndex {
            if cur == idx {
                // Focus the neighbour on the left, or the new first if we
                // closed the very first tab.
                activeIndex = max(0, min(idx, openFiles.count - 1))
            } else if cur > idx {
                activeIndex = cur - 1
            }
        }
    }

    private func saveActive() {
        guard let idx = activeIndex, openFiles.indices.contains(idx) else { return }
        let f = openFiles[idx]
        do {
            try f.content.write(toFile: f.path, atomically: true, encoding: .utf8)
            openFiles[idx].originalContent = f.content    // clears isDirty
            // A manual save is an implicit accept of whatever Claude did.
            pendingClaudeEdit.remove(f.path)
            preEditSnapshot.removeValue(forKey: f.path)
        } catch {
            print("Failed to save: \(error)")
        }
    }

    /// Re-read the on-disk version (discarding edits). Picks up external
    /// modifications in addition to undoing unsaved work.
    private func revertActive() {
        guard let idx = activeIndex, openFiles.indices.contains(idx) else { return }
        let path = openFiles[idx].path
        if let fresh = try? String(contentsOfFile: path, encoding: .utf8) {
            openFiles[idx].content = fresh
            openFiles[idx].originalContent = fresh
        }
    }

    /// Context menu for the currently-open file. Used on both the header
    /// strip and the editor body as a fallback when Monaco's in-webview
    /// menu isn't what the user's trying to reach.
    @ViewBuilder
    private func editorFileContextMenu(path: String) -> some View {
        let idx = activeIndex
        let isDirty = idx.flatMap { openFiles.indices.contains($0) ? openFiles[$0].isDirty : nil } ?? false
        let content = idx.flatMap { openFiles.indices.contains($0) ? openFiles[$0].content : nil } ?? ""

        if isDirty {
            Button { saveActive() } label: { Label("Save", systemImage: "square.and.arrow.down") }
                .keyboardShortcut("s")
            Button(role: .destructive) { revertActive() }
                label: { Label("Revert Changes", systemImage: "arrow.uturn.backward") }
            Divider()
        }
        Button {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        } label: { Label("Reveal in Finder", systemImage: "folder") }
        Button {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        } label: { Label("Open with Default App", systemImage: "arrow.up.forward.app") }
        Divider()
        Button {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(path, forType: .string)
        } label: { Label("Copy Path", systemImage: "doc.on.doc") }
        Button {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString((path as NSString).lastPathComponent, forType: .string)
        } label: { Label("Copy Filename", systemImage: "doc.on.doc") }
        if !content.isEmpty {
            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(content, forType: .string)
            } label: { Label("Copy File Contents", systemImage: "text.quote") }
        }
        Divider()
        Button {
            if let idx = idx { closeFile(at: idx) }
        } label: { Label("Close File", systemImage: "xmark") }
    }

    private func languageForFile(_ path: String) -> String {
        // Special-case filenames whose extension alone doesn't tell the
        // whole story — Dockerfile, Makefile, .gitignore, etc. — then
        // fall through to an extension-based map. Monaco ships with all
        // of these built in; we just have to hand it the right id.
        let name = (path as NSString).lastPathComponent.lowercased()
        switch name {
        case "dockerfile", "containerfile": return "dockerfile"
        case "makefile", "gnumakefile": return "makefile"
        case "cmakelists.txt": return "cmake"
        case ".gitignore", ".dockerignore", ".npmignore", ".eslintignore",
             ".prettierignore": return "ignore"
        case "gemfile", "rakefile", "podfile", "brewfile": return "ruby"
        case "package.swift": return "swift"
        case ".env", ".env.local", ".env.production", ".env.development":
            return "ini"
        default: break
        }

        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        // Apple platforms
        case "swift": return "swift"
        case "m", "mm": return "objective-c"
        // Web
        case "js", "mjs", "cjs": return "javascript"
        case "ts", "mts", "cts": return "typescript"
        case "jsx": return "javascript"
        case "tsx": return "typescript"
        case "html", "htm", "xhtml": return "html"
        case "css": return "css"
        case "scss", "sass": return "scss"
        case "less": return "less"
        case "vue": return "html"
        case "svelte": return "html"
        case "graphql", "gql": return "graphql"
        // Data / config
        case "json", "jsonc", "json5": return "json"
        case "yaml", "yml": return "yaml"
        case "toml": return "ini"
        case "ini", "cfg", "conf": return "ini"
        case "xml", "plist", "storyboard", "xib", "xsd", "xsl": return "xml"
        case "csv", "tsv": return "plaintext"
        // Docs
        case "md", "markdown", "mdown", "mkd": return "markdown"
        case "rst": return "restructuredtext"
        case "tex", "latex": return "latex"
        // Shells
        case "sh", "bash", "zsh", "ksh", "fish": return "shell"
        case "bat", "cmd": return "bat"
        case "ps1", "psm1", "psd1": return "powershell"
        // Systems
        case "c", "h": return "c"
        case "cpp", "cc", "cxx", "hpp", "hh", "hxx", "h++": return "cpp"
        case "rs": return "rust"
        case "go": return "go"
        case "zig": return "zig"
        case "d": return "cpp"              // no D tokenizer, C/C++ is close
        case "nim", "nims": return "nim"
        case "v": return "systemverilog"    // .v is much more commonly Verilog than V
        case "odin": return "odin"
        case "gleam": return "gleam"
        case "cr": return "crystal"
        // JVM
        case "java": return "java"
        case "kt", "kts": return "kotlin"
        case "scala", "sc": return "scala"
        case "groovy", "gradle": return "groovy"
        case "clj", "cljs", "cljc", "edn": return "clojure"
        // Dynamic
        case "py", "pyw", "pyi": return "python"
        case "rb", "rbw": return "ruby"
        case "php", "phtml": return "php"
        case "pl", "pm": return "perl"
        case "lua": return "lua"
        case "tcl": return "tcl"
        case "r", "rmd": return "r"
        case "jl": return "julia"
        // Functional
        case "hs", "lhs": return "haskell"
        case "elm": return "elm"
        case "ex", "exs": return "elixir"
        case "erl", "hrl": return "erlang"
        case "ml", "mli": return "ocaml"
        case "fs", "fsi", "fsx": return "fsharp"
        case "lisp", "lsp", "cl": return "lisp"
        case "rkt": return "racket"
        case "scm", "ss": return "scheme"
        // .NET
        case "cs": return "csharp"
        case "vb": return "vb"
        case "razor", "cshtml": return "razor"
        case "xaml": return "xml"
        // Mobile / cross
        case "dart": return "dart"
        // Scientific / numeric
        case "f", "for", "f77", "f90", "f95", "f03", "f08": return "fortran"
        case "m.octave", "octave": return "matlab"
        case "mat": return "matlab"
        // Databases
        case "sql", "mysql", "pgsql": return "sql"
        // Hardware description
        case "vhd", "vhdl": return "vhdl"
        case "sv", "svh", "v.sv", "verilog": return "systemverilog"
        // Assembly
        case "asm", "s", "nasm": return "asm"
        // Makefiles / build
        case "mk", "make": return "makefile"
        case "cmake": return "cmake"
        case "bazel", "bzl", "starlark": return "python"
        // Infrastructure
        case "tf", "tfvars": return "hcl"
        case "hcl": return "hcl"
        case "nix": return "nix"
        // Misc
        case "proto": return "protobuf"
        case "coffee": return "coffeescript"
        case "pas", "pp.pas": return "pascal"
        case "apex", "cls", "trigger": return "apex"
        case "bicep": return "bicep"
        case "mdx": return "mdx"
        case "cls.apex": return "apex"
        case "abap": return "abap"
        case "pug", "jade": return "pug"
        case "hbs", "handlebars": return "handlebars"
        case "twig": return "twig"
        case "liquid": return "liquid"
        case "wgsl": return "wgsl"
        case "bb", "blade": return "html"
        case "thrift": return "thrift"
        case "sol": return "solidity"
        case "pp": return "puppet"
        case "dhall": return "dhall"
        case "log": return "log"
        case "diff", "patch": return "diff"
        case "txt", "text": return "plaintext"
        case "alg": return "algol"
        default: return ext.isEmpty ? "plaintext" : ext
        }
    }

    private func loadDirectory() async {
        guard let session = store.activeSession else { return }
        let workDir = session.workDir.hasPrefix("~")
            ? session.workDir.replacingOccurrences(of: "~", with: NSHomeDirectory(), range: session.workDir.range(of: "~"))
            : session.workDir

        do {
            let fm = FileManager.default
            let contents = try fm.contentsOfDirectory(atPath: workDir)
                .filter { !$0.hasPrefix(".") && $0 != "node_modules" && $0 != ".git" }
                .sorted()

            var result: [FileEntry] = []
            for name in contents {
                let path = (workDir as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                fm.fileExists(atPath: path, isDirectory: &isDir)
                result.append(FileEntry(name: name, path: path, isDirectory: isDir.boolValue))
            }

            result.sort { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }

            await MainActor.run { self.entries = result }
            await refreshGitStatuses(workDir: workDir)
        } catch {
            print("Failed to load directory: \(error)")
        }
    }

    /// Probe git for per-file status and publish to `gitStatuses`. Runs
    /// off the main actor so the shell-out doesn't stall the UI thread;
    /// the result is hopped back on.
    private func refreshGitStatuses(workDir: String) async {
        let map = await Task.detached(priority: .utility) {
            GitStatus.invalidate(workDir: workDir)
            return GitStatus.fileStatuses(for: workDir)
        }.value
        await MainActor.run { self.gitStatuses = map }
    }
}

struct FileRow: View {
    let entry: FileEntry
    /// Absolute path of the currently-focused tab, if any — used only for
    /// highlighting the row. The row doesn't read or write files itself;
    /// that all routes through `onOpen`.
    let activePath: String?
    /// Per-file git status, keyed by absolute path. Rendered as a single-
    /// letter marker next to the filename ("M", "A", "U", etc.) colored
    /// by state. Empty dict = not a repo or nothing changed.
    var gitStatuses: [String: GitStatus.FileState] = [:]
    let onOpen: (String) -> Void
    /// Called when the user picks "Show Diff vs HEAD" from the context
    /// menu. Parent handles presentation since the sheet outlives this row.
    var onShowGitDiff: (String) -> Void = { _ in }
    /// Notify the tree when a file gets renamed so open-tabs can update.
    var onPathRenamed: (String, String) -> Void = { _, _ in }
    /// Notify the tree when a path is deleted so open-tabs can close.
    var onPathDeleted: (String) -> Void = { _ in }
    /// Called when this row's siblings change (rename/delete/create at this
    /// level) — the owning parent re-reads its children list.
    var onSiblingsChanged: () -> Void = {}
    let depth: Int

    @EnvironmentObject var store: AppStore
    @State private var expanded = false
    @State private var children: [FileEntry]?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if entry.isDirectory {
                    expanded.toggle()
                    if expanded && children == nil { loadChildren() }
                } else {
                    onOpen(entry.path)
                }
            } label: {
                HStack(spacing: 4) {
                    Spacer().frame(width: CGFloat(depth) * 14)
                    if entry.isDirectory {
                        Image(systemName: expanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(Color.kilnTextTertiary)
                            .frame(width: 12)
                    } else {
                        Spacer().frame(width: 12)
                    }
                    Image(systemName: entry.isDirectory
                          ? (expanded ? "folder.fill" : "folder.fill")
                          : iconForFile(entry.name))
                        .font(.system(size: 10))
                        .foregroundStyle(entry.isDirectory ? Color.kilnAccent.opacity(0.7) : Color.kilnTextTertiary)
                        .frame(width: 14)
                    Text(entry.name)
                        .font(.system(size: 11))
                        .foregroundStyle(gitTintForName(activePath == entry.path))
                        .lineLimit(1)
                    Spacer()
                    if let marker = gitMarker {
                        Text(marker.letter)
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(marker.color)
                            .frame(width: 12, alignment: .trailing)
                    }
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(activePath == entry.path ? Color.kilnAccentMuted :
                                (hovering ? Color.kilnSurfaceHover : .clear))
                )
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .contextMenu {
                if !entry.isDirectory {
                    Button { onOpen(entry.path) }
                        label: { Label("Open", systemImage: "doc.text") }
                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: entry.path))
                    } label: { Label("Open with Default App", systemImage: "arrow.up.forward.app") }
                    if let state = gitStatuses[entry.path], state != .untracked {
                        Button { onShowGitDiff(entry.path) }
                            label: { Label("Show Diff vs HEAD", systemImage: "arrow.triangle.2.circlepath") }
                    }
                    Button {
                        store.composerPrefill = "About `\(entry.path)`:\n\n"
                    } label: { Label("Ask Claude About This File", systemImage: "sparkles") }
                    Divider()
                }
                if entry.isDirectory {
                    Button { createInside(isDirectory: false) }
                        label: { Label("New File…", systemImage: "doc.badge.plus") }
                    Button { createInside(isDirectory: true) }
                        label: { Label("New Folder…", systemImage: "folder.badge.plus") }
                    Divider()
                }
                Button { renameEntry() }
                    label: { Label("Rename…", systemImage: "pencil") }
                Button { duplicateEntry() }
                    label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                Divider()
                Button(role: .destructive) { deleteEntry() }
                    label: { Label("Move to Trash", systemImage: "trash") }
                Divider()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
                } label: { Label("Reveal in Finder", systemImage: "folder") }
                Divider()
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(entry.path, forType: .string)
                } label: { Label("Copy Path", systemImage: "doc.on.doc") }
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(entry.name, forType: .string)
                } label: { Label("Copy Name", systemImage: "doc.on.doc") }
            }

            if expanded, let children {
                ForEach(children) { child in
                    FileRow(
                        entry: child,
                        activePath: activePath,
                        gitStatuses: gitStatuses,
                        onOpen: onOpen,
                        onShowGitDiff: onShowGitDiff,
                        onPathRenamed: onPathRenamed,
                        onPathDeleted: onPathDeleted,
                        onSiblingsChanged: { loadChildren() },
                        depth: depth + 1
                    )
                }
            }
        }
    }

    // MARK: Git markers
    //
    // Directory rows summarize the worst child state (untracked < modified
    // < conflicted). File rows show their own state directly. Colors match
    // the Git panel's palette for consistency.

    private struct Marker {
        let letter: String
        let color: SwiftUI.Color
    }

    private var gitMarker: Marker? {
        guard !gitStatuses.isEmpty else { return nil }
        if entry.isDirectory {
            // Summarize children: show the "strongest" state nested under
            // this directory so the user can see at a glance which folders
            // contain changes without expanding every branch.
            let prefix = entry.path + "/"
            var strongest: GitStatus.FileState?
            for (path, state) in gitStatuses where path.hasPrefix(prefix) {
                strongest = combine(strongest, state)
            }
            return strongest.map { Marker(letter: $0.marker, color: color(for: $0).opacity(0.55)) }
        }
        guard let state = gitStatuses[entry.path] else { return nil }
        return Marker(letter: state.marker, color: color(for: state))
    }

    /// Combine two file states into the "stronger" one for directory
    /// summarization. Conflicted beats everything; modified/added/deleted
    /// beat untracked.
    private func combine(_ a: GitStatus.FileState?, _ b: GitStatus.FileState) -> GitStatus.FileState {
        guard let a else { return b }
        func rank(_ s: GitStatus.FileState) -> Int {
            switch s {
            case .conflicted: return 5
            case .deleted: return 4
            case .modified: return 3
            case .renamed: return 3
            case .added: return 2
            case .untracked: return 1
            }
        }
        return rank(b) > rank(a) ? b : a
    }

    private func color(for state: GitStatus.FileState) -> SwiftUI.Color {
        switch state {
        case .modified, .renamed: return Color.kilnAccent
        case .added:              return Color.kilnSuccess
        case .deleted:            return Color.kilnError
        case .untracked:          return Color.kilnTextTertiary
        case .conflicted:         return Color.kilnError
        }
    }

    private func gitTintForName(_ isActive: Bool) -> SwiftUI.Color {
        if isActive { return Color.kilnAccent }
        // Dim untracked file names so changed files stand out, without
        // making them hard to read.
        if let state = gitStatuses[entry.path], case .untracked = state {
            return Color.kilnTextSecondary
        }
        return Color.kilnText
    }

    private func loadChildren() {
        let fm = FileManager.default
        do {
            let contents = try fm.contentsOfDirectory(atPath: entry.path)
                .filter { !$0.hasPrefix(".") && $0 != "node_modules" }
                .sorted()

            var result: [FileEntry] = []
            for name in contents {
                let path = (entry.path as NSString).appendingPathComponent(name)
                var isDir: ObjCBool = false
                fm.fileExists(atPath: path, isDirectory: &isDir)
                result.append(FileEntry(name: name, path: path, isDirectory: isDir.boolValue))
            }
            result.sort { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            children = result
        } catch {
            print("Failed to load children: \(error)")
        }
    }

    // MARK: - File operations
    //
    // All of these run on the main thread because they're kicked off by the
    // context menu. For very large trees this could block briefly — good
    // enough for a single-node op.

    private func renameEntry() {
        let alert = NSAlert()
        alert.messageText = "Rename"
        alert.informativeText = "New name for \"\(entry.name)\""
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = entry.name
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newName.isEmpty, newName != entry.name else { return }
        let parent = (entry.path as NSString).deletingLastPathComponent
        let newPath = (parent as NSString).appendingPathComponent(newName)
        do {
            try FileManager.default.moveItem(atPath: entry.path, toPath: newPath)
            onPathRenamed(entry.path, newPath)
            onSiblingsChanged()
        } catch {
            presentError("Rename failed", error)
        }
    }

    private func duplicateEntry() {
        let parent = (entry.path as NSString).deletingLastPathComponent
        let ext = (entry.name as NSString).pathExtension
        let stem = (entry.name as NSString).deletingPathExtension
        var n = 1
        var candidate: String
        repeat {
            let base = n == 1 ? "\(stem) copy" : "\(stem) copy \(n)"
            candidate = ext.isEmpty ? base : "\(base).\(ext)"
            n += 1
        } while FileManager.default.fileExists(atPath: (parent as NSString).appendingPathComponent(candidate))
        let dest = (parent as NSString).appendingPathComponent(candidate)
        do {
            try FileManager.default.copyItem(atPath: entry.path, toPath: dest)
            onSiblingsChanged()
        } catch {
            presentError("Duplicate failed", error)
        }
    }

    private func deleteEntry() {
        let alert = NSAlert()
        alert.messageText = "Move \"\(entry.name)\" to Trash?"
        alert.informativeText = "You can restore it from the Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileManager.default.trashItem(at: URL(fileURLWithPath: entry.path), resultingItemURL: nil)
            onPathDeleted(entry.path)
            onSiblingsChanged()
        } catch {
            presentError("Delete failed", error)
        }
    }

    private func createInside(isDirectory: Bool) {
        let alert = NSAlert()
        alert.messageText = isDirectory ? "New Folder" : "New File"
        alert.informativeText = "Name"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = isDirectory ? "untitled folder" : "untitled.txt"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let dest = (entry.path as NSString).appendingPathComponent(name)
        let fm = FileManager.default
        do {
            if isDirectory {
                try fm.createDirectory(atPath: dest, withIntermediateDirectories: false)
            } else {
                fm.createFile(atPath: dest, contents: Data())
            }
            // Expand the directory so the new item is visible, then reload.
            if !expanded { expanded = true }
            loadChildren()
        } catch {
            presentError("Create failed", error)
        }
    }

    private func presentError(_ title: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}

// MARK: - Claude edit banner
//
// Appears under the file header after Claude finishes an Edit/Write/
// MultiEdit. Accept dismisses it; Revert restores the pre-edit snapshot
// to both the buffer and disk. Disappears automatically when the user
// manually saves — handled by the caller clearing `pendingClaudeEdit`.

struct ClaudeEditBanner: View {
    let path: String
    let hasSnapshot: Bool
    let isDiffing: Bool
    let onAccept: () -> Void
    let onRevert: () -> Void
    let onToggleDiff: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.kilnAccent)
            Text("Claude edited this file")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.kilnText)
            Spacer()
            Button(action: onToggleDiff) {
                HStack(spacing: 3) {
                    Image(systemName: isDiffing ? "doc.text" : "rectangle.split.2x1")
                        .font(.system(size: 9, weight: .semibold))
                    Text(isDiffing ? "Edit" : "Diff")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(Color.kilnTextSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.kilnSurfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .disabled(!hasSnapshot)
            .help(isDiffing ? "Return to editor" : "Show before/after diff")

            Button(action: onRevert) {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Revert")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(Color.kilnTextSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.kilnSurfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .disabled(!hasSnapshot)
            .help(hasSnapshot ? "Restore the pre-edit version to disk" : "No snapshot available")

            Button(action: onAccept) {
                HStack(spacing: 3) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .semibold))
                    Text("Accept")
                        .font(.system(size: 10, weight: .medium))
                }
                .foregroundStyle(Color.kilnBg)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.kilnAccent)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .help("Dismiss this banner and keep the change")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.kilnAccentMuted)
    }
}

// MARK: - Diff view
//
// Line-level unified diff rendered as a scrollable list of colored rows.
// LCS-based — simple, correct for the common cases, O(n·m) memory which
// is fine for source files (hundreds of lines). For huge files this
// would need Myers, but Claude's edits are typically small enough.

enum DiffLineKind { case context, add, remove }

struct DiffLine: Identifiable {
    let id = UUID()
    let kind: DiffLineKind
    let text: String
    let oldNumber: Int?
    let newNumber: Int?
}

struct DiffView: View {
    let before: String
    let after: String

    private var lines: [DiffLine] {
        Self.diff(
            before: before.components(separatedBy: "\n"),
            after: after.components(separatedBy: "\n")
        )
    }

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(lines) { line in
                    DiffRow(line: line)
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.kilnBg)
    }

    /// Classic LCS back-tracked into a unified line list.  (Actual impl below.)
    static func marker(_ k: DiffLineKind) -> String {
        switch k { case .add: return "+"; case .remove: return "−"; case .context: return " " }
    }
    static func rowBackground(_ k: DiffLineKind) -> SwiftUI.Color {
        switch k {
        case .add:     return SwiftUI.Color.green.opacity(0.12)
        case .remove:  return SwiftUI.Color.red.opacity(0.12)
        case .context: return SwiftUI.Color.clear
        }
    }
    static func rowTextColor(_ k: DiffLineKind) -> SwiftUI.Color {
        switch k {
        case .add:     return SwiftUI.Color.green.opacity(0.95)
        case .remove:  return SwiftUI.Color.red.opacity(0.9)
        case .context: return SwiftUI.Color.kilnText
        }
    }

    static func diff(before: [String], after: [String]) -> [DiffLine] {
        let n = before.count, m = after.count
        // lcs[i][j] = length of LCS of before[i...] and after[j...]
        var lcs = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                if before[i] == after[j] {
                    lcs[i][j] = lcs[i + 1][j + 1] + 1
                } else {
                    lcs[i][j] = max(lcs[i + 1][j], lcs[i][j + 1])
                }
            }
        }
        var out: [DiffLine] = []
        var i = 0, j = 0, oldN = 1, newN = 1
        while i < n && j < m {
            if before[i] == after[j] {
                out.append(DiffLine(kind: .context, text: before[i], oldNumber: oldN, newNumber: newN))
                i += 1; j += 1; oldN += 1; newN += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                out.append(DiffLine(kind: .remove, text: before[i], oldNumber: oldN, newNumber: nil))
                i += 1; oldN += 1
            } else {
                out.append(DiffLine(kind: .add, text: after[j], oldNumber: nil, newNumber: newN))
                j += 1; newN += 1
            }
        }
        while i < n {
            out.append(DiffLine(kind: .remove, text: before[i], oldNumber: oldN, newNumber: nil))
            i += 1; oldN += 1
        }
        while j < m {
            out.append(DiffLine(kind: .add, text: after[j], oldNumber: nil, newNumber: newN))
            j += 1; newN += 1
        }
        return out
    }
}

struct DiffRow: View {
    let line: DiffLine
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(line.oldNumber.map(String.init) ?? "")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.kilnTextTertiary)
                .frame(width: 40, alignment: .trailing)
                .padding(.trailing, 6)
            Text(line.newNumber.map(String.init) ?? "")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.kilnTextTertiary)
                .frame(width: 40, alignment: .trailing)
                .padding(.trailing, 8)
            Text(DiffView.marker(line.kind))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(DiffView.rowTextColor(line.kind))
                .frame(width: 14)
            Text(line.text.isEmpty ? " " : line.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(DiffView.rowTextColor(line.kind))
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DiffView.rowBackground(line.kind))
    }
}

// MARK: - Editor breadcrumbs
//
// Path components above the editor, rendered as separated, clickable
// segments. Each folder component opens that folder in Finder; the last
// segment (the file itself) reveals it. Keeps the header compact by
// truncating the middle when the path is deep, showing at most a head,
// a middle ellipsis, and the last two components.

struct EditorBreadcrumbs: View {
    let path: String
    let workDir: String

    private var components: [(name: String, fullPath: String)] {
        // Strip the workDir prefix so breadcrumbs show the project-relative
        // path rather than `/Users/you/.../project/src/...`.
        let rel: String = {
            if path.hasPrefix(workDir + "/") {
                return String(path.dropFirst(workDir.count + 1))
            }
            return path
        }()
        let parts = rel.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var out: [(String, String)] = []
        var acc = workDir
        for part in parts {
            acc = (acc as NSString).appendingPathComponent(part)
            out.append((part, acc))
        }
        return out
    }

    /// Collapse the middle when the trail is deep. Keeps the first
    /// component and the last two so context ("src / .../ Views / Foo.swift")
    /// is always legible.
    private var displayComponents: [(name: String, fullPath: String, isEllipsis: Bool)] {
        let all = components
        guard all.count > 4 else {
            return all.map { ($0.name, $0.fullPath, false) }
        }
        var out: [(String, String, Bool)] = []
        out.append((all[0].name, all[0].fullPath, false))
        out.append(("…", all[all.count - 3].fullPath, true))
        out.append((all[all.count - 2].name, all[all.count - 2].fullPath, false))
        out.append((all[all.count - 1].name, all[all.count - 1].fullPath, false))
        return out
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(displayComponents.enumerated()), id: \.offset) { idx, comp in
                if idx > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8))
                        .foregroundStyle(Color.kilnTextTertiary)
                }
                Button {
                    if comp.isEllipsis { return }
                    let url = URL(fileURLWithPath: comp.fullPath)
                    if idx == displayComponents.count - 1 {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } else {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Text(comp.name)
                        .font(.system(size: 11, weight: idx == displayComponents.count - 1 ? .semibold : .regular))
                        .foregroundStyle(idx == displayComponents.count - 1 ? Color.kilnText : Color.kilnTextSecondary)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .disabled(comp.isEllipsis)
                .help(comp.isEllipsis ? "" : comp.fullPath)
            }
        }
    }
}

// MARK: - Git diff sheet
//
// Presents a HEAD-vs-worktree diff for a single file in a modal. Loads
// HEAD content via `git show HEAD:<relpath>` on appear; worktree content
// comes straight from disk. Reuses DiffView's LCS renderer so the visual
// language matches the Accept/Revert flow.

struct GitDiffTarget: Identifiable {
    let path: String
    var id: String { path }
}

struct GitDiffSheet: View {
    let path: String
    let workDir: String
    @Environment(\.dismiss) private var dismiss

    @State private var head: String = ""
    @State private var working: String = ""
    @State private var loading = true
    @State private var errorMsg: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .foregroundStyle(Color.kilnAccent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(relativeDisplayPath)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.kilnText)
                    Text("Working copy vs. HEAD")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.kilnTextTertiary)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.kilnTextSecondary)
                        .frame(width: 22, height: 22)
                        .background(Color.kilnSurface)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)
            }
            .padding(14)

            Rectangle().fill(Color.kilnBorder).frame(height: 1)

            Group {
                if loading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let msg = errorMsg {
                    VStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .foregroundStyle(Color.kilnError)
                        Text(msg)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.kilnTextSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    DiffView(before: head, after: working)
                }
            }
        }
        .frame(width: 820, height: 560)
        .background(Color.kilnBg)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task { await load() }
    }

    private var relativeDisplayPath: String {
        path.hasPrefix(workDir + "/") ? String(path.dropFirst(workDir.count + 1)) : path
    }

    private func load() async {
        let rel = relativeDisplayPath
        let (headText, workText, err) = await Task.detached(priority: .userInitiated) {
            () -> (String, String, String?) in
            // HEAD side — empty string is a valid result (file didn't exist
            // at HEAD, i.e. fully added). Distinguish that from a real
            // error by checking exit code.
            let head = GitDiffSheet.runGit(["show", "HEAD:" + rel], in: workDir) ?? ""
            let work: String
            do {
                work = try String(contentsOfFile: path, encoding: .utf8)
            } catch {
                return ("", "", "Failed to read working copy: \(error.localizedDescription)")
            }
            return (head, work, nil)
        }.value
        await MainActor.run {
            head = headText
            working = workText
            errorMsg = err
            loading = false
        }
    }

    /// Lightweight shell-out. Returns nil if git exits non-zero (e.g. the
    /// file isn't in HEAD). Empty string is a valid zero-exit result.
    nonisolated static func runGit(_ args: [String], in dir: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["git", "-C", dir] + args
        let out = Pipe()
        let err = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        do {
            try proc.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            if proc.terminationStatus != 0 { return nil }
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return nil
        }
    }
}

// MARK: - Editor tab strip
//
// Horizontal scroll of one "tab" per open file, plus a Files button on the
// left that flips back to the tree without closing any tabs. A visible
// indicator runs along the bottom of the active tab. Dirty files get an
// accent dot; middle-click / x-button closes.

struct EditorTabStrip: View {
    let openFiles: [OpenFile]
    let activeIndex: Int?
    let showingTree: Bool
    var editingPaths: Set<String> = []
    var conflictPaths: Set<String> = []
    let onSelect: (Int) -> Void
    let onClose: (Int) -> Void
    let onToggleTree: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onToggleTree) {
                Image(systemName: showingTree ? "sidebar.left" : "list.bullet.indent")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(showingTree ? Color.kilnAccent : Color.kilnTextSecondary)
                    .frame(width: 28, height: 24)
                    .background(showingTree ? Color.kilnAccentMuted : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .help(showingTree ? "Back to editor" : "Show file tree")
            .padding(.leading, 4)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(Array(openFiles.enumerated()), id: \.element.id) { idx, f in
                        EditorTab(
                            file: f,
                            active: !showingTree && activeIndex == idx,
                            claudeEditing: editingPaths.contains(f.path),
                            externalConflict: conflictPaths.contains(f.path),
                            onSelect: { onSelect(idx) },
                            onClose: { onClose(idx) }
                        )
                    }
                }
                .padding(.horizontal, 4)
            }
        }
        .padding(.vertical, 3)
        .background(Color.kilnSurface)
    }
}

struct EditorTab: View {
    let file: OpenFile
    let active: Bool
    var claudeEditing: Bool = false
    var externalConflict: Bool = false
    let onSelect: () -> Void
    let onClose: () -> Void
    @State private var hovering = false
    @State private var pulse = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 5) {
                Image(systemName: iconForFile(file.path))
                    .font(.system(size: 9))
                    .foregroundStyle(active ? Color.kilnAccent : Color.kilnTextTertiary)
                Text((file.path as NSString).lastPathComponent)
                    .font(.system(size: 11, weight: active ? .semibold : .medium))
                    .foregroundStyle(active ? Color.kilnText : Color.kilnTextSecondary)
                    .lineLimit(1)
                if externalConflict {
                    // Claude wrote while buffer was dirty — user needs to
                    // reconcile by saving or reverting.
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color(hex: 0xF59E0B))
                        .help("Claude edited this file while you had unsaved changes")
                } else if claudeEditing {
                    // In-flight tool call touching this file — pulse the dot.
                    Circle()
                        .fill(Color.kilnAccent)
                        .frame(width: 6, height: 6)
                        .opacity(pulse ? 0.35 : 1.0)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                                pulse = true
                            }
                        }
                        .onDisappear { pulse = false }
                        .help("Claude is editing this file")
                } else if file.isDirty {
                    Circle().fill(Color.kilnAccent).frame(width: 5, height: 5)
                }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.kilnTextTertiary)
                        .frame(width: 18, height: 18)
                        .background(hovering ? Color.kilnSurfaceHover : Color.clear)
                        .clipShape(Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .help("Close tab")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(active ? Color.kilnBg : (hovering ? Color.kilnSurfaceHover : Color.clear))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(active ? Color.kilnBorder : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(file.path)
    }
}

func iconForFile(_ name: String) -> String {
    let ext = (name as NSString).pathExtension.lowercased()
    switch ext {
    case "swift": return "swift"
    case "js", "ts", "jsx", "tsx": return "doc.text"
    case "json": return "curlybraces"
    case "md": return "doc.richtext"
    case "py": return "doc.text"
    case "css": return "paintbrush"
    case "html": return "globe"
    case "zip": return "doc.zipper"
    default: return "doc"
    }
}

// MARK: - Git Panel

struct GitPanelView: View {
    @EnvironmentObject var store: AppStore
    @State private var branch = ""
    @State private var status: [GitFileStatus] = []
    @State private var log: [GitLogEntry] = []
    @State private var commitMessage = ""
    @State private var isLoading = false
    @State private var errorMsg: String?
    @State private var selectedFiles: Set<String> = []

    private var workDir: String {
        let dir = store.activeSession?.workDir ?? NSHomeDirectory()
        return dir.hasPrefix("~")
            ? dir.replacingOccurrences(of: "~", with: NSHomeDirectory(), range: dir.range(of: "~"))
            : dir
    }

    var body: some View {
        VStack(spacing: 0) {
            // Branch header
            HStack(spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.kilnAccent)
                Text(branch.isEmpty ? store.settings.language.ui.notGitRepo : branch)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.kilnText)
                    .lineLimit(1)
                Spacer()
                Button {
                    Task { await refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.kilnTextSecondary)
                        .frame(width: 22, height: 22)
                        .background(Color.kilnSurfaceElevated)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.kilnSurface)

            Rectangle().fill(Color.kilnBorder).frame(height: 1)

            if isLoading {
                ProgressView()
                    .tint(Color.kilnAccent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if let err = errorMsg {
                            Text(err)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.kilnTextTertiary)
                                .padding(12)
                        }

                        // Changed files
                        if !status.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("\(store.settings.language.ui.changes.uppercased()) (\(status.count))")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Color.kilnTextTertiary)
                                    .tracking(0.5)

                                ForEach(status, id: \.path) { file in
                                    GitFileRow(
                                        file: file,
                                        isSelected: selectedFiles.contains(file.path),
                                        onToggle: {
                                            if selectedFiles.contains(file.path) {
                                                selectedFiles.remove(file.path)
                                            } else {
                                                selectedFiles.insert(file.path)
                                            }
                                        }
                                    )
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.top, 8)

                            // Commit section
                            VStack(spacing: 8) {
                                TextField(store.settings.language.ui.commitMessage, text: $commitMessage, axis: .vertical)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.kilnText)
                                    .lineLimit(1...4)
                                    .padding(8)
                                    .background(Color.kilnSurface)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.kilnBorder, lineWidth: 1))

                                HStack(spacing: 8) {
                                    Button {
                                        Task { await stageAndCommit() }
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.system(size: 10))
                                            Text(store.settings.language.ui.commit)
                                                .font(.system(size: 11, weight: .semibold))
                                        }
                                        .foregroundStyle(Color.kilnBg)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 6)
                                        .background(commitMessage.isEmpty ? Color.kilnTextTertiary : Color.kilnAccent)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(commitMessage.isEmpty)

                                    Button {
                                        Task { await push() }
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "arrow.up")
                                                .font(.system(size: 10, weight: .semibold))
                                            Text(store.settings.language.ui.push)
                                                .font(.system(size: 11, weight: .medium))
                                        }
                                        .foregroundStyle(Color.kilnText)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(Color.kilnSurfaceElevated)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                    }
                                    .buttonStyle(.plain)

                                    Button {
                                        Task { await pull() }
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "arrow.down")
                                                .font(.system(size: 10, weight: .semibold))
                                            Text(store.settings.language.ui.pull)
                                                .font(.system(size: 11, weight: .medium))
                                        }
                                        .foregroundStyle(Color.kilnText)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(Color.kilnSurfaceElevated)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 12)
                        }

                        // Recent commits
                        if !log.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(store.settings.language.ui.recentCommits.uppercased())
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(Color.kilnTextTertiary)
                                    .tracking(0.5)

                                ForEach(log) { entry in
                                    GitCommitRow(entry: entry)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.top, 4)
                        }

                        if status.isEmpty && log.isEmpty && errorMsg == nil {
                            VStack(spacing: 8) {
                                Image(systemName: "checkmark.circle")
                                    .font(.system(size: 20))
                                    .foregroundStyle(Color.kilnSuccess)
                                Text(store.settings.language.ui.cleanTree)
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.kilnTextSecondary)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                        }
                    }
                    .padding(.bottom, 12)
                }
            }
        }
        .background(Color.kilnBg)
        .task { await refresh() }
    }

    private func refresh() async {
        isLoading = true
        errorMsg = nil

        // Branch
        branch = await git("rev-parse --abbrev-ref HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
        if branch.isEmpty || branch.contains("fatal") {
            errorMsg = store.settings.language.ui.notGitRepo
            branch = ""
            isLoading = false
            return
        }

        // Status
        let statusOut = await git("status --porcelain")
        status = statusOut.split(separator: "\n").compactMap { line in
            let s = String(line)
            guard s.count >= 3 else { return nil }
            let code = String(s.prefix(2))
            let path = String(s.dropFirst(3))
            return GitFileStatus(code: code.trimmingCharacters(in: .whitespaces), path: path)
        }

        // Select all by default
        selectedFiles = Set(status.map(\.path))

        // Log
        let logOut = await git("log --oneline -20 --format=%H||%s||%an||%ar")
        log = logOut.split(separator: "\n").compactMap { line in
            let parts = String(line).split(separator: "||", maxSplits: 3).map(String.init)
            guard parts.count >= 4 else { return nil }
            return GitLogEntry(hash: String(parts[0].prefix(8)), message: parts[1], author: parts[2], ago: parts[3])
        }

        isLoading = false
    }

    private func stageAndCommit() async {
        if selectedFiles.isEmpty {
            // Stage all
            _ = await git("add -A")
        } else {
            for file in selectedFiles {
                _ = await git("add \"\(file)\"")
            }
        }
        _ = await git("commit -m \"\(commitMessage.replacingOccurrences(of: "\"", with: "\\\""))\"")
        commitMessage = ""
        await refresh()
    }

    private func push() async {
        _ = await git("push")
        await refresh()
    }

    private func pull() async {
        _ = await git("pull")
        await refresh()
    }

    private func git(_ args: String) async -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args.components(separatedBy: " ")
        process.currentDirectoryURL = URL(fileURLWithPath: workDir)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        } catch {
            return ""
        }
    }
}

struct GitFileStatus {
    let code: String
    let path: String

    var statusColor: SwiftUI.Color {
        if code.contains("M") { return SwiftUI.Color.kilnAccent }
        if code.contains("A") { return SwiftUI.Color.kilnSuccess }
        if code.contains("D") { return SwiftUI.Color.kilnError }
        if code.contains("?") { return SwiftUI.Color.kilnTextTertiary }
        return SwiftUI.Color.kilnTextSecondary
    }

    var statusLabel: String {
        if code.contains("M") { return "M" }
        if code.contains("A") { return "A" }
        if code.contains("D") { return "D" }
        if code.contains("?") { return "?" }
        return code
    }
}

struct GitLogEntry: Identifiable {
    let hash: String
    let message: String
    let author: String
    let ago: String
    var id: String { hash }
}

struct GitFileRow: View {
    let file: GitFileStatus
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button { onToggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 11))
                    .foregroundStyle(isSelected ? Color.kilnAccent : Color.kilnTextTertiary)

                Text(file.statusLabel)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(file.statusColor)
                    .frame(width: 14)

                Text(file.path)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.kilnText)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(isSelected ? Color.kilnAccent.opacity(0.05) : .clear)
            )
        }
        .buttonStyle(.plain)
    }
}

struct GitCommitRow: View {
    let entry: GitLogEntry

    var body: some View {
        HStack(spacing: 8) {
            Text(entry.hash)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.kilnAccent)
            Text(entry.message)
                .font(.system(size: 11))
                .foregroundStyle(Color.kilnText)
                .lineLimit(1)
            Spacer()
            Text(entry.ago)
                .font(.system(size: 9))
                .foregroundStyle(Color.kilnTextTertiary)
        }
        .padding(.vertical, 3)
    }
}

// MARK: - Terminal View

// MARK: - Activity Panel (live tool use stream)

struct ActivityPanelView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.kilnAccent)
                Text(store.settings.language.ui.activity)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.kilnText)
                if store.isBusy {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(Color.kilnAccent)
                }
                Spacer()
                Text("\(store.activeToolCalls.count) \(store.settings.language.ui.callsSuffix)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.kilnTextTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.kilnSurface)

            Rectangle().fill(Color.kilnBorder).frame(height: 1)

            if store.activeToolCalls.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.kilnTextTertiary)
                    Text(store.settings.language.ui.noActivityYet)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.kilnTextSecondary)
                    Text(store.settings.language.ui.activityHint)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.kilnTextTertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(store.activeToolCalls) { call in
                                ActivityCard(call: call)
                                    .id(call.id)
                            }
                        }
                        .padding(10)
                    }
                    .onChange(of: store.activeToolCalls.count) { _, _ in
                        if let last = store.activeToolCalls.last?.id {
                            withAnimation { proxy.scrollTo(last, anchor: .bottom) }
                        }
                    }
                }
            }
        }
        .background(Color.kilnBg)
    }
}

struct ActivityCard: View {
    let call: ToolUseBlock

    private var parsedInput: [String: Any] {
        guard let data = call.input.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return json
    }

    private var accentColor: SwiftUI.Color {
        if call.isError { return SwiftUI.Color.kilnError }
        if !call.isDone { return SwiftUI.Color.kilnAccent }
        return SwiftUI.Color.kilnSuccess
    }

    private var iconName: String {
        switch call.name {
        case "Edit", "MultiEdit": return "pencil"
        case "Write": return "plus.square"
        case "Read": return "doc.text"
        case "Bash", "BashOutput": return "terminal"
        case "Glob", "Grep": return "magnifyingglass"
        case "Task": return "arrow.triangle.branch"
        case "WebFetch", "WebSearch": return "globe"
        case "TodoWrite": return "checklist"
        default:
            if call.name.hasPrefix("mcp__") { return "bolt.circle" }
            return "wrench.and.screwdriver"
        }
    }

    private var displayName: String {
        if call.name.hasPrefix("mcp__") {
            let parts = call.name.split(separator: "_", omittingEmptySubsequences: true)
            if parts.count >= 3 {
                return "\(parts[1]).\(parts[2...].joined(separator: "_"))"
            }
        }
        return call.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: iconName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(accentColor)
                Text(displayName)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.kilnText)
                Spacer()
                if !call.isDone {
                    ProgressView()
                        .controlSize(.mini)
                } else if call.isError {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.kilnError)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.kilnSuccess)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.kilnSurface)

            Rectangle().fill(Color.kilnBorder).frame(height: 1)

            // Body — render per-tool content
            bodyForTool
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.kilnBg)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.kilnBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var bodyForTool: some View {
        switch call.name {
        case "Edit", "MultiEdit":
            editBody
        case "Write":
            writeBody
        case "Read":
            readBody
        case "Bash":
            bashBody
        case "Glob", "Grep":
            searchBody
        default:
            genericBody
        }
    }

    private var editBody: some View {
        let path = parsedInput["file_path"] as? String ?? "?"
        let oldStr = parsedInput["old_string"] as? String ?? ""
        let newStr = parsedInput["new_string"] as? String ?? ""
        return VStack(alignment: .leading, spacing: 6) {
            pathLine(path)
            if !oldStr.isEmpty {
                codeBlock("- " + oldStr, color: Color.kilnError.opacity(0.8), bg: Color.kilnError.opacity(0.08))
            }
            if !newStr.isEmpty {
                codeBlock("+ " + newStr, color: Color.kilnSuccess, bg: Color.kilnSuccess.opacity(0.08))
            }
        }
    }

    private var writeBody: some View {
        let path = parsedInput["file_path"] as? String ?? "?"
        let content = parsedInput["content"] as? String ?? (call.isDone ? "" : "…writing…")
        return VStack(alignment: .leading, spacing: 6) {
            pathLine(path)
            codeBlock(content, color: Color.kilnText, bg: Color.kilnSurface)
        }
    }

    private var readBody: some View {
        let path = parsedInput["file_path"] as? String ?? "?"
        return pathLine(path)
    }

    private var bashBody: some View {
        let cmd = parsedInput["command"] as? String ?? ""
        return VStack(alignment: .leading, spacing: 6) {
            codeBlock("$ " + cmd, color: Color.kilnAccent, bg: Color.kilnSurface)
            if let result = call.result, !result.isEmpty {
                codeBlock(result.prefix(1200) + (result.count > 1200 ? "\n…(truncated)" : ""),
                          color: Color.kilnTextSecondary, bg: Color.kilnBg)
            }
        }
    }

    private var searchBody: some View {
        let pattern = parsedInput["pattern"] as? String ?? parsedInput["query"] as? String ?? ""
        return VStack(alignment: .leading, spacing: 4) {
            Text(pattern)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.kilnText)
            if let result = call.result, !result.isEmpty {
                Text(result.prefix(400) + (result.count > 400 ? "…" : ""))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.kilnTextTertiary)
                    .lineLimit(8)
            }
        }
    }

    private var genericBody: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !call.input.isEmpty && call.input != "{}" {
                Text(call.input.prefix(300) + (call.input.count > 300 ? "…" : ""))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.kilnTextSecondary)
                    .lineLimit(6)
            }
            if let result = call.result, !result.isEmpty {
                Text(result.prefix(400) + (result.count > 400 ? "…" : ""))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.kilnTextTertiary)
                    .lineLimit(8)
            }
        }
    }

    private func pathLine(_ path: String) -> some View {
        let short = (path as NSString).lastPathComponent
        return HStack(spacing: 4) {
            Image(systemName: iconForFile(short))
                .font(.system(size: 9))
                .foregroundStyle(Color.kilnAccent)
            Text(short)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.kilnText)
            Text(path)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(Color.kilnTextTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func codeBlock<S: StringProtocol>(_ text: S, color: SwiftUI.Color, bg: SwiftUI.Color) -> some View {
        Text(String(text))
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
            .background(bg)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .textSelection(.enabled)
    }
}

struct TerminalPanelView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        let workDir = store.activeSession?.workDir ?? NSHomeDirectory()
        let resolved = workDir.hasPrefix("~")
            ? workDir.replacingOccurrences(of: "~", with: NSHomeDirectory(), range: workDir.range(of: "~"))
            : workDir

        SwiftTermView(workDir: resolved)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.kilnBg)
    }
}

struct SwiftTermView: NSViewRepresentable {
    let workDir: String

    final class Coordinator {
        var termView: LocalProcessTerminalView?
        var lastSize: CGSize = .zero
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        // Container fills whatever SwiftUI gives us. The terminal is pinned
        // to its bounds with autoresizing so it actually grows with the pane.
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
        container.autoresizingMask = [.width, .height]
        container.translatesAutoresizingMaskIntoConstraints = true

        let termView = LocalProcessTerminalView(frame: container.bounds)
        termView.autoresizingMask = [.width, .height]
        termView.translatesAutoresizingMaskIntoConstraints = true

        termView.nativeBackgroundColor = NSColor(Color.kilnBg)
        termView.nativeForegroundColor = NSColor(Color.kilnText)

        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let env = Terminal.getEnvironmentVariables(termName: "xterm-256color")

        termView.startProcess(
            executable: shell,
            args: [],
            environment: env,
            execName: (shell as NSString).lastPathComponent,
            currentDirectory: workDir
        )

        container.addSubview(termView)
        context.coordinator.termView = termView
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Push the container's size down to the terminal view and trigger
        // a pty resize so the shell's cell grid matches the pane.
        guard let termView = context.coordinator.termView else { return }
        let size = nsView.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        if size != context.coordinator.lastSize {
            context.coordinator.lastSize = size
            termView.frame = nsView.bounds
            termView.needsLayout = true
            termView.layoutSubtreeIfNeeded()
        }
    }
}
