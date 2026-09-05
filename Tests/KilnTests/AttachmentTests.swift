import XCTest
import AppKit
import SwiftUI
import UniformTypeIdentifiers
@testable import Kiln

final class AttachmentTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kiln attachments " + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func image(_ type: NSBitmapImageRep.FileType) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 64, pixelsHigh: 64,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        let red = NSColor(deviceRed: 1, green: 0, blue: 0, alpha: 1)
        for x in 0..<64 { for y in 0..<64 { bitmap.setColor(red, atX: x, y: y) } }
        return try XCTUnwrap(bitmap.representation(using: type, properties: [:]))
    }

    @MainActor func testTIFFAndPNGProvidersPersistAsUniquePNGFiles() async throws {
        let importer = AttachmentImporter(directory: try directory())
        for (format, type) in [(NSBitmapImageRep.FileType.tiff, UTType.tiff), (.png, .png), (.jpeg, .jpeg)] {
            let provider = NSItemProvider(item: try image(format) as NSData, typeIdentifier: type.identifier)
            let a = try await importer.load(provider)
            let b = try await importer.load(provider)
            XCTAssertNotEqual(a.path, b.path)
            XCTAssertTrue(a.isImage)
            XCTAssertEqual((a.path as NSString).pathExtension, "png")
            let data = try Data(contentsOf: URL(fileURLWithPath: a.path))
            XCTAssertEqual(Array(data.prefix(8)), [137, 80, 78, 71, 13, 10, 26, 10])
            XCTAssertNotNil(NSImage(contentsOfFile: a.path))
            let permissions = try FileManager.default.attributesOfItem(atPath: a.path)[.posixPermissions] as? NSNumber
            XCTAssertEqual(permissions?.intValue, 0o600)
        }
    }

    @MainActor func testFinderFilesWinOverThumbnailsAndKeepSpaces() async throws {
        let root = try directory()
        let files = [root.appendingPathComponent("a report.pdf"), root.appendingPathComponent("hello world.txt")]
        for file in files { try Data("fixture".utf8).write(to: file) }
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let items = files.map { file in
            let item = NSPasteboardItem()
            item.setString(file.absoluteString, forType: .fileURL)
            item.setData(Data("not an actual thumbnail".utf8), forType: .tiff)
            return item
        }
        board.writeObjects(items)
        let providers = AttachmentImporter.providers(from: board)
        XCTAssertEqual(providers.count, 2)
        for (provider, file) in zip(providers, files) {
            let attachment = try await AttachmentImporter(directory: root).load(provider)
            XCTAssertEqual(attachment.path, file.path)
            XCTAssertEqual(attachment.name, file.lastPathComponent)
        }
    }

    @MainActor func testNativePasteRoutesImagesWithoutChangingDraft() throws {
        _ = NSApplication.shared
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        board.setData(try image(.tiff), forType: .tiff)
        let view = AttachmentTextView()
        view.string = "keep this draft"
        view.clipboard = { board }
        var received = 0
        view.onPaste = { received += $0.count }
        view.paste(nil)
        XCTAssertEqual(received, 1)
        XCTAssertEqual(view.string, "keep this draft")
        board.clearContents()
        board.setString("ordinary text", forType: .string)
        XCTAssertTrue(AttachmentImporter.providers(from: board).isEmpty)
        view.isRichText = false
        view.setSelectedRange(NSRange(location: 5, length: 4))
        XCTAssertTrue(view.readSelection(from: board, type: .string))
        XCTAssertEqual(view.string, "keep ordinary text draft")
    }

    @MainActor func testNativeReturnAndCommandReturnRouting() throws {
        _ = NSApplication.shared
        let view = AttachmentTextView()
        var sent = 0, commandSent = 0
        view.onReturn = { sent += 1 }
        view.onCommandReturn = { commandSent += 1 }
        for modifiers in [NSEvent.ModifierFlags(), .command] {
            let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: 0, windowNumber: 0, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
            view.keyDown(with: event)
        }
        XCTAssertEqual(sent, 1)
        XCTAssertEqual(commandSent, 1)
    }

    @MainActor func testNativeComposerHasVisibleTextLayout() throws {
        _ = NSApplication.shared
        let root = ComposerTextInput(text: .constant("Paste a screenshot here"), isFocused: .constant(false), onPaste: { _ in })
            .frame(width: 400).padding(14)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 428, height: 80), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        func find(_ view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }
            return view.subviews.lazy.compactMap(find).first
        }
        let text = try XCTUnwrap(find(host))
        XCTAssertEqual(text.string, "Paste a screenshot here")
        XCTAssertGreaterThan(text.bounds.width, 100)
        XCTAssertGreaterThan(text.bounds.height, 10)
        XCTAssertLessThan(host.fittingSize.height, 200)
    }

    func testInvalidAttachmentsFailVisibly() throws {
        let importer = AttachmentImporter(directory: try directory())
        XCTAssertThrowsError(try importer.saveImage(Data("not an image".utf8)))
        XCTAssertThrowsError(try importer.saveImage(Data(count: 32 * 1024 * 1024 + 1)))
        XCTAssertThrowsError(try AttachmentImporter.file(URL(string: "https://example.com/image.png")!))
        XCTAssertThrowsError(try AttachmentImporter.file(importer.directory))
        XCTAssertThrowsError(try AttachmentImporter.file(importer.directory.appendingPathComponent("missing")))
    }

    func testBackendAttachmentArgumentsForNewAndResumedTurns() {
        let images = ["/tmp/screenshot one.png", "/tmp/second.png"]
        for thread in [nil, "existing-thread"] {
            let args = CodexProtocol.buildArguments(threadId: thread, model: .gpt55, workDir: "/tmp",
                options: SendOptions(), imagePaths: images)
            XCTAssertEqual(args.filter { $0 == "--image" }.count, 2)
            for path in images { XCTAssertTrue(args.contains(path)) }
            XCTAssertEqual(args.last, "-")
        }
        let paths = images + ["/tmp/report.pdf"]
        let args = OpenCodeProtocol.arguments(sessionId: "existing", model: AgentModel(rawValue: "opencode:openai/gpt-5.5")!,
            workDir: "/tmp", options: SendOptions(), filePaths: paths)
        XCTAssertEqual(args.filter { $0 == "--file" }.count, 3)
        XCTAssertEqual(Array(args.suffix(6)), paths.flatMap { ["--file", $0] })
    }

    @MainActor func testLiveImageAttachmentWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["KILN_LIVE_IMAGE_CHECK"] == "1" else { throw XCTSkip("Opt-in live image check") }
        let attachment = try AttachmentImporter(directory: directory()).saveImage(image(.png))
        let service = AgentService()
        let id = UUID().uuidString
        defer { service.forgetThread(for: id) }
        var options = SendOptions()
        options.permissions = .deny
        let timeout = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(90)) } catch { return }
            service.interrupt(sessionId: id)
        }
        defer { timeout.cancel() }
        for _ in 0..<2 {
            var output = "", errors: [String] = []
            await service.sendMessage(sessionId: id, message: "Name the single color in the attached image. One word only. Do not use tools.",
                model: .gpt6Astra, workDir: "/tmp", options: options, attachments: [attachment]) {
                if case .textDelta(let value) = $0 { output += value }
                if case .error(let value) = $0 { errors.append(value) }
            }
            XCTAssertTrue(errors.isEmpty, errors.joined(separator: "\n"))
            XCTAssertTrue(output.lowercased().contains("red"), output)
        }
    }
}
