import SwiftUI
import AppKit

// MARK: - Onboarding
//
// Four-step first-run flow:
//   1. Welcome — what Kiln is.
//   2. Claude Code check — detect `claude` in common paths; if missing
//      show the install command (Homebrew → npm fallback) with a one-click
//      copy.
//   3. Login — nudge the user to run `claude` once to authenticate. We
//      don't drive it ourselves; the CLI handles its own auth.
//   4. Pick a working directory — optional, sets up the first session.
//
// The sheet is dismissed via `store.completeOnboarding()` which writes a
// UserDefaults flag so it never re-appears.

struct OnboardingView: View {
    @EnvironmentObject var store: AppStore
    @State private var step: Step = .welcome
    @State private var claudeStatus: ClaudeStatus = .checking
    @State private var claudePath: String?
    @State private var claudeVersion: String?
    @State private var pickedWorkDir: String?
    @State private var engramStatus: EngramStatus = .checking
    @State private var engramPath: String?

    enum Step: Int, CaseIterable { case welcome, install, login, engram, workDir }

    enum EngramStatus {
        case checking
        case installed   // `engram` found on PATH
        case missing     // not installed
    }

    enum ClaudeStatus {
        case checking
        case installed   // found and responds to --version
        case missing     // not on disk
        case broken      // on disk but --version failed
    }

