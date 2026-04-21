import XCTest

@testable import Kiln

/// Compile-smoke: proves the test target can link Kiln's module and that
/// at least one internal type is exercised. Real coverage lands as features
/// grow — treat this as a canary for the test pipeline itself.
final class SmokeTests: XCTestCase {
    func testClaudeModelHasRawValue() {
        // Any internal ClaudeModel case should have a non-empty rawValue
        // (the Anthropic model ID the CLI forwards).
        XCTAssertFalse(ClaudeModel.opus47.rawValue.isEmpty)
        XCTAssertFalse(ClaudeModel.sonnet46.rawValue.isEmpty)
        XCTAssertFalse(ClaudeModel.haiku45.rawValue.isEmpty)

        // All three should map to distinct model IDs — regression guard
        // against accidental aliasing when new models land.
        let ids = Set([
            ClaudeModel.opus47.rawValue,
            ClaudeModel.sonnet46.rawValue,
            ClaudeModel.haiku45.rawValue,
        ])
        XCTAssertEqual(ids.count, 3, "ClaudeModel raw values collide: \(ids)")
    }

    func testSessionKindHasDistinctRawValues() {
        XCTAssertNotEqual(SessionKind.code.rawValue, SessionKind.chat.rawValue)
    }
}
