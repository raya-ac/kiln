import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    // Nested ObservableObjects on `store` (remoteServer, wardenTunnels)
    // don't propagate their @Published mutations through the outer
    // AppStore, so the settings sheet would otherwise only refresh on
    // window re-focus. `refreshTick` is bumped on each nested-object
    // publish (see `.onReceive` in body), forcing a re-render.
    @State private var refreshTick: Int = 0
    @State private var tab: SettingsTab = .settings
    // Local editing buffer for the Port field so typing "9000" doesn't
    // mutate the live server port through the intermediate values 9, 90, 900.
    // Synced from `store.remoteServer.port` on appear and when the server
    // mutates it (e.g. on launch); applied back on submit/focus loss.
    @State private var portDraft: String = ""
    @FocusState private var portFocused: Bool

    enum SettingsTab: String, CaseIterable, Identifiable {
        case settings, stats
        var id: String { rawValue }
        var label: String { self == .settings ? "Settings" : "Stats" }
        var icon: String { self == .settings ? "gearshape" : "chart.bar.fill" }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with tab switcher
            HStack {
                Text(tab == .settings ? store.settings.language.ui.settings : "Stats")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.kilnText)

                Spacer().frame(width: 16)

                HStack(spacing: 2) {
                    ForEach(SettingsTab.allCases) { t in
                        let selected = tab == t
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) { tab = t }
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: t.icon)
                                    .font(.system(size: 10))
                                Text(t.label)
                                    .font(.system(size: 11, weight: .medium))
                            }
                            .foregroundStyle(selected ? Color.kilnBg : Color.kilnTextSecondary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(selected ? Color.kilnAccent : Color.kilnSurface)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                    }
                }

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
            .padding(.horizontal, 24)
            .padding(.vertical, 16)

            Rectangle().fill(Color.kilnBorder).frame(height: 1)

            if tab == .stats {
                StatsView()
            } else {
                settingsScroll
            }
        }
        .frame(width: 540, height: 560)
        .background(Color.kilnBg)
        // Persist on any settings mutation — lets us drop the per-Toggle
        // `saveSettings()` calls and gives SwiftUI a direct `$store.settings.X`
        // binding so toggles animate live instead of waiting for re-open.
        .onChange(of: store.settings) { _, _ in store.saveSettings() }
        // Bridge the nested publishers into this view's update graph.
        .onReceive(store.remoteServer.objectWillChange) { _ in refreshTick &+= 1 }
        .onReceive(store.wardenTunnels.objectWillChange) { _ in refreshTick &+= 1 }
        // Touch refreshTick so SwiftUI tracks it as a dependency.
        .background(Color.clear.id(refreshTick))
    }

    private var settingsScroll: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    // Defaults
                    SettingsSection(title: store.settings.language.ui.defaults) {
                        // Default model
                        SettingsRow(label: store.settings.language.ui.modelLabel) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 2) {
                                    ForEach(ClaudeModel.allCases) { model in
                                        let selected = store.settings.defaultModel == model
                                        Button {
                                            store.settings.defaultModel = model
                                            store.saveSettings()
                                        } label: {
                                            Text(model.label)
                                                .font(.system(size: 11, weight: .medium))
                                                .foregroundStyle(selected ? Color.kilnBg : Color.kilnTextSecondary)
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 5)
                                                .background(selected ? Color.kilnAccent : Color.kilnSurface)
                                                .clipShape(RoundedRectangle(cornerRadius: 5))
                                        }
                                        .buttonStyle(.plain)
                                        .help(model.fullId)
                                    }
                                }
                                Text(store.settings.defaultModel.fullId)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Color.kilnTextTertiary)
                            }
                        }

                        // Default mode
                        SettingsRow(label: store.settings.language.ui.modeLabel) {
                            HStack(spacing: 2) {
                                ForEach(SessionMode.allCases) { mode in
                                    let selected = store.settings.defaultMode == mode
                                    Button {
                                        store.settings.defaultMode = mode
                                        store.saveSettings()
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: mode.icon)
                                                .font(.system(size: 9))
                                            Text(mode.label)
                                                .font(.system(size: 11, weight: .medium))
                                        }
                                        .foregroundStyle(selected ? Color.kilnBg : Color.kilnTextSecondary)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 5)
                                        .background(selected ? Color.kilnAccent : Color.kilnSurface)
                                        .clipShape(RoundedRectangle(cornerRadius: 5))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        // Default permissions
                        SettingsRow(label: store.settings.language.ui.permissionsLabel) {
                            HStack(spacing: 2) {
                                ForEach(PermissionMode.allCases) { perm in
                                    let selected = store.settings.defaultPermissions == perm
                                    Button {
                                        store.settings.defaultPermissions = perm
                                        store.saveSettings()
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: perm.icon)
                                                .font(.system(size: 9))
                                            Text(perm.label)
                                                .font(.system(size: 11, weight: .medium))
                                        }
                                        .foregroundStyle(selected ? Color.kilnBg : Color.kilnTextSecondary)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 5)
                                        .background(selected ? Color.kilnAccent : Color.kilnSurface)
                                        .clipShape(RoundedRectangle(cornerRadius: 5))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        // Default working directory
                        SettingsRow(label: store.settings.language.ui.workDir) {
                            HStack(spacing: 8) {
                                Text(store.settings.defaultWorkDir)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(Color.kilnTextSecondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer()
                                Button(store.settings.language.ui.browse) {
                                    let panel = NSOpenPanel()
                                    panel.canChooseDirectories = true
                                    panel.canChooseFiles = false
                                    panel.directoryURL = URL(fileURLWithPath: store.settings.defaultWorkDir)
                                    if panel.runModal() == .OK, let url = panel.url {
                                        store.settings.defaultWorkDir = url.path
                                        store.saveSettings()
                                    }
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.kilnText)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(Color.kilnSurfaceElevated)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                            }
                        }
                    }

                    // Language
                    SettingsSection(title: store.settings.language.ui.language) {
                        SettingsRow(label: store.settings.language.ui.languageLabel) {
                            HStack(spacing: 2) {
                                ForEach(AppLanguage.allCases) { lang in
                                    let selected = store.settings.language == lang
                                    Button {
                                        store.settings.language = lang
                                        store.saveSettings()
                                    } label: {
                                        HStack(spacing: 4) {
                                            Text(lang.flag)
                                                .font(.system(size: 12))
                                            Text(lang.label)
                                                .font(.system(size: 10, weight: .medium))
                                        }
                                        .foregroundStyle(selected ? Color.kilnBg : Color.kilnTextSecondary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 5)
                                        .background(selected ? Color.kilnAccent : Color.kilnSurface)
                                        .clipShape(RoundedRectangle(cornerRadius: 5))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }

                        Text(store.settings.language.ui.langDescription)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.kilnTextTertiary)
                    }

                    // Engram
                    SettingsSection(title: store.settings.language.ui.memory) {
                        SettingsRow(label: store.settings.language.ui.enableEngram) {
                            SettingsToggle(value: store.settings.useEngram) { v in
                                store.settings.useEngram = v
                                // Auto-apply the engram primer on opt-in when
                                // the prompt is blank, so new users don't have
                                // to copy-paste it from docs.
                                if v && store.settings.systemPrompt.isEmpty {
                                    store.settings.systemPrompt = KilnSettings.engramSystemPrompt
                                }
                            }
                        }

                        // Manual path override. Detected path auto-discovery
                        // covers the common cases; this lets users point Kiln
                        // at a venv / shim / dev checkout when engram lives
                        // somewhere unusual. Empty = auto-detect.
                        SettingsRow(label: "Engram binary") {
                            HStack(spacing: 6) {
                                Text(store.settings.engramPath.isEmpty ? "auto-detect" : store.settings.engramPath)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(store.settings.engramPath.isEmpty ? Color.kilnTextTertiary : Color.kilnText)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Button("Pick…") {
                                    let panel = NSOpenPanel()
                                    panel.canChooseFiles = true
                                    panel.canChooseDirectories = false
                                    panel.allowsMultipleSelection = false
                                    panel.prompt = "Use this binary"
                                    panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
                                    if panel.runModal() == .OK, let url = panel.url,
                                       FileManager.default.isExecutableFile(atPath: url.path) {
                                        store.settings.engramPath = url.path
                                    }
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color.kilnTextSecondary)
                                if !store.settings.engramPath.isEmpty {
                                    Button("Clear") { store.settings.engramPath = "" }
                                        .buttonStyle(.plain)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(Color.kilnTextTertiary)
                                }
                            }
                        }

                        if store.settings.useEngram {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(store.settings.language.ui.systemPrompt)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(Color.kilnTextSecondary)

                                TextEditor(text: Binding(
                                    get: { store.settings.systemPrompt },
                                    set: { store.settings.systemPrompt = $0 }
                                ))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color.kilnText)
                                .scrollContentBackground(.hidden)
                                .padding(8)
                                .frame(minHeight: 120)
                                .background(Color.kilnBg)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.kilnBorder, lineWidth: 1))

                                HStack {
                                    Button(store.settings.language.ui.resetToDefault) {
                                        // With engram on, "default" is the
                                        // engram primer — the empty base
                                        // prompt would disable the tools.
                                        store.settings.systemPrompt = store.settings.useEngram
                                            ? KilnSettings.engramSystemPrompt
                                            : KilnSettings.defaultSystemPrompt
                                        store.saveSettings()
                                    }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(Color.kilnTextTertiary)

                                    Spacer()

                                    Button(store.settings.language.ui.save) {
                                        store.saveSettings()
                                    }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Color.kilnAccent)
                                }
                            }
                        }
                    }

                    // Appearance
                    appearanceSection

                    // Chat
                    chatSection

                    // Composer
                    composerSection

                    // MCP servers
                    mcpSection

                    // Advanced
                    advancedSection

                    // Notifications
                    notificationsSection

                    // Keyboard shortcuts
                    shortcutsSection

                    // Remote Control
                    remoteControlSection

                    // Warden Tunnel (expose Kiln / dev servers publicly)
                    wardenTunnelSection

                    // Live view of every running tunnel (Kiln + sessions)
                    allTunnelsSection

                    // Easter egg
                    SettingsSection(title: "MISC") {
                        // Export every session as a zip of markdown files.
                        HStack {
                            Text("Export all")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.kilnTextSecondary)
                                .frame(width: 120, alignment: .leading)
                            Spacer()
                            Text("\(store.sessions.count) sessions")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.kilnTextTertiary)
                            Button("Export zip") {
                                guard let zipURL = store.exportAllSessionsAsZip() else { return }
                                let panel = NSSavePanel()
                                panel.allowedContentTypes = [.zip]
                                panel.nameFieldStringValue = "kiln-sessions-\(ISO8601DateFormatter().string(from: .now).prefix(10)).zip"
                                if panel.runModal() == .OK, let dest = panel.url {
                                    try? FileManager.default.removeItem(at: dest)
                                    try? FileManager.default.copyItem(at: zipURL, to: dest)
                                    NSWorkspace.shared.activateFileViewerSelecting([dest])
                                }
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.kilnAccent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.kilnAccentMuted)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                        }

                        // Settings backup — JSON round-trip of the whole KilnSettings.
                        HStack {
                            Text("Settings")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.kilnTextSecondary)
                                .frame(width: 120, alignment: .leading)
                            Spacer()
                            Text("backup / restore")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.kilnTextTertiary)
                            Button("Export") {
                                guard let data = store.exportSettingsJSONData() else { return }
                                let panel = NSSavePanel()
                                panel.allowedContentTypes = [.json]
                                panel.nameFieldStringValue = "kiln-settings-\(ISO8601DateFormatter().string(from: .now).prefix(10)).json"
                                if panel.runModal() == .OK, let dest = panel.url {
                                    try? data.write(to: dest)
                                    NSWorkspace.shared.activateFileViewerSelecting([dest])
                                }
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.kilnAccent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.kilnAccentMuted)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                            Button("Import") {
                                let panel = NSOpenPanel()
                                panel.allowedContentTypes = [.json]
                                panel.allowsMultipleSelection = false
                                panel.canChooseDirectories = false
                                if panel.runModal() == .OK, let src = panel.url,
                                   let data = try? Data(contentsOf: src) {
                                    _ = store.importSettingsJSON(data)
                                }
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.kilnAccent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.kilnAccentMuted)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                        }

                        // Session import — paste a single session JSON back in.
                        // Export-single-session lives in the sidebar context menu;
                        // this is the matching import entry point.
                        HStack {
                            Text("Import session")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.kilnTextSecondary)
                                .frame(width: 120, alignment: .leading)
                            Spacer()
                            Text("from JSON")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.kilnTextTertiary)
                            Button("Import") {
                                let panel = NSOpenPanel()
                                panel.allowedContentTypes = [.json]
                                panel.allowsMultipleSelection = false
                                panel.canChooseDirectories = false
                                if panel.runModal() == .OK, let src = panel.url,
                                   let data = try? Data(contentsOf: src) {
                                    _ = store.importSessionJSON(data)
                                }
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.kilnAccent)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.kilnAccentMuted)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                        }

                    }

                    // About
                    SettingsSection(title: store.settings.language.ui.about) {
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(
                                        LinearGradient(
                                            colors: [Color.kilnAccent, Color.kilnAccent.opacity(0.6)],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .frame(width: 40, height: 40)
                                Image(systemName: "flame.fill")
                                    .font(.system(size: 20, weight: .heavy))
                                    .foregroundStyle(Color.kilnBg)
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Kiln Code")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Color.kilnText)
                                Text(store.settings.language.ui.tagline)
                                    .font(.system(size: 11))
                                    .foregroundStyle(Color.kilnTextTertiary)
                                Text(verbatim: "© \(Calendar.current.component(.year, from: .now)) Raya Creations")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color.kilnTextTertiary)
                            }
                            Spacer()
                            Text(Self.versionString)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color.kilnTextTertiary)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(24)
            }
    }

    // MARK: - Version

    /// Reads `CFBundleShortVersionString` + `CFBundleVersion` from Info.plist.
    /// In dev (swift run / swift build open), Info.plist isn't bundled, so
    /// we fall back to reading the repo-root `VERSION` file if the binary
    /// is sitting inside a checkout.
    static var versionString: String {
        let info = Bundle.main.infoDictionary ?? [:]
        if let short = info["CFBundleShortVersionString"] as? String, !short.isEmpty {
            let build = info["CFBundleVersion"] as? String ?? ""
            return build.isEmpty || build == short ? "v\(short)" : "v\(short) (\(build))"
        }
        // Dev fallback: look for a VERSION file next to the executable's
        // enclosing package root. Works for `swift run`/`swift build` runs.
        let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: "/")
        var dir = exe.deletingLastPathComponent()
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("VERSION")
            if let v = try? String(contentsOf: candidate, encoding: .utf8) {
                return "v\(v.trimmingCharacters(in: .whitespacesAndNewlines)) (dev)"
            }
            dir.deleteLastPathComponent()
        }
        return "dev"
    }

    // MARK: - Appearance

    private var accentPresets: [(String, String)] {
        [("f97316", "Orange"), ("ef4444", "Red"), ("eab308", "Yellow"),
         ("22c55e", "Green"), ("3b82f6", "Blue"), ("a855f7", "Purple"),
         ("ec4899", "Pink"), ("14b8a6", "Teal"), ("64748b", "Slate")]
    }

    @ViewBuilder
    private var appearanceSection: some View {
        SettingsSection(title: "APPEARANCE") {
            // Identity — avatar + display name, shown on every user message.
            SettingsRow(label: "You") {
                UserIdentityEditor()
                Spacer()
            }

            SettingsRow(label: "Theme") {
                pickRow(options: ThemeMode.allCases, current: store.settings.themeMode) { v in
                    store.settings.themeMode = v
                    // Also keep the legacy string in sync so a downgrade
                    // still shows the right mode at the top level.
                    store.settings.theme = (v == .light) ? "light" : "dark"
                    store.saveSettings()
                } label: { $0.label }
                Spacer()
            }

            SettingsRow(label: "Accent") {
                HStack(spacing: 6) {
                    ForEach(accentPresets, id: \.0) { (hex, name) in
                        let selected = store.settings.accentHex.lowercased() == hex.lowercased()
                        Button {
                            store.settings.accentHex = hex
                            store.saveSettings()
                        } label: {
                            Circle()
                                .fill(Color(hexString: hex))
                                .frame(width: 20, height: 20)
                                .overlay(Circle().stroke(selected ? Color.kilnText : Color.clear, lineWidth: 2))
                                .overlay(Circle().stroke(Color.kilnBorder, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .help(name)
                    }
                }
                Spacer()
                TextField("hex", text: Binding(
                    get: { store.settings.accentHex },
                    set: { store.settings.accentHex = $0; store.saveSettings() }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 10, design: .monospaced))
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .frame(width: 80)
                .background(Color.kilnBg)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.kilnBorder, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            SettingsRow(label: "Text size") {
                pickRow(options: FontScale.allCases, current: store.settings.fontScale) { v in
                    store.settings.fontScale = v; store.saveSettings()
                } label: { $0.label }
                Spacer()
            }

            SettingsRow(label: "Density") {
                pickRow(options: Density.allCases, current: store.settings.density) { v in
                    store.settings.density = v; store.saveSettings()
                } label: { $0.label }
                Spacer()
            }
        }
    }

    // MARK: - Chat

    @ViewBuilder
    private var chatSection: some View {
        SettingsSection(title: "CHAT") {
            SettingsRow(label: "Avatars") {
                SettingsToggle(value: store.settings.showAvatars) { v in
                    store.settings.showAvatars = v
                }
                Spacer()
            }

            SettingsRow(label: "Timestamps") {
                pickRow(options: TimestampDisplay.allCases, current: store.settings.showTimestamps) { v in
                    store.settings.showTimestamps = v; store.saveSettings()
                } label: { $0.label }
                Spacer()
            }

            SettingsRow(label: "Auto-scroll") {
                SettingsToggle(value: store.settings.autoScroll) { v in
                    store.settings.autoScroll = v
                }
                Spacer()
                Text("Scroll to bottom as Claude streams")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.kilnTextTertiary)
            }

            SettingsRow(label: "Thinking") {
                SettingsToggle(
                    value: store.settings.thinkingCollapsedByDefault,
                    set: { store.settings.thinkingCollapsedByDefault = $0 }
                ) {
                    Text("Collapsed by default")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.kilnTextSecondary)
                }
                Spacer()
            }

            SettingsRow(label: "Follow-ups") {
                SettingsToggle(
                    value: store.settings.showFollowUpChips,
                    set: { store.settings.showFollowUpChips = $0 }
                ) {
                    Text("Show suggestion chips in briefings")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.kilnTextSecondary)
                }
                Spacer()
            }
        }
    }

    // MARK: - Composer

    @ViewBuilder
    private var composerSection: some View {
        SettingsSection(title: "COMPOSER") {
            SettingsRow(label: "Send key") {
                pickRow(options: SendKey.allCases, current: store.settings.sendKey) { v in
                    store.settings.sendKey = v; store.saveSettings()
                } label: { $0.label }
                Spacer()
            }

            Text(store.settings.sendKey.subtitle)
                .font(.system(size: 10))
                .foregroundStyle(Color.kilnTextTertiary)

            SettingsRow(label: "Hint strip") {
                pickRow(options: HintStripMode.allCases, current: store.settings.hintStripMode) { v in
                    store.settings.hintStripMode = v; store.saveSettings()
                } label: { $0.label }
                Spacer()
            }

            SettingsRow(label: "Spell check") {
                SettingsToggle(value: store.settings.spellCheck) { v in
                    store.settings.spellCheck = v
                }
                Spacer()
            }

            SettingsRow(label: "Placeholder") {
                TextField(store.settings.language.ui.messagePlaceholder, text: Binding(
                    get: { store.settings.composerPlaceholder },
                    set: { store.settings.composerPlaceholder = $0; store.saveSettings() }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 11))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.kilnBg)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.kilnBorder, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
        }
    }

    // MARK: - MCP Servers

    @State private var mcpServers: [MCPServerInfo] = []

    @ViewBuilder
    private var mcpSection: some View {
        SettingsSection(title: "MCP SERVERS") {
            if mcpServers.isEmpty {
                HStack {
                    Text("No MCP servers found in \(MCPServerReader.claudeSettingsPath)")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.kilnTextTertiary)
                    Spacer()
                    Button("Reload") {
                        mcpServers = MCPServerReader.loadAll()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.kilnAccent)
                }
            } else {
                ForEach(mcpServers) { server in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: server.disabled ? "circle" : "circle.fill")
                                .font(.system(size: 7))
                                .foregroundStyle(server.disabled ? Color.kilnTextTertiary : Color.kilnSuccess)
                            Text(server.name)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Color.kilnText)
                            Text(server.kind)
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(Color.kilnTextTertiary)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.kilnSurface)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                            Spacer()
                        }
                        if let cmd = server.command {
                            Text("\(cmd) \(server.args.joined(separator: " "))")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Color.kilnTextTertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if let u = server.url {
                            Text(u)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Color.kilnTextTertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if !server.env.isEmpty {
                            Text("env: \(server.env.keys.sorted().joined(separator: ", "))")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(Color.kilnTextTertiary)
                        }
                    }
                    .padding(.vertical, 4)

                    if server.id != mcpServers.last?.id {
                        Rectangle().fill(Color.kilnBorderSubtle).frame(height: 1)
                    }
                }
                HStack {
                    Button {
                        NSWorkspace.shared.open(URL(fileURLWithPath: MCPServerReader.claudeSettingsPath))
                    } label: {
                        Text("Edit ~/.claude.json")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.kilnAccent)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button("Reload") {
                        mcpServers = MCPServerReader.loadAll()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.kilnTextSecondary)
                }
                .padding(.top, 4)
            }
        }
        .onAppear { mcpServers = MCPServerReader.loadAll() }
    }

    // MARK: - Advanced

    @ViewBuilder
    private var advancedSection: some View {
        SettingsSection(title: "ADVANCED") {
            SettingsRow(label: "Undo send") {
                HStack(spacing: 8) {
                    Stepper(value: Binding(
                        get: { store.settings.undoSendWindow },
                        set: { store.settings.undoSendWindow = max(0, min(30, $0)); store.saveSettings() }
                    ), in: 0...30) {
                        Text(store.settings.undoSendWindow == 0 ? "Off" : "\(store.settings.undoSendWindow)s")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.kilnText)
                    }
                    .controlSize(.small)
                }
                Spacer()
                Text("Delay before messages actually send")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.kilnTextTertiary)
            }

            SettingsRow(label: "Rate meter") {
                HStack(spacing: 6) {
                    TextField("", value: Binding(
                        get: { UserDefaults.standard.integer(forKey: "rateLimit.softCap") == 0 ? 500_000 : UserDefaults.standard.integer(forKey: "rateLimit.softCap") },
                        set: { UserDefaults.standard.set(max(10_000, $0), forKey: "rateLimit.softCap") }
                    ), format: .number)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.kilnText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.kilnBg)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.kilnBorder, lineWidth: 1))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .frame(width: 110)
                    Text("tokens / 5 min")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.kilnTextTertiary)
                }
                Spacer()
                Text("Soft cap for the composer's rate meter. Default 500K.")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.kilnTextTertiary)
            }

            SettingsRow(label: "Repo info") {
                SettingsToggle(
                    value: store.settings.enableRepoAwareness,
                    set: { store.settings.enableRepoAwareness = $0 }
                ) {
                    Text("Show git branch + dirty status in sidebar")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.kilnTextSecondary)
                }
                Spacer()
            }

            SettingsRow(label: "Token heatmap") {
                SettingsToggle(
                    value: store.settings.showTokenHeatmap,
                    set: { store.settings.showTokenHeatmap = $0 }
                ) {
                    Text("Color-code message bars by estimated size")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.kilnTextSecondary)
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("On-complete shell")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.kilnTextSecondary)
                TextEditor(text: Binding(
                    get: { store.settings.onCompleteShellCommand },
                    set: { store.settings.onCompleteShellCommand = $0 }
                ))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.kilnText)
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 60)
                .background(Color.kilnBg)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.kilnBorder, lineWidth: 1))
                Text("Runs when Claude finishes. Env: KILN_SESSION_NAME, KILN_WORKDIR, KILN_LAST_ASSISTANT_TEXT, …")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.kilnTextTertiary)
                HStack {
                    Spacer()
                    Button("Save") { store.saveSettings() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.kilnAccent)
                }
            }
        }
    }

    // MARK: - Notifications

    @ViewBuilder
    private var notificationsSection: some View {
        SettingsSection(title: "NOTIFICATIONS") {
            SettingsRow(label: "On completion") {
                SettingsToggle(
                    value: store.settings.notifyOnCompletion,
                    set: { store.settings.notifyOnCompletion = $0 }
                ) {
                    Text("Notify when Claude finishes")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.kilnTextSecondary)
                }
                Spacer()
            }

            SettingsRow(label: "Sound") {
                SettingsToggle(
                    value: store.settings.notifySound,
                    set: { store.settings.notifySound = $0 }
                ) {
                    Text("Play sound with notification")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.kilnTextSecondary)
                }
                .disabled(!store.settings.notifyOnCompletion)
                Spacer()
            }

            Text("Notifications only fire when Kiln is not the frontmost app.")
                .font(.system(size: 10))
                .foregroundStyle(Color.kilnTextTertiary)
        }
    }

    // MARK: - Keyboard shortcuts reference

    private var shortcutRows: [(String, String)] {
        [("⌘N", "New session"),
         ("⌘K", "Command palette"),
         ("⌘⇧F", "Search messages"),
         ("⌘1 / ⌘2", "Code / Chat sidebar"),
         ("⌘[ / ⌘]", "Previous / next session"),
         ("⌘/", "Snippets"),
         ("⌘,", "Settings"),
         ("⌘⇧E", "Export chat"),
         ("⌘⇧R", "Retry last"),
         ("⌘.", "Interrupt"),
         ("⌘W", "Close session")]
    }

    private var shortcutsSection: some View {
        SettingsSection(title: "KEYBOARD SHORTCUTS") {
            VStack(spacing: 4) {
                ForEach(shortcutRows, id: \.0) { row in
                    HStack {
                        Text(row.0)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color.kilnTextSecondary)
                            .frame(width: 80, alignment: .leading)
                        Text(row.1)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.kilnText)
                        Spacer()
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    // Helper — renders a horizontal pill picker for an enum.
    @ViewBuilder
    private func pickRow<T: Hashable>(options: [T], current: T, set: @escaping (T) -> Void, label: @escaping (T) -> String) -> some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { opt in
                let selected = opt == current
                Button { set(opt) } label: {
                    Text(label(opt))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(selected ? Color.kilnBg : Color.kilnTextSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(selected ? Color.kilnAccent : Color.kilnSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Remote Control Section

    @ViewBuilder
    private var remoteControlSection: some View {
        SettingsSection(title: "REMOTE CONTROL") {
            SettingsRow(label: "Enable") {
                SettingsToggle(value: store.remoteServer.isRunning) { enabled in
                    UserDefaults.standard.set(enabled, forKey: "remote.enabled")
                    if enabled { store.remoteServer.start() } else { store.remoteServer.stop() }
                }

                Spacer()

                if let err = store.remoteServer.lastError {
                    Text(err)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.red.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else if store.remoteServer.isRunning {
                    HStack(spacing: 4) {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                        Text("running").font(.system(size: 10)).foregroundStyle(Color.kilnTextTertiary)
                    }
                }
            }

            SettingsRow(label: "Port") {
                TextField("8421", text: $portDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Color.kilnText)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.kilnBg)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.kilnBorder, lineWidth: 1))
                    .frame(width: 90)
                    .focused($portFocused)
                    .onAppear { portDraft = String(store.remoteServer.port) }
                    .onChange(of: store.remoteServer.port) { _, new in
                        // Re-sync if the server's port changes out-from-under us
                        // (e.g. loaded from defaults on launch) and we're not
                        // actively editing.
                        if !portFocused { portDraft = String(new) }
                    }
                    .onSubmit { commitPort() }
                    .onChange(of: portFocused) { _, focused in
                        if !focused { commitPort() }
                    }

                Spacer()
            }

            SettingsRow(label: "Token") {
                SecureField("optional bearer token", text: Binding(
                    get: { store.remoteServer.token },
                    set: {
                        store.remoteServer.token = $0
                        UserDefaults.standard.set($0, forKey: "remote.token")
                    }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.kilnText)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.kilnBg)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.kilnBorder, lineWidth: 1))

                Button {
                    let t = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
                    store.remoteServer.token = t
                    UserDefaults.standard.set(t, forKey: "remote.token")
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.kilnTextSecondary)
                        .frame(width: 22, height: 22)
                        .background(Color.kilnSurfaceElevated)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .help("Generate new token")
            }

            SettingsRow(label: "Access") {
                HStack(spacing: 2) {
                    ForEach(RemoteAccessLevel.allCases, id: \.self) { level in
                        let selected = store.remoteServer.accessLevel == level
                        let (label, icon): (String, String) = {
                            switch level {
                            case .loopback: return ("local", "lock.shield")
                            case .lan: return ("lan", "wifi")
                            case .tailscale: return ("tailscale", "network")
                            }
                        }()
                        Button {
                            store.remoteServer.accessLevel = level
                            store.remoteServer.allowLAN = (level != .loopback)
                            UserDefaults.standard.set(level.rawValue, forKey: "remote.accessLevel")
                            UserDefaults.standard.set(level != .loopback, forKey: "remote.allowLAN")
                            if store.remoteServer.isRunning { store.remoteServer.start() }
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: icon).font(.system(size: 9))
                                Text(label).font(.system(size: 10, weight: .medium))
                            }
                            .foregroundStyle(selected ? Color.kilnBg : Color.kilnTextSecondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(selected ? Color.kilnAccent : Color.kilnSurface)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer()
            }

            // Tailscale status
            if store.remoteServer.accessLevel == .tailscale {
                HStack(spacing: 8) {
                    Circle()
                        .fill(tailscaleStatusColor)
                        .frame(width: 6, height: 6)
                    Text("tailscale: \(store.remoteServer.tailscaleStatus)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.kilnTextTertiary)
                    Spacer()
                    Button("Refresh") {
                        Task { await store.remoteServer.refreshTailscale() }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.kilnAccent)
                }
                if store.remoteServer.tailscaleStatus == "absent" {
                    Text("Install Tailscale from tailscale.com, then log in to get a tailnet IP.")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.kilnTextTertiary)
                } else if store.remoteServer.tailscaleStatus == "installed" {
                    Text("Tailscale is installed but not logged in. Run: tailscale up")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.kilnTextTertiary)
                }
            }

            // URL display
            VStack(alignment: .leading, spacing: 6) {
                Text("URLs")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.kilnTextTertiary)
                    .tracking(0.5)

                urlRow(label: "local", url: "http://127.0.0.1:\(store.remoteServer.port)")

                if store.remoteServer.accessLevel != .loopback, let lan = RemoteControlServer.localIPv4() {
                    urlRow(label: "lan", url: "http://\(lan):\(store.remoteServer.port)")
                }

                if let ts = store.remoteServer.tailscaleIP {
                    urlRow(label: "ts", url: "http://\(ts):\(store.remoteServer.port)")
                }

                Text("Tailscale gives you a global URL that works from any device on your tailnet. LAN is local network only. Loopback is this Mac only.")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.kilnTextTertiary)
                    .padding(.top, 4)
            }
        }
    }

    // MARK: - Warden Tunnel Section

    /// Exposes a publicly-reachable HTTPS URL for the Kiln remote server via
    /// the user's own warden-tunnel-server deployment. Config is stored in
    /// `WardenTunnelService.config` (UserDefaults) and loaded on launch.
    @ViewBuilder
    private var wardenTunnelSection: some View {
        SettingsSection(title: "WARDEN TUNNEL") {
            // Auto-config status: the app claims its own bearer token from
            // the baked-in tunnel server on first launch. No PSK file,
            // no manual credential. Server/domain/scheme live under
            // Advanced for the rare case of pointing at a different host.
            SettingsRow(label: "Credential") {
                if store.wardenTunnels.claimInFlight {
                    HStack(spacing: 6) {
                        ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
                        Text("claiming token…").font(.system(size: 11)).foregroundStyle(Color.kilnTextSecondary)
                    }
                } else if !store.wardenTunnels.config.bearerToken.isEmpty {
                    // Token present = healthy, even if the last re-claim
                    // hit the 24h rate limit. The existing token is still
                    // valid until it expires.
                    HStack(spacing: 6) {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                        Text("token claimed").font(.system(size: 11)).foregroundStyle(Color.kilnTextSecondary)
                    }
                } else if let err = store.wardenTunnels.claimError {
                    Text(err)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.red.opacity(0.9))
                        .lineLimit(1).truncationMode(.middle)
                } else {
                    Text("no token").font(.system(size: 11)).foregroundStyle(Color.kilnTextTertiary)
                }

                Spacer()

                Button {
                    Task { await store.wardenTunnels.claimIfNeeded() }
                } label: {
                    Text(store.wardenTunnels.config.bearerToken.isEmpty ? "Claim" : "Re-claim")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.kilnText)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(Color.kilnSurfaceElevated)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .disabled(store.wardenTunnels.claimInFlight)
            }

            Divider().background(Color.kilnBorderSubtle).padding(.vertical, 6)

            // Kiln self-tunnel
            let selfKey = TunnelOwner.kilnSelf.key
            let selfState = store.wardenTunnels.tunnels[selfKey]

            SettingsRow(label: "Tunnel Kiln") {
                SettingsToggle(value: UserDefaults.standard.bool(forKey: "warden.tunnelKiln")) { enabled in
                    UserDefaults.standard.set(enabled, forKey: "warden.tunnelKiln")
                    if enabled {
                        // Always register the sub our token was issued for;
                        // any other value is rejected by the server. Nil →
                        // client rolls a random one, which only works
                        // pre-claim.
                        let sub = store.wardenTunnels.config.claimedSub
                        store.wardenTunnels.start(
                            owner: .kilnSelf,
                            target: "127.0.0.1:\(store.remoteServer.port)",
                            sub: sub.isEmpty ? nil : sub
                        )
                    } else {
                        store.wardenTunnels.stop(owner: .kilnSelf)
                    }
                }
                .disabled(!store.wardenTunnels.config.isConfigured)

                Spacer()

                if let s = selfState {
                    switch s.status {
                    case .connecting:
                        HStack(spacing: 4) {
                            ProgressView().scaleEffect(0.5).frame(width: 14, height: 14)
                            Text("connecting").font(.system(size: 10)).foregroundStyle(Color.kilnTextTertiary)
                        }
                    case .ready:
                        HStack(spacing: 4) {
                            Circle().fill(Color.green).frame(width: 6, height: 6)
                            Text("up • \(s.requestCount) req").font(.system(size: 10)).foregroundStyle(Color.kilnTextTertiary)
                        }
                    case .failed(let msg):
                        Text(msg)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.red.opacity(0.9))
                            .lineLimit(1).truncationMode(.middle)
                    case .idle:
                        Text("idle").font(.system(size: 10)).foregroundStyle(Color.kilnTextTertiary)
                    }
                }
            }

            // Subdomain is derived from the claimed token — the server
            // only authorizes the sub the token was issued for, so there's
            // no free-text override. Shown read-only so the user can see
            // which URL they'll get.
            if !store.wardenTunnels.config.claimedSub.isEmpty {
                SettingsRow(label: "Subdomain") {
                    Text(store.wardenTunnels.config.claimedSub)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.kilnTextSecondary)
                    Spacer()
                }
            }

            if let s = selfState, case .ready(let url) = s.status {
                VStack(alignment: .leading, spacing: 6) {
                    urlRow(label: "public", url: url)
                    if !store.remoteServer.token.isEmpty {
                        urlRow(label: "with token", url: "\(url)/?t=\(store.remoteServer.token)")
                    }
                }
                .padding(.top, 6)
            }

            if !store.wardenTunnels.config.isConfigured {
                Text("Configure a tunnel server + PSK above, then flip Tunnel Kiln on. Your server can be anywhere — warden-tunnel-server is a ~500 LoC Go binary that runs on any VPS.")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.kilnTextTertiary)
                    .padding(.top, 6)
            }
        }
    }

    /// Unified list of every tunnel the service is currently managing —
    /// Kiln's own remote server plus one entry per session that has its
    /// tunnel toggle flipped on. Lets the user see everything at a glance
    /// and kill any of them without hunting through per-session panels.
    private var allTunnelsSection: some View {
        SettingsSection(title: "ACTIVE TUNNELS") {
            let entries = store.wardenTunnels.tunnels.values.sorted { a, b in
                // Kiln-self first, then sessions alphabetically by target.
                if a.owner == .kilnSelf { return true }
                if b.owner == .kilnSelf { return false }
                return a.target < b.target
            }

            if entries.isEmpty {
                Text("No tunnels running. Flip \"Tunnel Kiln\" above or open a session's Tunnel panel to expose a dev server.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.kilnTextTertiary)
                    .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(entries) { entry in
                        tunnelRow(entry)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func tunnelRow(_ s: TunnelState) -> some View {
        let title: String = {
            switch s.owner {
            case .kilnSelf:
                return "Kiln (remote control)"
            case .session(let id):
                if let name = store.sessions.first(where: { $0.id == id })?.name, !name.isEmpty {
                    return name
                }
                return "session \(id.prefix(8))"
            }
        }()

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: s.owner == .kilnSelf ? "gearshape.circle" : "network")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.kilnTextSecondary)

                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.kilnText)
                    .lineLimit(1).truncationMode(.tail)

                Text("→ \(s.target)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Color.kilnTextTertiary)
                    .lineLimit(1).truncationMode(.middle)

                Spacer()

                switch s.status {
                case .connecting:
                    HStack(spacing: 4) {
                        ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                        Text("connecting").font(.system(size: 10)).foregroundStyle(Color.kilnTextTertiary)
                    }
                case .ready:
                    HStack(spacing: 4) {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                        Text("\(s.requestCount) req").font(.system(size: 10)).foregroundStyle(Color.kilnTextTertiary)
                    }
                case .failed(let msg):
                    Text(msg)
                        .font(.system(size: 10))
                        .foregroundStyle(Color.red.opacity(0.9))
                        .lineLimit(1).truncationMode(.middle)
                case .idle:
                    Text("idle").font(.system(size: 10)).foregroundStyle(Color.kilnTextTertiary)
                }

                Button {
                    // Clean stop via the service; for sessions also clear
                    // the persisted "enabled" flag so it stays down across
                    // restarts — matches what the per-session panel does.
                    switch s.owner {
                    case .kilnSelf:
                        UserDefaults.standard.set(false, forKey: "warden.tunnelKiln")
                        store.wardenTunnels.stop(owner: .kilnSelf)
                    case .session(let id):
                        store.stopSessionTunnel(sessionId: id)
                    }
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.kilnTextSecondary)
                        .frame(width: 22, height: 22)
                        .background(Color.kilnSurfaceElevated)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .help("Stop tunnel")
            }

            if case .ready(let url) = s.status {
                HStack(spacing: 6) {
                    Text(url)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.kilnTextSecondary)
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)

                    Spacer()

                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.kilnTextSecondary)
                            .frame(width: 22, height: 22)
                            .background(Color.kilnSurfaceElevated)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .help("Copy URL")
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.kilnSurface)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.kilnBorderSubtle, lineWidth: 1))
    }

    /// Apply the port draft: parse → persist → rebind the listener if the
    /// server is already running. Invalid input (non-numeric or port 0) is
    /// silently reverted to the live port so the field can never show a value
    /// that disagrees with the server.
    private func commitPort() {
        let trimmed = portDraft.trimmingCharacters(in: .whitespaces)
        guard let p = UInt16(trimmed), p > 0 else {
            portDraft = String(store.remoteServer.port)
            return
        }
        if p == store.remoteServer.port { return }
        store.remoteServer.port = p
        UserDefaults.standard.set(Int(p), forKey: "remote.port")
        if store.remoteServer.isRunning { store.remoteServer.start() }
        // A running Kiln self-tunnel points at the old port — retarget it.
        restartKilnTunnelIfActive()
    }

    /// Restart Kiln's own warden tunnel if the user has it enabled, picking
    /// up whatever config + target + subdomain are current right now. Called
    /// after any change that the live tunnel wouldn't otherwise notice:
    /// remote server port, warden server/domain/scheme/psk/insecure, or the
    /// kiln subdomain field.
    private func restartKilnTunnelIfActive() {
        guard store.wardenTunnels.isActive(owner: .kilnSelf) else { return }
        let sub = UserDefaults.standard.string(forKey: "warden.kilnSub")
            .flatMap { $0.isEmpty ? nil : $0 }
        store.wardenTunnels.start(
            owner: .kilnSelf,
            target: "127.0.0.1:\(store.remoteServer.port)",
            sub: sub
        )
    }

    private var tailscaleStatusColor: Color {
        switch store.remoteServer.tailscaleStatus {
        case "active": return .green
        case "installed": return .yellow
        case "absent": return Color.kilnTextTertiary
        case "error": return Color.kilnError
        default: return Color.kilnTextTertiary
        }
    }

    @ViewBuilder
    private func urlRow(label: String, url: String) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Color.kilnTextTertiary)
                .tracking(0.5)
                .frame(width: 32, alignment: .leading)

            Text(url)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.kilnText)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Button {
                NSPasteboard.general.clearContents()
                var s = url
                // Only append the token if the URL doesn't already carry
                // it — otherwise the "with token" row double-appends and
                // the browser lands on `?t=X?t=X`, which the server reads
                // as a single malformed value and 401s.
                let tok = store.remoteServer.token
                if !tok.isEmpty && !s.contains("t=\(tok)") {
                    s += (s.contains("?") ? "&" : "?") + "t=\(tok)"
                }
                NSPasteboard.general.setString(s, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.kilnTextSecondary)
                    .frame(width: 22, height: 22)
                    .background(Color.kilnSurfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .help("Copy URL with token")
        }
    }
}

