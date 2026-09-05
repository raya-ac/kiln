import Foundation

enum CompactionArchives {
    struct Entry: Identifiable, Sendable {
        var id: URL { file }
        let file: URL
        let name: String
        let date: Date
        let messageCount: Int
        let workDir: String
    }

    struct Listing: Sendable {
        var entries: [Entry] = []
        var unreadableCount = 0
    }

    static func list(directory: URL = Persistence.compactionArchiveDirectory) throws -> Listing {
        guard FileManager.default.fileExists(atPath: directory.path) else { return Listing() }
        let files = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey], options: [.skipsHiddenFiles])
        var result = Listing()
        for file in files where file.pathExtension == "json" {
            do {
                let values = try file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
                guard values.isRegularFile == true else { continue }
                let data = try read(file)
                result.entries.append(Entry(file: file, name: data.name,
                    date: values.contentModificationDate ?? .distantPast,
                    messageCount: data.messages.count, workDir: data.workDir))
            } catch { result.unreadableCount += 1 }
        }
        result.entries.sort { $0.date > $1.date }
        return result
    }

    static func read(_ file: URL) throws -> SessionData {
        let values = try file.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
        guard values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 64 * 1024 * 1024 else {
            throw CocoaError(.fileReadTooLarge)
        }
        return try JSONDecoder().decode(SessionData.self, from: Data(contentsOf: file))
    }

    static func restoredSession(from data: SessionData) -> Session {
        let source = data.toSession()
        var restored = Session(workDir: source.workDir, name: source.name + " (restored)",
            model: source.model, group: source.group, forkedFrom: source.id, kind: source.kind,
            readOnly: source.readOnly, sessionInstructions: source.sessionInstructions, tags: source.tags,
            openAIFastMode: source.openAIFastMode, composerPreferences: source.composerPreferences)
        restored.messages = source.messages
        return restored
    }
}
