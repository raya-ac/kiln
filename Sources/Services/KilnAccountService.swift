import Combine
import CryptoKit
import Darwin
import Foundation
import Security

struct KilnAccountCredential: Codable, Equatable, Sendable {
    let accountID: String
    let token: String
}

@MainActor protocol KilnAccountCredentialStore {
    func load() throws -> KilnAccountCredential?
    func save(_ credential: KilnAccountCredential) throws
    func delete() throws
}

@MainActor final class KilnAccountKeychain: KilnAccountCredentialStore {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "ac.raya.kiln.account.v1",
         kSecAttrAccount as String: "production-session",
         kSecAttrSynchronizable as String: false]
    }

    func load() throws -> KilnAccountCredential? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data,
              let credential = try? JSONDecoder().decode(KilnAccountCredential.self, from: data)
        else { throw KilnAccountError.keychain }
        return credential
    }

    func save(_ credential: KilnAccountCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let result = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if result == errSecItemNotFound {
            var item = query
            attributes.forEach { item[$0.key] = $0.value }
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw KilnAccountError.keychain }
        } else if result != errSecSuccess { throw KilnAccountError.keychain }
    }

    func delete() throws {
        let result = SecItemDelete(query as CFDictionary)
        guard result == errSecSuccess || result == errSecItemNotFound else { throw KilnAccountError.keychain }
    }
}

@MainActor protocol KilnAccountTransport {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Authenticated API requests do not need redirects, even within the same origin.
final class KilnAccountRedirectGuard: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor final class KilnAccountHTTP: KilnAccountTransport {
    private let session: URLSession
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 40
        session = URLSession(configuration: configuration, delegate: KilnAccountRedirectGuard(), delegateQueue: nil)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw KilnAccountError.invalidResponse }
        return (data, response)
    }
}

struct KilnUsageBinding: Codable, Sendable {
    let accountID: String
    let fingerprint: String
    var pending: KilnUsageEvent?
    var blocked = false
}

struct KilnAccountOutbox: Codable, Sendable {
    var version = 1
    var requiresLogin = true
    var consentAccountID: String?
    var consentGeneration = UUID()
    // Retain ownership and exact-payload fingerprints after ACK/logout, never reattribute a replay.
    var bindings: [String: KilnUsageBinding] = [:]

    mutating func discardPending() {
        consentAccountID = nil
        consentGeneration = UUID()
        for key in Array(bindings.keys) { bindings[key]?.pending = nil }
    }
}

@MainActor final class KilnAccountOutboxFile {
    let url: URL
    init(url: URL) { self.url = url }

    func load() throws -> KilnAccountOutbox {
        guard FileManager.default.fileExists(atPath: url.path) else { return KilnAccountOutbox() }
        guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw KilnAccountError.storage
        }
        let state = try KilnAccountJSON.decoder().decode(KilnAccountOutbox.self, from: Data(contentsOf: url))
        guard state.version == 1 else { throw KilnAccountError.storage }
        return state
    }

    func save(_ state: KilnAccountOutbox) throws {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        guard try directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw KilnAccountError.storage
        }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let temporary = directory.appendingPathComponent(".outbox-" + UUID().uuidString)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw KilnAccountError.storage }
        defer { close(descriptor); unlink(temporary.path) }
        let data = try KilnAccountJSON.encoder().encode(state)
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { throw KilnAccountError.storage }
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: written), bytes.count - written)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw KilnAccountError.storage }
                written += count
            }
        }
        guard fsync(descriptor) == 0, rename(temporary.path, url.path) == 0 else {
            throw KilnAccountError.storage
        }
        let directoryFD = open(directory.path, O_RDONLY | O_NOFOLLOW)
        guard directoryFD >= 0 else { throw KilnAccountError.storage }
        defer { close(directoryFD) }
        guard fsync(directoryFD) == 0 else { throw KilnAccountError.storage }
    }
}

@MainActor final class KilnAccountService: ObservableObject {
    static let shared = KilnAccountService()
    static let productionURL = URL(string: "https://kiln.raya.ac")!

    @Published private(set) var account: KilnAccount?
    @Published private(set) var isLoading = false
    @Published private(set) var isSyncing = false
    @Published private(set) var isLoadingHistory = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var syncError: String?
    @Published private(set) var recoveryCodes: [String] = []
    @Published private(set) var history: [KilnUsageHistoryEntry] = []
    @Published private(set) var aggregate: KilnUsageAggregate?
    @Published private(set) var nextHistoryCursor: Int?
    @Published private(set) var pendingCount = 0
    @Published private(set) var shareUsageEnabled = false
    @Published private(set) var chatSharingDefault = false
    @Published private(set) var readmes: [KilnSharedReadme] = []
    @Published private(set) var hasStoredSession = false

