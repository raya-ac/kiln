import Foundation
import SwiftUI
import Sparkle

/// Wraps `SPUStandardUpdaterController` so SwiftUI can observe
/// "can check for updates now" state for the menu item's disabled flag
/// and trigger a manual check.
///
/// Sparkle reads `SUFeedURL` + `SUPublicEDKey` from the bundle's Info.plist,
/// so this type is near-trivial — the integration work lives in the
/// bundle-building script and the GitHub Actions release workflow.
///
/// Only makes sense when running from a `.app` bundle. When launched as a
/// raw binary from `.build/release/Kiln`, Sparkle has nothing to replace;
/// we gate init on that so dev runs don't spam the log.
@MainActor
final class UpdaterService: ObservableObject {
    private let controller: SPUStandardUpdaterController?
    private let delegate: UpdaterDelegate

    /// True when Sparkle is ready for a manual update check. Menu item
    /// binds to this for its `.disabled` state.
    @Published var canCheck: Bool = false

    init() {
        self.delegate = UpdaterDelegate()

        // Only activate inside a proper .app bundle. Dev runs via
        // `swift run` or `.build/release/Kiln` skip updater plumbing.
        let isBundled = Bundle.main.bundleURL.pathExtension == "app"
        if isBundled {
            self.controller = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: delegate,
                userDriverDelegate: nil
            )
        } else {
            self.controller = nil
        }

        // Publish initial state + observe changes from Sparkle.
        canCheck = controller?.updater.canCheckForUpdates ?? false
        if let updater = controller?.updater {
            // Sparkle exposes canCheckForUpdates as KVO-compliant.
            NotificationCenter.default.addObserver(
                forName: Notification.Name("SUUpdaterDidFinishUpdateCycleNotification"),
                object: nil,
                queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in
                    self.canCheck = updater.canCheckForUpdates
                }
            }
        }
    }

    /// Triggered by the "Check for Updates…" menu item.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// True if we're in a .app bundle and Sparkle is live.
    var isActive: Bool { controller != nil }
}

/// Minimal Sparkle delegate — mostly defaults. Hook here if we later want
/// to surface progress in UI, inject custom version comparators, or
/// provide feed URLs dynamically.
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {}
