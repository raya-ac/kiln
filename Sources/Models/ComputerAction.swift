import Foundation
import CoreFoundation

struct ComputerTarget: Identifiable, Hashable, Sendable {
    let id: UInt32
    let pid: Int32
    let app: String
    let title: String
    let frame: CGRect
    var label: String { title.isEmpty ? app : "\(app) - \(title)" }
    func uniquelyIdentifies(_ windows: [ComputerTarget]) -> Bool {
        let matches = windows.filter { $0.pid == pid && $0.frame == frame }
        return matches.count == 1 && matches[0].id == id
    }

    func isTopmost(at point: CGPoint, windowsFrontToBack: [ComputerTarget]) -> Bool {
        guard let hit = windowsFrontToBack.first(where: { $0.frame.contains(point) }) else { return false }
        return hit.id == id && hit.pid == pid && hit.frame == frame
    }
}

struct ComputerCapture: Sendable {
    let id: String
    let target: ComputerTarget
    let width: Int
    let height: Int
    let timestamp: Date
    let jpeg: Data

    func point(x: Double, y: Double, current: ComputerTarget, now: Date = .now) throws -> CGPoint {
        guard now.timeIntervalSince(timestamp) >= 0, now.timeIntervalSince(timestamp) <= 60,
              current.id == target.id, current.pid == target.pid,
              current.frame == target.frame, width > 0, height > 0,
              x.isFinite, y.isFinite, x >= 0, y >= 0, x < Double(width), y < Double(height) else {
            throw ComputerUseError.staleCapture
        }
        return CGPoint(x: target.frame.minX + x * target.frame.width / Double(width),
                       y: target.frame.minY + y * target.frame.height / Double(height))
    }
}

enum ComputerUseError: LocalizedError {
    case inactive, permissions, targetGone, staleCapture, invalidAction, denied, busy, secureField, unsupported, listenerTimeout
    var errorDescription: String? {
        switch self {
        case .inactive: "Computer access is off for this turn. Enable it in Kiln for a selected window."
        case .permissions: "Kiln needs Screen Recording and Accessibility access in macOS Privacy & Security."
        case .targetGone: "The selected window is no longer available. Select a window again."
        case .staleCapture: "The screenshot expired or the window moved. Observe the window again before acting."
        case .invalidAction: "Invalid computer action. Use the advertised coordinates, keys, and size limits."
        case .denied: "The action was denied, timed out, or computer access was stopped. Nothing was executed."
        case .busy: "Another computer action is awaiting approval. Wait for its result."
        case .secureField: "Typing into a password field or an unidentified input is not allowed."
        case .unsupported: "This backend does not support Kiln's computer connection."
        case .listenerTimeout: "The local computer connection did not become ready. Try the request again."
        }
    }
}

struct ComputerAction: Sendable, Equatable {
    enum Kind: String, Sendable { case click, type_text, press_key, scroll }
    let kind: Kind
    let captureID: String
    let x: Double
    let y: Double
    let text: String
    let key: String
    let amount: Int
    let direction: String

    static let keys = ["Enter", "Escape", "Tab", "Backspace", "Delete", "ArrowLeft", "ArrowRight",
                       "ArrowUp", "ArrowDown", "Home", "End", "PageUp", "PageDown", "cmd+a", "cmd+f", "cmd+l", "cmd+z", "cmd+shift+z"]

    init(name: String, arguments: [String: Any]) throws {
        guard let kind = Kind(rawValue: name), let capture = arguments["capture_id"] as? String,
              UUID(uuidString: capture) != nil else { throw ComputerUseError.invalidAction }
        func number(_ value: Any?) -> Double? {
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
            return n.doubleValue
        }
        self.kind = kind
        captureID = capture
        x = number(arguments["x"]) ?? 0
        y = number(arguments["y"]) ?? 0
        text = arguments["text"] as? String ?? ""
        key = arguments["key"] as? String ?? ""
        let rawAmount = number(arguments["amount"]) ?? 0
        amount = rawAmount >= 1 && rawAmount <= 10 && rawAmount.rounded() == rawAmount ? Int(rawAmount) : 0
        direction = arguments["direction"] as? String ?? ""
        switch kind {
        case .click, .scroll:
            guard number(arguments["x"]) != nil, number(arguments["y"]) != nil, x >= 0, y >= 0, x < 1280, y < 960 else { throw ComputerUseError.invalidAction }
            if kind == .scroll, !(amount > 0 && ["up", "down", "left", "right"].contains(direction)) { throw ComputerUseError.invalidAction }
        case .type_text:
            guard !text.isEmpty, text.utf16.count <= 2_000,
                  text.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) || "\n\t".unicodeScalars.contains($0) }) else { throw ComputerUseError.invalidAction }
        case .press_key:
            guard Self.keys.contains(key) else { throw ComputerUseError.invalidAction }
        }
    }

    var title: String {
        switch kind {
        case .click: "Click at \(Int(x)), \(Int(y))"
        case .type_text: "Type \(text.count) characters"
        case .press_key: "Press \(key)"
        case .scroll: "Scroll \(direction) \(amount)"
        }
    }
}

enum ComputerConnection {
    static let serverName = "kiln_computer"
    static let environmentKeys = ["KILN_COMPUTER_PORT", "KILN_COMPUTER_TOKEN"]
    static func eligible(provider: ModelProvider, options: SendOptions) -> Bool {
        provider == .codex && !options.chatMode && options.mode == .build && options.permissions != .deny
    }
    static func blockers(provider: ModelProvider, options: SendOptions, screenAllowed: Bool,
                         inputAllowed: Bool, windowSelected: Bool, consent: Bool) -> [String] {
        var reasons: [String] = []
        if provider != .codex { reasons.append("Computer control is unavailable for \(provider.label). Choose a Codex model.") }
        if options.chatMode { reasons.append("Use a Code chat for computer control.") }
        if options.mode != .build { reasons.append("Switch this chat to Build mode.") }
        if options.permissions == .deny { reasons.append("Choose Guarded or Bypass permissions. Each computer action still needs approval.") }
        if !screenAllowed { reasons.append("Screen Recording is not granted to this running Kiln build.") }
        if !inputAllowed { reasons.append("Accessibility is not granted to this running Kiln build.") }
        if !windowSelected { reasons.append("Choose a window.") }
        if !consent { reasons.append("Confirm window sharing for this chat.") }
        return reasons
    }
    static func codexArguments(executable: String) -> [String] {
        func literal(_ value: Any) -> String {
            String(decoding: (try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])) ?? Data(), as: UTF8.self)
        }
        return ["-c", "mcp_servers.kiln_computer.command=\(literal(executable))",
                "-c", "mcp_servers.kiln_computer.args=[\"--computer-mcp\"]",
                "-c", "mcp_servers.kiln_computer.env_vars=\(literal(environmentKeys))",
                "-c", "mcp_servers.kiln_computer.tool_timeout_sec=125",
                "-c", "mcp_servers.kiln_computer.default_tools_approval_mode=\"auto\""]
    }
    static func openCodeServer(executable: String) -> [String: Any] {
        ["type": "local", "command": [executable, "--computer-mcp"], "codemode": false,
         "timeout": ["execution": 125_000]]
    }
}