// MARK: - Helpers

struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Color.kilnTextTertiary)
                .tracking(1)

            VStack(alignment: .leading, spacing: 10) {
                content
            }
            .padding(16)
            .background(Color.kilnSurface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.kilnBorder, lineWidth: 1))
        }
    }
}

struct SettingsRow<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.kilnTextSecondary)
                .frame(width: 90, alignment: .leading)
            content
        }
    }
}

// MARK: - SettingsToggle
//
// Custom-built switch. macOS SwiftUI's Toggle(.switch) bridges to NSSwitch,
// which refuses to animate its knob when the underlying binding source
// isn't itself a SwiftUI-observed value (e.g. UserDefaults, a nested
// ObservableObject like store.remoteServer). We sidestep the bridge
// entirely: this is just a Button with a local @State driving the knob.
struct SettingsToggle<Label: View>: View {
    let value: Bool
    let set: (Bool) -> Void
    @ViewBuilder let label: () -> Label
    @State private var local: Bool = false
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        HStack(spacing: 8) {
            Button {
                let new = !local
                withAnimation(.easeInOut(duration: 0.15)) { local = new }
                set(new)
            } label: {
                ZStack(alignment: local ? .trailing : .leading) {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(local ? Color.kilnAccent : Color.kilnSurfaceElevated)
                        .frame(width: 32, height: 18)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.kilnBorder.opacity(local ? 0 : 0.6), lineWidth: 1)
                        )
                    Circle()
                        .fill(Color.white)
                        .frame(width: 14, height: 14)
                        .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                        .padding(.horizontal, 2)
                }
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1.0 : 0.45)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
            label()
        }
        .onAppear { local = value }
        .onChange(of: value) { _, v in
            if v != local {
                withAnimation(.easeInOut(duration: 0.15)) { local = v }
            }
        }
    }
}

