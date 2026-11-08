import XCTest
import SwiftUI
import AppKit
@testable import Kiln

final class WorkspaceRedesignTests: XCTestCase {
    @MainActor func testMemoryModePickerStaysInsideNarrowInspectors() throws {
        _ = NSApplication.shared
        for width in [240.0, 300.0, 420.0, 620.0] {
            let root = CognitiveModePicker(selection: .constant("Assumptions"))
                .padding(.horizontal, 12).frame(width: width, height: 48)
                .background(Color.kilnBg).environment(\.colorScheme, .dark)
            let host = NSHostingView(rootView: root)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 48),
                                  styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let image = try XCTUnwrap(bitmap.cgImage)
            func segments(_ view: NSView) -> [NSSegmentedControl] {
                (view as? NSSegmentedControl).map { [$0] } ?? view.subviews.flatMap(segments)
            }
            let visible = segments(host).filter { !$0.isHiddenOrHasHiddenAncestor }
            if width == 240 {
                XCTAssertTrue(visible.isEmpty, "Narrow mode picker must use its menu fallback")
            } else if width == 620 {
                let control = try XCTUnwrap(visible.first, "Wide mode picker must remain segmented")
                XCTAssertEqual(control.segmentCount, CognitiveModePicker.modes.count)
                XCTAssertEqual((0..<control.segmentCount).compactMap { control.label(forSegment: $0) }, CognitiveModePicker.modes)
            }
            for control in visible {
                let frame = host.convert(control.bounds, from: control)
                XCTAssertGreaterThanOrEqual(frame.minX, 12 - 1)
                XCTAssertLessThanOrEqual(frame.maxX, width - 12 + 1)
            }
            let foreground = try XCTUnwrap(foregroundBounds(image), "Mode picker must render visible pixels")
            let scale = CGFloat(image.width) / width
            XCTAssertGreaterThan(foreground.width * foreground.height, 50)
            XCTAssertGreaterThanOrEqual(foreground.minX / scale, 12 - 1)
            XCTAssertLessThanOrEqual(foreground.maxX / scale, width - 12 + 1)
            if let directory = ProcessInfo.processInfo.environment["KILN_VISUAL_OUTPUT"] {
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("memory-mode-\(Int(width)).png"))
            }
        }
    }

    @MainActor func testLongMemoryProjectPathFitsInspectorContent() throws {
        _ = NSApplication.shared
        let path = "/Users/test/" + String(repeating: "a-very-long-project-directory/", count: 12)
        for width in [240.0, 300.0, 420.0] {
            let root = CognitiveView.projectPath(path).padding(.horizontal, 14)
                .frame(width: width).background(Color.kilnBg)
            let renderer = ImageRenderer(content: root)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage)
            XCTAssertEqual(image.width, Int(width * 2))
            XCTAssertGreaterThan(image.height, 0)
            XCTAssertLessThan(image.height, 80)
            let foreground = try XCTUnwrap(foregroundBounds(image), "Project path must render visible text")
            XCTAssertGreaterThanOrEqual(foreground.minX / 2, 14 - 1)
            XCTAssertLessThanOrEqual(foreground.maxX / 2, width - 14 + 1)
            if let directory = ProcessInfo.processInfo.environment["KILN_VISUAL_OUTPUT"] {
                let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("memory-path-\(Int(width)).png"))
            }
        }
    }

    private func foregroundBounds(_ image: CGImage) -> CGRect? {
        let width = image.width, height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        return pixels.withUnsafeMutableBytes { bytes in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            let rgba = bytes.bindMemory(to: UInt8.self)
            let background = [rgba[0], rgba[1], rgba[2]]
            var minX = width, minY = height, maxX = -1, maxY = -1
            for y in 0..<height {
                for x in 0..<width {
                    let offset = (y * width + x) * 4
                    guard (0..<3).contains(where: { abs(Int(rgba[offset + $0]) - Int(background[$0])) > 4 }) else { continue }
                    minX = min(minX, x); minY = min(minY, y)
                    maxX = max(maxX, x); maxY = max(maxY, y)
                }
            }
            guard maxX >= minX, maxY >= minY else { return nil }
            return CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        }
    }

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
