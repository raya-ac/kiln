import SwiftUI
import UniformTypeIdentifiers

// MARK: - Session color labels
//
// Six named swatches a user can pin to a session for at-a-glance
// grouping. Kept to fixed presets so the dots read consistently in
// both light and dark themes — arbitrary hex makes the sidebar look
// noisy and lowers contrast against the row background.
enum SessionColor {
    static let all: [(name: String, color: Color)] = [
        ("red",    Color(hex: 0xEF4444)),
        ("amber",  Color(hex: 0xF59E0B)),
        ("green",  Color(hex: 0x10B981)),
        ("blue",   Color(hex: 0x3B82F6)),
        ("purple", Color(hex: 0x8B5CF6)),
        ("pink",   Color(hex: 0xEC4899)),
    ]
    static func color(for name: String) -> Color? {
        all.first(where: { $0.name == name })?.color
    }
}

struct SidebarView: View {
    @EnvironmentObject var store: AppStore
    @State private var renamingId: String?
    @State private var renameText = ""
    @State private var newGroupName = ""
    @State private var showNewGroupAlert = false
    @State private var groupTargetId: String?
    @State private var dragOverId: String?
    @State private var dragOverGroup: String? = nil
    @State private var isDraggingOverUngrouped = false
    @State private var searchText = ""
    @State private var showArchived: Bool = false

    private func sortLabel(_ order: AppStore.SessionSort) -> String {
        switch order {
        case .manual: return "Manual"
        case .recent: return "Recent"
        case .name: return "Name"
        case .created: return "Created"
        }
    }

    private func filterArchived(_ s: Session) -> Bool {
        showArchived ? s.isArchived : !s.isArchived
    }

