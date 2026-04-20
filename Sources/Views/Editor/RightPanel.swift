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
                            .padding(.horizontal, 9)
                            .padding(.top, 6)
                            .foregroundStyle(selectedTab == tab ? Color.kilnAccent : Color.kilnTextTertiary)

                            Rectangle()
                                .fill(selectedTab == tab ? Color.kilnAccent : Color.clear)
                                .frame(height: 2)
                        }
                    }
                    .buttonStyle(.plain)
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

struct FileTreeView: View {
    @EnvironmentObject var store: AppStore
    @State private var entries: [FileEntry] = []
    @State private var selectedFile: String?
    @State private var fileContent: String?
    @State private var isDirty = false
    @State private var originalContent: String?
    @State private var filter: String = ""

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

    var body: some View {
        VStack(spacing: 0) {
            if fileContent != nil, let path = selectedFile {
                // Tab bar for open file
                HStack(spacing: 6) {
                    Button {
                        selectedFile = nil
                        fileContent = nil
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.kilnTextSecondary)
                            .frame(width: 20, height: 20)
                            .background(Color.kilnSurfaceElevated)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)

                    Image(systemName: iconForFile(URL(fileURLWithPath: path).lastPathComponent))
                        .font(.system(size: 10))
                        .foregroundStyle(Color.kilnAccent)
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.kilnText)
                    if isDirty {
                        Circle()
                            .fill(Color.kilnAccent)
                            .frame(width: 6, height: 6)
                    }
                    Spacer()
                    if isDirty {
                        Button {
                            saveFile()
                        } label: {
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
                // File-level context menu on the header bar. Monaco has its
                // own in-webview right-click menu for editor operations
                // (cut/copy/paste/command palette/etc.) — this is for the
                // file *around* that editor: save, revert, reveal, close.
                .contextMenu { editorFileContextMenu(path: path) }

                Rectangle().fill(Color.kilnBorder).frame(height: 1)

                // Editor
                CodeEditorView(
                    text: Binding(
                        get: { fileContent ?? "" },
                        set: { newValue in
                            fileContent = newValue
                            isDirty = true
                        }
                    ),
                    language: languageForFile(path),
                    isEditable: true,
                    onSave: { saveFile() }
                )
                // Same context menu is attached to the editor area so a
                // two-finger click anywhere in the pane surfaces file ops
                // as a fallback. Monaco's own right-click lives inside the
                // WKWebView and intercepts first when the pointer is over
                // editor glyphs; SwiftUI's contextMenu wins over the empty
                // margins / gutter.
                .contextMenu { editorFileContextMenu(path: path) }
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
                                    entries: $entries,
                                    selectedFile: $selectedFile,
                                    fileContent: $fileContent,
                                    isDirty: $isDirty,
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
    }

    private func displayPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }

    private func saveFile() {
        guard let path = selectedFile, let content = fileContent else { return }
        do {
            try content.write(toFile: path, atomically: true, encoding: .utf8)
            isDirty = false
            originalContent = content
        } catch {
            print("Failed to save: \(error)")
        }
    }

    /// Revert to the on-disk version. Reads fresh rather than relying on
    /// `originalContent` so externally-modified files get picked up.
    private func revertFile() {
        guard let path = selectedFile else { return }
        if let fresh = try? String(contentsOfFile: path, encoding: .utf8) {
            fileContent = fresh
            originalContent = fresh
            isDirty = false
        }
    }

    private func closeCurrentFile() {
        selectedFile = nil
        fileContent = nil
        isDirty = false
        originalContent = nil
    }

    /// Context menu for the currently-open file. Used on both the header
    /// strip and the editor body as a fallback when Monaco's in-webview
    /// menu isn't what the user's trying to reach.
    @ViewBuilder
    private func editorFileContextMenu(path: String) -> some View {
        if isDirty {
            Button {
                saveFile()
            } label: { Label("Save", systemImage: "square.and.arrow.down") }
            .keyboardShortcut("s")
            Button(role: .destructive) {
                revertFile()
            } label: { Label("Revert Changes", systemImage: "arrow.uturn.backward") }
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
        if let content = fileContent, !content.isEmpty {
            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(content, forType: .string)
            } label: { Label("Copy File Contents", systemImage: "text.quote") }
        }
        Divider()
        Button {
            closeCurrentFile()
        } label: { Label("Close File", systemImage: "xmark") }
    }

    private func languageForFile(_ path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "swift": return "swift"
        case "js": return "js"
        case "ts": return "ts"
        case "jsx": return "jsx"
        case "tsx": return "tsx"
        case "py": return "python"
        case "json": return "json"
        case "css": return "css"
        case "html", "htm": return "html"
        case "md": return "markdown"
        case "sh", "bash", "zsh": return "shell"
        case "rs": return "rust"
        case "go": return "go"
        case "rb": return "ruby"
        default: return ext
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
        } catch {
            print("Failed to load directory: \(error)")
        }
    }
}

struct FileRow: View {
    let entry: FileEntry
    @Binding var entries: [FileEntry]
    @Binding var selectedFile: String?
    @Binding var fileContent: String?
    @Binding var isDirty: Bool
    let depth: Int

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
                    selectedFile = entry.path
                    loadFile()
                }
            } label: {
                HStack(spacing: 4) {
                    // Indent
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
                        .foregroundStyle(selectedFile == entry.path ? Color.kilnAccent : Color.kilnText)
                        .lineLimit(1)

                    Spacer()
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 4)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(selectedFile == entry.path ? Color.kilnAccentMuted :
                                (hovering ? Color.kilnSurfaceHover : .clear))
                )
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            .contextMenu {
                if !entry.isDirectory {
                    Button {
                        selectedFile = entry.path
                        loadFile()
                    } label: { Label("Open", systemImage: "doc.text") }
                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: entry.path))
                    } label: { Label("Open with Default App", systemImage: "arrow.up.forward.app") }
                    Divider()
                }
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
                        entries: $entries,
                        selectedFile: $selectedFile,
                        fileContent: $fileContent,
                        isDirty: $isDirty,
                        depth: depth + 1
                    )
                }
            }
        }
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

    private func loadFile() {
        do {
            fileContent = try String(contentsOfFile: entry.path, encoding: .utf8)
            isDirty = false
        } catch {
            fileContent = "Failed to read: \(error.localizedDescription)"
        }
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
