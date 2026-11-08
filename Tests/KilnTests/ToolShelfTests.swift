import XCTest
import SwiftUI
import AppKit
@testable import Kiln

final class ToolShelfTests: XCTestCase {
    func testIndexKeepsRecentCallsBoundedAndIDsScoped() {
        let blocks: [MessageBlock] = (0..<1000).map {
            .toolUse(ToolUseBlock(id: "call-\($0)", name: "Read", input: "{}", isDone: true))
        }
        let message = ChatMessage(id: "one", role: .assistant, blocks: blocks)
        let second = ChatMessage(id: "two", role: .assistant, blocks: [.toolUse(ToolUseBlock(id: "call-999", name: "Read", input: "{}", isDone: true))])
        let index = IndexedToolCall.collect(messages: [message, second], active: [])
        XCTAssertEqual(index.count, 400)
        XCTAssertEqual(index.first?.id, ToolPresentation.disclosureID(messageID: "two", toolID: "call-999"))
        XCTAssertEqual(Set(index.map(\.id)).count, 400)
        XCTAssertFalse(index.contains { $0.tool.id == "call-0" })
    }

    func testLiveCallsLeadAndSearchCoversFailuresAndOutput() {
        let active = ToolUseBlock(id: "live", name: "Bash", input: #"{"command":"swift test"}"#, isDone: false)
        var failure = ToolUseBlock(id: "failed", name: "Read", input: #"{"path":"README.md"}"#, isDone: true)
        failure.isError = true; failure.result = "Permission denied"
        let index = IndexedToolCall.collect(messages: [ChatMessage(role: .assistant, blocks: [.toolUse(failure)])], active: [active])
        XCTAssertEqual(index.first?.tool.id, "live")
        XCTAssertTrue(index[1].matches("read permission", failuresOnly: true))
        XCTAssertFalse(index[0].matches("swift", failuresOnly: true))
        XCTAssertTrue(index[0].matches("swift test", failuresOnly: false))
        let repeated = IndexedToolCall.collect(messages: [ChatMessage(role: .assistant, blocks: [.toolUse(active)])], active: [active])
        XCTAssertEqual(repeated.count, 1)
    }

    func testRemoteDrawerIsLocalSanitizedAndNativeApprovalsAreNotExposed() {
        let page = RemoteWebAssets.page
        XCTAssertTrue(page.contains("toolShelfBtn"))
        XCTAssertTrue(page.contains("toolCallSearch"))
        XCTAssertTrue(page.contains("Computer access and input approvals remain native-only"))
        XCTAssertFalse(page.contains("/api/computer/approve"))
        XCTAssertTrue(page.contains("timelineNode('pre'"))
    }

    @MainActor func testApprovalPreviewFitsAndShowsFullTypingInScrollableRegion() throws {
        _ = NSApplication.shared
        let target = ComputerTarget(id: 1, pid: 2, app: "Fixture", title: "Test window", frame: CGRect(x: 0, y: 0, width: 800, height: 500))
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 500,
            bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let jpeg = try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [:]))
        let capture = ComputerCapture(id: UUID().uuidString, target: target, width: 800, height: 500, timestamp: .now, jpeg: jpeg)
        let action = try ComputerAction(name: "type_text", arguments: ["capture_id": capture.id, "text": String(repeating: "review this text\n", count: 100)])
        let proposal = ComputerApproval(id: UUID().uuidString, sessionID: "fixture", model: "Fixture model", action: action, capture: capture, expires: Date().addingTimeInterval(55))
        let renderer = ImageRenderer(content: ComputerApprovalView(proposal: proposal, chatName: "Origin chat") { _ in }.environment(\.colorScheme, .dark))
        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertEqual(image.width, 560)
        XCTAssertLessThanOrEqual(image.height, 680)
        XCTAssertGreaterThanOrEqual(image.height, 360)
        if let directory = ProcessInfo.processInfo.environment["KILN_VISUAL_OUTPUT"] {
            let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("computer-approval.png"))
            let hosted = NSHostingView(rootView: ComputerApprovalView(proposal: proposal, chatName: "Origin chat") { _ in }.environment(\.colorScheme, .dark))
            hosted.frame = CGRect(x: 0, y: 0, width: 560, height: ComputerApprovalView.height)
            let window = NSWindow(contentRect: hosted.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = hosted
            hosted.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(hosted.bitmapImageRepForCachingDisplay(in: hosted.bounds))
            hosted.cacheDisplay(in: hosted.bounds, to: bitmap)
            let hostedPNG = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            try hostedPNG.write(to: URL(fileURLWithPath: directory).appendingPathComponent("computer-approval-hosted.png"))
            window.close()
        }
    }
}
