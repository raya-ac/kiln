import XCTest
@testable import Kiln

final class ChatRecoveryTests: XCTestCase {
    private func directory() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-recovery-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: path) }
        return path
    }

    func testPreferencesRoundTripAndLegacyDefaults() throws {
        var settings = KilnSettings()
        settings.defaultPermissions = .deny
        XCTAssertEqual(ComposerPreferences.defaults(from: settings).permissions, .deny)
        let old = Session(workDir: "/tmp")
        XCTAssertNil(try JSONDecoder().decode(SessionData.self, from: JSONEncoder().encode(SessionData(from: old))).toSession().composerPreferences)
        var session = old
        session.composerPreferences = ComposerPreferences(mode: .plan, permissions: .ask,
            extendedContext: true, maxTurns: 12, thinkingEnabled: true, effort: .high)
        let restored = try JSONDecoder().decode(SessionData.self, from: JSONEncoder().encode(SessionData(from: session))).toSession()
        XCTAssertEqual(restored.composerPreferences, session.composerPreferences)
        XCTAssertNil(old.composerPreferences)
    }

    func testCheckedSavePersistsAndReportsFailure() throws {
        let root = try directory()
        let session = Session(workDir: "/tmp")
        try Persistence.saveSessionChecked(session, directory: root)
        XCTAssertEqual(try CompactionArchives.read(root.appendingPathComponent(session.id + ".json")).id, session.id)
        let invalid = root.appendingPathComponent("not-a-directory")
        try Data().write(to: invalid)
        XCTAssertThrowsError(try Persistence.saveSessionChecked(session, directory: invalid))
        XCTAssertThrowsError(try Persistence.saveSessionChecked(Session(id: "../escape", workDir: "/tmp"), directory: root))
    }

    func testArchiveListingAndNonDestructiveRestore() throws {
        let root = try directory()
        var original = Session(workDir: "/tmp", name: "Original", isPinned: true, isArchived: true,
            tunnelPort: 3000, tunnelSub: "test", composerPreferences: ComposerPreferences(permissions: .deny))
        original.wasInterrupted = true
        original.messages = [ChatMessage(role: .user, blocks: [.text("original request")])]
        try Persistence.saveCompactionArchive(original, directory: root)
        try Data("invalid".utf8).write(to: root.appendingPathComponent("broken.json"))
        let listing = try CompactionArchives.list(directory: root)
        XCTAssertEqual(listing.entries.count, 1)
        XCTAssertEqual(listing.unreadableCount, 1)
        let entry = try XCTUnwrap(listing.entries.first)
        XCTAssertEqual(entry.messageCount, 1)
        let archive = try CompactionArchives.read(entry.file)
        let restored = CompactionArchives.restoredSession(from: archive)
        XCTAssertNotEqual(restored.id, original.id)
        XCTAssertEqual(restored.forkedFrom, original.id)
        XCTAssertEqual(restored.messages.first?.id, original.messages.first?.id)
        XCTAssertEqual(restored.composerPreferences, original.composerPreferences)
        XCTAssertFalse(restored.wasInterrupted)
        XCTAssertFalse(restored.isArchived)
        XCTAssertFalse(restored.isPinned)
        XCTAssertNil(restored.tunnelPort)
        XCTAssertNil(restored.tunnelSub)
        XCTAssertEqual(try CompactionArchives.read(entry.file).id, original.id)
    }

    func testMissingArchiveDirectoryIsEmptyAndSymlinksRejected() throws {
        let root = try directory()
        XCTAssertTrue(try CompactionArchives.list(directory: root.appendingPathComponent("absent")).entries.isEmpty)
        let target = root.appendingPathComponent("target.json")
        try Data("{}".utf8).write(to: target)
        let link = root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try CompactionArchives.read(link))
    }
}
