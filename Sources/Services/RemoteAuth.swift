import Foundation
import Network
import Security

/// Remote-control auth and request limits. Pure where it can be, so the
/// server and the tests share one decision instead of two stories.
enum RemoteAuth {
    struct Context: Equatable {
        var method: String
        var path: String
        var authorization: String?
        var peerIsLoopback: Bool
        var accessLevel: RemoteAccessLevel
        var tunnelExposed: Bool
        var token: String
    }

    enum Decision: Equatable {
        case allow
        case unauthorized
    }

    /// True when this request can be seen by something other than a process
    /// on this Mac. The warden tunnel arrives as loopback, so peer address
    /// alone is not enough.
    static func leavesMachine(_ context: Context) -> Bool {
        context.accessLevel != .loopback || context.tunnelExposed || !context.peerIsLoopback
    }

    /// `GET /` stays open so a phone can load the shell and read a fragment
    /// token. The fragment is never a request credential. Everything else
    /// always needs a configured nonempty bearer, including on loopback.
    static func credentialRequired(_ context: Context) -> Bool {
        if context.method == "GET" && context.path == "/" { return false }
        return true
    }

    static func decision(_ context: Context) -> Decision {
        guard credentialRequired(context) else { return .allow }
        guard !context.token.isEmpty else { return .unauthorized }
        let presented = bearerToken(from: context.authorization)
        return constantTimeEq(presented, context.token) ? .allow : .unauthorized
    }

    /// Authorization scheme only. Query `t` is not a credential and is not
    /// accepted here, on purpose.
    static func bearerToken(from authorization: String?) -> String {
        guard let authorization else { return "" }
        let prefix = "bearer "
        guard authorization.lowercased().hasPrefix(prefix) else { return "" }
        return String(authorization.dropFirst(prefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func constantTimeEq(_ a: String, _ b: String) -> Bool {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        if aBytes.count != bBytes.count { return false }
        var diff: UInt8 = 0
        for i in 0..<aBytes.count {
            diff |= aBytes[i] ^ bBytes[i]
        }
        return diff == 0
    }

    static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case .hostPort(let host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let address):
            let bytes = [UInt8](address.rawValue)
            return bytes.count == 4 && bytes[0] == 127
        case .ipv6(let address):
            let bytes = [UInt8](address.rawValue)
            guard bytes.count == 16 else { return false }
            if bytes == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1] { return true }
            let mapped = bytes[0..<10].allSatisfy { $0 == 0 } && bytes[10] == 0xff && bytes[11] == 0xff
            return mapped && bytes[12] == 127
        case .name(let name, _):
            return name == "localhost" || name == "127.0.0.1" || name == "::1"
        @unknown default:
            return false
        }
    }
}

enum RemoteLimits {
    static let maxHeaderBytes = 16 * 1024
    static let maxBodyBytes = 48 * 1024 * 1024
    static let requestTimeout: TimeInterval = 120
    static let maxInFlight = 32

    /// 431 if headers never finish inside the cap. 413 if Content-Length
    /// already admits a body we will not read. nil means keep reading.
    static func ingressStatus(buffer: Data,
                              maxHeaderBytes: Int = RemoteLimits.maxHeaderBytes,
                              maxBodyBytes: Int = RemoteLimits.maxBodyBytes) -> Int? {
        let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8))
        if buffer.count > maxHeaderBytes + maxBodyBytes { return 413 }
        if buffer.count > maxHeaderBytes && headerEnd == nil { return 431 }
        guard let headerEnd else { return nil }
        if headerEnd.lowerBound > maxHeaderBytes { return 431 }
        let header = buffer[..<headerEnd.lowerBound]
        guard let text = String(data: header, encoding: .utf8) else { return 400 }
        var length: Int?
        for line in text.components(separatedBy: "\r\n").dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return 400 }
            let name = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            if name == "transfer-encoding" { return 400 }
            guard name == "content-length" else { continue }
            let raw = parts[1].trimmingCharacters(in: .whitespaces)
            guard length == nil, let parsed = Int(raw), parsed >= 0 else { return 400 }
            length = parsed
            if parsed > maxBodyBytes { return 413 }
        }
        if text.components(separatedBy: "\r\n").first?.split(separator: " ").first?.uppercased() == "GET",
           (length ?? 0) != 0 { return 400 }
        if buffer.count - headerEnd.upperBound > (length ?? 0) { return 400 }
        return nil
    }
}