extension SettingsToggle where Label == EmptyView {
    init(value: Bool, set: @escaping (Bool) -> Void) {
        self.value = value
        self.set = set
        self.label = { EmptyView() }
    }
}

// MARK: - User Identity Editor
//
// Small settings UI that lets the user pick a custom avatar image and a
// display name. Both are surfaced in every user message throughout the
// chat. Uses AvatarStore so the NSImage cache stays hot.

struct UserIdentityEditor: View {
    @EnvironmentObject var store: AppStore
    @ObservedObject private var avatars: AvatarStore = .shared
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            // Avatar preview + pick/clear controls
            ZStack {
                Circle()
                    .fill(Color.kilnSurfaceElevated)
                    .frame(width: 40, height: 40)
                if let img = avatars.avatar {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 40, height: 40)
                        .clipShape(Circle())
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.kilnTextSecondary)
                }
            }
            .overlay(Circle().stroke(Color.kilnBorder, lineWidth: 1))
            .onHover { hovering = $0 }
            .onTapGesture { pickAvatar() }
            .overlay {
                if hovering {
                    Circle()
                        .fill(Color.black.opacity(0.5))
                        .frame(width: 40, height: 40)
                        .overlay(
                            Image(systemName: "camera.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.white)
                        )
                        .allowsHitTesting(false)
                }
            }
            .help("Click to choose an image")

            VStack(alignment: .leading, spacing: 4) {
                TextField("Display name (default: You)", text: Binding(
                    get: { store.settings.userDisplayName },
                    set: { store.settings.userDisplayName = $0; store.saveSettings() }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.kilnBg)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.kilnBorder, lineWidth: 1))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .frame(width: 200)

                HStack(spacing: 6) {
                    Button(avatars.avatar == nil ? "Choose avatar" : "Change") { pickAvatar() }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.kilnAccent)
                    if avatars.avatar != nil {
                        Text("·").foregroundStyle(Color.kilnTextTertiary)
                        Button("Remove", role: .destructive) { clearAvatar() }
                            .buttonStyle(.plain)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.kilnError)
                    }
                }
            }
        }
    }

    private func pickAvatar() {
        if let newName = AvatarStore.shared.pickAndImport() {
            // Clean up the old file so we don't accumulate stale avatars.
            let old = store.settings.userAvatarFilename
            if !old.isEmpty && old != newName {
                let oldURL = FileManager.default
                    .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                    .appendingPathComponent("Kiln/avatars")
                    .appendingPathComponent(old)
                try? FileManager.default.removeItem(at: oldURL)
            }
            store.settings.userAvatarFilename = newName
            store.saveSettings()
        }
    }

    private func clearAvatar() {
        AvatarStore.shared.clear(filename: store.settings.userAvatarFilename)
        store.settings.userAvatarFilename = ""
        store.saveSettings()
    }
}
