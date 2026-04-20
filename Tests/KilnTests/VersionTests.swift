import XCTest

/// Smoke tests anchoring the 1.0 test story. Intentionally minimal — the
/// goal for now is just to prove the target builds, runs, and that we have
/// a place to add real coverage as features land.
final class VersionTests: XCTestCase {
    /// The VERSION file at repo root is the single source of truth the
    /// Makefile, make-app-bundle.sh, and About panel all read from. If
    /// this ever disagrees with itself, catch it in CI rather than at ship.
    func testVersionFileIsSemverShaped() throws {
        // Walk up from this source file to find the repo root.
        let thisFile = URL(fileURLWithPath: #filePath)
        var dir = thisFile.deletingLastPathComponent()
        var versionURL: URL?
        for _ in 0..<6 {
            let candidate = dir.appendingPathComponent("VERSION")
            if FileManager.default.fileExists(atPath: candidate.path) {
                versionURL = candidate
                break
            }
            dir.deleteLastPathComponent()
        }
        let url = try XCTUnwrap(versionURL, "VERSION file not found walking up from tests")

        let raw = try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Allow "X.Y.Z" or "X.Y.Z-<suffix>". Reject empties, spaces, or "v" prefix.
        let pattern = #"^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$"#
        let regex = try NSRegularExpression(pattern: pattern)
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        XCTAssertNotNil(
            regex.firstMatch(in: raw, range: range),
            "VERSION file contents \(raw.debugDescription) are not semver-shaped"
        )
    }
}
