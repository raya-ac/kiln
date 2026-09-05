import XCTest
import Network
import AVFoundation
import MarkdownUI
import SwiftUI
import PDFKit
@testable import Kiln

final class MediaTests: XCTestCase {
    func testMarkdownImagesAudioVideoPDFAndReferenceLinks() {
        let source = """
        ![Screenshot](/tmp/demo%20image.png)

        ![Clip](https://example.com/demo.mp4?download=1)

        [Listen](audio/demo.flac)

        [Report][report]

        [report]: reports/test.pdf
        """
        let sections = MediaMarkdown.sections(source)
        XCTAssertEqual(sections.flatMap(\.media).map(\.kind), [.image, .video, .audio, .document])
        XCTAssertFalse(sections.map(\.markdown).joined().contains("!["))
        XCTAssertEqual(MediaMarkdown.references(source).first?.label, "Screenshot")
    }

    func testNoCodeSamplesOrUnsafeSchemesBecomeMedia() {
        let source = """
        ```markdown
        ![not an image](https://example.com/code.png)
        ```
        `![inline](https://example.com/inline.mp4)`
        \\![escaped](https://example.com/not-image)
        [section](#heading)
        [unsafe](javascript:alert(1))
        """
        XCTAssertTrue(MediaMarkdown.references(source).isEmpty)
        XCTAssertNil(MediaReference.make(source: "data:text/html,<script>alert(1)</script>", imageSyntax: true))
        XCTAssertNil(MediaReference.make(source: "javascript:alert(1)", imageSyntax: true))
        XCTAssertNil(MediaReference.make(source: "https://example.com/page"))
    }

    func testBareLinksAndDuplicateImages() {
        let refs = MediaMarkdown.references("https://example.com/demo.webm\n\n![same](https://example.com/a.gif)\n\n![same again](https://example.com/a.gif)")
        XCTAssertEqual(refs.map(\.kind), [.video, .image])
        XCTAssertEqual(refs.last?.id, MediaReference.make(source: "https://example.com/a.gif", imageSyntax: true)?.id)
    }

    func testOrdinaryMarkdownIsUnchanged() {
        let markdown = "| a | b |\n|---|---|\n| x | y |\n\n- [x] done\n\n~~old~~ **bold**"
        XCTAssertEqual(MediaMarkdown.sections(markdown).first?.markdown, markdown)
    }

    func testLocalFileBoundaryAndEscapedPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-media-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let work = root.appendingPathComponent("workspace")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let outside = root.appendingPathComponent("private.png")
        try Data([0]).write(to: outside)
        try FileManager.default.createSymbolicLink(at: work.appendingPathComponent("escape.png"), withDestinationURL: outside)
        XCTAssertNil(MediaReference.make(source: "escape.png")?.permittedURL(workDir: work.path))
        XCTAssertNil(MediaReference.make(source: "../private.png")?.permittedURL(workDir: work.path))
        XCTAssertNil(MediaReference.make(source: "file://remote-host/image.png")?.url(workDir: work.path))
        XCTAssertNil(MediaReference.make(source: "https://user:password@example.com/a.png")?.url(workDir: work.path))
        XCTAssertEqual(MediaReference.make(source: "output/my%20image.png")?.permittedURL(workDir: work.path)?.lastPathComponent, "my image.png")
        XCTAssertNotNil(MediaReference.make(source: "https://example.com/a.png")?.permittedURL(workDir: work.path))
    }

    func testByteRangesForSeeking() {
        XCTAssertEqual(MediaByteRange.parse("bytes=0-99", size: 1000), .init(offset: 0, count: 100))
        XCTAssertEqual(MediaByteRange.parse("bytes=900-", size: 1000), .init(offset: 900, count: 100))
        XCTAssertEqual(MediaByteRange.parse("bytes=-100", size: 1000), .init(offset: 900, count: 100))
        XCTAssertEqual(MediaByteRange.parse("bytes=0-9999", size: 1000), .init(offset: 0, count: 1000))
        for bad in ["bytes=1000-", "bytes=5-2", "bytes=0-1,4-5", "bytes=-0", "bytes=18446744073709551616-", "units=0-2"] {
            XCTAssertNil(MediaByteRange.parse(bad, size: 1000), bad)
        }
        XCTAssertNil(MediaByteRange.parse("bytes=0-", size: 0))
    }

    func testMediaHeadersHeadAndRange() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        try Data(repeating: 0, count: 1000).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let response = try MediaHTTP.response(file: file, rangeHeader: "bytes=20-29", download: false)
        XCTAssertEqual(response.status, 206)
        XCTAssertEqual(response.headers["Content-Range"], "bytes 20-29/1000")
        XCTAssertEqual(response.file?.range.count, 10)
        XCTAssertTrue(response.body.isEmpty)
        XCTAssertEqual(response.headers["X-Content-Type-Options"], "nosniff")
        let head = try MediaHTTP.response(file: file, rangeHeader: nil, download: false, head: true)
        XCTAssertNil(head.file)
        XCTAssertTrue(String(decoding: head.serialize(), as: UTF8.self).contains("Content-Length: 1000"))
        XCTAssertEqual(try MediaHTTP.response(file: file, rangeHeader: "bytes=2000-", download: false).status, 416)
    }

    func testChunkedFileTransferReturnsExactRequestedBytes() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        let bytes = Data((0..<400_000).map { UInt8($0 % 251) })
        try bytes.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let listener = try NWListener(using: .tcp, on: .any)
        let queue = DispatchQueue(label: "kiln.test.media")
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
                do {
                    let response = try MediaHTTP.response(file: file, rangeHeader: "bytes=100000-299999", download: false)
                    let transfer = try HTTPFileTransfer(body: response.file!, connection: connection)
                    connection.send(content: response.serialize(), completion: .contentProcessed { error in
                        if error != nil { connection.cancel() } else { transfer.sendNext() }
                    })
                } catch { connection.cancel() }
            }
        }
        let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                if case .ready = state, let port = listener.port {
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: port.rawValue)
                } else if case .failed(let error) = state {
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                }
            }
            listener.start(queue: queue)
        }
        defer { listener.cancel() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/media")!)
        request.timeoutInterval = 5
        request.setValue("bytes=100000-299999", forHTTPHeaderField: "Range")
        let (received, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual(received, bytes.subdata(in: 100_000..<300_000))
    }

    func testMediaDoesNotBreakSurroundingGFM() {
        let source = "| a | b |\n|---|---|\n| x | y |\n\n- [x] done\n\n~~old~~\n\n![image](output.png)"
        let sections = MediaMarkdown.sections(source)
        let html = sections.map { MarkdownContent($0.markdown).renderHTML() }.joined()
        XCTAssertTrue(html.contains("<table>"))
        XCTAssertTrue(html.contains("checked"))
        XCTAssertTrue(html.contains("<del>old</del>"))
        XCTAssertEqual(sections.flatMap(\.media).count, 1)
    }

    @MainActor func testNativeImageAndPDFViewsLoadWithoutAppStore() async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-native-media-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = NSImage(size: NSSize(width: 320, height: 160), flipped: false) { rect in
            NSColor.systemTeal.setFill(); rect.fill()
            return true
        }
        let png = try XCTUnwrap(NSBitmapImageRep(data: XCTUnwrap(image.tiffRepresentation))?.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("image.png"))
        let pdf = PDFDocument()
        pdf.insert(try XCTUnwrap(PDFPage(image: image)), at: 0)
        try XCTUnwrap(pdf.dataRepresentation()).write(to: directory.appendingPathComponent("report.pdf"))
        let host = NSHostingView(rootView: MediaMarkdownView(text: "![Image](image.png)\n\n[Report](report.pdf)", workDir: directory.path)
            .padding(20).frame(width: 600, height: 680).background(Color.kilnBg))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 680), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
        var loaded = false
        for _ in 0..<40 {
            host.layoutSubtreeIfNeeded()
            let views = descendants(host)
            loaded = views.contains { ($0 as? NSImageView)?.image != nil } && views.contains { ($0 as? PDFView)?.document != nil }
            if loaded { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(loaded, "The actual native image and PDF views should load their local fixtures")
        if let output = ProcessInfo.processInfo.environment["KILN_VISUAL_OUTPUT"],
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: output).appendingPathComponent("media-native.png"))
        }
    }
}
