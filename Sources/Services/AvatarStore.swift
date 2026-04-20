import Foundation
import AppKit
import SwiftUI

/// Manages the user's custom avatar image. Picked images are copied into
/// `~/Library/Application Support/Kiln/avatars/` so they survive even if
/// the original file moves or is deleted. The filename is stored in
/// `KilnSettings.userAvatarFilename`; views read the NSImage through this
/// store's `@Published avatar` property so they update live when the user
/// picks a new one.
@MainActor
final class AvatarStore: ObservableObject {
    static let shared = AvatarStore()

    @Published private(set) var avatar: NSImage?

    private let dir: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Kiln", isDirectory: true)
            .appendingPathComponent("avatars", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// Call on app launch (or when settings load) to hydrate the cached image
    /// from the stored filename.
    func load(filename: String) {
        guard !filename.isEmpty else {
            avatar = nil
            return
        }
        let url = dir.appendingPathComponent(filename)
        avatar = NSImage(contentsOf: url)
    }

    /// Shows an NSOpenPanel, copies the picked file into app support, and
    /// returns the new filename (or nil if cancelled / failed).
    func pickAndImport() -> String? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.png, .jpeg, .heic, .tiff, .gif, .webP, .bmp]
        guard panel.runModal() == .OK, let source = panel.url else { return nil }
        let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension
        // Always use a fresh filename so SwiftUI picks up the change even
        // when the user replaces their avatar with another file of the same
        // name.
        let filename = "user-\(Int(Date().timeIntervalSince1970)).\(ext)"
        let dest = dir.appendingPathComponent(filename)
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: source, to: dest)
            avatar = NSImage(contentsOf: dest)
            return filename
        } catch {
            return nil
        }
    }

    /// Remove the stored avatar and clear the cached image.
    func clear(filename: String) {
        if !filename.isEmpty {
            let url = dir.appendingPathComponent(filename)
            try? FileManager.default.removeItem(at: url)
        }
        avatar = nil
    }
}