    private let baseURL: URL
    private let transport: any KilnAccountTransport
    private let secrets: any KilnAccountCredentialStore
    private let file: KilnAccountOutboxFile
    private var automaticallyFlush = true
    private var state = KilnAccountOutbox()
    private var credential: KilnAccountCredential?
    private var storageHealthy = true
    private var started = false
    private var generation = UUID()
    private var uploadTask: Task<Void, Never>?
    private var retryAfter = Date.distantPast

    convenience init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Kiln/Account", isDirectory: true)
        self.init(baseURL: Self.productionURL, transport: KilnAccountHTTP(), secrets: KilnAccountKeychain(),
                  file: KilnAccountOutboxFile(url: directory.appendingPathComponent("outbox-v1.json")))
    }

    /// Explicit test dependency injection; production has no URL/default/environment override.
    convenience init(testingBaseURL: URL, transport: any KilnAccountTransport,
                     secrets: any KilnAccountCredentialStore, outboxURL: URL) throws {
        guard testingBaseURL == Self.productionURL ||
            (testingBaseURL.scheme == "http" && ["localhost", "127.0.0.1", "[::1]"].contains(testingBaseURL.host ?? "")
             && testingBaseURL.user == nil && testingBaseURL.password == nil
             && testingBaseURL.query == nil && testingBaseURL.fragment == nil
             && ["", "/"].contains(testingBaseURL.path)) else { throw KilnAccountError.invalidOrigin }
        self.init(baseURL: testingBaseURL, transport: transport, secrets: secrets,
                  file: KilnAccountOutboxFile(url: outboxURL))
        automaticallyFlush = false
    }

    private init(baseURL: URL, transport: any KilnAccountTransport,
                 secrets: any KilnAccountCredentialStore, file: KilnAccountOutboxFile) {
        self.baseURL = baseURL
        self.transport = transport
        self.secrets = secrets
        self.file = file
        do { state = try file.load() }
        catch { storageHealthy = false; syncError = KilnAccountError.storage.localizedDescription }
        updateSharingState()
    }

    func start() async {
        guard !started else { return }
        started = true
        if storageHealthy {
            do {
                if state.requiresLogin { try secrets.delete() }
                else { credential = try secrets.load() }
            } catch { errorMessage = KilnAccountError.keychain.localizedDescription }
            updateSharingState()
            await refresh()
            await flushOutbox()
        }
    }

    func stop() { uploadTask?.cancel(); started = false }
    func dismissRecoveryCodes() { recoveryCodes = [] }
    func clearError() { errorMessage = nil }

    @discardableResult func register(handle: String, password: String, displayName: String = "") async -> Bool {
        var body = ["handle": handle, "password": password]
        if !displayName.isEmpty { body["displayName"] = displayName }
        return await authenticate(path: "/auth/register", body: body)
    }

    @discardableResult func signIn(handle: String, password: String) async -> Bool {
        await authenticate(path: "/auth/login", body: ["handle": handle, "password": password])
    }

    @discardableResult func recover(handle: String, recoveryCode: String, newPassword: String) async -> Bool {
        await authenticate(path: "/auth/recover", body: ["handle": handle, "recoveryCode": recoveryCode, "newPassword": newPassword])
    }

    private func authenticate(path: String, body: [String: String]) async -> Bool {
        guard !isLoading, credential == nil, storageHealthy else { return false }
        isLoading = true
        errorMessage = nil
        let epoch = generation
        defer { isLoading = false }
        do {
            let response: AuthResponse = try await request(path, method: "POST", body: body, token: nil)
            guard epoch == generation else { return false }
            try install(response)
            return true
        } catch { report(error); return false }
    }

    func refresh() async {
        guard let credential, !isLoading, Date.now >= retryAfter else { return }
        isLoading = true
        let epoch = generation
        defer { isLoading = false }
        do {
            let response: AccountResponse = try await request("/me", token: credential.token)
            guard epoch == generation else { return }
            try accept(response.account, expectedID: credential.accountID)
            errorMessage = nil
        } catch { if epoch == generation { report(error) } }
    }

    @discardableResult func updateProfile(displayName: String, bio: String, location: String = "", website: String = "", accent: String = "") async -> Bool {
        await updateAccount("/profile", body: ["displayName": displayName, "bio": bio, "location": location,
                                               "website": website, "accent": accent])
    }

    /// Uploads the app's current profile picture to the account so the public
    /// profile shows it. PNG/JPEG, 512 KB cap (server enforced too).
    @discardableResult func uploadAvatar(_ data: Data, mediaType: String) async -> Bool {
        guard let credential, !isLoading, data.count <= 524_288,
              ["image/png", "image/jpeg"].contains(mediaType) else { return false }
        isLoading = true
        errorMessage = nil
        let epoch = generation
        defer { isLoading = false }
        do {
            let response: AccountResponse = try await rawRequest("/avatar", method: "POST", data: data,
                                                                 contentType: mediaType, token: credential.token)
            guard epoch == generation else { return false }
            try accept(response.account, expectedID: credential.accountID)
            return true
        } catch { report(error); return false }
    }

    @discardableResult func clearAvatar() async -> Bool {
        guard let credential, !isLoading else { return false }
        isLoading = true
        errorMessage = nil
        let epoch = generation
        defer { isLoading = false }
        do {
            let response: AccountResponse = try await rawRequest("/avatar/clear", method: "POST",
                                                                 data: Data("{}".utf8), contentType: "application/json",
                                                                 token: credential.token)
            guard epoch == generation else { return false }
            try accept(response.account, expectedID: credential.accountID)
            return true
        } catch { report(error); return false }
    }

    /// Publishes measured usage on the public profile. This is separate from
    /// private usage reporting: enabling it does not require upload consent.
    @discardableResult func setPublicUsage(_ enabled: Bool) async -> Bool {
        await updateAccount("/settings", body: ["publicUsageEnabled": enabled])
    }

    /// Preference: default the "share this chat" choice on. Never auto-publishes.
    @discardableResult func setChatSharingDefault(_ enabled: Bool) async -> Bool {
        guard await updateAccount("/settings", body: ["chatSharingDefault": enabled]) else { return false }
        chatSharingDefault = enabled
        return true
    }

    /// Publishes a chat as a public README. Requires explicit training consent;
    /// the server rejects the call without it.
    @discardableResult func createReadme(title: String, body: String, sourceChatId: String? = nil) async -> KilnSharedReadme? {
        guard let credential, !isLoading else { return nil }
        isLoading = true
        errorMessage = nil
        let epoch = generation
        defer { isLoading = false }
        do {
            let payload = ReadmeBody(title: title, body: body, trainingConsent: true, sourceChatId: sourceChatId)
            let response: ReadmeResponse = try await request("/readmes", method: "POST", body: payload, token: credential.token)
            guard epoch == generation else { return nil }
            readmes.removeAll { $0.id == response.readme.id }
            readmes.insert(response.readme, at: 0)
            return response.readme
        } catch { report(error); return nil }
    }

    @discardableResult func refreshReadmes() async -> Bool {
        guard let credential, !isLoading else { return false }
        isLoading = true
        errorMessage = nil
        let epoch = generation
        defer { isLoading = false }
        do {
            let response: ReadmeList = try await request("/readmes", token: credential.token)
            guard epoch == generation else { return false }
            readmes = response.readmes
            return true
        } catch { report(error); return false }
    }

    @discardableResult func setReadme(_ id: String, enabled: Bool) async -> Bool {
        guard let credential, !isLoading else { return false }
        isLoading = true
        errorMessage = nil
        let epoch = generation
        defer { isLoading = false }
        do {
            let response: ReadmeResponse = try await request("/readmes/" + id, method: "PATCH",
                                                             body: ["enabled": enabled], token: credential.token)
            guard epoch == generation else { return false }
            if let index = readmes.firstIndex(where: { $0.id == id }) { readmes[index] = response.readme }
            return true
        } catch { report(error); return false }
    }

    @discardableResult func deleteReadme(_ id: String) async -> Bool {
        guard let credential, !isLoading else { return false }
        isLoading = true
        errorMessage = nil
        let epoch = generation
        defer { isLoading = false }
        do {
            let _: DeletedResponse = try await request("/readmes/" + id, method: "DELETE",
                                                       body: Optional<EmptyBody>.none, token: credential.token)
            guard epoch == generation else { return false }
            readmes.removeAll { $0.id == id }
            return true
        } catch { report(error); return false }
    }

    @discardableResult func setShareUsage(_ enabled: Bool) async -> Bool {
        guard let credential, !isLoading, account?.id == credential.accountID else { return false }
        var localRevocationSaved = true
        // Revocation is local and durable before waiting on the server.
        if !enabled {
            generation = UUID()
            uploadTask?.cancel()
            state.discardPending()
            localRevocationSaved = persist()
            if !localRevocationSaved {
                // If disk revocation fails, remove the credential too. Still attempt server-side revocation below.
                do { try secrets.delete() } catch { errorMessage = KilnAccountError.keychain.localizedDescription }
                self.credential = nil
                account = nil
                updateSharingState()
            }
        }
        isLoading = true
        errorMessage = nil
        let epoch = generation
        defer { isLoading = false }
        do {
            let response: AccountResponse = try await request("/settings", method: "PATCH",
                body: ["usageSharingEnabled": enabled], token: credential.token)
            guard epoch == generation else { return false }
            guard localRevocationSaved else { return false }
            try accept(response.account, expectedID: credential.accountID)
            guard response.account.usageSharingEnabled == enabled else { throw KilnAccountError.invalidResponse }
            state.consentAccountID = enabled ? credential.accountID : nil
            state.consentGeneration = UUID()
            guard persist() else { return false }
            if enabled { scheduleUpload() }
            return true
        } catch { report(error); return false }
    }

    private func updateAccount<T: Encodable>(_ path: String, body: T) async -> Bool {
        guard let credential, !isLoading else { return false }
        isLoading = true
        errorMessage = nil
        let epoch = generation
        defer { isLoading = false }
        do {
            let response: AccountResponse = try await request(path, method: "PATCH", body: body, token: credential.token)
            guard epoch == generation else { return false }
            try accept(response.account, expectedID: credential.accountID)
            return true
        } catch { report(error); return false }
    }

    @discardableResult func changePassword(currentPassword: String, newPassword: String) async -> Bool {
        guard let credential, !isLoading else { return false }
        isLoading = true
        errorMessage = nil
        let epoch = generation
        defer { isLoading = false }
        do {
            let response: AuthResponse = try await request("/auth/password", method: "POST",
                body: ["currentPassword": currentPassword, "newPassword": newPassword], token: credential.token)
            guard epoch == generation, response.account.id == credential.accountID else {
                throw KilnAccountError.invalidResponse
            }
            try install(response, preservingConsent: true)
            return true
        } catch { report(error); return false }
    }

    func signOut() async {
        guard !isLoading else { return }
        let oldCredential = credential
        isLoading = true
        defer { isLoading = false }
        clearSession()
        guard let oldCredential else { return }
        do {
            let _: OKResponse = try await request("/auth/logout", method: "POST", body: EmptyBody(), token: oldCredential.token)
        } catch {
            errorMessage = "Signed out on this Mac. Server session revocation could not be confirmed."
        }
    }

    /// Capture at turn START. Never ask for a fresh owner when a completed turn reports its usage.
    func usageCaptureOwner() -> KilnUsageCaptureOwner? {
        guard shareUsageEnabled, let account else { return nil }
        return KilnUsageCaptureOwner(accountID: account.id, consentGeneration: state.consentGeneration)
    }

    /// Call only for parser source usage. Returns true only after durable storage (or an identical prior receipt).
    @discardableResult func record(_ event: KilnUsageEvent, owner: KilnUsageCaptureOwner?) -> Bool {
        guard let owner, owner == usageCaptureOwner(), shareUsageEnabled,
              let account, let credential, account.id == credential.accountID else { return false }
        guard event.isValid() else { syncError = KilnAccountError.invalidEvent.localizedDescription; return false }
        do {
            let fingerprint = SHA256.hash(data: try KilnAccountJSON.encoder().encode(event))
                .map { String(format: "%02x", $0) }.joined()
            if let existing = state.bindings[event.eventID] {
                guard existing.accountID == account.id, existing.fingerprint == fingerprint else {
                    throw KilnAccountError.eventConflict
                }
                return true
            }
            guard state.bindings.count < 100_000, pendingCount < 5_000 else { throw KilnAccountError.storage }
            state.bindings[event.eventID] = KilnUsageBinding(accountID: account.id, fingerprint: fingerprint, pending: event)
            guard persist() else { return false }
            scheduleUpload()
            return true
        } catch { syncError = safeMessage(error); return false }
    }

    func flushOutbox() async {
        guard !isSyncing, shareUsageEnabled, !isLoading, Date.now >= retryAfter,
              let credential else { return }
        isSyncing = true
        let epoch = generation
        defer { isSyncing = false }
        let pending = state.bindings.values.filter {
            $0.accountID == credential.accountID && $0.pending != nil && !$0.blocked
        }
            .compactMap(\.pending).sorted { $0.occurredAt < $1.occurredAt }
        for event in pending {
            guard !Task.isCancelled, epoch == generation, shareUsageEnabled else { return }
            do {
                let receipt: UsageReceipt = try await request("/usage/events", method: "POST", body: event, token: credential.token)
                guard epoch == generation, shareUsageEnabled else { return }
                guard receipt.eventId == event.eventID else { throw KilnAccountError.invalidResponse }
                state.bindings[event.eventID]?.pending = nil
                guard persist() else { return }
                syncError = state.bindings.values.contains(where: \.blocked)
                    ? "A saved usage snapshot was rejected. It is retained locally and will not be retried." : nil
            } catch {
                guard epoch == generation else { return }
                syncError = safeMessage(error)
                if case KilnAccountError.unauthorized = error { clearSession() }
                else if case KilnAccountError.sharingDisabled = error {
                    state.discardPending(); _ = persist()
                } else if case let KilnAccountError.server(status, _) = error,
                          (400...499).contains(status), status != 429 {
                    state.bindings[event.eventID]?.blocked = true
                    _ = persist()
                    continue
                }
                return
            }
        }
    }

    func refreshHistory(loadMore: Bool = false) async {
        guard let credential, account?.id == credential.accountID, !isLoadingHistory else { return }
        if loadMore && nextHistoryCursor == nil { return }
        isLoadingHistory = true
        let epoch = generation
        defer { isLoadingHistory = false }
        do {
            var path = "/usage/history?limit=50"
            if loadMore, let cursor = nextHistoryCursor { path += "&before=\(cursor)" }
            let page: KilnUsageHistory = try await request(path, token: credential.token)
            let totals: KilnUsageAggregate = try await request("/usage/aggregate", token: credential.token)
            guard epoch == generation else { return }
            let existing = loadMore ? history : []
            let identifiers = Set(existing.map(\.id))
            history = existing + page.events.filter { !identifiers.contains($0.id) }
            aggregate = totals
            nextHistoryCursor = page.nextBefore
        } catch { if epoch == generation { report(error) } }
    }

    private func install(_ response: AuthResponse, preservingConsent: Bool = false) throws {
        guard !response.session.token.isEmpty, UUID(uuidString: response.account.id) != nil,
              KilnAccount.validHandle(response.account.handle) else { throw KilnAccountError.invalidResponse }
        let newCredential = KilnAccountCredential(accountID: response.account.id, token: response.session.token)
        try secrets.save(newCredential)
        if !preservingConsent { state.discardPending() }
        state.requiresLogin = false
        guard persist() else { try? secrets.delete(); throw KilnAccountError.storage }
        generation = UUID()
        credential = newCredential
        account = response.account
        recoveryCodes = response.recoveryCode.map { [$0] } ?? []
        errorMessage = nil
        updateSharingState()
    }

    private func accept(_ account: KilnAccount, expectedID: String) throws {
        guard account.id == expectedID, UUID(uuidString: account.id) != nil,
              KilnAccount.validHandle(account.handle) else { throw KilnAccountError.invalidResponse }
        self.account = account
        if !account.usageSharingEnabled { state.discardPending(); _ = persist() }
        chatSharingDefault = account.chatSharingDefault == true
        updateSharingState()
    }

    private func clearSession() {
        generation = UUID()
        uploadTask?.cancel()
        credential = nil
        account = nil
        history = []
        aggregate = nil
        readmes = []
        chatSharingDefault = false
        nextHistoryCursor = nil
        recoveryCodes = []
        state.discardPending()
        state.requiresLogin = true
        _ = persist()
        do { try secrets.delete() } catch { errorMessage = KilnAccountError.keychain.localizedDescription }
        updateSharingState()
    }

    @discardableResult private func persist() -> Bool {
        guard storageHealthy else { updateSharingState(); return false }
        do { try file.save(state); updateSharingState(); return true }
        catch {
            storageHealthy = false
            syncError = KilnAccountError.storage.localizedDescription
            updateSharingState()
            return false
        }
    }

    private func updateSharingState() {
        hasStoredSession = credential != nil
        shareUsageEnabled = storageHealthy && !state.requiresLogin && account != nil
            && account?.usageSharingEnabled == true && state.consentAccountID == account?.id
            && credential?.accountID == account?.id
        pendingCount = state.bindings.values.filter { $0.pending != nil }.count
    }

    private func scheduleUpload() {
        guard automaticallyFlush, uploadTask == nil else { return }
        uploadTask = Task { [weak self] in
            // A finite retry window; foreground refresh or a new event can start another window.
            for attempt in 0..<5 {
                guard !Task.isCancelled, let service = self else { break }
                await service.flushOutbox()
                guard service.shareUsageEnabled,
                      service.state.bindings.values.contains(where: { $0.pending != nil && !$0.blocked }) else { break }
                let delay = max(pow(2.0, Double(attempt + 1)), service.retryAfter.timeIntervalSinceNow)
                do { try await Task.sleep(for: .seconds(min(delay, 3600))) } catch { break }
            }
            self?.uploadTask = nil
        }
    }

    private func report(_ error: Error) {
        errorMessage = safeMessage(error)
        if case KilnAccountError.unauthorized = error { clearSession() }
    }

    private func safeMessage(_ error: Error) -> String {
        if let error = error as? KilnAccountError { return error.localizedDescription }
        return "Cannot reach Kiln securely. Check your connection and try again."
    }

    private func request<R: Decodable>(_ path: String, token: String?) async throws -> R {
        try await request(path, method: "GET", body: Optional<EmptyBody>.none, token: token)
    }

    private func request<R: Decodable, B: Encodable>(_ path: String, method: String, body: B?, token: String?) async throws -> R {
        guard let url = URL(string: "/api/v1" + path, relativeTo: baseURL)?.absoluteURL,
              Self.sameOrigin(url, baseURL) else { throw KilnAccountError.invalidOrigin }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpBody = try KilnAccountJSON.encoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return try await perform(request, url: url)
    }

    /// Sends a raw (non-JSON-body) request to a site path such as `/avatar`.
    private func rawRequest<R: Decodable>(_ path: String, method: String, data: Data?, contentType: String?, token: String) async throws -> R {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL,
              Self.sameOrigin(url, baseURL) else { throw KilnAccountError.invalidOrigin }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let data {
            request.httpBody = data
            request.setValue(contentType ?? "application/octet-stream", forHTTPHeaderField: "Content-Type")
        }
        return try await perform(request, url: url)
    }

    private func perform<R: Decodable>(_ request: URLRequest, url: URL) async throws -> R {
        let (data, response) = try await transport.send(request)
        guard let finalURL = response.url, Self.sameOrigin(finalURL, baseURL), finalURL == url,
              !(300...399).contains(response.statusCode) else { throw KilnAccountError.invalidOrigin }
        guard data.count <= 2_000_000 else { throw KilnAccountError.invalidResponse }
        if !(200...299).contains(response.statusCode) {
            let code = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error.code ?? ""
            if response.statusCode == 401 && code != "invalid_credentials" { throw KilnAccountError.unauthorized }
            if response.statusCode == 403 && code == "usage_sharing_disabled" { throw KilnAccountError.sharingDisabled }
            if response.statusCode == 429 || response.statusCode == 503 {
                let seconds = response.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 60
                retryAfter = Date.now.addingTimeInterval(min(max(seconds, 1), 3600))
            }
            throw KilnAccountError.server(response.statusCode, code)
        }
        do { return try JSONDecoder().decode(R.self, from: data) }
        catch { throw KilnAccountError.invalidResponse }
    }

    static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        func port(_ url: URL) -> Int { url.port ?? (url.scheme == "https" ? 443 : 80) }
        return lhs.scheme == rhs.scheme && lhs.host == rhs.host && port(lhs) == port(rhs)
            && lhs.user == nil && lhs.password == nil
    }

    private struct EmptyBody: Encodable {}
    private struct ReadmeBody: Encodable { let title: String; let body: String; let trainingConsent: Bool; let sourceChatId: String? }
    private struct ReadmeResponse: Decodable { let readme: KilnSharedReadme }
    private struct ReadmeList: Decodable { let readmes: [KilnSharedReadme] }
    private struct DeletedResponse: Decodable { let deleted: Bool }
    private struct AccountResponse: Decodable { let account: KilnAccount }
    private struct AuthResponse: Decodable {
        struct Session: Decodable { let token: String; let expiresAt: String }
        let account: KilnAccount
        let session: Session
        let recoveryCode: String?
    }
    private struct OKResponse: Decodable { let ok: Bool }
    private struct UsageReceipt: Decodable { let eventId: String; let duplicate: Bool }
    private struct ErrorResponse: Decodable {
        struct Detail: Decodable { let code: String }
        let error: Detail
    }
}
