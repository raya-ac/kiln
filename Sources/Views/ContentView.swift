import SwiftUI
import UniformTypeIdentifiers
import AVKit
import UserNotifications

// MARK: - Panel slots (reorderable)

enum PanelSlot: String, Codable, CaseIterable, Identifiable {
    case sessions, chat, tools
    var id: String { rawValue }
}

struct ContentView: View {
    @EnvironmentObject var store: AppStore

    @AppStorage("panelOrder") private var panelOrderRaw: String = "sessions,chat,tools"
    @AppStorage("sidebarWidth") private var sidebarWidth: Double = 220
    @AppStorage("rightPanelWidth") private var rightPanelWidth: Double = 420
    @AppStorage("sidebarCollapsed") private var sidebarCollapsed: Bool = false
    @AppStorage("rightPanelCollapsed") private var rightPanelCollapsed: Bool = false

    private let sidebarMin: Double = 180
    private let sidebarMax: Double = 420
    private let rightMin: Double = 300
    /// Absolute max; the GeometryReader clamp can lower this further based
    /// on the live window width.
    private let rightMax: Double = 700
    /// Minimum chat column width — prevents the right/left panels from being
    /// resized so wide they cover the chat and its toolbar. Enforced live.
    private let chatMin: Double = 420

    @State private var dragTargetSlot: PanelSlot?

    private var panelOrder: [PanelSlot] {
        let parsed = panelOrderRaw.split(separator: ",").compactMap { PanelSlot(rawValue: String($0)) }
        // Ensure all slots present exactly once
        var seen = Set<PanelSlot>()
        var result: [PanelSlot] = []
        for s in parsed where !seen.contains(s) { seen.insert(s); result.append(s) }
        for s in PanelSlot.allCases where !seen.contains(s) { result.append(s) }
        return result
    }

    private var visibleSlots: [PanelSlot] {
        panelOrder.filter { slot in
            switch slot {
            case .sessions: return true
            case .chat: return true
            case .tools: return store.activeSession?.kind == .code
            }
        }
    }

    private func movePanel(_ source: PanelSlot, toIndexOf target: PanelSlot) {
        var order = panelOrder
        guard let fromIdx = order.firstIndex(of: source),
              let toIdx = order.firstIndex(of: target),
              fromIdx != toIdx else { return }
        let item = order.remove(at: fromIdx)
        let insertIdx = toIdx > fromIdx ? toIdx : toIdx
        order.insert(item, at: insertIdx)
        withAnimation(.easeInOut(duration: 0.22)) {
            panelOrderRaw = order.map(\.rawValue).joined(separator: ",")
        }
    }

