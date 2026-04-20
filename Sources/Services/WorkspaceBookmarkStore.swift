import Foundation
import SwiftUI

// MARK: - Workspace Bookmarks
//
// Favorite working directories you can pin for quick access. The WorkDirButton
// shows them as a menu so switching a session's cwd is one click, not a
// native-panel dance.

struct WorkspaceBookmark: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var path: String
    var icon: String

    init(id: UUID = UUID(), name: String, path: String, icon: String = "folder") {
        self.id = id
        self.name = name
        self.path = path
        self.icon = icon
    }
}

@MainActor
final class WorkspaceBookmarkStore: ObservableObject {
    static let shared = WorkspaceBookmarkStore()

    @Published var bookmarks: [WorkspaceBookmark] = []

    private let key = "workspace.bookmarks.v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let arr = try? JSONDecoder().decode([WorkspaceBookmark].self, from: data) {
            bookmarks = arr
        } else {
            // Seed with the user's home as a useful default.
            bookmarks = [
                WorkspaceBookmark(name: "Home", path: NSHomeDirectory(), icon: "house"),
            ]
            persist()
        }
    }

    func add(path: String, name: String? = nil, icon: String = "folder") {
        let resolvedName = name ?? URL(fileURLWithPath: path).lastPathComponent
        // Dedup by path.
        if let existing = bookmarks.firstIndex(where: { $0.path == path }) {
            bookmarks[existing].name = resolvedName
            bookmarks[existing].icon = icon
        } else {
            bookmarks.append(WorkspaceBookmark(name: resolvedName, path: path, icon: icon))
        }
        persist()
    }

    func remove(_ id: UUID) {
        bookmarks.removeAll { $0.id == id }
        persist()
    }

    func move(from source: IndexSet, to destination: Int) {
        bookmarks.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(bookmarks) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