    @ViewBuilder
    private var bulkActionBar: some View {
        HStack(spacing: 6) {
            Text("\(store.selectedSessionIds.count) selected")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.kilnAccent)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(Color.kilnAccentMuted)
                .clipShape(RoundedRectangle(cornerRadius: 4))

            Spacer()

            Button {
                store.bulkArchive()
            } label: {
                Image(systemName: "archivebox")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.kilnTextSecondary)
                    .frame(width: 22, height: 22)
                    .background(Color.kilnSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .help("Archive selected sessions")

            Button {
                store.bulkDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.kilnError)
                    .frame(width: 22, height: 22)
                    .background(Color.kilnSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .help("Delete selected sessions")

            Button {
                store.clearSelection()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.kilnTextTertiary)
                    .frame(width: 22, height: 22)
                    .background(Color.kilnSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            .help("Clear selection (Esc)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.kilnSurface.opacity(0.6))
    }

    private var filteredGroupedSessions: [(group: String?, sessions: [Session])] {
        let tab = store.selectedSidebarTab
        let base = store.groupedSessions.map { group in
            (group: group.group, sessions: group.sessions.filter { $0.kind == tab && filterArchived($0) })
        }.filter { !$0.sessions.isEmpty }

        if searchText.isEmpty { return base }
        let query = searchText.lowercased()
        let filtered = store.sortedSessions.filter { session in
            session.kind == tab && filterArchived(session) && (
                session.name.lowercased().contains(query) ||
                session.workDir.lowercased().contains(query) ||
                (session.group?.lowercased().contains(query) ?? false) ||
                session.tags.contains { $0.contains(query.hasPrefix("#") ? String(query.dropFirst()) : query) }
            )
        }
        if filtered.isEmpty { return [] }
        return [(group: nil, sessions: filtered)]
    }

    private var sessionsForTab: [Session] {
        store.sessions.filter { $0.kind == store.selectedSidebarTab && filterArchived($0) }
    }

    private var archivedCount: Int {
        store.sessions.filter { $0.kind == store.selectedSidebarTab && $0.isArchived }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(alignment: .center) {
                // Custom "Kiln Code" mark — flame glyph overlaid on a rounded
                // tile tinted with the current accent color.
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.kilnAccent)
                        .frame(width: 22, height: 22)
                    Image(systemName: "flame.fill")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(Color.kilnBg)
                }
                Text("Kiln Code")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.kilnText)
                Spacer()
                Menu {
                    Button("New session") {
                        if store.selectedSidebarTab == .chat {
                            store.createSession(workDir: NSHomeDirectory(), kind: .chat)
                        } else {
                            store.showNewSessionSheet = true
                        }
                    }
                    .keyboardShortcut("n", modifiers: .command)

                    Divider()

                    // Direct template shortcuts — top 6 for quick access
                    ForEach(SessionTemplateStore.shared.templates.prefix(6)) { t in
                        Button {
                            store.createSessionFromTemplate(t)
                        } label: {
                            Label(t.name, systemImage: t.icon)
                        }
                    }

                    if !SessionTemplateStore.shared.templates.isEmpty {
                        Divider()
                    }

                    Button("Manage templates…") {
                        store.showSessionTemplates = true
                    }
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.kilnTextSecondary)
                        .frame(width: 24, height: 24)
                        .background(Color.kilnSurfaceElevated)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .buttonStyle(.plain)
                .help("New session (click for templates)")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            // Code / Chat tabs
            HStack(spacing: 4) {
                ForEach(SessionKind.allCases) { kind in
                    let selected = store.selectedSidebarTab == kind
                    let label = kind == .code ? store.settings.language.ui.code : store.settings.language.ui.chat
                    Button {
                        store.selectedSidebarTab = kind
                        if let first = store.sessions.first(where: { $0.kind == kind }) {
                            store.activeSessionId = first.id
                        } else {
                            store.activeSessionId = nil
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: kind.icon)
                                .font(.system(size: 10))
                            Text(label)
                                .font(.system(size: 11, weight: .medium))
                        }
                        .foregroundStyle(selected ? Color.kilnBg : Color.kilnTextSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(selected ? Color.kilnAccent : Color.kilnSurfaceElevated)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 4)

            // Sort control — Pinned sessions always float to the top; this
            // picker just reorders the rest. Kept understated (right-aligned
            // small menu) so it doesn't compete with the tabs or search.
            HStack {
                Spacer()
                Menu {
                    ForEach(AppStore.SessionSort.allCases, id: \.self) { order in
                        Button {
                            store.sessionSort = order
                        } label: {
                            Label(sortLabel(order), systemImage: store.sessionSort == order ? "checkmark" : "")
                        }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 8))
                        Text(sortLabel(store.sessionSort))
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(Color.kilnTextTertiary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)

            // Search bar
            if sessionsForTab.count > 3 {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.kilnTextTertiary)
                    TextField(store.settings.language.ui.search, text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.kilnText)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.kilnBg)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }

            // Archive toggle — only show if there's at least one archived session
            if archivedCount > 0 || showArchived {
                HStack(spacing: 6) {
                    Button {
                        showArchived.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: showArchived ? "archivebox.fill" : "archivebox")
                                .font(.system(size: 9))
                            Text(showArchived ? "Back to active" : "Archive (\(archivedCount))")
                                .font(.system(size: 10, weight: .medium))
                        }
                        .foregroundStyle(showArchived ? Color.kilnAccent : Color.kilnTextTertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(showArchived ? Color.kilnAccentMuted : Color.kilnSurfaceElevated)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .help(showArchived ? "Show active sessions" : "Show archived sessions")
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
            }

            Rectangle().fill(Color.kilnBorder).frame(height: 1)

            // Bulk action bar — only when multi-select is active
            if !store.selectedSessionIds.isEmpty {
                bulkActionBar
            }

            // Session list — grouped with drag & drop
            ScrollView {
                if sessionsForTab.isEmpty {
                    VStack(spacing: 16) {
                        Spacer().frame(height: 40)
                        Image(systemName: store.selectedSidebarTab.icon)
                            .font(.system(size: 28))
                            .foregroundStyle(Color.kilnTextTertiary)
                        Text(store.settings.language.ui.noSessions)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.kilnTextSecondary)
                        Button {
                            if store.selectedSidebarTab == .chat {
                                store.createSession(workDir: NSHomeDirectory(), kind: .chat)
                            } else {
                                store.showNewSessionSheet = true
                            }
                        } label: {
                            Text(store.settings.language.ui.newSession)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.kilnBg)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 7)
                                .background(Color.kilnAccent)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredGroupedSessions, id: \.group) { entry in
                            if let group = entry.group {
                                // Group header — drop target for moving sessions into group
                                GroupHeader(group: group, isDropTarget: dragOverGroup == group)
                                    .dropDestination(for: String.self) { ids, _ in
                                        guard let id = ids.first else { return false }
                                        store.setGroup(id, group: group)
                                        return true
                                    } isTargeted: { targeted in
                                        dragOverGroup = targeted ? group : nil
                                    }
                            }

                            ForEach(entry.sessions) { session in
                                SessionRow(
                                    session: session,
                                    renamingId: $renamingId,
                                    renameText: $renameText,
                                    isDropTarget: dragOverId == session.id,
                                    onRequestGroup: { id in
                                        groupTargetId = id
                                        newGroupName = session.group ?? ""
                                        showNewGroupAlert = true
                                    }
                                )
                                .draggable(session.id)
                                .dropDestination(for: String.self) { ids, _ in
                                    guard let draggedId = ids.first, draggedId != session.id else { return false }
                                    // Move dragged session before this one, and match its group
                                    store.setGroup(draggedId, group: session.group)
                                    store.moveSession(draggedId, before: session.id)
                                    return true
                                } isTargeted: { targeted in
                                    dragOverId = targeted ? session.id : nil
                                }
                            }
                        }
                    }
                    .padding(6)
                }
            }

            Spacer(minLength: 0)

            Rectangle().fill(Color.kilnBorder).frame(height: 1)

            // Settings button
            Button {
                store.showSettings = true
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "gear")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.kilnTextSecondary)
                    Text(store.settings.language.ui.settings)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.kilnTextSecondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .help("Open Settings (⌘,)")
        }
        .background(Color.kilnSurface)
        .sheet(isPresented: $store.showSettings) {
            SettingsView()
                .environmentObject(store)
                .preferredColorScheme(Color.kilnPreferredColorScheme)
        }
        .alert(store.settings.language.ui.setGroup, isPresented: $showNewGroupAlert) {
            TextField(store.settings.language.ui.groupName, text: $newGroupName)
            Button(store.settings.language.ui.set) {
                if let id = groupTargetId {
                    store.setGroup(id, group: newGroupName.isEmpty ? nil : newGroupName)
                }
            }
            Button(store.settings.language.ui.removeGroup, role: .destructive) {
                if let id = groupTargetId {
                    store.setGroup(id, group: nil)
                }
            }
            Button(store.settings.language.ui.cancel, role: .cancel) {}
        }
    }
}