    var body: some View {
        GeometryReader { geo in
            // Compute effective widths for this frame, then write them back
            // into state *once* per change (avoids re-render loops). Using
            // task(id:) so mutations happen off the current render pass.
            let totalWidth = geo.size.width
            let railWidth: Double = 36
            let dividerWidth: Double = 8
            let slots = visibleSlots
            let slotCount = Double(slots.count)
            let availableForPanels = max(0, totalWidth - dividerWidth * (slotCount - 1))

            // Only reserve space for panels that are actually visible. When
            // switching from a code session (tools visible) to a chat session
            // (tools hidden), the freed space flows into the chat column.
            let sessionsVisible = slots.contains(.sessions)
            let toolsVisible = slots.contains(.tools)
            let leftReserved: Double = sessionsVisible ? (sidebarCollapsed ? railWidth : min(sidebarWidth, availableForPanels - (toolsVisible ? (rightPanelCollapsed ? railWidth : rightMin) : 0) - chatMin)) : 0
            let rightReserved: Double = toolsVisible ? (rightPanelCollapsed ? railWidth : min(rightPanelWidth, availableForPanels - leftReserved - chatMin)) : 0
            let leftUsed = leftReserved
            let rightUsed = rightReserved
            let chatUsed = max(chatMin, availableForPanels - leftUsed - rightUsed)

            HStack(spacing: 0) {
                let slots = visibleSlots
                ForEach(Array(slots.enumerated()), id: \.element) { idx, slot in
                    renderSlot(slot, chatWidth: chatUsed, leftWidth: leftUsed, rightWidth: rightUsed)

                if idx < slots.count - 1 {
                    let leftSlot = slot
                    let rightSlot = slots[idx + 1]
                    ResizableDivider(
                        collapseSide: dividerCollapseSide(left: leftSlot, right: rightSlot),
                        showCollapseButton: dividerShouldShowCollapseButton(left: leftSlot, right: rightSlot),
                        onDrag: { delta in handleDrag(leftSlot: leftSlot, rightSlot: rightSlot, delta: delta) },
                        onCollapse: { collapseAdjacentPanel(left: leftSlot, right: rightSlot) }
                    )
                }
                }
            }
        } // GeometryReader
        .background(Color.kilnBg)
        .safeAreaInset(edge: .top, spacing: 0) {
            // Launch-time recovery strip — any sessions marked interrupted
            // (from the previous app run) get surfaced once, with a jump
            // button each and a dismiss-all.
            if !store.launchRecoveryDismissed && !store.interruptedSessions.isEmpty {
                LaunchRecoveryBanner()
            }
        }
        .preferredColorScheme(Color.kilnPreferredColorScheme)
        .sheet(isPresented: $store.showNewSessionSheet) {
            NewSessionSheet()
                .preferredColorScheme(Color.kilnPreferredColorScheme)
        }
        .sheet(isPresented: $store.showSessionTemplates) {
            SessionTemplatesView()
                .environmentObject(store)
                .preferredColorScheme(Color.kilnPreferredColorScheme)
        }
        // PreToolUse approvals: while the queue is non-empty, block on the
        // head of the queue. The hook that spawned the request is suspended
        // on a CheckedContinuation until the user resolves it.
        .sheet(isPresented: Binding(
            get: { !store.pendingApprovals.isEmpty },
            set: { _ in }
        )) {
            if let approval = store.pendingApprovals.first {
                ApprovalDialog(approval: approval)
                    .environmentObject(store)
                    .preferredColorScheme(Color.kilnPreferredColorScheme)
            }
        }
        .overlay {
            if store.showCommandPalette {
                ZStack {
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                        .onTapGesture { store.showCommandPalette = false }
                    VStack {
                        Spacer().frame(height: 96)
                        CommandPaletteView()
                            .transition(.move(edge: .top).combined(with: .opacity))
                        Spacer()
                    }
                }
                .transition(.opacity)
                .zIndex(10)
            }
            if store.showGlobalSearch {
                ZStack {
                    Color.black.opacity(0.35)
                        .ignoresSafeArea()
                        .onTapGesture { store.showGlobalSearch = false }
                    VStack {
                        Spacer().frame(height: 80)
                        GlobalSearchView()
                            .transition(.move(edge: .top).combined(with: .opacity))
                        Spacer()
                    }
                }
                .transition(.opacity)
                .zIndex(10)
            }

            if store.showShortcutsOverlay {
                ZStack {
                    Color.black.opacity(0.4)
                        .ignoresSafeArea()
                        .onTapGesture { store.showShortcutsOverlay = false }
                    ShortcutsOverlay()
                        .transition(.scale(scale: 0.96).combined(with: .opacity))
                }
                .transition(.opacity)
                .zIndex(11)
            }
        }
        .animation(.easeOut(duration: 0.15), value: store.showCommandPalette)
        .animation(.easeOut(duration: 0.15), value: store.showGlobalSearch)
        .onAppear { CompletionNotifier.shared.requestAuthorization() }
        .onChange(of: store.isBusy) { wasBusy, isBusy in
            if wasBusy && !isBusy && store.settings.notifyOnCompletion {
                CompletionNotifier.shared.notifyIfUnfocused(
                    sessionName: store.activeSession?.name ?? "Session",
                    playSound: store.settings.notifySound
                )
            }
        }
        .tint(Color(hexString: store.settings.accentHex))
        .environment(\.kilnAccent, Color(hexString: store.settings.accentHex))
        .environment(\.kilnFontScale, store.settings.fontScale.factor)
    }

    // MARK: - Slot rendering

