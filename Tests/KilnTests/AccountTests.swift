import Foundation
import XCTest
@testable import Kiln

@MainActor private final class AccountTestSecrets: KilnAccountCredentialStore {
    var value: KilnAccountCredential?
    var failSave = false
    var failDelete = false
    func load() throws -> KilnAccountCredential? { value }
    func save(_ credential: KilnAccountCredential) throws {
        if failSave { throw KilnAccountError.keychain }
        value = credential
    }
    func delete() throws {
        if failDelete { throw KilnAccountError.keychain }
        value = nil
    }
}

@MainActor private final class AccountTestHTTP: KilnAccountTransport {
    var requests: [URLRequest] = []
    var accountID = "A0000000-0000-0000-0000-000000000001"
    var sharing = false
    var usageFailure: Int?
    var meFailure: Int?
    var logoutFails = false
    var responseURL: URL?
    var duplicate = false
    var token = "synthetic-secret-never-on-disk"
    var usageGate: CheckedContinuation<Void, Never>?
    var holdUsage = false
    var badCurrentPassword = false

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        var status = 200
        var body: [String: Any] = [:]
        let input = (try? JSONSerialization.jsonObject(with: request.httpBody ?? Data())) as? [String: Any] ?? [:]
        let path = request.url!.path
        if path == "/api/v1/usage/events" {
            if holdUsage { await withCheckedContinuation { usageGate = $0 } }
            if let usageFailure {
                if usageFailure == 0 { throw URLError(.notConnectedToInternet) }
                status = usageFailure
                body = ["error": ["code": usageFailure == 403 ? "usage_sharing_disabled" : "event_conflict",
                                   "message": token + " /private/path must never surface"]]
            } else {
                body = ["eventId": input["eventId"] ?? "", "duplicate": duplicate]
            }
        } else if path == "/api/v1/auth/logout" {
            if logoutFails { throw URLError(.notConnectedToInternet) }
            body = ["ok": true]
        } else if path == "/api/v1/usage/history" {
            body = ["events": [], "nextBefore": NSNull()]
        } else if path == "/api/v1/usage/aggregate" {
            let counts: [String: Any] = ["knownTotal": NSNull(), "knownEvents": 0, "unknownEvents": 1]
            body = ["eventCount": 1, "counts": ["inputTokens": counts, "outputTokens": counts,
                "cachedInputTokens": counts, "reasoningOutputTokens": counts]]
        } else if path == "/api/v1/auth/password", badCurrentPassword {
            status = 401
            body = ["error": ["code": "invalid_credentials", "message": "Never reflect this"]]
        } else if path == "/api/v1/me", let meFailure {
            status = meFailure
            body = ["error": ["code": "expired", "message": token]]
        } else {
            if path == "/api/v1/settings" { sharing = input["usageSharingEnabled"] as? Bool ?? false }
            let account: [String: Any] = ["id": accountID, "handle": "test_handle", "displayName": "Test",
                "bio": "", "profileURL": "https://hostile.invalid/ignore", "usageSharingEnabled": sharing,
                "createdAt": "2026-09-01T00:00:00Z"]
            body = ["account": account]
            if path.hasPrefix("/api/v1/auth/") {
                body["session"] = ["token": token, "expiresAt": "2026-12-01T00:00:00Z"]
                if path != "/api/v1/auth/login" { body["recoveryCode"] = "synthetic-recovery-code" }
            }
        }
        return (try JSONSerialization.data(withJSONObject: body),
                HTTPURLResponse(url: responseURL ?? request.url!, statusCode: status,
                                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!)
    }
}

