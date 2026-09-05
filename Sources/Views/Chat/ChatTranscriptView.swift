import SwiftUI
import AppKit

struct ChatTranscriptView: View {
    @EnvironmentObject var store: AppStore
    @Binding var jumpTarget: String?
    @State private var visibleCount = 40
    @State private var followsOutput = true

    private var messages: [ChatMessage] { store.activeSession?.messages ?? [] }
    private var window: ArraySlice<ChatMessage> { messages.suffix(visibleCount) }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Text("\(messages.count) messages")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.kilnTextSecondary)
                    if store.compactingSessionIds.contains(store.activeSessionId ?? "") {
                        ProgressView().controlSize(.mini)
                        Text("Compacting").font(.system(size: 11))
                    }
                    Spacer()
                    Button { store.showInSessionFind.toggle() } label: {
                        Image(systemName: "magnifyingglass")
                    }.help("Find in conversation")
                    Toggle(isOn: $followsOutput) {
                        Image(systemName: "arrow.down.to.line")
                    }
                    .toggleStyle(.button)
                    .help("Follow new output")
                    Button { followsOutput = true; scrollToBottom(proxy) } label: {
                        Image(systemName: "arrow.down")
                    }.help("Jump to latest")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .padding(.horizontal, 20)
                .frame(height: 34)
                .background(Color.kilnSurface)

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        if messages.count > visibleCount {
                            Button {
                                let anchor = window.first?.id
                                visibleCount += 40
                                followsOutput = false
                                Task { @MainActor in
                                    await Task.yield()
                                    if let anchor { proxy.scrollTo(anchor, anchor: .top) }
                                }
                            } label: {
                                Label("Load earlier messages (\(messages.count - visibleCount))", systemImage: "arrow.up")
                                    .font(.system(size: 12, weight: .medium))
                                    .frame(maxWidth: .infinity).padding(12)
                            }
                            .buttonStyle(.plain)
                        }
                        ForEach(window) { message in
                            MessageRow(message: message).id(message.id)
                        }
                        if store.isBusy || !store.streamingText.isEmpty || !store.traceEntries.isEmpty {
                            LiveAssistantRow()
                        }
                        if let error = store.lastError {
                            ErrorRow(error: error).padding(20)
                        }
                        if let session = store.activeSession, session.wasInterrupted,
                           !store.isBusy, session.messages.last?.role == .user {
                            ResumeInterruptedBanner().padding(20)
                        }
                        if messages.isEmpty && !store.isBusy {
                            VStack(alignment: .leading, spacing: 8) {
                                Image(systemName: "terminal").font(.system(size: 26))
                                Text(store.activeSession?.name ?? "Kiln")
                                    .font(.system(size: 20, weight: .semibold))
                                Text(store.activeSession?.workDir ?? "")
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(Color.kilnTextSecondary)
                            }.padding(28)
                        }
                        Color.clear.frame(height: 1).id("transcript-bottom")
                    }
                    .background(TranscriptScrollObserver { nearBottom in followsOutput = nearBottom })
                    .padding(.vertical, 8)
                }
                .onAppear { scrollToBottom(proxy) }
                .onChange(of: store.streamingText) { scrollIfFollowing(proxy) }
                .onChange(of: store.thinkingText) { scrollIfFollowing(proxy) }
                .onChange(of: store.activeToolCalls.count) { scrollIfFollowing(proxy) }
                .onChange(of: messages.count) { scrollIfFollowing(proxy) }
                .onChange(of: jumpTarget) { _, id in
                    guard let id else { return }
                    jump(id, proxy: proxy)
                    jumpTarget = nil
                }
                .onChange(of: store.pendingJumpMessageId) { _, id in
                    guard let id else { return }
                    jump(id, proxy: proxy)
                    store.pendingJumpMessageId = nil
                }
            }
        }
    }

    private func jump(_ id: String, proxy: ScrollViewProxy) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        visibleCount = max(visibleCount, messages.count - index)
        followsOutput = false
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo(id, anchor: .center)
        }
    }

    private func scrollIfFollowing(_ proxy: ScrollViewProxy) {
        guard followsOutput && store.settings.autoScroll else { return }
        scrollToBottom(proxy)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        Task { @MainActor in
            await Task.yield()
            proxy.scrollTo("transcript-bottom", anchor: .bottom)
        }
    }
}

/// Observe user scrolling only; content growth must not turn following off.
private struct TranscriptScrollObserver: NSViewRepresentable {
    let onScroll: (Bool) -> Void

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) { view.onScroll = onScroll }
    static func dismantleNSView(_ view: Probe, coordinator: ()) { view.stopObserving() }

    final class Probe: NSView {
        var onScroll: ((Bool) -> Void)?
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard window != nil else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSScrollView.didLiveScrollNotification, object: nil, queue: .main
            ) { @Sendable [weak self] notification in
                guard let scroll = notification.object as? NSScrollView else { return }
                Task { @MainActor [weak self, weak scroll] in
                    guard let self, let scroll, scroll === self.enclosingScrollView else { return }
                    let bottom = scroll.documentView?.bounds.maxY ?? 0
                    self.onScroll?(bottom - scroll.documentVisibleRect.maxY < 80)
                }
            }
        }

        func stopObserving() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }
    }
}