    @ViewBuilder
    private func renderSlot(_ slot: PanelSlot, chatWidth: Double, leftWidth: Double, rightWidth: Double) -> some View {
        switch slot {
        case .sessions:
            if sidebarCollapsed {
                CollapsedRail(side: railSide(for: .sessions)) {
                    withAnimation(.easeInOut(duration: 0.18)) { sidebarCollapsed = false }
                }
                .onDrop(of: [UTType.plainText], delegate: PanelDropDelegate(
                    targetSlot: .sessions, dragTargetSlot: $dragTargetSlot,
                    onDrop: { src in if src != .sessions { movePanel(src, toIndexOf: .sessions) } }
                ))
            } else {
                draggablePanel(slot: .sessions) {
                    SidebarView()
                        .frame(width: leftWidth)
                }
            }

        case .chat:
            if store.activeSession != nil || store.playingVideo != nil {
                draggablePanel(slot: .chat) {
                    MainTabbedView()
                        .frame(width: chatWidth)
                        .frame(maxHeight: .infinity)
                }
            } else {
                EmptyStateView()
                    .frame(width: chatWidth)
                    .frame(maxHeight: .infinity)
            }

        case .tools:
            if rightPanelCollapsed {
                CollapsedRail(side: railSide(for: .tools)) {
                    withAnimation(.easeInOut(duration: 0.18)) { rightPanelCollapsed = false }
                }
                .onDrop(of: [UTType.plainText], delegate: PanelDropDelegate(
                    targetSlot: .tools, dragTargetSlot: $dragTargetSlot,
                    onDrop: { src in if src != .tools { movePanel(src, toIndexOf: .tools) } }
                ))
            } else {
                draggablePanel(slot: .tools) {
                    RightPanel()
                        .frame(width: rightWidth)
                        .clipped()
                }
            }
        }
    }

    private func railSide(for slot: PanelSlot) -> CollapsedRail.Side {
        // Point the chevron toward where its expanded content would appear —
        // i.e., toward the chat, which is wherever the chat slot currently sits.
        guard let myIdx = visibleSlots.firstIndex(of: slot),
              let chatIdx = visibleSlots.firstIndex(of: .chat)
        else { return .left }
        return chatIdx > myIdx ? .left : .right
    }

    // MARK: - Drag + drop for reordering

    @ViewBuilder
    private func draggablePanel<V: View>(slot: PanelSlot, @ViewBuilder _ content: () -> V) -> some View {
        content()
            // Drop highlight — non-hit-testing overlay
            .overlay(
                Rectangle()
                    .fill(Color.kilnAccent.opacity(dragTargetSlot == slot ? 0.08 : 0))
                    .allowsHitTesting(false)
            )
            // Drag handle — small visible grip at top-center, only this area
            // initiates reorder-drag. The rest of the panel stays fully
            // interactive for normal clicks.
            .overlay(alignment: .top) {
                DragHandle(slot: slot)
                    .onDrag { NSItemProvider(object: slot.rawValue as NSString) }
                    .padding(.top, 2)
            }
            // Drop target applies to the whole panel but doesn't block hit testing
            .onDrop(of: [UTType.plainText], delegate: PanelDropDelegate(
                targetSlot: slot,
                dragTargetSlot: $dragTargetSlot,
                onDrop: { src in if src != slot { movePanel(src, toIndexOf: slot) } }
            ))
    }

    // MARK: - Divider resize logic

    private func handleDrag(leftSlot: PanelSlot, rightSlot: PanelSlot, delta: CGFloat) {
        // Prefer resizing a fixed-width panel. Chat is flexible.
        switch (leftSlot, rightSlot) {
        case (.chat, .tools):
            rightPanelWidth = clamp(rightPanelWidth - Double(delta), rightMin, rightMax)
        case (.chat, .sessions):
            sidebarWidth = clamp(sidebarWidth - Double(delta), sidebarMin, sidebarMax)
        case (.tools, .chat):
            rightPanelWidth = clamp(rightPanelWidth + Double(delta), rightMin, rightMax)
        case (.sessions, .chat):
            sidebarWidth = clamp(sidebarWidth + Double(delta), sidebarMin, sidebarMax)
        case (.sessions, .tools), (.tools, .sessions):
            // Two fixed panels adjacent — resize the left one
            if leftSlot == .sessions {
                sidebarWidth = clamp(sidebarWidth + Double(delta), sidebarMin, sidebarMax)
            } else {
                rightPanelWidth = clamp(rightPanelWidth + Double(delta), rightMin, rightMax)
            }
        default:
            break
        }
    }