// MARK: - Group Header

struct GroupHeader: View {
    let group: String
    let isDropTarget: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder.fill")
                .font(.system(size: 9))
                .foregroundStyle(isDropTarget ? Color.kilnAccent : Color.kilnTextTertiary)
            Text(group)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isDropTarget ? Color.kilnAccent : Color.kilnTextTertiary)
                .textCase(.uppercase)
                .tracking(0.5)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isDropTarget ? Color.kilnAccent.opacity(0.1) : .clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isDropTarget ? Color.kilnAccent.opacity(0.4) : .clear, lineWidth: 1.5)
        )
        .padding(.top, 8)
    }
}

// MARK: - Session Row

struct SessionRow: View {
    let session: Session
    @EnvironmentObject var store: AppStore
    @State private var hovering = false
    @State private var showDeleteConfirm = false
    @State private var showAddTagAlert = false
    @State private var newTagText = ""
    @State private var tagPromptSessionId: String?
    @Binding var renamingId: String?
    @Binding var renameText: String
    let isDropTarget: Bool
    let onRequestGroup: (String) -> Void

    private var isActive: Bool { session.id == store.activeSessionId }
    // Shows a busy dot on whichever row is actually generating, even if it
    // isn't the active session. Lets you see background work at a glance.
    private var isBusy: Bool { store.isSessionBusy(session.id) }
    private var isRenaming: Bool { renamingId == session.id }

    private var isMultiSelected: Bool {
        store.selectedSessionIds.contains(session.id)
    }

