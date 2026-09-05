import SwiftUI

struct CompactionArchivesView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var listing = CompactionArchives.Listing()
    @State private var loading = true
    @State private var restoring = false
    @State private var query = ""
    @State private var selected: URL?
    @State private var error: String?

    private var entries: [CompactionArchives.Entry] {
        listing.entries.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.workDir.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Compaction Archives").font(.headline)
                Spacer()
                Button { NSWorkspace.shared.open(Persistence.compactionArchiveDirectory) } label: { Image(systemName: "folder") }
                    .help("Show archive folder").accessibilityLabel("Show archive folder")
                Button { dismiss() } label: { Image(systemName: "xmark") }
                    .help("Close archives").accessibilityLabel("Close archives")
            }.buttonStyle(.borderless).padding(20)
            Divider()
            TextField("Search archives", text: $query).textFieldStyle(.roundedBorder).padding(16)
            if loading {
                Spacer()
                ProgressView()
                Spacer()
            } else if entries.isEmpty {
                Spacer()
                ContentUnavailableView(query.isEmpty ? "No archives yet" : "No matching archives", systemImage: "archivebox")
                Spacer()
            } else {
                List(entries, selection: $selected) { entry in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(entry.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                            Spacer()
                            Text(entry.date, format: .dateTime.month().day().hour().minute()).font(.system(size: 11))
                        }
                        HStack {
                            Text(entry.workDir).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Text("\(entry.messageCount) messages").fixedSize()
                        }.font(.system(size: 11)).foregroundStyle(.secondary)
                    }.padding(.vertical, 5).tag(entry.file)
                }.listStyle(.inset)
            }
            if let error { Text(error).font(.system(size: 12)).foregroundStyle(.red).padding(.horizontal, 20).textSelection(.enabled) }
            if listing.unreadableCount > 0 {
                Text("\(listing.unreadableCount) archives could not be read.").font(.system(size: 11)).foregroundStyle(.secondary).padding(8)
            }
            Divider()
            HStack {
                Text("\(listing.entries.count) archives").font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh archives").accessibilityLabel("Refresh archives").disabled(loading || restoring)
                Button(restoring ? "Restoring..." : "Restore as New Chat") { restore() }
                    .disabled(selected == nil || restoring || loading)
            }.padding(16)
        }
        .frame(width: 640, height: 480)
        .task { await refresh() }
    }

    private func refresh() async {
        loading = true
        error = nil
        do { listing = try await Task.detached { try CompactionArchives.list() }.value }
        catch { self.error = error.localizedDescription }
        if !listing.entries.contains(where: { $0.file == selected }) { selected = nil }
        loading = false
    }

    private func restore() {
        guard let selected else { return }
        restoring = true
        error = nil
        Task {
            do {
                let restored = try await Task.detached {
                    let session = CompactionArchives.restoredSession(from: try CompactionArchives.read(selected))
                    try Persistence.saveSessionChecked(session)
                    return session
                }.value
                store.sessions.insert(restored, at: 0)
                store.activeSessionId = restored.id
                store.selectedSidebarTab = restored.kind
                ToastCenter.shared.show("Archive restored as a new chat.", kind: .success)
                dismiss()
            } catch { self.error = "Could not restore archive: " + error.localizedDescription }
            restoring = false
        }
    }
}
