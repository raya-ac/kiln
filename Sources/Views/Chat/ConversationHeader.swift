import SwiftUI

struct ConversationHeader: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage("sidebarCollapsed") private var sidebarCollapsed = false
    @AppStorage("rightPanelCollapsed") private var toolsCollapsed = false
    @AppStorage("classicWorkspace") private var classicWorkspace = false
    @AppStorage("workspaceInspectorVisible") private var inspectorVisible = false
    @AppStorage("focusMode") private var focusMode = false
    @Environment(\.workspaceWidth) private var workspaceWidth
    @State private var sharingReadme = false
    let showInstructions: () -> Void

    private var sessionsVisible: Bool {
        classicWorkspace ? !sidebarCollapsed : WorkspaceVisibility.sessions(collapsed: sidebarCollapsed, focused: focusMode,
            inspector: inspectorVisible && store.activeSession?.kind == .code, width: workspaceWidth)
    }

    var body: some View {
        if let session = store.activeSession {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    WorkspaceIconButton(icon: "sidebar.left", label: "Toggle sessions", active: sessionsVisible) {
                        if sessionsVisible { sidebarCollapsed = true }
                        else {
                            if focusMode { store.toggleFocusMode() }
                            if !classicWorkspace {
                                if workspaceWidth < 1120 && session.kind == .code { inspectorVisible = false }
                            }
                            sidebarCollapsed = false
                        }
                    }
                    Divider().frame(height: 18).padding(.trailing, 4)
                    Text(session.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.kilnText)
                        .lineLimit(1).help(session.name)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if store.isSessionBusy(session.id) { ActivityBadge(store: store) }
                    if classicWorkspace || focusMode {
                        WorkspaceIconButton(icon: "wrench.and.screwdriver", label: "Tools") { store.openTools() }
                    }
                    Menu {
                        Button("Session details") { store.showSessionInfo = true }
                        Button("Instructions", action: showInstructions)
                        Button("Tool timeline") { store.showToolTimeline = true }
                        Divider()
                        Button("Share as README…") { sharingReadme = true }
                            .disabled(session.messages.isEmpty)
                        Divider()
                        Button("Compact conversation") { Task { await store.compact() } }
                            .disabled(store.isSessionBusy(session.id) || session.messages.isEmpty || store.compactingSessionIds.contains(session.id))
                    } label: { Image(systemName: "ellipsis").frame(width: 30, height: 30) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .foregroundStyle(Color.kilnTextSecondary).help("Conversation actions")
                    .accessibilityLabel("Conversation actions")
                    if session.kind == .code {
                        WorkspaceIconButton(icon: "sidebar.right", label: "Toggle workspace tools", active: !focusMode && (classicWorkspace ? !toolsCollapsed : inspectorVisible)) {
                            let visible = !focusMode && (classicWorkspace ? !toolsCollapsed : inspectorVisible)
                            if focusMode { store.toggleFocusMode() }
                            if classicWorkspace { toolsCollapsed = visible } else { inspectorVisible = !visible }
                        }
                    }
                }
                HStack(spacing: 8) {
                    WorkDirButton(session: session)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if session.forkedFrom != nil {
                        Image(systemName: "arrow.triangle.branch").foregroundStyle(Color.kilnTextTertiary).help("Forked conversation")
                    }
                    HStack(spacing: 6) {
                        ModelBrandIcon(brand: session.model.brand, size: 12)
                        Text(session.model.label)
                    }
                        .font(.system(size: 11))
                        .foregroundStyle(Color.kilnTextTertiary)
                        .lineLimit(1).truncationMode(.middle)
                        .help(session.model.helpText)
                        .frame(maxWidth: 200, alignment: .trailing)
                }
                .font(.system(size: 12))
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            .background(Color.kilnBg)
            .sheet(isPresented: $sharingReadme) {
                if let session = store.activeSession {
                    ShareReadmeSheet(session: session)
                        .onExitCommand { sharingReadme = false }
                }
            }
        }
    }
}
