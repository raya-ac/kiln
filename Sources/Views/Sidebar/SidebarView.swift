import SwiftUI
import UniformTypeIdentifiers

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
            .help("Archive selected")

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
            .help("Delete selected")

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
            .help("Clear selection")
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
            .padding(.bottom, 8)

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
        }
        .background(Color.kilnSurface)
        .sheet(isPresented: $store.showSettings) {
            SettingsView()
                .environmentObject(store)
                .preferredColorScheme(.dark)
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
                    HStack(spacing: 3) {
                        Image(systemName: "folder")
                            .font(.system(size: 8))
                        Text(URL(fileURLWithPath: session.workDir).lastPathComponent)
                            .lineLimit(1)

                        // Git branch badge — only when repo awareness is on
                        // and the workdir is inside a git repository.
                        if store.settings.enableRepoAwareness,
                           let git = GitStatus.info(for: session.workDir) {
                            Text("·")
                            HStack(spacing: 2) {
                                Image(systemName: "arrow.triangle.branch")
                                    .font(.system(size: 8))
                                Text(git.branch)
                                    .font(.system(size: 10, design: .monospaced))
                                    .lineLimit(1)
                                if git.dirtyCount > 0 {
                                    Text("●")
                                        .font(.system(size: 7))
                                        .foregroundStyle(Color.kilnAccent)
                                        .help("\(git.dirtyCount) uncommitted change\(git.dirtyCount == 1 ? "" : "s")")
                                }
                            }
                            .foregroundStyle(git.dirtyCount > 0 ? Color.kilnAccent : Color.kilnTextTertiary)
                        }

                        if !session.messages.isEmpty {
                            Text("·")
                            Text("\(session.messages.count) \(store.settings.language.ui.msgs)")
                        }

                        Text("·")
                        Text(relativeTime(session.createdAt))
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(Color.kilnTextTertiary)

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

            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.workDir, forType: .string)
            } label: {
                Label("Copy Path", systemImage: "doc.on.doc")
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
