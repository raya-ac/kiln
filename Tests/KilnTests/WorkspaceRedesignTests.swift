import XCTest
import SwiftUI
import AppKit
@testable import Kiln

final class WorkspaceRedesignTests: XCTestCase {
    func testPaletteIdentitySurvivesFilteringAndCompactionAvailability() throws {
        let action = CommandPaletteView.PaletteAction(id: "compact", title: "Compact context", subtitle: "Current context", icon: "arrow.triangle.2.circlepath", shortcut: nil) {}
        let item = CommandPaletteView.PaletteItem.action(action)
        XCTAssertEqual(item.id, "action-compact")
        XCTAssertTrue(item.isEnabled)
        XCTAssertTrue(CommandPaletteView.fuzzyMatch(haystack: item.title.lowercased(), needle: "compact"))
        var session = Session(workDir: "/tmp", model: .gpt61Sol)
        XCTAssertFalse(CommandPaletteView.canCompact(nil, busy: false))
        XCTAssertFalse(CommandPaletteView.canCompact(session, busy: false))
        session.messages = [ChatMessage(role: .user, blocks: [.text("test")])]
        XCTAssertTrue(CommandPaletteView.canCompact(session, busy: false))
        XCTAssertFalse(CommandPaletteView.canCompact(session, busy: true))
        session.readOnly = true
        XCTAssertFalse(CommandPaletteView.canCompact(session, busy: false))
        session.readOnly = false
        session.model = try XCTUnwrap(AgentModel(rawValue: "grok:grok-4.7"))
        XCTAssertFalse(CommandPaletteView.canCompact(session, busy: false))
    }

    func testSessionVisibilityAtInspectorBreakpoint() {
        XCTAssertFalse(WorkspaceVisibility.sessions(collapsed: false, focused: false, inspector: true, width: 1119))
        XCTAssertTrue(WorkspaceVisibility.sessions(collapsed: false, focused: false, inspector: true, width: 1120))
        XCTAssertTrue(WorkspaceVisibility.sessions(collapsed: false, focused: false, inspector: false, width: 900))
        XCTAssertFalse(WorkspaceVisibility.sessions(collapsed: true, focused: false, inspector: false, width: 1400))
        XCTAssertFalse(WorkspaceVisibility.sessions(collapsed: false, focused: true, inspector: false, width: 1400))
    }

    func testBrandTapSequenceIsLocalBoundedAndResets() {
        var sequence = BrandTapSequence()
        let now = Date()
        for offset in 0..<6 { XCTAssertFalse(sequence.tap(now: now.addingTimeInterval(Double(offset) / 10))) }
        XCTAssertTrue(sequence.tap(now: now.addingTimeInterval(0.6)))
        XCTAssertFalse(sequence.tap(now: now.addingTimeInterval(0.7)))
        XCTAssertFalse(sequence.tap(now: now.addingTimeInterval(10)))
        for offset in 1..<6 { XCTAssertFalse(sequence.tap(now: now.addingTimeInterval(10 + Double(offset) / 10))) }
        XCTAssertTrue(sequence.tap(now: now.addingTimeInterval(10.6)))
    }

    @MainActor func testModernTabsKeepStableDimensionsAcrossSelections() throws {
        for width in [320.0, 620.0] {
            for tab in ToolShelfTab.allCases {
                let view = ToolShelfTabs(selection: .constant(tab)).frame(width: width)
                    .background(Color.kilnBg).environment(\.colorScheme, .dark)
                let image = try XCTUnwrap(ImageRenderer(content: view).cgImage)
                XCTAssertEqual(image.width, Int(width))
                XCTAssertEqual(image.height, 40)
                if let directory = ProcessInfo.processInfo.environment["KILN_VISUAL_OUTPUT"] {
                    let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                    try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("tabs-\(Int(width))-\(tab.id).png"))
                }
            }
        }
    }

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