    var body: some View {
        Button {
            if !isRenaming {
                // ⌘-click or shift-click → toggle into multi-select.
                if NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift) {
                    store.toggleSelect(session.id)
                } else {
                    store.clearSelection()
                    store.activeSessionId = session.id
                }
            }
        } label: {
            HStack(spacing: 10) {
                // Icon
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isActive ? Color.kilnAccentMuted : Color.kilnSurfaceElevated)
                        .frame(width: 28, height: 28)
                    Image(systemName: session.isPinned ? "pin.fill" : (session.forkedFrom != nil ? "arrow.triangle.branch" : "bubble.left.fill"))
                        .font(.system(size: 11))
                        .foregroundStyle(isActive ? Color.kilnAccent : Color.kilnTextTertiary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if let color = session.colorLabel,
                           let swatch = SessionColor.color(for: color) {
                            Circle()
                                .fill(swatch)
                                .frame(width: 7, height: 7)
                        }
                        if isRenaming {
                            TextField(store.settings.language.ui.rename, text: $renameText, onCommit: {
                                store.renameSession(session.id, name: renameText)
                                renamingId = nil
                            })
                            .textFieldStyle(.plain)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.kilnText)
                            .onExitCommand { renamingId = nil }
                        } else {
                            Text(session.name)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(isActive ? Color.kilnText : Color.kilnTextSecondary)
                                .lineLimit(1)
                        }
                        if isBusy {
                            Circle()
                                .fill(Color.kilnAccent)
                                .frame(width: 5, height: 5)
                        } else if store.recentlyCompleted[session.id] != nil {
                            // Session finished while user was elsewhere —
                            // pulse a green dot until they open it.
                            SessionDonePulse()
                        }
                    }
                    // Metadata line. Rendered as a single Text with middle
                    // truncation so narrow sidebars don't break each chunk
                    // into its own character-per-line column — the previous
                    // HStack-of-Texts collapsed ugly when space was tight.
                    metadataLine(for: session)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.kilnTextTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    // Tag chips — cross-cutting labels on top of the group field.
                    if !session.tags.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 4) {
                                ForEach(session.tags, id: \.self) { tag in
                                    Text("#\(tag)")
                                        .font(.system(size: 9, weight: .medium))
                                        .foregroundStyle(Color.kilnAccent)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Color.kilnAccentMuted)
                                        .clipShape(RoundedRectangle(cornerRadius: 3))
                                }
                            }
                        }
                    }
                }

                Spacer(minLength: 0)

                // Drag handle on hover
                if hovering && !isRenaming {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.kilnTextTertiary)
                        .frame(width: 16)
                        .help("Drag to reorder or move to a group")
                }

                // Delete on hover
                if hovering && !isRenaming {
                    Button {
                        showDeleteConfirm = true
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.kilnTextTertiary)
                            .frame(width: 22, height: 22)
                            .background(Color.kilnSurfaceHover)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                    .buttonStyle(.plain)
                    .help("Delete session")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isMultiSelected ? Color.kilnAccentMuted : (isActive ? Color.kilnSurfaceElevated : (hovering ? Color.kilnSurfaceElevated.opacity(0.5) : .clear)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        isDropTarget ? Color.kilnAccent.opacity(0.6)
                            : (isMultiSelected ? Color.kilnAccent.opacity(0.5) : .clear),
                        lineWidth: 1.5
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .simultaneousGesture(
            TapGesture(count: 2).onEnded {
                if !isRenaming {
                    renameText = session.name
                    renamingId = session.id
                }
            }
        )
        .contextMenu {
            Button {
                renameText = session.name
                renamingId = session.id
            } label: {
                Label(store.settings.language.ui.rename, systemImage: "pencil")
            }

            Button {
                store.togglePin(session.id)
            } label: {
                Label(session.isPinned ? store.settings.language.ui.unpin : store.settings.language.ui.pin, systemImage: session.isPinned ? "pin.slash" : "pin")
            }

            Button {
                store.duplicateSession(session.id)
            } label: {
                Label("Duplicate (empty)", systemImage: "square.on.square")
            }

            Button {
                store.duplicateSessionWithMessages(session.id)
            } label: {
                Label("Duplicate with messages", systemImage: "doc.on.doc")
            }

            Menu("Color") {
                ForEach(SessionColor.all, id: \.name) { entry in
                    Button {
                        store.setSessionColor(session.id, color: entry.name)
                    } label: {
                        if session.colorLabel == entry.name {
                            Label(entry.name.capitalized, systemImage: "checkmark")
                        } else {
                            Text(entry.name.capitalized)
                        }
                    }
                }
                if session.colorLabel != nil {
                    Divider()
                    Button("Clear color") {
                        store.setSessionColor(session.id, color: nil)
                    }
                }
            }

            Divider()

            Button {
                onRequestGroup(session.id)
            } label: {
                Label(store.settings.language.ui.setGroup, systemImage: "folder")
            }

            if !store.sessionGroups.isEmpty {
                Menu(store.settings.language.ui.moveToGroup) {
                    ForEach(store.sessionGroups, id: \.self) { group in
                        Button(group) {
                            store.setGroup(session.id, group: group)
                        }
                    }
                    Divider()
                    Button(store.settings.language.ui.removeFromGroup) {
                        store.setGroup(session.id, group: nil)
                    }
                }
            }

            // Tags menu — add new or toggle existing
            Menu("Tags") {
                Button("Add tag…") {
                    tagPromptSessionId = session.id
                    newTagText = ""
                    showAddTagAlert = true
                }
                if !session.tags.isEmpty {
                    Divider()
                    ForEach(session.tags, id: \.self) { tag in
                        Button("Remove #\(tag)") {
                            store.removeTag(tag, from: session.id)
                        }
                    }
                }
                if !store.allTags.isEmpty {
                    Divider()
                    ForEach(store.allTags.filter { !session.tags.contains($0) }, id: \.self) { tag in
                        Button("Add #\(tag)") {
                            store.addTag(tag, to: session.id)
                        }
                    }
                }
            }

            Button {
                let prompt = store.sessionAsContinuationPrompt(session.id)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(prompt, forType: .string)
            } label: {
                Label("Copy as continuation prompt", systemImage: "doc.on.clipboard")
            }

            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.workDir)])
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }

            // Start a fresh session pointed at the same workdir. Useful when
            // you want a clean chat for the same repo without redoing the
            // directory picker.
            Button {
                store.createSession(workDir: session.workDir, model: session.model, kind: session.kind)
            } label: {
                Label("New session here", systemImage: "plus.bubble")
            }

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.workDir, forType: .string)
            } label: {
                Label("Copy Path", systemImage: "doc.on.doc")
            }

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.id, forType: .string)
            } label: {
                Label("Copy Session ID", systemImage: "number")
            }

            Button {
                guard let data = store.exportSessionJSONData(session.id) else { return }
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.json]
                let safeName = session.name
                    .replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: " ", with: "-")
                panel.nameFieldStringValue = "kiln-session-\(safeName).json"
                if panel.runModal() == .OK, let dest = panel.url {
                    try? data.write(to: dest)
                    NSWorkspace.shared.activateFileViewerSelecting([dest])
                }
            } label: {
                Label("Export as JSON", systemImage: "square.and.arrow.up")
            }

            if store.activeSession?.id == session.id {
                Button {
                    let term = NSAppleScript(source: """
                        tell application "Terminal"
                            activate
                            do script "cd \\"\(session.workDir)\\""
                        end tell
                        """)
                    term?.executeAndReturnError(nil)
                } label: {
                    Label("Open in Terminal", systemImage: "terminal")
                }
            }

            Divider()

            Button {
                store.clearSession(session.id)
            } label: {
                Label(store.settings.language.ui.clearMessages, systemImage: "eraser")
            }

            Button {
                store.toggleArchiveSession(session.id)
            } label: {
                Label(session.isArchived ? "Unarchive" : "Archive", systemImage: session.isArchived ? "tray.and.arrow.up" : "archivebox")
            }

            Divider()

            Button(role: .destructive) {
                showDeleteConfirm = true
            } label: {
                Label(store.settings.language.ui.delete, systemImage: "trash")
            }
        }
        .alert(store.settings.language.ui.deleteSession, isPresented: $showDeleteConfirm) {
            Button(store.settings.language.ui.delete, role: .destructive) {
                store.deleteSession(session.id)
            }
            Button(store.settings.language.ui.cancel, role: .cancel) {}
        } message: {
            Text("\(store.settings.language.ui.deleteConfirm) \"\(session.name)\"? \(store.settings.language.ui.cantUndo)")
        }
        .alert("Add tag", isPresented: $showAddTagAlert) {
            TextField("tag", text: $newTagText)
            Button("Add") {
                if let sid = tagPromptSessionId, !newTagText.isEmpty {
                    store.addTag(newTagText, to: sid)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Tags are lowercased free-form labels. Used for cross-cutting filters.")
        }
    }

    /// Compose the subtitle metadata as a single Text so it truncates as
    /// one unit instead of wrapping each chunk independently.
    private func metadataLine(for session: Session) -> Text {
        let folder = URL(fileURLWithPath: session.workDir).lastPathComponent
        var parts: [String] = [folder]

        if store.settings.enableRepoAwareness,
           let git = GitStatus.info(for: session.workDir) {
            let branch = git.dirtyCount > 0 ? "\(git.branch)●" : git.branch
            parts.append(branch)
        }

        if !session.messages.isEmpty {
            parts.append("\(session.messages.count) \(store.settings.language.ui.msgs)")
        }

        parts.append(relativeTime(session.createdAt))

        // U+00B7 (·) as the separator — same as before but baked into one string.
        return Text(Image(systemName: "folder"))
            + Text(" ")
            + Text(parts.joined(separator: " · "))
    }

    private func relativeTime(_ date: Date) -> String {
        let ui = store.settings.language.ui
        let seconds = Int(-date.timeIntervalSinceNow)
        if seconds < 60 { return ui.justNow }
        if seconds < 3600 { return "\(seconds / 60) \(ui.mAgo)" }
        if seconds < 86400 { return "\(seconds / 3600) \(ui.hAgo)" }
        if seconds < 172800 { return ui.yesterday }
        if seconds < 604800 { return "\(seconds / 86400) \(ui.dAgo)" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}
