import SwiftUI
import AppKit

struct ComputerUseView: View {
    @EnvironmentObject private var store: AppStore
    @ObservedObject private var computer = ComputerUse.shared
    @State private var targets: [ComputerTarget] = []
    @State private var selected: UInt32?
    @State private var consent = false
    @State private var loading = false
    @State private var screenAllowed = false
    @State private var inputAllowed = false

    private var options: SendOptions {
        var options = SendOptions()
        options.chatMode = store.activeSession?.kind != .code
        options.mode = store.sessionMode
        options.permissions = store.permissionMode
        return options
    }

    private var eligible: Bool {
        guard let session = store.activeSession else { return false }
        return ComputerConnection.eligible(provider: session.model.provider, options: options)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Label("Computer", systemImage: "desktopcomputer").font(.system(size: 18, weight: .semibold))
                    Spacer()
                    if let id = store.activeSessionId, computer.enabled[id] != nil {
                        Button(role: .destructive) { computer.stop(sessionID: id) } label: { Label("Stop access", systemImage: "stop.fill") }
                    }
                    Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                        .help("Refresh windows and permissions").disabled(loading)
                }
                HStack(spacing: 16) {
                    permission("Screen Recording", allowed: screenAllowed, privacy: "Privacy_ScreenCapture")
                    permission("Accessibility", allowed: inputAllowed, privacy: "Privacy_Accessibility")
                }
                if !inputAllowed || !screenAllowed {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Running copy: \(Bundle.main.bundleURL.path)")
                            .textSelection(.enabled)
                        Text("Already enabled in macOS? Quit and reopen this copy. A replaced, ad-hoc signed build may need to be removed and added again in Privacy & Security.")
                            .fixedSize(horizontal: false, vertical: true)
                    }.font(.system(size: 11)).foregroundStyle(Color.kilnTextSecondary)
                }
                Divider()
                if let session = store.activeSession {
                    if let target = computer.enabled[session.id] {
                        Label(target.label, systemImage: "record.circle.fill")
                            .font(.system(size: 13, weight: .medium)).foregroundStyle(Color.kilnSuccess)
                        Text("Shared with \(session.model.label) for this chat. Every input action needs approval.")
                            .font(.system(size: 12)).foregroundStyle(Color.kilnTextSecondary)
                    } else {
                        Text("Window").font(.system(size: 12, weight: .semibold))
                        if loading { ProgressView().controlSize(.small) }
                        Picker("Window", selection: $selected) {
                            Text("Choose a window").tag(Optional<UInt32>.none)
                            ForEach(targets) { target in Text(target.label).tag(Optional(target.id)) }
                        }.labelsHidden().frame(maxWidth: .infinity).disabled(!eligible)
                        Toggle("Share this window with \(session.model.label) for this chat", isOn: $consent)
                            .toggleStyle(.checkbox).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                            .disabled(!eligible)
                        Text("Screenshots are sent to the selected model. Clicks, typing, keys, and scrolling require approval each time. Password inputs and clipboard access are blocked.")
                            .font(.system(size: 11)).foregroundStyle(Color.kilnTextSecondary).fixedSize(horizontal: false, vertical: true)
                        Button {
                            guard let target = targets.first(where: { $0.id == selected }) else { return }
                            do { try computer.enable(sessionID: session.id, target: target, model: session.model) }
                            catch { computer.problem = error.localizedDescription }
                        } label: { Label("Enable for this chat", systemImage: "cursorarrow.rays") }
                        .disabled(!eligible || !consent || selected == nil || !inputAllowed || !screenAllowed || loading)
                        let blockers = ComputerConnection.blockers(provider: session.model.provider, options: options,
                            screenAllowed: screenAllowed, inputAllowed: inputAllowed,
                            windowSelected: selected != nil, consent: consent)
                        ForEach(blockers, id: \.self) { reason in
                            Label(reason, systemImage: "exclamationmark.circle")
                                .font(.system(size: 11)).foregroundStyle(Color.kilnWarning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    Text("Select a chat first.").foregroundStyle(Color.kilnTextSecondary)
                }
                if let problem = computer.problem {
                    Text(problem).font(.system(size: 12)).foregroundStyle(Color.kilnWarning).textSelection(.enabled)
                }
                if let preview = computer.preview(for: store.activeSessionId), let image = NSImage(data: preview.jpeg) {
                    Divider()
                    HStack {
                        Text("Latest observation").font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text(preview.timestamp, style: .time).font(.system(size: 11)).foregroundStyle(Color.kilnTextTertiary)
                    }
                    Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 280)
                }
                let history = computer.history(for: store.activeSessionId)
                if !history.isEmpty {
                    Divider()
                    Text("Approved actions").font(.system(size: 12, weight: .semibold))
                    ForEach(Array(history.enumerated()), id: \.offset) { _, entry in
                        Label(entry, systemImage: "checkmark").font(.system(size: 11)).foregroundStyle(Color.kilnTextSecondary)
                    }
                }
            }.padding(20)
        }
        .task { await refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refresh() }
        }
        .onChange(of: selected) { consent = false }
        .onChange(of: store.activeSessionId) { consent = false; Task { await refresh() } }
    }

    private func permission(_ name: String, allowed: Bool, privacy: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: allowed ? "checkmark.circle.fill" : "lock.circle")
                .foregroundStyle(allowed ? Color.kilnSuccess : Color.kilnTextTertiary)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.system(size: 11, weight: .medium))
                if !allowed {
                    Button("Open macOS settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(privacy)") { NSWorkspace.shared.open(url) }
                    }.font(.system(size: 10)).buttonStyle(.link)
                }
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func refresh() async {
        guard !loading else { return }
        loading = true
        screenAllowed = ComputerPlatform.screenAllowed
        inputAllowed = ComputerPlatform.inputAllowed
        defer {
            screenAllowed = ComputerPlatform.screenAllowed
            inputAllowed = ComputerPlatform.inputAllowed
            if !screenAllowed { targets = [] }
            if !targets.contains(where: { $0.id == selected }) { selected = nil; consent = false }
            loading = false
        }
        if screenAllowed {
            do { targets = try await ComputerPlatform.targets(); computer.problem = nil }
            catch { computer.problem = error.localizedDescription }
        } else { targets = [] }
    }
}

