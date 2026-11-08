import SwiftUI
import AppKit

struct ToolShelfView: View {
    @EnvironmentObject private var store: AppStore
    @State private var query = ""
    @State private var failuresOnly = false
    @State private var expanded: Set<String> = []
    @FocusState private var focused: Bool
    @AppStorage("kiln.pinnedTools") private var pinned = "files,terminal,activity"
    private var calls: [IndexedToolCall] { IndexedToolCall.collect(messages: store.activeSession?.messages ?? [], active: store.activeToolCalls) }
    private var panels: [RightTab] {
        RightTab.allCases.filter { query.isEmpty || $0.label.localizedCaseInsensitiveContains(query) }
            .sorted { isPinned($0) == isPinned($1) ? $0.label < $1.label : isPinned($0) }
    }
    private func isPinned(_ tab: RightTab) -> Bool { pinned.split(separator: ",").contains(Substring(tab.rawValue)) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "wrench.and.screwdriver").foregroundStyle(Color.kilnAccent)
                    .frame(width: 30, height: 30).background(Color.kilnAccentMuted.opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Text("Tools").font(.system(size: 17, weight: .semibold))
                Spacer()
                if store.toolShelfTab == .calls {
                    Text("\(calls.count) calls").font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.kilnTextTertiary)
                }
                WorkspaceIconButton(icon: "xmark", label: "Close tools") { store.showToolShelf = false }
            }.padding(.horizontal, 20).padding(.vertical, 12)
            ToolShelfTabs(selection: $store.toolShelfTab).padding(.horizontal, 20).padding(.bottom, 16)
            Divider()
            if store.toolShelfTab == .computer {
                ComputerUseView()
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Color.kilnTextTertiary)
                    TextField(store.toolShelfTab == .calls ? "Filter calls by tool, file, or status" : "Find a tool", text: $query)
                        .textFieldStyle(.plain).focused($focused)
                        .onSubmit {
                            if store.toolShelfTab == .tools, let first = panels.first, store.activeSession?.kind == .code { open(first) }
                        }
                    if !query.isEmpty {
                        WorkspaceIconButton(icon: "xmark.circle", label: "Clear search") { query = "" }
                    }
                    if store.toolShelfTab == .calls {
                        Toggle(isOn: $failuresOnly) { Image(systemName: "exclamationmark.triangle") }
                            .toggleStyle(.button).help("Show failed calls only").accessibilityLabel("Failed calls only")
                    }
                }.padding(10).background(Color.kilnSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 6)).padding(.horizontal, 20).padding(.vertical, 12)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if store.toolShelfTab == .tools {
                            ForEach(panels) { panel in
                                HStack(spacing: 12) {
                                    Button { open(panel) } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: panel.icon).frame(width: 30, height: 30).foregroundStyle(Color.kilnTextSecondary)
                                                .background(Color.kilnSurfaceElevated).clipShape(RoundedRectangle(cornerRadius: 6))
                                            Text(panel.label).font(.system(size: 13, weight: .medium))
                                            Spacer()
                                            Image(systemName: "arrow.up.right").font(.system(size: 10)).foregroundStyle(Color.kilnTextTertiary)
                                        }.padding(.vertical, 8).padding(.horizontal, 8).contentShape(Rectangle())
                                    }.buttonStyle(WorkspaceButtonStyle()).disabled(store.activeSession?.kind != .code)
                                    WorkspaceIconButton(icon: isPinned(panel) ? "pin.fill" : "pin", label: isPinned(panel) ? "Unpin \(panel.label)" : "Pin \(panel.label)", active: isPinned(panel)) { togglePin(panel) }
                                }.padding(.horizontal, 12).padding(.vertical, 2)
                            }
                            if panels.isEmpty { empty("No matching tools") }
                            HStack {
                                Button { store.showToolShelf = false; store.showCommandPalette = true } label: { Label("All commands", systemImage: "command") }
                                Spacer()
                                Button { store.showToolShelf = false; store.openCLIUpdates() } label: { Label("CLI updates", systemImage: "arrow.down.circle") }
                            }.font(.system(size: 12)).buttonStyle(.borderless).padding(20)
                        } else {
                            let matches = calls.filter { $0.matches(query, failuresOnly: failuresOnly) }
                            if matches.isEmpty { empty("No matching tool calls") }
                            ForEach(matches) { call in callRow(call) }
                        }
                    }
                }
            }
        }
        .frame(width: 660, height: min(610, max(400, (NSScreen.main?.visibleFrame.height ?? 800) - 140)))
        .background(Color.kilnBg).foregroundStyle(Color.kilnText)
        .onAppear { focused = store.toolShelfTab != .computer }
        .onChange(of: store.toolShelfTab) { query = ""; focused = store.toolShelfTab != .computer }
        .onExitCommand { store.showToolShelf = false }
    }

    private func empty(_ title: String) -> some View {
        Text(title).font(.system(size: 13)).foregroundStyle(Color.kilnTextTertiary)
            .frame(maxWidth: .infinity, minHeight: 150)
    }

    private func callRow(_ call: IndexedToolCall) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if expanded.contains(call.id) { expanded.remove(call.id) } else { expanded.insert(call.id) }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: call.presentation.symbol).frame(width: 22).foregroundStyle(Color.kilnTextSecondary)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(call.tool.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                        if !call.presentation.summary.isEmpty {
                            Text(call.presentation.summary).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.kilnTextTertiary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: call.presentation.status.symbol)
                        .foregroundStyle(call.presentation.status == .failure ? Color.kilnError : Color.kilnTextSecondary)
                        .help(call.presentation.status.label)
                    Image(systemName: expanded.contains(call.id) ? "chevron.down" : "chevron.right").font(.system(size: 9))
                }.contentShape(Rectangle()).padding(.horizontal, 20).padding(.vertical, 13)
            }.buttonStyle(WorkspaceButtonStyle())
            if expanded.contains(call.id) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(call.presentation.status.label).font(.system(size: 11, weight: .medium))
                        if let duration = call.presentation.duration { Text(String(format: "%.1fs", duration)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.kilnTextTertiary) }
                        Spacer()
                        WorkspaceIconButton(icon: "doc.on.doc", label: "Copy tool output", identifier: "tools.copy." + call.id) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(call.tool.result ?? call.tool.input, forType: .string)
                        }
                    }
                    Text(ToolPresentation.preview(call.tool.input, limit: 4_000)).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    if let output = call.tool.result {
                        Divider()
                        Text(ToolPresentation.preview(output)).font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(call.tool.isError ? Color.kilnError : Color.kilnTextSecondary).textSelection(.enabled)
                    }
                }.padding(.leading, 54).padding(.trailing, 20).padding(.bottom, 14)
            }
            Divider().padding(.leading, 54)
        }
    }

    private func open(_ panel: RightTab) { store.openWorkspacePanel(panel); store.showToolShelf = false }
    private func togglePin(_ tab: RightTab) {
        var items = pinned.split(separator: ",").map(String.init)
        if items.contains(tab.rawValue) { items.removeAll { $0 == tab.rawValue } } else { items.append(tab.rawValue) }
        pinned = items.joined(separator: ",")
    }
}