final class AccountTests: XCTestCase {
    @MainActor private func fixture() throws -> (KilnAccountService, AccountTestHTTP, AccountTestSecrets, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-account-tests-" + UUID().uuidString)
        let file = directory.appendingPathComponent("outbox.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let http = AccountTestHTTP()
        let secrets = AccountTestSecrets()
        let service = try KilnAccountService(testingBaseURL: URL(string: "http://localhost:8765")!,
            transport: http, secrets: secrets, outboxURL: file)
        return (service, http, secrets, file)
    }

    private func event(_ id: String = "00000000-0000-0000-0000-000000000001", input: Int? = 20) -> KilnUsageEvent {
        KilnUsageEvent(eventID: id, provider: "codex", model: "gpt-source-exact", occurredAt: Date(timeIntervalSince1970: 1_789_300_000),
            inputTokens: input, outputTokens: nil, cachedTokens: 0, reasoningTokens: nil,
            sessionID: "opaque-session-000000000001")
    }

    @MainActor private func enable(_ service: KilnAccountService) async throws -> KilnUsageCaptureOwner {
        let signedIn = await service.signIn(handle: "test_handle", password: "test-password-only")
        XCTAssertTrue(signedIn)
        let enabled = await service.setShareUsage(true)
        XCTAssertTrue(enabled)
        return try XCTUnwrap(service.usageCaptureOwner())
    }

    @MainActor func testUnknownCountsAndWireAllowlist() async throws {
        let snapshot = event(input: nil)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: KilnAccountJSON.encoder().encode(snapshot)) as? [String: Any])
        XCTAssertNil(json["inputTokens"])
        XCTAssertNil(json["outputTokens"])
        XCTAssertNil(json["reasoningOutputTokens"])
        XCTAssertEqual(json["cachedInputTokens"] as? Int, 0)
        XCTAssertEqual(json["provider"] as? String, "codex")
        XCTAssertEqual(json["model"] as? String, "gpt-source-exact")
        XCTAssertEqual(json["sessionId"] as? String, "opaque-session-000000000001")
        XCTAssertEqual(Set(json.keys), ["eventId", "sessionId", "provider", "model", "timestamp", "cachedInputTokens"])
        XCTAssertEqual(try KilnAccountJSON.decoder().decode(KilnUsageEvent.self,
            from: KilnAccountJSON.encoder().encode(snapshot)), snapshot)
    }

    @MainActor func testProviderModelAndCountValidation() async throws {
        XCTAssertTrue(event().isValid())
        XCTAssertFalse(event(input: -1).isValid())
        XCTAssertFalse(event(input: 1_000_000_001).isValid())
        for (provider, model) in [("unverified", "gpt"), ("codex", "model\ncontent"), ("codex", String(repeating: "x", count: 97))] {
            XCTAssertFalse(KilnUsageEvent(eventID: event().eventID, provider: provider, model: model,
                occurredAt: .now).isValid())
        }
        XCTAssertFalse(event("/private/transcript/path").isValid())
        XCTAssertFalse(KilnAccount.validHandle("test_handle\n"))
        XCTAssertFalse(KilnUsageEvent(eventID: event().eventID, provider: "codex", model: "model\n", occurredAt: .now).isValid())
        XCTAssertFalse(KilnUsageEvent(eventID: event().eventID, provider: "claude", model: "model", occurredAt: .now).isValid())
    }

    @MainActor func testExplicitConsentRequiredEvenWhenServerEnabled() async throws {
        let (service, http, _, _) = try fixture()
        XCTAssertNil(service.usageCaptureOwner())
        XCTAssertFalse(service.record(event(), owner: nil))
        http.sharing = true
        let signedIn = await service.signIn(handle: "test_handle", password: "test-password-only")
        XCTAssertTrue(signedIn)
        XCTAssertFalse(service.shareUsageEnabled)
        XCTAssertNil(service.usageCaptureOwner())
        XCTAssertFalse(service.record(event(), owner: nil))
        XCTAssertEqual(service.pendingCount, 0)
    }

    @MainActor func testOldTurnCannotUploadAfterConsentOffAndOn() async throws {
        let (service, _, _, _) = try fixture()
        let owner = try await enable(service)
        let disabled = await service.setShareUsage(false)
        XCTAssertTrue(disabled)
        let enabled = await service.setShareUsage(true)
        XCTAssertTrue(enabled)
        XCTAssertNotEqual(owner, service.usageCaptureOwner())
        XCTAssertFalse(service.record(event(), owner: owner))
        XCTAssertTrue(service.record(event(), owner: service.usageCaptureOwner()))
    }

    @MainActor func testLogoutAndAccountSwitchCannotReattributeOldTurnOrReplay() async throws {
        let (service, http, _, _) = try fixture()
        let owner = try await enable(service)
        XCTAssertTrue(service.record(event(), owner: owner))
        await service.signOut()
        XCTAssertEqual(service.pendingCount, 0)
        http.accountID = "B0000000-0000-0000-0000-000000000002"
        let replacement = try await enable(service)
        XCTAssertFalse(service.record(event("00000000-0000-0000-0000-000000000099"), owner: owner))
        XCTAssertFalse(service.record(event(), owner: replacement))
        XCTAssertEqual(service.pendingCount, 0)
    }

    @MainActor func testDurableReplayKeepsPayloadAndConsentAndNeverWritesSecrets() async throws {
        let (service, http, secrets, file) = try fixture()
        let owner = try await enable(service)
        XCTAssertTrue(service.record(event(), owner: owner))
        let original = try Data(contentsOf: file)
        let text = String(decoding: original, as: UTF8.self)
        XCTAssertFalse(text.contains(http.token))
        XCTAssertFalse(text.contains("test-password-only"))
        XCTAssertFalse(text.contains("recoveryCode"))
        XCTAssertFalse(text.contains("displayName"))
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        http.usageFailure = 0
        let restored = try KilnAccountService(testingBaseURL: URL(string: "http://localhost:8765")!, transport: http,
            secrets: secrets, outboxURL: file)
        await restored.start()
        XCTAssertTrue(restored.shareUsageEnabled)
        XCTAssertEqual(restored.usageCaptureOwner(), owner)
        XCTAssertEqual(restored.pendingCount, 1)
        http.usageFailure = nil
        http.duplicate = true
        await restored.flushOutbox()
        XCTAssertEqual(restored.pendingCount, 0)
        let sent = http.requests.filter { $0.url?.path == "/api/v1/usage/events" }
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[0].httpBody, sent[1].httpBody)
        XCTAssertTrue(restored.record(event(), owner: restored.usageCaptureOwner()))
        XCTAssertEqual(restored.pendingCount, 0)
        restored.stop()
    }

    @MainActor func testDuplicateMismatchNeverMutatesOriginal() async throws {
        let (service, _, _, file) = try fixture()
        let owner = try await enable(service)
        XCTAssertTrue(service.record(event(), owner: owner))
        let data = try Data(contentsOf: file)
        XCTAssertFalse(service.record(event(input: 30), owner: owner))
        XCTAssertEqual(try Data(contentsOf: file), data)
        XCTAssertEqual(service.pendingCount, 1)
    }

    @MainActor func testRevocationClearsPendingBeforeNetworkAndPersists() async throws {
        let (service, http, secrets, file) = try fixture()
        let owner = try await enable(service)
        XCTAssertTrue(service.record(event(), owner: owner))
        http.responseURL = URL(string: "https://hostile.invalid/redirect")!
        let disabled = await service.setShareUsage(false)
        XCTAssertFalse(disabled)
        XCTAssertFalse(service.shareUsageEnabled)
        XCTAssertEqual(service.pendingCount, 0)
        XCTAssertFalse(service.record(event(), owner: owner))
        http.responseURL = nil
        http.sharing = true
        let restored = try KilnAccountService(testingBaseURL: URL(string: "http://localhost:8765")!, transport: http,
            secrets: secrets, outboxURL: file)
        await restored.start()
        XCTAssertFalse(restored.shareUsageEnabled)
        XCTAssertEqual(restored.pendingCount, 0)
        restored.stop()
    }

    @MainActor func testLogoutFailureCannotRestoreStaleKeychainSession() async throws {
        let (service, http, secrets, file) = try fixture()
        let owner = try await enable(service)
        XCTAssertTrue(service.record(event(), owner: owner))
        http.logoutFails = true
        secrets.failDelete = true
        await service.signOut()
        XCTAssertNil(service.account)
        XCTAssertNil(service.usageCaptureOwner())
        let restored = try KilnAccountService(testingBaseURL: URL(string: "http://localhost:8765")!, transport: http,
            secrets: secrets, outboxURL: file)
        await restored.start()
        XCTAssertNil(restored.account)
        XCTAssertFalse(restored.shareUsageEnabled)
        XCTAssertEqual(restored.pendingCount, 0)
        restored.stop()
    }

    @MainActor func testKeychainFailureNeverAuthenticates() async throws {
        let (service, _, secrets, _) = try fixture()
        secrets.failSave = true
        let signedIn = await service.signIn(handle: "test_handle", password: "test-password-only")
        XCTAssertFalse(signedIn)
        XCTAssertNil(service.account)
        XCTAssertNil(service.usageCaptureOwner())
    }

    @MainActor func testCrossOriginAndPortAndSchemeRejected() async throws {
        let (service, http, secrets, file) = try fixture()
        http.responseURL = URL(string: "https://hostile.invalid/me")!
        let signedIn = await service.signIn(handle: "test_handle", password: "test-password-only")
        XCTAssertFalse(signedIn)
        XCTAssertNil(secrets.value)
        XCTAssertFalse(KilnAccountService.sameOrigin(URL(string: "https://kiln.raya.ac")!, URL(string: "http://kiln.raya.ac")!))
        XCTAssertFalse(KilnAccountService.sameOrigin(URL(string: "https://kiln.raya.ac:444")!, KilnAccountService.productionURL))
        XCTAssertThrowsError(try KilnAccountService(testingBaseURL: URL(string: "http://kiln.raya.ac")!,
            transport: http, secrets: secrets, outboxURL: file))
        XCTAssertThrowsError(try KilnAccountService(testingBaseURL: URL(string: "https://staging.invalid")!,
            transport: http, secrets: secrets, outboxURL: file))
    }

    @MainActor func testServerRevocationAndExpiryFailClosed() async throws {
        let (service, http, secrets, _) = try fixture()
        let owner = try await enable(service)
        XCTAssertTrue(service.record(event(), owner: owner))
        http.usageFailure = 403
        await service.flushOutbox()
        XCTAssertFalse(service.shareUsageEnabled)
        XCTAssertEqual(service.pendingCount, 0)
        XCTAssertFalse(service.record(event(), owner: owner))
        http.meFailure = 401
        await service.refresh()
        XCTAssertNil(service.account)
        XCTAssertNil(secrets.value)
    }

    @MainActor func testServerErrorsNeverExposeResponseContent() async throws {
        let (service, http, _, _) = try fixture()
        let owner = try await enable(service)
        XCTAssertTrue(service.record(event(), owner: owner))
        http.usageFailure = 409
        await service.flushOutbox()
        XCTAssertEqual(service.pendingCount, 1)
        XCTAssertFalse(service.syncError?.contains(http.token) ?? true)
        XCTAssertFalse(service.syncError?.contains("/private/path") ?? true)
        await service.flushOutbox()
        XCTAssertEqual(http.requests.filter { $0.url?.path == "/api/v1/usage/events" }.count, 1)
    }

    @MainActor func testPrivateProfileAndAggregateAreServerDerived() async throws {
        let (service, _, _, _) = try fixture()
        _ = try await enable(service)
        XCTAssertEqual(service.account?.publicProfileURL?.absoluteString, "https://kiln.raya.ac/u/test_handle")
        await service.refreshHistory()
        XCTAssertEqual(service.aggregate?.eventCount, 1)
        XCTAssertNil(service.aggregate?.counts.inputTokens.knownTotal)
        XCTAssertEqual(service.aggregate?.counts.inputTokens.formattedTotal, "Unknown")
        XCTAssertEqual(service.aggregate?.counts.inputTokens.unknownEvents, 1)
    }

    @MainActor func testRecoveryRotatesCredentialsWithoutPersistingRecoveryCode() async throws {
        let (service, _, secrets, file) = try fixture()
        let recovered = await service.recover(handle: "test_handle", recoveryCode: "test-recovery", newPassword: "test-new-password")
        XCTAssertTrue(recovered)
        XCTAssertNotNil(secrets.value)
        XCTAssertEqual(service.recoveryCodes, ["synthetic-recovery-code"])
        XCTAssertFalse(String(decoding: try Data(contentsOf: file), as: UTF8.self).contains("synthetic-recovery-code"))
        service.dismissRecoveryCodes()
        XCTAssertTrue(service.recoveryCodes.isEmpty)
    }

    @MainActor func testCorruptOutboxIsPreservedAndFailsClosed() async throws {
        let (_, http, secrets, file) = try fixture()
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let damaged = Data("damaged outbox preserve".utf8)
        try damaged.write(to: file)
        let service = try KilnAccountService(testingBaseURL: URL(string: "http://localhost:8765")!, transport: http,
            secrets: secrets, outboxURL: file)
        await service.start()
        let signedIn = await service.signIn(handle: "test_handle", password: "test-password-only")
        XCTAssertFalse(signedIn)
        XCTAssertFalse(service.shareUsageEnabled)
        XCTAssertEqual(try Data(contentsOf: file), damaged)
        XCTAssertNotNil(service.syncError)
        service.stop()
    }

    @MainActor func testInflightReceiptCannotResurrectRevokedOutbox() async throws {
        let (service, http, _, _) = try fixture()
        let owner = try await enable(service)
        XCTAssertTrue(service.record(event(), owner: owner))
        http.holdUsage = true
        let upload = Task { await service.flushOutbox() }
        while http.usageGate == nil { await Task.yield() }
        let disabled = await service.setShareUsage(false)
        XCTAssertTrue(disabled)
        http.usageGate?.resume()
        http.usageGate = nil
        await upload.value
        XCTAssertFalse(service.shareUsageEnabled)
        XCTAssertEqual(service.pendingCount, 0)
        XCTAssertFalse(service.record(event(), owner: owner))
    }

    @MainActor func testWrongCurrentPasswordKeepsExistingSession() async throws {
        let (service, http, secrets, _) = try fixture()
        let owner = try await enable(service)
        let original = secrets.value
        http.badCurrentPassword = true
        let changed = await service.changePassword(currentPassword: "wrong-password", newPassword: "new-password-value")
        XCTAssertFalse(changed)
        XCTAssertEqual(secrets.value, original)
        XCTAssertEqual(service.usageCaptureOwner(), owner)
        XCTAssertNotNil(service.account)
    }

    @MainActor func testRegistrationOmitsBlankOptionalNameAndProfileNeverChangesHandle() async throws {
        let (service, http, _, _) = try fixture()
        let registered = await service.register(handle: "test_handle", password: "test-password-only")
        XCTAssertTrue(registered)
        let registration = try XCTUnwrap(http.requests.first?.httpBody)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: registration) as? [String: Any])
        XCTAssertNil(fields["displayName"])
        let saved = await service.updateProfile(displayName: "Updated", bio: "Public bio",
                                                location: "Berlin", website: "https://example.com")
        XCTAssertTrue(saved)
        let profile = try XCTUnwrap(http.requests.last?.httpBody)
        let profileFields = try XCTUnwrap(JSONSerialization.jsonObject(with: profile) as? [String: Any])
        XCTAssertEqual(Set(profileFields.keys), ["displayName", "bio", "location", "website", "accent"])
        XCTAssertEqual(profileFields["location"] as? String, "Berlin")
        XCTAssertEqual(profileFields["website"] as? String, "https://example.com")
    }

    @MainActor func testAvatarUploadAndClearUseRawImageRequests() async throws {
        let (service, http, _, _) = try fixture()
        _ = await service.register(handle: "test_handle", password: "test-password-only")
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + Array(repeating: 0, count: 32))
        let uploaded = await service.uploadAvatar(png, mediaType: "image/png")
        XCTAssertTrue(uploaded)
        XCTAssertEqual(http.requests.last?.url?.path, "/avatar")
        XCTAssertEqual(http.requests.last?.value(forHTTPHeaderField: "Content-Type"), "image/png")
        let cleared = await service.clearAvatar()
        XCTAssertTrue(cleared)
        XCTAssertEqual(http.requests.last?.url?.path, "/avatar/clear")
        let rejected = await service.uploadAvatar(Data(repeating: 1, count: 600_000), mediaType: "image/png")
        XCTAssertFalse(rejected)
    }

    @MainActor func testPublicUsageToggleSendsSetting() async throws {
        let (service, http, _, _) = try fixture()
        _ = await service.register(handle: "test_handle", password: "test-password-only")
        let enabled = await service.setPublicUsage(true)
        XCTAssertTrue(enabled)
        let body = try XCTUnwrap(http.requests.last?.httpBody)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(fields["publicUsageEnabled"] as? Bool, true)
    }

    @MainActor func testRevocationDiskFailureRemovesCredentialAndStillRevokesServer() async throws {
        let (service, http, secrets, file) = try fixture()
        let owner = try await enable(service)
        XCTAssertTrue(service.record(event(), owner: owner))
        try FileManager.default.removeItem(at: file.deletingLastPathComponent())
        try Data("blocked directory".utf8).write(to: file.deletingLastPathComponent())
        let disabled = await service.setShareUsage(false)
        XCTAssertFalse(disabled)
        XCTAssertNil(secrets.value)
        XCTAssertNil(service.account)
        XCTAssertFalse(service.shareUsageEnabled)
        XCTAssertFalse(http.sharing)
    }

    /// Run only against an explicitly started disposable backend, never a default local service.
    @MainActor func testOptInRealBackendRoundTrip() async throws {
        guard let value = ProcessInfo.processInfo.environment["KILN_ACCOUNT_TEST_BASE"] else {
            throw XCTSkip("Set KILN_ACCOUNT_TEST_BASE to the disposable loopback backend to run this test.")
        }
        let base = try XCTUnwrap(URL(string: value))
        guard base.scheme == "http", ["localhost", "127.0.0.1", "[::1]"].contains(base.host ?? "") else {
            XCTFail("KILN_ACCOUNT_TEST_BASE must be explicit HTTP loopback; production uses a separate opt-in.")
            return
        }
        try await realBackendRoundTrip(base: base)
    }

    /// Creates one clearly named test account on the fixed production origin only with explicit operator opt-in.
    @MainActor func testOptInProductionTLSRoundTrip() async throws {
        guard ProcessInfo.processInfo.environment["KILN_ACCOUNT_TEST_PRODUCTION"] == "1" else {
            throw XCTSkip("Set KILN_ACCOUNT_TEST_PRODUCTION=1 only when production test-account creation is authorized.")
        }
        try await realBackendRoundTrip(base: KilnAccountService.productionURL)
    }

    @MainActor private func realBackendRoundTrip(base: URL) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kiln-real-account-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("outbox.json")
        let secrets = AccountTestSecrets()
        let client = try KilnAccountService(testingBaseURL: base, transport: KilnAccountHTTP(), secrets: secrets, outboxURL: file)
        defer { client.stop() }
        let handle = "native_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12).lowercased()
        let password = UUID().uuidString + "-test"
        let registered = await client.register(handle: handle, password: password, displayName: "Native integration test")
        XCTAssertTrue(registered, client.errorMessage ?? "Registration failed")
        let accountID = try XCTUnwrap(client.account?.id)
        print("KILN_ACCOUNT_TEST_ACCOUNT_ID=\(accountID)")
        let recovery = try XCTUnwrap(client.recoveryCodes.first)
        let originalURL = client.account?.publicProfileURL
        XCTAssertFalse(client.shareUsageEnabled)
        let updated = await client.updateProfile(displayName: "Native integration verified", bio: "Disposable native API acceptance account.")
        XCTAssertTrue(updated, client.errorMessage ?? "Profile update failed")
        XCTAssertEqual(client.account?.publicProfileURL, originalURL)
        let enabled = await client.setShareUsage(true)
        XCTAssertTrue(enabled, client.errorMessage ?? "Consent failed")
        let owner = try XCTUnwrap(client.usageCaptureOwner())
        let snapshot = KilnUsageEvent(eventID: UUID().uuidString, provider: "codex", model: "native-integration-test",
            occurredAt: .now, inputTokens: nil, outputTokens: 7, cachedTokens: 0, reasoningTokens: nil,
            sessionID: UUID().uuidString)
        XCTAssertTrue(client.record(snapshot, owner: owner))
        let beforeAcknowledgment = try Data(contentsOf: file)
        await client.flushOutbox()
        XCTAssertEqual(client.pendingCount, 0, client.syncError ?? "Usage upload failed")
        // Restore the pre-ACK state to simulate a crash after server insert but before local acknowledgment.
        try beforeAcknowledgment.write(to: file, options: .atomic)
        let replay = try KilnAccountService(testingBaseURL: base, transport: KilnAccountHTTP(), secrets: secrets, outboxURL: file)
        defer { replay.stop() }
        await replay.start()
        XCTAssertEqual(replay.pendingCount, 0, replay.syncError ?? "Idempotent replay failed")
        await replay.refreshHistory()
        XCTAssertEqual(replay.history.count, 1)
        XCTAssertEqual(replay.aggregate?.eventCount, 1)
        XCTAssertNil(replay.aggregate?.counts.inputTokens.knownTotal)
        XCTAssertEqual(replay.aggregate?.counts.inputTokens.unknownEvents, 1)
        XCTAssertEqual(replay.aggregate?.counts.outputTokens.knownTotal, 7)
        XCTAssertEqual(replay.aggregate?.counts.cachedInputTokens.knownTotal, 0)
        XCTAssertNil(replay.aggregate?.counts.reasoningOutputTokens.knownTotal)
        let revoked = await replay.setShareUsage(false)
        XCTAssertTrue(revoked)
        XCTAssertFalse(replay.record(snapshot, owner: owner))
        await replay.signOut()
        XCTAssertNil(secrets.value)
        let replacement = UUID().uuidString + "-replacement"
        let recovered = await replay.recover(handle: handle, recoveryCode: recovery, newPassword: replacement)
        XCTAssertTrue(recovered, replay.errorMessage ?? "Recovery failed")
        XCTAssertEqual(replay.account?.id, accountID)
        XCTAssertNotEqual(replay.recoveryCodes.first, recovery)
        XCTAssertFalse(replay.shareUsageEnabled)
        let finalPassword = UUID().uuidString + "-final"
        let changed = await replay.changePassword(currentPassword: replacement, newPassword: finalPassword)
        XCTAssertTrue(changed, replay.errorMessage ?? "Password change failed")
        await replay.signOut()
        let signedIn = await replay.signIn(handle: handle, password: finalPassword)
        XCTAssertTrue(signedIn, replay.errorMessage ?? "Sign-in failed")
        XCTAssertEqual(replay.account?.id, accountID)
        await replay.refreshHistory()
        XCTAssertEqual(replay.aggregate?.eventCount, 1)
        await replay.signOut()
        XCTAssertNil(replay.account)
        XCTAssertNil(secrets.value)
    }
}