struct ComputerApprovalView: View {
    let proposal: ComputerApproval
    let chatName: String?
    let decide: (Bool) -> Void
    static var height: Double { min(680, max(360, (NSScreen.main?.visibleFrame.height ?? 800) - 100)) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "hand.raised.fill").foregroundStyle(Color.kilnWarning)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Approve computer action").font(.system(size: 17, weight: .semibold))
                    Text(proposal.model + " · " + proposal.capture.target.label)
                        .font(.system(size: 12)).foregroundStyle(Color.kilnTextSecondary).lineLimit(2)
                }
            }
            Text(proposal.originLabel(chatName: chatName))
                .font(.system(size: 12, weight: .medium)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text(proposal.action.title).font(.system(size: 14, weight: .medium))
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if proposal.action.kind == .type_text {
                        Text(proposal.action.text).font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(10).background(Color.kilnSurface)
                    }
                    if let image = NSImage(data: proposal.capture.jpeg) {
                        let ratio = Double(proposal.capture.width) / Double(max(1, proposal.capture.height))
                        Image(nsImage: image).resizable().scaledToFit()
                            .frame(width: min(516, 290 * ratio), height: min(290, 516 / ratio))
                            .overlay {
                                if proposal.action.kind == .click || proposal.action.kind == .scroll {
                                    GeometryReader { geometry in
                                        Image(systemName: "plus.circle.fill").font(.system(size: 23, weight: .bold))
                                            .foregroundStyle(.yellow).shadow(color: .black, radius: 2)
                                            .position(x: proposal.action.x / Double(proposal.capture.width) * geometry.size.width,
                                                      y: proposal.action.y / Double(proposal.capture.height) * geometry.size.height)
                                    }
                                }
                            }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Text("This can change or submit content in the selected window. Approving applies only to this action.")
                .font(.system(size: 11)).foregroundStyle(Color.kilnTextSecondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Text(proposal.expires, style: .timer).font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.kilnTextTertiary)
                Spacer()
                Button("Deny") { decide(false) }.keyboardShortcut(.cancelAction)
                Button("Approve once") { decide(true) }.tint(Color.kilnAccent)
            }
        }.padding(22).frame(width: 560, height: Self.height)
            .background(Color.kilnBg).foregroundStyle(Color.kilnText)
    }
}

@MainActor
final class ComputerApprovalPresenter: NSObject, NSWindowDelegate {
    static let shared = ComputerApprovalPresenter()
    private var panel: NSPanel?
    private var id: String?
    func show(_ proposal: ComputerApproval?, chatName: String?) {
        guard proposal?.id != id else { return }
        let old = panel
        panel = nil; id = nil
        old?.delegate = nil; old?.close()
        guard let proposal else { return }
        id = proposal.id
        let view = ComputerApprovalView(proposal: proposal, chatName: chatName) { allow in ComputerUse.shared.decide(id: proposal.id, allow: allow) }
        let controller = NSHostingController(rootView: view)
        let panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 560, height: ComputerApprovalView.height), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Kiln - Computer approval"
        panel.contentViewController = controller
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.center(); panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.panel = panel
    }
    func windowWillClose(_ notification: Notification) {
        let closed = id
        id = nil; panel = nil
        if let closed { ComputerUse.shared.decide(id: closed, allow: false) }
    }
}
