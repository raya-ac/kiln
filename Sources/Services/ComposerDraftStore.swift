import AppKit
import Combine

struct ComposerDraft: Codable, Equatable, Sendable {
    var text = ""
    var attachments: [ComposerAttachment] = []
    var isEmpty: Bool { text.isEmpty && attachments.isEmpty }

    func merging(_ newer: ComposerDraft) -> ComposerDraft {
        var result = self
        if !newer.text.isEmpty, newer.text != text {
            result.text += result.text.isEmpty ? newer.text : "\n\n" + newer.text
        }
        for file in newer.attachments where !result.attachments.contains(where: { $0.path == file.path }) {
            result.attachments.append(file)
        }
        return result
    }
}

@MainActor
final class ComposerDraftStore: ObservableObject {
    private struct Pending: Codable { let id: String; let draft: ComposerDraft }
    private struct Archive: Codable {
        var drafts: [String: ComposerDraft] = [:]
        var pending: [String: Pending] = [:]
    }

    @Published private(set) var drafts: [String: ComposerDraft] = [:]
    @Published private(set) var imports: [String: Int] = [:]
    @Published private(set) var storageError: String?
    private var pending: [String: Pending] = [:]
    private var saveTask: Task<Void, Never>?
    private var termination: AnyCancellable?
    private let file: URL
    private var loadFailed = false

    init(file: URL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".kiln/drafts.json")) {
        self.file = file
        if FileManager.default.fileExists(atPath: file.path) {
            do {
                let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: file))
                drafts = archive.drafts
                // Interrupted undo windows become drafts, never automatic sends.
                for (id, draft) in archive.pending {
                    drafts[id] = draft.draft.merging(drafts[id] ?? ComposerDraft())
                }
            } catch {
                loadFailed = true
                storageError = "Saved drafts could not be read. The existing file has been left untouched."
            }
        }
        termination = NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { _ = self?.flush() } }
    }

    func draft(for id: String?) -> ComposerDraft { id.flatMap { drafts[$0] } ?? ComposerDraft() }
    func hasDraft(_ id: String) -> Bool { !draft(for: id).isEmpty }
    func isImporting(_ id: String?) -> Bool { (id.flatMap { imports[$0] } ?? 0) > 0 }

    func set(_ draft: ComposerDraft, for id: String) {
        drafts[id] = draft.isEmpty ? nil : draft
        scheduleSave()
    }

    func setText(_ text: String, for id: String) {
        var draft = draft(for: id)
        draft.text = text
        set(draft, for: id)
    }

    func setAttachments(_ attachments: [ComposerAttachment], for id: String) {
        var draft = draft(for: id)
        draft.attachments = attachments
        set(draft, for: id)
    }

    func addAttachment(_ attachment: ComposerAttachment, for id: String) {
        var draft = draft(for: id)
        guard !draft.attachments.contains(where: { $0.path == attachment.path }) else { return }
        draft.attachments.append(attachment)
        set(draft, for: id)
    }

    func beginImport(_ id: String) { imports[id, default: 0] += 1 }
    func endImport(_ id: String) { imports[id] = max(0, (imports[id] ?? 1) - 1) }

    /// Persist the request before clearing the input or starting its undo timer.
    func stage(_ draft: ComposerDraft, for id: String, requestID: String = UUID().uuidString) -> Bool {
        guard pending[id] == nil, !draft.isEmpty else { return false }
        let previous = drafts[id]
        pending[id] = Pending(id: requestID, draft: draft)
        drafts[id] = nil
        if flush() { return true }
        pending[id] = nil
        drafts[id] = previous
        return false
    }

    func restorePending(_ id: String, requestID: String) {
        guard pending[id]?.id == requestID, let request = pending.removeValue(forKey: id) else { return }
        set(request.draft.merging(draft(for: id)), for: id)
        _ = flush()
    }

    func completePending(_ id: String, requestID: String) {
        guard pending[id]?.id == requestID else { return }
        pending.removeValue(forKey: id)
        _ = flush()
    }

    func remove(_ id: String) {
        drafts.removeValue(forKey: id)
        pending.removeValue(forKey: id)
        _ = flush()
    }

    @discardableResult func flush() -> Bool {
        saveTask?.cancel()
        saveTask = nil
        guard !loadFailed else { return false }
        do {
            let directory = file.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(Archive(drafts: drafts, pending: pending))
            try data.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            storageError = nil
            return true
        } catch {
            storageError = "Drafts could not be saved. Your current text is still available in Kiln."
            return false
        }
    }

    func retrySaving() {
        if loadFailed {
            do {
                let backup = file.deletingLastPathComponent().appendingPathComponent("drafts-unreadable-" + UUID().uuidString + ".json")
                try FileManager.default.copyItem(at: file, to: backup)
                loadFailed = false
            } catch { return }
        }
        flush()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            _ = self?.flush()
        }
    }
}
