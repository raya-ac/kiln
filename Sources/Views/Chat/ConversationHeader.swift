import SwiftUI

struct ConversationHeader: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage("sidebarCollapsed") private var sidebarCollapsed = false
    @AppStorage("rightPanelCollapsed") private var toolsCollapsed = false
    let showInstructions: () -> Void

    var body: some View {
        if let session = store.activeSession {
            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Text(session.name)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.kilnText)
                        .lineLimit(1).help(session.name)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if store.isSessionBusy(session.id) { ActivityBadge(store: store) }
                    Menu {
                        Button("Session details") { store.showSessionInfo = true }
                        Button("Instructions", action: showInstructions)
                        Button("Tool timeline") { store.showToolTimeline = true }
                        Divider()
                        Button("Compact conversation") { Task { await store.compact() } }
                            .disabled(store.isSessionBusy(session.id) || session.messages.isEmpty || store.compactingSessionIds.contains(session.id))
                    } label: { Image(systemName: "ellipsis").frame(width: 30, height: 30) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .foregroundStyle(Color.kilnTextSecondary).help("Conversation actions")
                    .accessibilityLabel("Conversation actions")
                    WorkspaceIconButton(icon: "sidebar.left", label: "Toggle sessions", active: !sidebarCollapsed) { sidebarCollapsed.toggle() }
                    if session.kind == .code {
                        WorkspaceIconButton(icon: "sidebar.right", label: "Toggle workspace tools", active: !toolsCollapsed) { toolsCollapsed.toggle() }
                    }
                }
                HStack(spacing: 8) {
                    WorkDirButton(session: session)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if session.forkedFrom != nil {
                        Image(systemName: "arrow.triangle.branch").foregroundStyle(Color.kilnTextTertiary).help("Forked conversation")
                    }
                    ModelPickerButton(selection: Binding(get: { session.model }, set: { store.setModel($0) }))
                        .disabled(store.isSessionBusy(session.id))
                        .frame(maxWidth: 200, alignment: .trailing)
                }
                .font(.system(size: 12))
            }
            .padding(.horizontal, 24).padding(.vertical, 14)
            .background(Color.kilnBg)
        }
    }
}
