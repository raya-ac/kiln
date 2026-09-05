import Foundation

struct ComposerPreferences: Codable, Equatable, Sendable {
    var mode: SessionMode = .build
    var permissions: PermissionMode = .bypass
    var extendedContext = false
    var maxTurns: Int?
    var thinkingEnabled = false
    var effort: EffortLevel = .medium

    static func defaults(from settings: KilnSettings) -> Self {
        Self(mode: settings.defaultMode, permissions: settings.defaultPermissions)
    }
}
