import Foundation

struct CLIVersion: Comparable, Sendable {
    let major: Int
    let minor: Int
    let patch: Int
    let prerelease: [String]
    let text: String

    init?(_ value: String) {
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"^(?:codex-cli |opencode |rust-v|v)?([0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        self.text = String(text[range])
        let version = self.text.split(separator: "+", maxSplits: 1)[0]
        let parts = version.split(separator: "-", maxSplits: 1)
        let numbers = parts[0].split(separator: ".").compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }
        major = numbers[0]; minor = numbers[1]; patch = numbers[2]
        prerelease = parts.count == 2 ? parts[1].split(separator: ".").map(String.init) : []
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.major == rhs.major && lhs.minor == rhs.minor && lhs.patch == rhs.patch && lhs.prerelease == rhs.prerelease
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        if lhs.prerelease.isEmpty || rhs.prerelease.isEmpty {
            return !lhs.prerelease.isEmpty && rhs.prerelease.isEmpty
        }
        for (a, b) in zip(lhs.prerelease, rhs.prerelease) where a != b {
            if let aNumber = Int(a), let bNumber = Int(b) { return aNumber < bNumber }
            if Int(a) != nil { return true }
            if Int(b) != nil { return false }
            return a < b
        }
        return lhs.prerelease.count < rhs.prerelease.count
    }
}
