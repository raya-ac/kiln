import XCTest
@testable import Kiln

final class ComposerDraftTests: XCTestCase {
    private func file() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-drafts-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("drafts.json")
    }

    @MainActor func testIndependentDraftsAndAttachmentsSurviveRestart() throws {
        let file = try file()
        let store = ComposerDraftStore(file: file)
        let attachment = ComposerAttachment(id: "image", path: "/tmp/screenshot.png", name: "Screenshot.png")
        store.setText("first conversation", for: "a")
        store.addAttachment(attachment, for: "a")
        store.setText("second conversation", for: "b")
        XCTAssertTrue(store.flush())
        let restored = ComposerDraftStore(file: file)
        XCTAssertEqual(restored.draft(for: "a"), ComposerDraft(text: "first conversation", attachments: [attachment]))
        XCTAssertEqual(restored.draft(for: "b").text, "second conversation")
        XCTAssertTrue(restored.draft(for: "b").attachments.isEmpty)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    @MainActor func testPendingMessagesRecoverWithoutAutomaticSending() throws {
        let file = try file()
        let store = ComposerDraftStore(file: file)
        XCTAssertTrue(store.stage(ComposerDraft(text: "queued a"), for: "a", requestID: "a1"))
        XCTAssertTrue(store.stage(ComposerDraft(text: "queued b"), for: "b", requestID: "b1"))
        store.setText("typed afterward", for: "a")
        store.flush()
        let recovered = ComposerDraftStore(file: file)
        XCTAssertEqual(recovered.draft(for: "a").text, "queued a\n\ntyped afterward")
        XCTAssertEqual(recovered.draft(for: "b").text, "queued b")
        XCTAssertTrue(recovered.stage(recovered.draft(for: "a"), for: "a", requestID: "manual-resend"))
    }

    @MainActor func testUndoMergesWithoutClobberingNewTextOrDuplicatingFiles() throws {
        let store = ComposerDraftStore(file: try file())
        let file = ComposerAttachment(id: "1", path: "/tmp/report.pdf", name: "Report")
        XCTAssertTrue(store.stage(ComposerDraft(text: "original", attachments: [file]), for: "a", requestID: "one"))
        store.set(ComposerDraft(text: "new draft", attachments: [file]), for: "a")
        store.restorePending("a", requestID: "one")
        XCTAssertEqual(store.draft(for: "a").text, "original\n\nnew draft")
        XCTAssertEqual(store.draft(for: "a").attachments.count, 1)
    }

    @MainActor func testOldCompletionCannotTouchANewerPendingMessage() throws {
        let store = ComposerDraftStore(file: try file())
        XCTAssertTrue(store.stage(ComposerDraft(text: "first"), for: "a", requestID: "one"))
        store.completePending("a", requestID: "one")
        XCTAssertTrue(store.stage(ComposerDraft(text: "second"), for: "a", requestID: "two"))
        store.completePending("a", requestID: "one")
        store.restorePending("a", requestID: "one")
        XCTAssertTrue(store.draft(for: "a").isEmpty)
        store.restorePending("a", requestID: "two")
        XCTAssertEqual(store.draft(for: "a").text, "second")
    }

    @MainActor func testOneChatsUndoDoesNotCancelAnother() throws {
        let store = ComposerDraftStore(file: try file())
        XCTAssertTrue(store.stage(ComposerDraft(text: "a"), for: "a", requestID: "a1"))
        XCTAssertTrue(store.stage(ComposerDraft(text: "b"), for: "b", requestID: "b1"))
        store.restorePending("a", requestID: "a1")
        XCTAssertFalse(store.stage(ComposerDraft(text: "replacement"), for: "b"))
        store.restorePending("b", requestID: "b1")
        XCTAssertEqual(store.draft(for: "a").text, "a")
        XCTAssertEqual(store.draft(for: "b").text, "b")
    }

    @MainActor func testAsyncAttachmentsKeepTheirOriginalConversation() throws {
        let store = ComposerDraftStore(file: try file())
        store.beginImport("a")
        store.setText("b is now active", for: "b")
        store.addAttachment(ComposerAttachment(id: "1", path: "/tmp/a.png", name: "a.png"), for: "a")
        store.endImport("a")
        XCTAssertFalse(store.isImporting("a"))
        XCTAssertEqual(store.draft(for: "a").attachments.count, 1)
        XCTAssertTrue(store.draft(for: "b").attachments.isEmpty)
    }

    @MainActor func testCorruptDraftFileIsNeverOverwritten() throws {
        let file = try file()
        let original = Data("corrupt but preserve me".utf8)
        try original.write(to: file)
        let store = ComposerDraftStore(file: file)
        store.setText("new text", for: "a")
        XCTAssertFalse(store.flush())
        XCTAssertNotNil(store.storageError)
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(store.draft(for: "a").text, "new text")
        store.retrySaving()
        XCTAssertNil(store.storageError)
        XCTAssertEqual(ComposerDraftStore(file: file).draft(for: "a").text, "new text")
        let backup = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: file.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("drafts-unreadable-") })
        XCTAssertEqual(try Data(contentsOf: backup), original)
    }

    @MainActor func testFailedStagingKeepsTheDraft() throws {
        let parent = try file()
        try Data().write(to: parent)
        let store = ComposerDraftStore(file: parent.appendingPathComponent("blocked.json"))
        store.setText("do not lose this", for: "a")
        XCTAssertFalse(store.stage(store.draft(for: "a"), for: "a"))
        XCTAssertEqual(store.draft(for: "a").text, "do not lose this")
        XCTAssertNotNil(store.storageError)
    }

    @MainActor func testDeletingSessionAlsoRemovesPendingRecovery() throws {
        let file = try file()
        let store = ComposerDraftStore(file: file)
        XCTAssertTrue(store.stage(ComposerDraft(text: "deleted"), for: "a"))
        store.remove("a")
        XCTAssertTrue(ComposerDraftStore(file: file).draft(for: "a").isEmpty)
    }
}