    var body: some View {
        VStack(spacing: 0) {
            // Progress strip
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.rawValue) { s in
                    Capsule()
                        .fill(s.rawValue <= step.rawValue ? Color.kilnAccent : Color.kilnBorder)
                        .frame(height: 3)
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 20)
            .padding(.bottom, 12)

            // Body
            Group {
                switch step {
                case .welcome:  welcomePane
                case .install:  installPane
                case .login:    loginPane
                case .engram:   engramPane
                case .workDir:  workDirPane
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 32)
            .padding(.vertical, 12)

            // Footer nav
            HStack {
                if step != .welcome {
                    Button("Back") { advance(-1) }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.kilnTextSecondary)
                }
                Spacer()
                Button("Skip setup") {
                    store.completeOnboarding()
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.kilnTextTertiary)
                .padding(.trailing, 8)

                Button(primaryLabel) { primaryAction() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.kilnBg)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(primaryEnabled ? Color.kilnAccent : Color.kilnBorder)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .disabled(!primaryEnabled)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 16)
            .background(Color.kilnSurface)
        }
        .frame(width: 560, height: 460)
        .background(Color.kilnBg)
        .task { await probeClaude() }
    }

    // MARK: - Panes

    private var welcomePane: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.kilnAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to Kiln")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.kilnText)
                    Text("A native macOS front-end for Claude Code.")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.kilnTextSecondary)
                }
            }
            .padding(.top, 8)

            VStack(alignment: .leading, spacing: 10) {
                bullet("Chat with Claude across multiple sessions, each with its own working directory.")
                bullet("Watch Claude edit files live in a built-in Monaco editor.")
                bullet("Git, terminal, tunnel, and activity panels alongside every session.")
                bullet("Everything runs locally — your Claude API key and files never leave the machine.")
            }
            .padding(.top, 4)
        }
    }

    private var installPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Claude Code")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.kilnText)

            Text("Kiln drives Anthropic's `claude` CLI under the hood.")
                .font(.system(size: 13))
                .foregroundStyle(Color.kilnTextSecondary)

            statusBadge

            if claudeStatus == .missing || claudeStatus == .broken {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Install it with:")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.kilnTextSecondary)
                    CopyableCommand(command: installCommand)
                    Text("Run that in Terminal, then come back and we'll re-check.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.kilnTextTertiary)
                }
                .padding(12)
                .background(Color.kilnSurface)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                HStack(spacing: 8) {
                    Button("Open Terminal") { openTerminal() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.kilnText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.kilnSurfaceElevated)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    Button("Re-check") {
                        Task { await probeClaude() }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.kilnText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.kilnSurfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
            }
        }
    }

    private var loginPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Log in")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.kilnText)

            Text("Claude Code handles its own authentication. Run it once in a Terminal and follow the browser prompt — Kiln inherits the session from there.")
                .font(.system(size: 13))
                .foregroundStyle(Color.kilnTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            CopyableCommand(command: "claude")

            Button("Open Terminal") { openTerminal() }
                .buttonStyle(.plain)
                .foregroundStyle(Color.kilnText)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.kilnSurfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: 5))

            Text("Already logged in? Skip ahead.")
                .font(.system(size: 11))
                .foregroundStyle(Color.kilnTextTertiary)
        }
    }

    private var engramPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
            Text("Memory (optional)")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.kilnText)

            Text("Engram is an optional memory layer for Claude. Off by default — skip this unless you specifically want persistent recall across sessions.")
                .font(.system(size: 13))
                .foregroundStyle(Color.kilnTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Text("What it actually does")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.kilnText)
                engramBullet(
                    "Stores things Claude learns",
                    "Each session Claude picks up facts about your code, your preferences, decisions you made, errors you hit. Normally that context evaporates when the session ends. Engram keeps it on disk as `memories` — small structured notes with content, tags, and timestamps."
                )
                engramBullet(
                    "Recalls them later with hybrid search",
                    "Next time you ask something, Claude can query engram and get back relevant prior memories. It uses five channels in parallel: HNSW vector search, BM25 keyword match, graph traversal over entity links, a Hopfield associative network, and a trained cross-encoder reranker on top. Fast (~20ms) and scales to ~1M memories."
                )
                engramBullet(
                    "Builds an entity graph",
                    "People, projects, files, tools — engram extracts and canonicalizes them as graph nodes with typed relationships. You can ask \"everything about project X\" and it pulls the full subgraph."
                )
                engramBullet(
                    "Tracks decisions, errors, and patterns",
                    "Special memory types for decisions (with rationale), error patterns (with prevention notes), and extracted procedural patterns. Over time it compresses, deduplicates, and checks itself for drift against the filesystem."
                )
                engramBullet(
                    "Runs entirely local",
                    "All storage is on-disk at `~/Ash/engram/`. No network calls required (embedding backends are pluggable — local MLX/sentence-transformers or API-backed if you configure one)."
                )
            }
            .padding(12)
            .background(Color.kilnSurface)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 6) {
                Text("Trade-offs")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.kilnText)
                Text("Claude will spend tokens querying memory at the start of turns and writing memories at the end. For casual use that's waste. For long-running projects where context compounds, it's the whole point.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.kilnTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            engramStatusBadge

            if engramStatus == .missing {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Install it with:")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.kilnTextSecondary)
                    CopyableCommand(command: engramInstallCommand)
                    Text("Then register it with Claude Code:")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.kilnTextSecondary)
                        .padding(.top, 4)
                    CopyableCommand(command: "claude mcp add engram engram --scope user -- mcp")
                }
                .padding(12)
                .background(Color.kilnSurface)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                HStack(spacing: 8) {
                    Button("Open Terminal") { openTerminal() }
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.kilnText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.kilnSurfaceElevated)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    Button("Re-check") {
                        Task { await probeEngram() }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.kilnText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.kilnSurfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
            }

            if engramStatus == .installed {
                Toggle(isOn: engramToggleBinding) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable engram for new sessions")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.kilnText)
                        Text("Adds a memory-tool primer to Kiln's system prompt.")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.kilnTextTertiary)
                    }
                }
                .toggleStyle(.switch)
                .tint(Color.kilnAccent)
                .padding(.top, 4)
            }

            Text("You can change this any time in Settings → Memory.")
                .font(.system(size: 11))
                .foregroundStyle(Color.kilnTextTertiary)
                .padding(.top, 4)
            }
        }
    }

    private func engramBullet(_ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(Color.kilnAccent)
                .frame(width: 4, height: 4)
                .padding(.top, 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.kilnText)
                Text(body)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.kilnTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var engramToggleBinding: Binding<Bool> {
        Binding(
            get: { store.settings.useEngram },
            set: { on in
                var s = store.settings
                s.useEngram = on
                if on, s.systemPrompt.isEmpty {
                    s.systemPrompt = KilnSettings.engramSystemPrompt
                }
                store.settings = s
            }
        )
    }

    @ViewBuilder
    private var engramStatusBadge: some View {
        HStack(spacing: 8) {
            switch engramStatus {
            case .checking:
                ProgressView().controlSize(.small)
                Text("Looking for `engram`…")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.kilnTextSecondary)
            case .installed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color(hex: 0x22C55E))
                Text("Engram is installed at \(engramPath ?? "engram")")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.kilnText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            case .missing:
                Image(systemName: "circle.dashed")
                    .foregroundStyle(Color.kilnTextSecondary)
                Text("Engram isn't installed. Skip this unless you want it.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.kilnTextSecondary)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.kilnSurface)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var engramInstallCommand: String {
        "pip install engram-memory"
    }

    private var workDirPane: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pick a starting folder")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.kilnText)

            Text("Kiln opens each session in a working directory. You can change it later per-session. Skip this if you'd rather start from scratch.")
                .font(.system(size: 13))
                .foregroundStyle(Color.kilnTextSecondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text(pickedWorkDir ?? "No folder selected")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(pickedWorkDir == nil ? Color.kilnTextTertiary : Color.kilnText)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(Color.kilnSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                Button("Choose…") { pickWorkDir() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.kilnText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.kilnSurfaceElevated)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    // MARK: - Pieces

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(Color.kilnAccent)
                .frame(width: 5, height: 5)
                .padding(.top, 6)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(Color.kilnTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        HStack(spacing: 8) {
            switch claudeStatus {
            case .checking:
                ProgressView().controlSize(.small)
                Text("Checking for `claude`…")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.kilnTextSecondary)
            case .installed:
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(Color(hex: 0x22C55E))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Claude Code is installed")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.kilnText)
                    if let v = claudeVersion {
                        Text(v)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color.kilnTextTertiary)
                    }
                }
            case .missing:
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(Color.kilnError)
                Text("Claude Code is not installed.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.kilnText)
            case .broken:
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Color(hex: 0xF59E0B))
                Text("Found `claude` but it's not responding.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.kilnText)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.kilnSurface)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Actions

    private var primaryLabel: String {
        switch step {
        case .welcome:  return "Get started"
        case .install:  return claudeStatus == .installed ? "Continue" : "Continue anyway"
        case .login:    return "I'm logged in"
        case .engram:   return store.settings.useEngram ? "Continue with engram" : "Skip engram"
        case .workDir:  return "Finish"
        }
    }

    private var primaryEnabled: Bool {
        switch step {
        case .install: return claudeStatus != .checking
        default: return true
        }
    }

    private func primaryAction() {
        if step == .workDir {
            if let dir = pickedWorkDir {
                // Kick off a session in the chosen directory so the user
                // has somewhere to land after finishing onboarding.
                store.createSession(workDir: dir, name: (dir as NSString).lastPathComponent)
            }
            store.completeOnboarding()
            return
        }
        advance(1)
    }

    private func advance(_ direction: Int) {
        let next = step.rawValue + direction
        if let s = Step(rawValue: next) {
            step = s
            if s == .install && claudeStatus == .checking {
                Task { await probeClaude() }
            }
            if s == .engram {
                Task { await probeEngram() }
            }
        }
    }

    private func pickWorkDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use directory"
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory())
        if panel.runModal() == .OK, let url = panel.url {
            pickedWorkDir = url.path
        }
    }

    private func openTerminal() {
        NSWorkspace.shared.launchApplication("Terminal")
    }

    // MARK: - Claude probe

    private var installCommand: String {
        // Prefer npm since the official Claude Code install path is via
        // `@anthropic-ai/claude-code`. Keep this copy-pasteable as one line.
        "npm install -g @anthropic-ai/claude-code"
    }

    private func probeClaude() async {
        claudeStatus = .checking
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/claude",
            "/usr/local/bin/claude",
            "/opt/homebrew/bin/claude",
        ]
        let found = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        guard let path = found else {
            claudeStatus = .missing
            claudePath = nil
            claudeVersion = nil
            return
        }
        claudePath = path
        // Run `claude --version` to confirm it's actually functional.
        let version = await runForOutput(path, args: ["--version"])
        if let v = version, !v.isEmpty {
            claudeStatus = .installed
            claudeVersion = v.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            claudeStatus = .broken
        }
    }

    private func probeEngram() async {
        engramStatus = .checking
        // Common install locations for a pip-installed binary. We don't
        // shell out to `which` because that requires a login shell to pick
        // up the user's PATH — checking the likely paths directly is
        // faster and works from app bundles.
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/engram",
            "/usr/local/bin/engram",
            "/opt/homebrew/bin/engram",
            "\(NSHomeDirectory())/Library/Python/3.12/bin/engram",
            "\(NSHomeDirectory())/Library/Python/3.11/bin/engram",
        ]
        let found = candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
        if let path = found {
            engramPath = path
            engramStatus = .installed
        } else {
            engramPath = nil
            engramStatus = .missing
        }
    }

    private func runForOutput(_ path: String, args: [String]) async -> String? {
        await withCheckedContinuation { cont in
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: path)
                p.arguments = args
                let pipe = Pipe()
                p.standardOutput = pipe
                p.standardError = Pipe()
                do {
                    try p.run()
                    p.waitUntilExit()
                    let data = pipe.fileHandleForReading.readDataToEndOfFile()
                    cont.resume(returning: String(data: data, encoding: .utf8))
                } catch {
                    cont.resume(returning: nil)
                }
            }
        }
    }
}

// MARK: - Copyable command

struct CopyableCommand: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Text("$")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.kilnTextTertiary)
            Text(command)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.kilnText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10))
                    Text(copied ? "Copied" : "Copy")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(copied ? Color(hex: 0x22C55E) : Color.kilnTextSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.kilnSurfaceElevated)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.kilnBg)
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.kilnBorder, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
