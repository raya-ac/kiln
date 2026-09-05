import XCTest
import SwiftUI
import AppKit
@testable import Kiln

final class WorkspaceRedesignTests: XCTestCase {
    func testRemotePageIncludesLocalAssetsAndSharedControls() {
        let page = RemoteWebAssets.page
        XCTAssertTrue(page.contains("Auto-compact at 90%"))
        XCTAssertTrue(page.contains("data:image/png;base64,"))
        XCTAssertTrue(page.contains("DOMPurify.sanitize"))
        XCTAssertTrue(page.contains("modelSearch"))
        XCTAssertTrue(page.contains("sessionId:s.id"))
        XCTAssertFalse(page.contains("<!--VENDOR-->"))
        XCTAssertFalse(page.contains("/*APPLICATION*/"))
        XCTAssertFalse(page.contains("<script src="))
        XCTAssertFalse(page.contains("__OPENAI_LOGO__"))
    }

    @MainActor func testComposerSurfaceAtCompactAndWideWidths() throws {
        _ = NSApplication.shared
        for width in [360.0, 860.0] {
            let content = ComposerSurface(focused: true) {
                Text("Check the workspace and review the latest changes.")
                    .font(.system(size: 14)).frame(minHeight: 60, alignment: .topLeading)
            } controls: {
                HStack {
                    WorkspaceIconButton(icon: "paperclip", label: "Attach files") {}
                    WorkspaceIconButton(icon: "text.alignleft", label: "Snippets") {}
                    Spacer()
                    WorkspaceIconButton(icon: "arrow.up", label: "Send message") {}
                }
            }.padding(20).frame(width: width).background(Color.kilnBg)
            let image = try XCTUnwrap(ImageRenderer(content: content).cgImage)
            XCTAssertEqual(image.width, Int(width))
            XCTAssertGreaterThan(image.height, 140)
            XCTAssertLessThan(image.height, 230)
            if let directory = ProcessInfo.processInfo.environment["KILN_VISUAL_OUTPUT"] {
                let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("composer-\(Int(width)).png"))
            }
        }
    }
}