    private func dividerCollapseSide(left: PanelSlot, right: PanelSlot) -> ResizableDivider.CollapseSide {
        // Chevron points toward the panel that would be collapsed.
        if left == .chat { return .right }
        if right == .chat { return .left }
        // Two fixed panels — point toward the left one by default
        return .left
    }

    private func dividerShouldShowCollapseButton(left: PanelSlot, right: PanelSlot) -> Bool {
        left != .chat || right != .chat
    }

    private func collapseAdjacentPanel(left: PanelSlot, right: PanelSlot) {
        // Collapse the fixed-width panel adjacent to this divider.
        let target: PanelSlot
        if left == .chat {
            target = right
        } else if right == .chat {
            target = left
        } else {
            target = left
        }
        withAnimation(.easeInOut(duration: 0.18)) {
            switch target {
            case .sessions: sidebarCollapsed = true
            case .tools: rightPanelCollapsed = true
            case .chat: break
            }
        }
    }

    private func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T {
        min(max(v, lo), hi)
    }
}

// MARK: - Drag handle grip

struct DragHandle: View {
    let slot: PanelSlot
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 8, weight: .bold))
        }
        .foregroundStyle(hovering ? Color.kilnAccent : Color.kilnTextTertiary.opacity(0.6))
        .frame(width: 28, height: 12)
        .background(hovering ? Color.kilnSurfaceHover : Color.kilnSurface.opacity(0.8))
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(Color.kilnBorder.opacity(hovering ? 1 : 0.4), lineWidth: 1)
        )
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
        }
        .help("Drag to rearrange this panel")
    }
}

// MARK: - Panel drop delegate (tracks hover state for highlight)

struct PanelDropDelegate: DropDelegate {
    let targetSlot: PanelSlot
    @Binding var dragTargetSlot: PanelSlot?
    let onDrop: (PanelSlot) -> Void

    func dropEntered(info: DropInfo) { dragTargetSlot = targetSlot }
    func dropExited(info: DropInfo) { if dragTargetSlot == targetSlot { dragTargetSlot = nil } }

    func performDrop(info: DropInfo) -> Bool {
        dragTargetSlot = nil
        guard let provider = info.itemProviders(for: [UTType.plainText]).first else { return false }
        provider.loadObject(ofClass: NSString.self) { obj, _ in
            guard let s = obj as? String, let source = PanelSlot(rawValue: s) else { return }
            DispatchQueue.main.async { onDrop(source) }
        }
        return true
    }
}

// MARK: - Resizable divider with hover cursor + collapse chevron

struct ResizableDivider: View {
    enum CollapseSide { case left, right }
    let collapseSide: CollapseSide
    var showCollapseButton: Bool = true
    let onDrag: (CGFloat) -> Void
    let onCollapse: () -> Void

    @State private var hovering = false
    @State private var dragging = false
    /// Track the last translation so we can emit deltas to `onDrag` instead of
    /// the cumulative `value.translation` (which was causing the divider to
    /// jump — earlier code fed total translation as if it were a delta).
    @State private var lastTranslationX: CGFloat = 0

    var body: some View {
        // Total hit area is 8pt wide (4pt on each side of the visual line).
        // Outer frame is 8, inner visible line is 1pt centered.
        ZStack {
            // Invisible wide hit strip. Everything clicky/draggable lives here.
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .onHover { inside in
                    hovering = inside
                    if inside {
                        NSCursor.resizeLeftRight.push()
                    } else if !dragging {
                        NSCursor.pop()
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if !dragging {
                                dragging = true
                                lastTranslationX = 0
                            }
                            let delta = value.translation.width - lastTranslationX
                            lastTranslationX = value.translation.width
                            onDrag(delta)
                        }
                        .onEnded { _ in
                            dragging = false
                            lastTranslationX = 0
                            if !hovering { NSCursor.pop() }
                        }
                )
                .help("Drag to resize")

            // Visible 1pt line, centered in the hit area. Brighter on hover.
            Rectangle()
                .fill(hovering || dragging ? Color.kilnAccent.opacity(0.6) : Color.kilnBorder)
                .frame(width: 1)
                .allowsHitTesting(false)
                .animation(.easeOut(duration: 0.12), value: hovering)

            if showCollapseButton {
                VStack {
                    Spacer()
                    CollapseChevron(
                        direction: collapseSide == .left ? "chevron.left" : "chevron.right",
                        action: onCollapse
                    )
                    Spacer()
                }
                .allowsHitTesting(true)
            }
        }
        .frame(width: 8)
    }
}

