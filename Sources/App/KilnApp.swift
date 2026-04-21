import SwiftUI
import AppKit

@main
struct KilnApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store = AppStore()
    @StateObject private var updater = UpdaterService()

    var body: some Scene {
        WindowGroup("Kiln Code") {
            ContentView()
                .environmentObject(store)
                .frame(minWidth: 900, minHeight: 600)
                .onOpenURL { url in store.handleRemoteURL(url) }
                .onAppear {
                    AppDelegate.urlHandler = { [weak store] url in
                        Task { @MainActor in store?.handleRemoteURL(url) }
                    }
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1400, height: 900)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Session") {
                    store.showNewSessionSheet = true
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("Command Palette…") {
                    store.showCommandPalette = true
                }
                .keyboardShortcut("k", modifiers: .command)

                Button("Quick Open…") {
                    store.showQuickOpen = true
                }
                .keyboardShortcut("p", modifiers: .command)

                Button("Search Messages…") {
                    store.showGlobalSearch = true
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])

                Button("Find in Session") {
                    store.showInSessionFind = true
                }
                .keyboardShortcut("f", modifiers: .command)

                Button("Toggle Focus Mode") {
                    store.toggleFocusMode()
                }
                .keyboardShortcut("f", modifiers: [.command, .option])

                Button("Session Info") {
                    store.showSessionInfo = true
                }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(store.activeSessionId == nil)

                Button("Archive / Unarchive") {
                    if let id = store.activeSessionId {
                        store.toggleArchiveSession(id)
                    }
                }
                .keyboardShortcut("a", modifiers: [.command, .option])
                .disabled(store.activeSessionId == nil)

                Divider()

                Button("Keyboard Shortcuts") {
                    store.showShortcutsOverlay = true
                }
                .keyboardShortcut("?", modifiers: .command)

                Button("Session Templates…") {
                    store.showSessionTemplates = true
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])

                Divider()

                Button("Show Code Sessions") {
                    store.selectedSidebarTab = .code
                }
                .keyboardShortcut("1", modifiers: .command)

                Button("Show Chat Sessions") {
                    store.selectedSidebarTab = .chat
                }
                .keyboardShortcut("2", modifiers: .command)

                Divider()

                Button("Previous Session") {
                    store.navigateSession(direction: -1)
                }
                .keyboardShortcut("[", modifiers: .command)

                Button("Next Session") {
                    store.navigateSession(direction: 1)
                }
                .keyboardShortcut("]", modifiers: .command)
            }

            CommandGroup(after: .newItem) {
                Button("Close Session") {
                    if let id = store.activeSessionId {
                        store.deleteSession(id)
                    }
                }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(store.activeSessionId == nil)

                Divider()

                Button("Settings") {
                    store.showSettings = true
                }
                .keyboardShortcut(",", modifiers: .command)

                Divider()

                Button("Export Chat…") {
                    guard let id = store.activeSessionId else { return }
                    let md = store.exportSessionMarkdown(id)
                    let panel = NSSavePanel()
                    panel.allowedContentTypes = [.plainText]
                    panel.nameFieldStringValue = "\(store.activeSession?.name ?? "chat").md"
                    if panel.runModal() == .OK, let url = panel.url {
                        try? md.write(to: url, atomically: true, encoding: .utf8)
                    }
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(store.activeSessionId == nil)
            }

            // Standard Sparkle "Check for Updates…" menu item under the
            // app menu. Disabled when not running from a .app bundle or
            // when Sparkle is mid-check.
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    updater.checkForUpdates()
                }
                .disabled(!updater.canCheck)
            }

            CommandGroup(after: .pasteboard) {
                Button("Interrupt") {
                    store.interrupt()
                }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!store.isBusy)

                Button("Retry Last Message") {
                    Task { await store.retryLastMessage() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(store.isBusy || store.activeSession?.messages.isEmpty != false)
            }
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    nonisolated(unsafe) static var urlHandler: ((URL) -> Void)?
    private var appearanceObservation: NSKeyValueObservation?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        // Tint the Dock icon with the user's accent as early as possible —
        // before ContentView's onAppear fires — so the Dock doesn't flash
        // the bundled amber default. Reads the hex straight from the
        // persisted settings file.
        if let hex = Persistence.loadSettings().accentHex as String?, !hex.isEmpty {
            DockIconRenderer.apply(accent: NSColor(kilnHexString: hex))
        }

        // Re-render the Dock icon when the effective appearance changes —
        // catches both system-wide dark-mode flips (when theme == system)
        // and the user's own theme override (which sets NSApp.appearance).
        // ContentView also re-applies on accent/theme change, but KVO is
        // the only way to react to a system flip without a settings edit.
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.new]) { _, _ in
            let hex = Persistence.loadSettings().accentHex
            Task { @MainActor in
                DockIconRenderer.apply(accent: NSColor(kilnHexString: hex))
            }
        }

        // Register kiln:// URL scheme handler (works even without Info.plist entry
        // when the app is invoked via `open kiln://...` from a running instance).
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURLEvent(event:reply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc func handleURLEvent(event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let urlStr = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URL(string: urlStr)
        else { return }
        // SwiftUI's onOpenURL also fires for us, but this covers the case where
        // the AppleEvent arrives before the scene is live.
        Self.urlHandler?(url)
    }
}
