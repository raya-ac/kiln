import Foundation
import CoreFoundation

struct MeasuredTokenUsage: Sendable, Equatable {
    let sourceID: String?
    let input: Int?
    let output: Int?
    let cached: Int?
    let reasoning: Int?

    static func count(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0,
              number.doubleValue <= 1_000_000_000,
              number.doubleValue.rounded() == number.doubleValue else { return nil }
        return number.intValue
    }

    static func codex(_ value: [String: Any], sourceID: String?) -> Self {
        Self(sourceID: sourceID, input: count(value["input_tokens"]), output: count(value["output_tokens"]),
             cached: count(value["cached_input_tokens"]), reasoning: count(value["reasoning_output_tokens"]))
    }

    static func openCode(_ value: [String: Any], sourceID: String) -> Self {
        let cache = value["cache"] as? [String: Any] ?? [:]
        return Self(sourceID: sourceID, input: count(value["input"]), output: count(value["output"]),
                    cached: count(cache["read"]), reasoning: count(value["reasoning"]))
    }
    var hasMeasurement: Bool { input != nil || output != nil || cached != nil || reasoning != nil }
}
