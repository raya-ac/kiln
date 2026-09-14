import Foundation

struct KilnUsageCaptureOwner: Equatable, Sendable {
    let accountID: String
    let consentGeneration: UUID
}

struct KilnAccount: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let handle: String
    let displayName: String
    let bio: String
    let profileURL: String
    let usageSharingEnabled: Bool
    let createdAt: String

    // Never open an arbitrary URL supplied in an account response.
    var publicProfileURL: URL? {
        guard Self.validHandle(handle) else { return nil }
        return URL(string: "https://kiln.raya.ac/u/\(handle)")
    }

    static func validHandle(_ value: String) -> Bool {
        value.range(of: "^[a-z0-9_]{3,24}$", options: .regularExpression) == value.startIndex..<value.endIndex
    }
}

/// One non-overlapping, source-measured snapshot. No estimated counts, content, or filesystem metadata.
struct KilnUsageEvent: Codable, Equatable, Sendable {
    let eventID: String
    let provider: String
    let model: String
    let occurredAt: Date
    let inputTokens: Int?
    let outputTokens: Int?
    let cachedTokens: Int?
    let reasoningTokens: Int?
    let sessionID: String

    init(eventID: String, provider: String, model: String, occurredAt: Date,
         inputTokens: Int? = nil, outputTokens: Int? = nil, cachedTokens: Int? = nil,
         reasoningTokens: Int? = nil, sessionID: String? = nil) {
        self.eventID = eventID
        self.provider = provider
        self.model = model
        // The v1 wire format has millisecond precision, including persisted retries.
        self.occurredAt = Date(timeIntervalSince1970: (occurredAt.timeIntervalSince1970 * 1000).rounded() / 1000)
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cachedTokens = cachedTokens
        self.reasoningTokens = reasoningTokens
        self.sessionID = sessionID ?? eventID
    }

    enum CodingKeys: String, CodingKey {
        case eventID = "eventId", provider, model, occurredAt = "timestamp"
        case inputTokens, outputTokens, cachedTokens = "cachedInputTokens"
        case reasoningTokens = "reasoningOutputTokens", sessionID = "sessionId"
    }

    func isValid(now: Date = .now) -> Bool {
        let opaque = "^[A-Za-z0-9_-]{16,128}$"
        let identifier = "^[A-Za-z0-9][A-Za-z0-9._:/-]{0,95}$"
        let providers: Set<String> = ["codex", "opencode"]
        func matches(_ value: String, _ pattern: String) -> Bool {
            value.range(of: pattern, options: .regularExpression) == value.startIndex..<value.endIndex
        }
        return matches(eventID, opaque)
            && matches(sessionID, opaque)
            && providers.contains(provider)
            && matches(model, identifier)
            && occurredAt.timeIntervalSince1970 >= 1_577_836_800
            && occurredAt <= now.addingTimeInterval(300)
            && [inputTokens, outputTokens, cachedTokens, reasoningTokens].allSatisfy {
                $0.map { (0...1_000_000_000).contains($0) } ?? true
            }
    }
}

struct KilnUsageHistoryEntry: Decodable, Identifiable, Sendable {
    let sequence: Int
    let eventId: String
    let sessionId: String
    let provider: String
    let model: String
    let timestamp: String
    let inputTokens: Int?
    let outputTokens: Int?
    let cachedInputTokens: Int?
    let reasoningOutputTokens: Int?
    var id: Int { sequence }
}

struct KilnUsageHistory: Decodable, Sendable {
    let events: [KilnUsageHistoryEntry]
    let nextBefore: Int?
}

struct KilnTokenAggregate: Decodable, Sendable {
    let knownTotal: Int?
    let knownEvents: Int
    let unknownEvents: Int

    var formattedTotal: String { knownTotal.map { $0.formatted() } ?? "Unknown" }
}

struct KilnUsageAggregate: Decodable, Sendable {
    struct Counts: Decodable, Sendable {
        let inputTokens: KilnTokenAggregate
        let outputTokens: KilnTokenAggregate
        let cachedInputTokens: KilnTokenAggregate
        let reasoningOutputTokens: KilnTokenAggregate
    }
    let eventCount: Int
    let counts: Counts
}

enum KilnAccountError: Error, LocalizedError, Equatable {
    case invalidEvent, eventConflict, storage, keychain, invalidResponse, unauthorized, sharingDisabled
    case invalidOrigin, busy, server(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidEvent: "This usage snapshot has invalid identifiers, counts, or a timestamp."
        case .eventConflict: "This event ID already belongs to a different snapshot or account. Nothing was reassigned."
        case .storage: "The private usage outbox could not be saved. Sharing is paused."
        case .keychain: "The account session could not be accessed securely in Keychain."
        case .invalidResponse: "Kiln returned an unexpected account response."
        case .unauthorized: "Your session has expired. Sign in again."
        case .sharingDisabled: "Usage sharing is disabled for this account."
        case .invalidOrigin: "The account request was blocked because its destination changed."
        case .busy: "An account operation is already in progress."
        case let .server(status, code):
            switch code {
            case "invalid_credentials": "The handle, password, or recovery code is incorrect."
            case "handle_unavailable": "That handle is unavailable."
            case "invalid_request": "Check the account fields and try again."
            case "event_conflict": "A saved usage event conflicts with the server snapshot. Sharing is paused."
            default:
                status == 429 ? "Too many attempts. Wait before trying again." : "The account request failed (\(status))."
            }
        }
    }
}

enum KilnAccountJSON {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(timestamp(date))
        }
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            guard let date = formatter.date(from: value) else { throw KilnAccountError.invalidResponse }
            return date
        }
        return decoder
    }

    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