/// Persistent remote bearer. Keychain is the store. UserDefaults and
/// `~/.kiln/psk` are migration sources, then they are removed.
enum RemoteTokenStore {
    private static let service = "ac.raya.kiln.remote.v1"
    private static let account = "bearer"
    private static let defaultsKey = "remote.token"

    static func loadOrCreate(allowInteraction: Bool = false) -> String {
        let existing = read(allowInteraction: allowInteraction)
        if let token = existing.token { return token }
        guard mayCreate(after: existing.status) else { return "" }
        let migrated = UserDefaults.standard.string(forKey: defaultsKey) ?? ""
        if !migrated.isEmpty {
            guard create(migrated, allowInteraction: allowInteraction) else { return "" }
            UserDefaults.standard.removeObject(forKey: defaultsKey)
            return migrated
        }
        do {
            if let fileToken = try legacyToken(at: URL(fileURLWithPath: legacyPath)) {
                guard create(fileToken, allowInteraction: allowInteraction) else { return "" }
                try? FileManager.default.removeItem(atPath: legacyPath)
                return fileToken
            }
        } catch { return "" }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return "" }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return create(hex, allowInteraction: allowInteraction) ? hex : ""
    }

    static func mayCreate(after status: OSStatus) -> Bool { status == errSecItemNotFound }

    private static func create(_ token: String, allowInteraction: Bool) -> Bool {
        var item = query(allowInteraction: allowInteraction)
        item[kSecValueData as String] = Data(token.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func replace(_ token: String) -> Bool {
        guard !token.isEmpty, save(token) else { return false }
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        return true
    }

    @discardableResult
    private static func save(_ token: String, allowInteraction: Bool = false) -> Bool {
        if token.isEmpty { return delete() }
        guard let data = token.data(using: .utf8) else { return false }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let lookup = query(allowInteraction: allowInteraction)
        let update = SecItemUpdate(lookup as CFDictionary, attributes as CFDictionary)
        if update == errSecItemNotFound {
            var item = lookup
            attributes.forEach { item[$0.key] = $0.value }
            return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
        }
        return update == errSecSuccess
    }

    static func load() -> String? {
        read(allowInteraction: false).token
    }

    private static func read(allowInteraction: Bool) -> (token: String?, status: OSStatus) {
        var lookup = query(allowInteraction: allowInteraction)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let token = String(data: data, encoding: .utf8), !token.isEmpty else { return (nil, status) }
        return (token, status)
    }

    @discardableResult
    static func delete() -> Bool {
        let status = SecItemDelete(query() as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func query(allowInteraction: Bool = false) -> [String: Any] {
        var value: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
        if !allowInteraction { value[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
        return value
    }

    private static var legacyPath: String { "\(NSHomeDirectory())/.kiln/psk" }

    static func legacyToken(at url: URL) throws -> String? {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
        catch let error as POSIXError where error.code == .ENOENT { return nil }
        guard let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        return token
    }
}

/// All remote credential reads, migrations and rotations use the same serial owner.
actor RemoteCredentialVault {
    static let shared = RemoteCredentialVault()
    private let restoreOperation: @Sendable (Bool) -> String
    private let replaceOperation: @Sendable (String) -> Bool

    init(restore: @escaping @Sendable (Bool) -> String = { RemoteTokenStore.loadOrCreate(allowInteraction: $0) },
         replace: @escaping @Sendable (String) -> Bool = { RemoteTokenStore.replace($0) }) {
        restoreOperation = restore
        replaceOperation = replace
    }

    func restore(allowInteraction: Bool) -> String { restoreOperation(allowInteraction) }
    func replace(_ token: String) -> Bool {
        guard !token.isEmpty, replaceOperation(token) else { return false }
        return true
    }
}