private struct CollapseChevron: View {
    let direction: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: direction)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(hovering ? Color.kilnBg : Color.kilnTextTertiary)
                .frame(width: 14, height: 28)
                .background(hovering ? Color.kilnAccent : Color.kilnSurface)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.kilnBorder, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Collapse panel")
    }
}

// MARK: - Collapsed rail

struct CollapsedRail: View {
    enum Side { case left, right }
    let side: Side
    let onExpand: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: onExpand) {
            Image(systemName: side == .left ? "sidebar.left" : "sidebar.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(hovering ? Color.kilnAccent : Color.kilnTextTertiary)
                .frame(width: 24)
                .frame(maxHeight: .infinity)
                .background(hovering ? Color.kilnSurfaceHover : Color.kilnSurface)
                .overlay(
                    Rectangle()
                        .fill(Color.kilnBorder)
                        .frame(width: 1),
                    alignment: side == .left ? .trailing : .leading
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(side == .left ? "Expand" : "Expand")
    }
}

struct EmptyStateView: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        VStack(spacing: 20) {
            // Large app mark — flame glyph on an accent-tinted rounded square
            ZStack {
                RoundedRectangle(cornerRadius: 18)
                    .fill(
                        LinearGradient(
                            colors: [Color.kilnAccent, Color.kilnAccent.opacity(0.6)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 84, height: 84)
                    .shadow(color: Color.kilnAccent.opacity(0.4), radius: 20, y: 6)
                Image(systemName: "flame.fill")
                    .font(.system(size: 40, weight: .heavy))
                    .foregroundStyle(Color.kilnBg)
            }
            Text("Kiln Code")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(Color.kilnText)
            Text(store.settings.language.ui.tagline)
                .font(.system(size: 14))
                .foregroundStyle(Color.kilnTextSecondary)

            Button {
                store.showNewSessionSheet = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                    Text(store.settings.language.ui.newSession)
                        .font(.system(size: 13, weight: .semibold))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color.kilnAccent)
                .foregroundStyle(Color.kilnBg)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.kilnBg)
    }
}

struct NewSessionSheet: View {
    @EnvironmentObject var store: AppStore
    @State private var workDir = NSHomeDirectory()
    @State private var model: ClaudeModel = .sonnet46
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 24) {
            // Header
            HStack {
                Text(store.settings.language.ui.newSession)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.kilnText)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.kilnTextSecondary)
                        .frame(width: 24, height: 24)
                        .background(Color.kilnSurfaceElevated)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }

            // Working directory
            VStack(alignment: .leading, spacing: 6) {
                Text(store.settings.language.ui.workingDirectory)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.kilnTextTertiary)
                    .tracking(1)
                HStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "folder.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.kilnAccent)
                        TextField(store.settings.language.ui.path, text: $workDir)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Color.kilnText)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.kilnSurface)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.kilnBorder, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    Button(store.settings.language.ui.browse) {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.directoryURL = URL(fileURLWithPath: workDir)
                        if panel.runModal() == .OK, let url = panel.url {
                            workDir = url.path
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.kilnText)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.kilnSurfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }

            // Model
            VStack(alignment: .leading, spacing: 6) {
                Text(store.settings.language.ui.model)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.kilnTextTertiary)
                    .tracking(1)
                VStack(spacing: 4) {
                    HStack(spacing: 2) {
                        ForEach(ClaudeModel.allCases) { m in
                            Button {
                                model = m
                            } label: {
                                VStack(spacing: 1) {
                                    Text(m.label)
                                        .font(.system(size: 12, weight: .medium))
                                    Text(m.tier)
                                        .font(.system(size: 9, weight: .regular))
                                        .foregroundStyle(model == m ? Color.kilnBg.opacity(0.7) : Color.kilnTextTertiary)
                                }
                                .foregroundStyle(model == m ? Color.kilnBg : Color.kilnTextSecondary)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 8)
                                .background(model == m ? Color.kilnAccent : Color.kilnSurface)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            .buttonStyle(.plain)
                            .help(m.fullId)
                        }
                    }
                    .padding(3)
                    .background(Color.kilnSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    Text(model.fullId)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.kilnTextTertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            // Actions
            HStack(spacing: 12) {
                Button { dismiss() } label: {
                    Text(store.settings.language.ui.cancel)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.kilnTextSecondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.kilnSurfaceElevated)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.cancelAction)

                Button {
                    store.createSession(workDir: workDir, model: model)
                } label: {
                    Text(store.settings.language.ui.createSession)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.kilnBg)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color.kilnAccent)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(Color.kilnBg)
    }
}

