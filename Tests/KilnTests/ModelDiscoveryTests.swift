import XCTest
@testable import Kiln

final class ModelDiscoveryTests: XCTestCase {
    func testLivePageParsingFiltersHiddenAndKeepsExactEfforts() throws {
        let data = Data(#"{"data":[{"model":"gpt-6-astra","displayName":"GPT-6-Astra","hidden":false,"supportedReasoningEfforts":[{"reasoningEffort":"ultra"}]},{"model":"gpt-hidden","displayName":"Hidden","hidden":true,"supportedReasoningEfforts":[]}],"nextCursor":"page2"}"#.utf8)
        let page = try JSONDecoder().decode(CodexModelDiscovery.Page.self, from: data)
        XCTAssertEqual(page.nextCursor, "page2")
        let models = CodexModelDiscovery.descriptors(from: [page, page])
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models.first?.model, .gpt6Astra)
        XCTAssertEqual(models.first?.efforts, ["ultra"])
    }

    func testCacheReloadDoesNotOverwriteLiveModelsFromSameCLI() throws {
        let catalog = ModelCatalog()
        let version = try XCTUnwrap(CLIVersion("0.153.4"))
        catalog.replaceLive([ModelDescriptor(model: .gpt6Astra, displayName: "Astra", description: "Live",
            contextWindow: 272_000, efforts: ["ultra"])], version: version)
        catalog.reload(installedVersion: version)
        XCTAssertEqual(catalog.models.map(\.model), [.gpt6Astra])
        XCTAssertTrue(catalog.hasRecentLiveModels(for: version))
        XCTAssertFalse(catalog.hasRecentLiveModels(for: CLIVersion("0.151.0")!))
        catalog.reload(installedVersion: CLIVersion("0.151.0"))
        XCTAssertFalse(catalog.hasRecentLiveModels(for: version))
    }

    func testLiveInstalledModelListWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["KILN_LIVE_MODEL_LIST"] == "1" else { throw XCTSkip("Opt-in live model discovery") }
        let models = try await CodexModelDiscovery.fetch()
        XCTAssertTrue(models.contains { $0.model == .gpt6Astra })
        print("Selected CLI models: " + models.map { $0.model.rawValue }.joined(separator: ", "))
        XCTAssertGreaterThan(models.count, 2)
        print("Speed tiers: " + models.map { $0.model.rawValue + "=" + ($0.fastModeTier ?? "standard only") }.joined(separator: ", "))
        XCTAssertNotNil(models.first { $0.model == .gpt6Astra }?.fastModeTier)
    }

    func testFastModeUsesAdvertisedTierAndNormalOverridesGlobalFast() throws {
        let data = Data(#"{"data":[{"model":"gpt-test-speed","displayName":"Test","supportedReasoningEfforts":[],"serviceTiers":[{"id":"fast","description":"Higher credit usage"}]}]}"#.utf8)
        let page = try JSONDecoder().decode(CodexModelDiscovery.Page.self, from: data)
        let descriptors = CodexModelDiscovery.descriptors(from: [page])
        XCTAssertEqual(descriptors.first?.fastModeTier, "fast")
        let original = ModelCatalog.shared.models
        let version = try XCTUnwrap(CLIVersion("0.153.4"))
        ModelCatalog.shared.replaceLive(descriptors, version: version)
        defer { ModelCatalog.shared.replaceLive(original, version: version) }
        let model = try XCTUnwrap(descriptors.first?.model)
        var options = SendOptions()
        XCTAssertEqual(CodexProtocol.fastModeArgs(for: model, options: options), ["-c", #"service_tier="default""#])
        options.openAIFastMode = true
        XCTAssertEqual(CodexProtocol.fastModeArgs(for: model, options: options), ["-c", #"service_tier="fast""#, "-c", "features.fast_mode=true"])
        XCTAssertTrue(CodexProtocol.fastModeArgs(for: AgentModel(rawValue: "opencode:openai/gpt-5.5")!, options: options).isEmpty)
    }
}