struct QuickToolRail: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var computer = ComputerUse.shared
    @AppStorage("kiln.pinnedTools") private var pinned = "files,terminal,activity"
    @AppStorage("classicWorkspace") private var classicWorkspace = false
    @AppStorage("focusMode") private var focusMode = false
    var body: some View {
        HStack(spacing: 2) {
            if classicWorkspace || focusMode {
                WorkspaceIconButton(icon: "desktopcomputer", label: "Computer use", active: store.activeSessionId.flatMap { computer.enabled[$0] } != nil, identifier: "composer.tools.computer") { store.openTools(.computer) }
            }
            if store.activeSession?.kind == .code {
                ForEach(pinned.split(separator: ",").compactMap { RightTab(rawValue: String($0)) }.filter {
                    classicWorkspace || focusMode || ![RightTab.files, .git, .terminal].contains($0)
                }) { tab in
                    WorkspaceIconButton(icon: tab.icon, label: tab.label, identifier: "composer.tools." + tab.rawValue) { store.openWorkspacePanel(tab) }
                }
            }
            Spacer(minLength: 4)
            let running = store.activeToolCalls.filter { !$0.isDone && $0.result == nil }
            if let latest = running.last {
                Button { store.openTools(.calls) } label: {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(latest.name).font(.system(size: 11)).lineLimit(1).frame(maxWidth: 120, alignment: .leading)
                        if running.count > 1 { Text("+\(running.count - 1)").font(.system(size: 10, design: .monospaced)) }
                    }
                }.buttonStyle(.plain).help("Open running tool calls")
            }
            if let id = store.activeSessionId, computer.enabled[id] != nil {
                WorkspaceIconButton(icon: "stop.circle.fill", label: "Stop computer access", active: true) { computer.stop(sessionID: id) }
            }
        }.frame(height: 32)
    }
}