// AVPlayerView wrapped for SwiftUI. Using AVPlayerView directly avoids
// SwiftUI's `VideoPlayer` runtime symbol-loading bug in SwiftPM builds.
struct AVPlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer
    var showsControls: Bool = true

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = showsControls ? .floating : .none
        v.showsFullScreenToggleButton = false
        v.videoGravity = .resizeAspect
        return v
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
        nsView.controlsStyle = showsControls ? .floating : .none
    }
}

// MARK: - Main Tabbed View
//
// The main content area. Always has a "Chat" tab; when a video is playing
// it adds a second tab for the video. Tabs render along the top. The chat
// tab is only visible if there's an active session.

struct MainTabbedView: View {
    @EnvironmentObject var store: AppStore
    @State private var selected: MainTab = .chat

    enum MainTab: Hashable { case chat, video }

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar — only show if there's more than one tab available
            if store.playingVideo != nil {
                tabBar
                Rectangle().fill(Color.kilnBorder).frame(height: 1)
            }

            // Body
            Group {
                if selected == .video, let url = store.playingVideo {
                    InlineVideoView(url: url) {
                        store.playingVideo = nil
                        selected = .chat
                    }
                } else if store.activeSession != nil {
                    ChatView()
                        .overlay(alignment: .bottomTrailing) {
                            // Mini player stays visible + playing on the
                            // chat tab so the video doesn't pause when you
                            // switch away from the video tab.
                            if store.playingVideo != nil {
                                MiniVideoView()
                            }
                        }
                } else {
                    EmptyStateView()
                }
            }
        }
        .onChange(of: store.playingVideo) { _, newValue in
            // Auto-switch to the video tab when one opens; back to chat when closed.
            if newValue != nil {
                selected = .video
            } else {
                selected = .chat
            }
        }
        .onAppear {
            if store.playingVideo != nil { selected = .video }
        }
    }

    @ViewBuilder
    private var tabBar: some View {
        HStack(spacing: 0) {
            if store.activeSession != nil {
                tabButton(
                    icon: "bubble.left.fill",
                    label: store.activeSession?.name ?? "Chat",
                    active: selected == .chat,
                    closable: false,
                    onSelect: { selected = .chat },
                    onClose: nil
                )
            }
            if let url = store.playingVideo {
                tabButton(
                    icon: "play.rectangle.fill",
                    label: url.lastPathComponent,
                    active: selected == .video,
                    closable: true,
                    onSelect: { selected = .video },
                    onClose: {
                        store.playingVideo = nil
                        selected = .chat
                    }
                )
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 0)
        .background(Color.kilnSurface)
    }

    @ViewBuilder
    private func tabButton(icon: String, label: String, active: Bool, closable: Bool, onSelect: @escaping () -> Void, onClose: (() -> Void)?) -> some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(active ? Color.kilnAccent : Color.kilnTextTertiary)
                Text(label)
                    .font(.system(size: 12, weight: active ? .semibold : .medium))
                    .foregroundStyle(active ? Color.kilnText : Color.kilnTextSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if closable, let onClose = onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.kilnTextTertiary)
                            .frame(width: 16, height: 16)
                            .background(Color.clear)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Close tab")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(active ? Color.kilnBg : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(active ? Color.kilnBorder : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .padding(.trailing, 4)
    }
}

// MARK: - Inline Video View
//
// Shown inside the main content area as a tab. Just a regular panel with a
// header bar + the video body.

struct InlineVideoView: View {
    let url: URL
    let onClose: () -> Void
    @EnvironmentObject var store: AppStore

