import XCTest
import SwiftUI
import AppKit
@testable import Kiln

final class ChatControlsTests: XCTestCase {
    @MainActor func testReasoningLayoutAtNarrowAndWideWidths() throws {
        _ = NSApplication.shared
        for width in [320.0, 620.0] {
            let content = ReasoningDisclosure(
                text: "Checking the selected workspace and available model capabilities.\n\nThe screenshot is attached to this turn. The file path and model selection are ready for verification.",
                isStreaming: false, initiallyExpanded: true)
                .padding(20).frame(width: width).background(Color.kilnBg)
            let renderer = ImageRenderer(content: content)
            let image = try XCTUnwrap(renderer.cgImage)
            XCTAssertEqual(image.width, Int(width))
            XCTAssertGreaterThan(image.height, 80)
            XCTAssertLessThan(image.height, 320)
            if let directory = ProcessInfo.processInfo.environment["KILN_VISUAL_OUTPUT"] {
                let url = URL(fileURLWithPath: directory).appendingPathComponent("reasoning-\(Int(width)).png")
                let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                try data.write(to: url)
            }
        }
    }

    @MainActor func testLiveFastModeWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["KILN_LIVE_FAST_CHECK"] == "1" else { throw XCTSkip("Opt-in live fast mode check") }
        let models = try await CodexModelDiscovery.fetch()
        let original = ModelCatalog.shared.models
        let version = try XCTUnwrap(CLIVersion("0.153.4"))
        ModelCatalog.shared.replaceLive(models, version: version)
        defer { ModelCatalog.shared.replaceLive(original, version: version) }
        XCTAssertTrue(AgentModel.gpt6Astra.supportsOpenAIFastMode)
        let service = AgentService()
        let id = UUID().uuidString
        defer { service.forgetThread(for: id) }
        var options = SendOptions()
        options.permissions = .deny
        options.openAIFastMode = true
        let timeout = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            service.interrupt(sessionId: id)
        }
        defer { timeout.cancel() }
        var output = "", errors: [String] = []
        await service.sendMessage(sessionId: id, message: "Reply with KILN_FAST_OK only. Do not use tools.", model: .gpt6Astra,
            workDir: "/tmp", options: options) {
            if case .textDelta(let text) = $0 { output += text }
            if case .error(let error) = $0 { errors.append(error) }
        }
        XCTAssertTrue(errors.isEmpty, errors.joined(separator: "\n"))
        XCTAssertTrue(output.contains("KILN_FAST_OK"), output)
    }
}
