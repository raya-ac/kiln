import SwiftUI

private struct WorkspaceWidthKey: EnvironmentKey { static let defaultValue = 1400.0 }
extension EnvironmentValues {
    var workspaceWidth: Double {
        get { self[WorkspaceWidthKey.self] }
        set { self[WorkspaceWidthKey.self] = newValue }
    }
}

enum WorkspaceVisibility {
    static func sessions(collapsed: Bool, focused: Bool, inspector: Bool, width: Double) -> Bool {
        !collapsed && !focused && (!inspector || width >= 1120)
    }
}

struct WorkspaceShell: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage("sidebarCollapsed") private var sidebarCollapsed = false
    @AppStorage("workspaceInspectorVisible") private var inspectorVisible = false
    @AppStorage("sidebarWidth") private var sidebarWidth = 260.0
    @AppStorage("rightPanelWidth") private var inspectorWidth = 420.0
    @AppStorage("focusMode") private var focusMode = false

    var body: some View {
        GeometryReader { geometry in
            let showInspector = inspectorVisible && store.activeSession?.kind == .code && !focusMode
            let showSessions = WorkspaceVisibility.sessions(collapsed: sidebarCollapsed, focused: focusMode,
                                                           inspector: showInspector, width: geometry.size.width)
            let rail = focusMode ? 0.0 : 52.0
            let left = showSessions ? min(max(230, sidebarWidth), max(0, geometry.size.width - rail - 428)) : 0
            let right = showInspector ? min(max(300, inspectorWidth), max(0, geometry.size.width - rail - left - 436)) : 0
            HStack(spacing: 0) {
                if !focusMode { WorkspaceNavigationRail().frame(width: rail) }
                if showSessions {
                    SidebarView().frame(width: left)
                    ResizableDivider(collapseSide: .left, showCollapseButton: true,
                        onDrag: { sidebarWidth = min(420, max(230, sidebarWidth + $0)) },
                        onCollapse: { sidebarCollapsed = true })
                }
                Group {
                    if store.activeSession != nil || store.playingVideo != nil { MainTabbedView() }
                    else { EmptyStateView() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if showInspector {
                    ResizableDivider(collapseSide: .right, showCollapseButton: true,
                        onDrag: { inspectorWidth = min(700, max(300, inspectorWidth - $0)) },
                        onCollapse: { inspectorVisible = false })
                    RightPanel().frame(width: right).clipped()
                }
            }.environment(\.workspaceWidth, geometry.size.width)
        }
    }
}

struct WorkspaceNavigationRail: View {
    @EnvironmentObject private var store: AppStore
    @AppStorage("workspaceInspectorVisible") private var inspectorVisible = false
    @State private var taps = BrandTapSequence()

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "flame.fill").font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.kilnBg).frame(width: 30, height: 32)
                .background(Color.kilnAccent).clipShape(RoundedRectangle(cornerRadius: 7))
                .contentShape(Rectangle()).onTapGesture {
                    if taps.tap() { ToastCenter.shared.show("theo is a larper", kind: .info, duration: 4) }
                }.padding(.bottom, 12)
            ForEach(SessionKind.allCases) { kind in
                WorkspaceIconButton(icon: kind.icon, label: kind == .code ? "Code chats" : "Chats", active: store.selectedSidebarTab == kind, identifier: "workspace.navigation." + kind.rawValue) {
                    guard store.selectedSidebarTab != kind else { return }
                    store.selectedSidebarTab = kind
                    store.activeSessionId = store.sortedSessions.first(where: { $0.kind == kind && !$0.isArchived })?.id
                }
            }
            Divider().padding(.horizontal, 12).padding(.vertical, 4)
            ForEach([RightTab.files, .git, .terminal]) { tab in
                WorkspaceIconButton(icon: tab.icon, label: tab.label, active: inspectorVisible && store.selectedWorkspaceTab == tab, identifier: "workspace.navigation." + tab.rawValue) {
                    if inspectorVisible && store.selectedWorkspaceTab == tab { inspectorVisible = false }
                    else { store.openWorkspacePanel(tab) }
                }.disabled(store.activeSession?.kind != .code)
            }
            WorkspaceIconButton(icon: "wrench.and.screwdriver", label: "All tools", identifier: "workspace.navigation.tools") { store.openTools() }
            WorkspaceIconButton(icon: "desktopcomputer", label: "Computer use", identifier: "workspace.navigation.computer") { store.openTools(.computer) }
            Spacer(minLength: 12)
            WorkspaceIconButton(icon: "command", label: "Commands", identifier: "workspace.navigation.commands") { store.showCommandPalette = true }
            WorkspaceIconButton(icon: "gearshape", label: "Settings", identifier: "workspace.navigation.settings") { store.showSettings = true }
        }.padding(.vertical, 18).frame(maxHeight: .infinity).frame(width: 52)
            .background(Color.kilnSurface)
            .overlay(alignment: .trailing) { Color.kilnBorderSubtle.frame(width: 1) }
    }
}