    var body: some View {
        Group {
            if let player = store.videoPlayer {
                AVPlayerViewRepresentable(player: player)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 28))
                        .foregroundStyle(Color.kilnError)
                    Text("File not found")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.kilnText)
                    Text(url.path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.kilnTextTertiary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.black)
    }
}

// MARK: - Mini Video View
//
// Picture-in-picture style floating window rendered over the chat. Uses the
// SAME AVPlayer as the fullscreen view so playback is uninterrupted when
// switching between tabs. Draggable, with a close button.

struct MiniVideoView: View {
    @EnvironmentObject var store: AppStore
    @State private var offset: CGSize = CGSize(width: -16, height: -16)
    @State private var dragStart: CGSize = .zero
    private let size = CGSize(width: 280, height: 170)

    var body: some View {
        if let player = store.videoPlayer {
            ZStack(alignment: .topLeading) {
                AVPlayerViewRepresentable(player: player, showsControls: false)
                    .frame(width: size.width, height: size.height)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.kilnBorder, lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.5), radius: 12, y: 4)

                // Drag + close strip
                HStack {
                    Button {
                        store.playingVideo = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(Color.black.opacity(0.5))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Close video")
                    Spacer()
                    // Grab handle
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(6)
                        .background(Color.black.opacity(0.4))
                        .clipShape(Capsule())
                }
                .padding(6)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture()
                        .onChanged { v in
                            offset = CGSize(
                                width: dragStart.width + v.translation.width,
                                height: dragStart.height + v.translation.height
                            )
                        }
                        .onEnded { _ in dragStart = offset }
                )
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            .offset(offset)
            .padding(12)
            .allowsHitTesting(true)
        }
    }
}

// MARK: - Completion Notifier
//
// Fires a macOS user notification when a session finishes generating, but
// only if the app isn't the frontmost application. Saves the user from
// babysitting long agentic runs.

@MainActor
final class CompletionNotifier {
    static let shared = CompletionNotifier()
    private var authorized = false
    private var usable = false

    /// UNUserNotificationCenter raises NSException when invoked from an
    /// unbundled / unsigned binary (e.g. `swift run` without an .app wrapper).
    /// Gate everything on a bundle-identifier check.
    private var isUsable: Bool {
        Bundle.main.bundleIdentifier != nil
    }

    func requestAuthorization() {
        guard isUsable else { return }
        usable = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
            Task { @MainActor in self?.authorized = granted }
        }
    }

    func notifyIfUnfocused(sessionName: String, playSound: Bool = true) {
        guard usable, authorized else { return }
        if NSApp.isActive { return }
        let content = UNMutableNotificationContent()
        content.title = "Claude is done"
        content.body = sessionName
        if playSound { content.sound = .default }
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}

// MARK: - Launch Recovery Banner
//
// Appears when one or more sessions still have `wasInterrupted = true` from
// the previous app run (crash, force-quit, claude subprocess death). Lets
// the user jump to each session to decide whether to resume or dismiss.

struct LaunchRecoveryBanner: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        let count = store.interruptedSessions.count
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color(hex: 0xF59E0B))
            VStack(alignment: .leading, spacing: 2) {
                Text("\(count) \(count == 1 ? "session was" : "sessions were") interrupted last run")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.kilnText)
                Text("Resume from where you left off or dismiss.")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.kilnTextTertiary)
            }

            Spacer()

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(store.interruptedSessions.prefix(5)) { s in
                        Button {
                            store.activeSessionId = s.id
                            store.selectedSidebarTab = s.kind
                        } label: {
                            Text(s.name)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.kilnText)
                                .lineLimit(1)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Color.kilnSurfaceElevated)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                    }
                    if count > 5 {
                        Text("+\(count - 5) more")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.kilnTextTertiary)
                    }
                }
            }
            .frame(maxWidth: 320)

            Button {
                // Dismiss all interruption markers and hide the banner for this run.
                for s in store.interruptedSessions {
                    store.dismissInterrupted(s.id)
                }
                store.launchRecoveryDismissed = true
            } label: {
                Text("Dismiss all")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.kilnTextSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.kilnSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(hex: 0xF59E0B).opacity(0.08))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color(hex: 0xF59E0B).opacity(0.4)).frame(height: 1)
        }
    }
}
