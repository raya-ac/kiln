import SwiftUI

/// Right-panel tab for tunnelling the active session's dev server over
/// warden. Per-session: the user sets a port (and optionally a stable
/// subdomain), flips the toggle, and gets a public URL. Config persists
/// on the `Session` and is restored on launch.
struct SessionTunnelPanel: View {
    @EnvironmentObject var store: AppStore

    // Local edit buffers so typing in the text fields doesn't immediately
    // persist every keystroke. We commit on blur / toggle / explicit save.
    @State private var portText: String = ""
    @State private var subText: String = ""

    private var session: Session? { store.activeSession }
    private var ownerKey: String? {
        session.map { TunnelOwner.session($0.id).key }
    }
    private var state: TunnelState? {
        ownerKey.flatMap { store.wardenTunnels.tunnels[$0] }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let session = session {
                    header(session: session)

                    if !store.wardenTunnels.config.isConfigured {
                        notConfiguredHint
                    } else {
                        configFields
                        statusRow
                        if let state = state, !state.recent.isEmpty {
                            recentLog(state.recent)
                        }
                    }
                } else {
                    Text("No active session")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.kilnTextTertiary)
                }
            }
            .padding(16)
        }
        .background(Color.kilnBg)
        .onAppear { loadBuffers() }
        .onChange(of: session?.id) { _, _ in loadBuffers() }
    }

    // MARK: - Pieces

    @ViewBuilder
    private func header(session: Session) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("TUNNEL")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.kilnTextTertiary)
                .tracking(0.8)
            Text(session.name)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.kilnText)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var notConfiguredHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Warden not configured")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.kilnText)
            Text("Set your tunnel server + PSK under Settings → Warden Tunnel, then come back here to expose this session's dev server publicly.")
                .font(.system(size: 11))
                .foregroundStyle(Color.kilnTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color.kilnSurface)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.kilnBorderSubtle, lineWidth: 1))
    }

    @ViewBuilder
    private var configFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("LOCAL PORT")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.kilnTextTertiary).tracking(0.8)
                TextField("3000", text: $portText, onCommit: commitBuffers)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.kilnText)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(Color.kilnSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.kilnBorder, lineWidth: 1))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("SUBDOMAIN (OPTIONAL)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.kilnTextTertiary).tracking(0.8)
                TextField("auto (random)", text: $subText, onCommit: commitBuffers)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.kilnText)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .background(Color.kilnSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.kilnBorder, lineWidth: 1))
            }
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        let isRunning: Bool = {
            guard let s = state else { return false }
            if case .ready = s.status { return true }
            if case .connecting = s.status { return true }
            return false
        }()

        HStack(spacing: 10) {
            Button {
                toggle()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: isRunning ? "stop.fill" : "play.fill")
                    Text(isRunning ? "Stop tunnel" : "Start tunnel")
                        .font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .foregroundStyle(isRunning ? Color.kilnText : .black)
                .background(isRunning ? Color.kilnSurfaceElevated : Color.kilnAccent)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isRunning ? Color.kilnBorder : .clear, lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .disabled(!canStart && !isRunning)

            Spacer()

            if let s = state {
                statusBadge(s)
            }
        }

        if let s = state, case .ready(let url) = s.status {
            VStack(alignment: .leading, spacing: 4) {
                Text("PUBLIC URL")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.kilnTextTertiary).tracking(0.8)
                HStack(spacing: 6) {
                    Text(url)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.kilnText)
                        .lineLimit(1).truncationMode(.middle)
                        .textSelection(.enabled)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.kilnTextSecondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy URL")
                }
                .padding(8)
                .background(Color.kilnSurface)
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
        }
    }

    @ViewBuilder
    private func statusBadge(_ s: TunnelState) -> some View {
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
    }

    @ViewBuilder
    private func recentLog(_ entries: [TunnelLogEntry]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ACTIVITY")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.kilnTextTertiary).tracking(0.8)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(entries.suffix(30).reversed()) { entry in
                    HStack(spacing: 6) {
                        Text(Self.formatter.string(from: entry.at))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color.kilnTextTertiary)
                        Text(entry.line)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(Color.kilnTextSecondary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.kilnSurface)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }

    // MARK: - State

    private var canStart: Bool {
        guard let port = Int(portText.trimmingCharacters(in: .whitespaces)),
              port > 0, port <= 65535
        else { return false }
        return store.wardenTunnels.config.isConfigured
    }

    private func loadBuffers() {
        guard let s = session else { portText = ""; subText = ""; return }
        portText = s.tunnelPort.map(String.init) ?? ""
        subText = s.tunnelSub ?? ""
    }

    private func commitBuffers() {
        guard let s = session else { return }
        let port = Int(portText.trimmingCharacters(in: .whitespaces))
        let sub = subText.trimmingCharacters(in: .whitespacesAndNewlines)
        store.setSessionTunnel(
            sessionId: s.id,
            port: port,
            sub: sub.isEmpty ? nil : sub
        )
        // If the tunnel is currently live, restart it so the new port /
        // subdomain take effect without the user having to flip the switch.
        // `startSessionTunnel` is idempotent — the service stops the prior
        // tunnel first.
        if store.wardenTunnels.isActive(owner: .session(s.id)), port != nil {
            store.startSessionTunnel(sessionId: s.id)
        }
    }

    private func toggle() {
        guard let s = session else { return }
        commitBuffers()
        if let state = state,
           (state.status == .connecting || { if case .ready = state.status { return true } else { return false } }())
        {
            store.stopSessionTunnel(sessionId: s.id)
        } else {
            store.startSessionTunnel(sessionId: s.id)
        }
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
