import Foundation
import SwiftUI

/// Tracks usage over time to give users a sense of how close they are to
/// rate limits. Claude Code's CLI doesn't expose rate-limit headers through
/// stream-json, so we do two things:
///
/// 1. Record token usage as it streams in, bucketed into 5-min windows.
/// 2. Watch error events for rate-limit language and surface an explicit
///    "rate limited" state with a cooldown estimate.
///
/// The meter goes amber above 70% of the user-configured soft cap and red
/// when actually rate-limited. It's a heuristic — not a real rate-limit
/// header — but it's better than no signal at all.
@MainActor
final class RateLimitTracker: ObservableObject {
    static let shared = RateLimitTracker()

    struct UsageEvent: Sendable {
        let at: Date
        let inputTokens: Int
        let outputTokens: Int
    }

    /// Rolling window of usage events. Capped to last 10 min.
    @Published private(set) var events: [UsageEvent] = []

    /// True while we've recently seen a 429-style error. Cleared after
    /// `rateLimitCooldown` elapses (rough estimate).
    @Published private(set) var isRateLimited: Bool = false

    /// When the most recent rate-limit hit was observed. Nil if none.
    @Published private(set) var rateLimitedAt: Date?

    /// Soft cap — shown as 100% on the meter. User-configurable via
    /// settings, default 500k tokens/5min which tracks roughly with
    /// Anthropic's TPM tiers for Pro/Max subscriptions.
    var softCapTokensPerFiveMin: Int {
        UserDefaults.standard.integer(forKey: "rateLimit.softCap").nonZeroOrDefault(500_000)
    }

    /// Cooldown window after a rate limit hit, in seconds. After this we
    /// clear `isRateLimited`. Anthropic's real reset headers are ~60s for
    /// RPM limits, up to 60min for daily; 5min is a reasonable middle.
    private let rateLimitCooldown: TimeInterval = 300

    private var cooldownTask: Task<Void, Never>?

    // MARK: - Recording

    func recordUsage(inputTokens: Int, outputTokens: Int) {
        guard inputTokens > 0 || outputTokens > 0 else { return }
        events.append(UsageEvent(at: .now, inputTokens: inputTokens, outputTokens: outputTokens))
        prune()
    }

    /// Inspect an error string for rate-limit indicators and flip
    /// `isRateLimited` if it matches.
    func observeError(_ message: String) {
        let lower = message.lowercased()
        let signals = ["rate limit", "rate-limit", "429", "too many requests", "quota exceeded", "usage limit"]
        if signals.contains(where: { lower.contains($0) }) {
            markRateLimited()
        }
    }

    private func markRateLimited() {
        isRateLimited = true
        rateLimitedAt = .now
        cooldownTask?.cancel()
        let cooldown = rateLimitCooldown
        cooldownTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(cooldown * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.isRateLimited = false
            }
        }
    }

    /// Manual dismiss — user explicitly acknowledges the warning.
    func clearRateLimited() {
        cooldownTask?.cancel()
        isRateLimited = false
        rateLimitedAt = nil
    }

    // MARK: - Derived

    /// Tokens used in the last 5 minutes across all sessions. This is the
    /// velocity signal that maps to the soft cap.
    var tokensLastFiveMin: Int {
        let cutoff = Date().addingTimeInterval(-300)
        return events
            .filter { $0.at >= cutoff }
            .reduce(0) { $0 + $1.inputTokens + $1.outputTokens }
    }

    /// Usage ratio against the soft cap, clamped [0, 1.5] so we can
    /// render "over budget" states visually.
    var usageRatio: Double {
        let cap = softCapTokensPerFiveMin
        guard cap > 0 else { return 0 }
        return min(1.5, Double(tokensLastFiveMin) / Double(cap))
    }

    /// Seconds until the cooldown clears (nil if not rate limited).
    var cooldownRemaining: Int? {
        guard let hitAt = rateLimitedAt else { return nil }
        let elapsed = Date().timeIntervalSince(hitAt)
        let remaining = rateLimitCooldown - elapsed
        return remaining > 0 ? Int(remaining) : 0
    }

    // MARK: - Helpers

    private func prune() {
        let cutoff = Date().addingTimeInterval(-600) // keep 10 min of history
        events.removeAll { $0.at < cutoff }
    }
}

private extension Int {
    func nonZeroOrDefault(_ fallback: Int) -> Int {
        self == 0 ? fallback : self
    }
}
