import Foundation
import XCTest
@testable import Kiln

private final class WardenCancellationTask: URLSessionTask, @unchecked Sendable {
    let cancellationEntered = DispatchSemaphore(value: 0)
    let releaseCancellation = DispatchSemaphore(value: 0)
    override func resume() {}
    override func cancel() {
        cancellationEntered.signal()
        releaseCancellation.wait()
    }
}

private actor WardenTestConnection: WardenTunnelConnection {
    private let started: XCTestExpectation?
    private var callback: (@Sendable @MainActor (TunnelEvent) -> Void)?
    private var lifetime: TunnelLifetime?

    init(started: XCTestExpectation? = nil) { self.started = started }

    func start(_ config: TunnelConfig, onEvent: @escaping @Sendable @MainActor (TunnelEvent) -> Void) async {
        callback = onEvent
        lifetime = config.lifetime
        started?.fulfill()
    }

    func stop() async {}
    func emit(_ event: TunnelEvent) async { await callback?(event) }
    func lifetimeIsActive() -> Bool { lifetime?.isActive == true }
}

final class WardenLifecycleTests: XCTestCase {
    func testEveryRevokerWaitsUntilCancellationIsIssued() async throws {
        let lifetime = TunnelLifetime()
        let request = WardenCancellationTask()
        XCTAssertTrue(lifetime.resumeIfActive(request))
        let first = Task.detached { lifetime.revoke() }
        XCTAssertEqual(request.cancellationEntered.wait(timeout: .now() + 2), .success)
        let secondEntered = DispatchSemaphore(value: 0)
        let secondReturned = DispatchSemaphore(value: 0)
        let second = Task.detached {
            secondEntered.signal()
            lifetime.revoke()
            secondReturned.signal()
        }
        XCTAssertEqual(secondEntered.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(secondReturned.wait(timeout: .now() + 0.1), .timedOut)
        request.releaseCancellation.signal()
        await first.value
        await second.value
        XCTAssertEqual(secondReturned.wait(timeout: .now() + 2), .success)
        XCTAssertFalse(lifetime.isActive)
    }

    func testRevokedLifetimeRejectsNewTasksWithoutNetworkAccess() async throws {
        let lifetime = TunnelLifetime()
        XCTAssertTrue(lifetime.isActive)
        lifetime.revoke()
        XCTAssertFalse(lifetime.isActive)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let request = URLRequest(url: URL(string: "http://127.0.0.1:1/fixture")!)
        let task = session.dataTask(with: request)
        XCTAssertFalse(lifetime.resumeIfActive(task))
        do {
            _ = try await lifetime.data(for: request, session: session)
            XCTFail("revoked request must fail before creating a task")
        } catch is CancellationError {}
    }

    @MainActor func testReplacementRejectsOldCallbacksAndCancelledReconnect() async throws {
        let oldStarted = expectation(description: "old client started")
        let newStarted = expectation(description: "replacement started")
        let old = WardenTestConnection(started: oldStarted)
        let replacement = WardenTestConnection(started: newStarted)
        var creations = 0
        var config = WardenConfig()
        config.bearerToken = "fixture-only"
        let service = WardenTunnelService(testingConfig: config, makeClient: {
            creations += 1
            return creations == 1 ? old : replacement
        }, claimRequest: { _ in throw URLError(.unsupportedURL) })
        defer { service.stopAll() }
        service.start(owner: .kilnSelf, target: "127.0.0.1:18001", sub: "fixture")
        await fulfillment(of: [oldStarted], timeout: 2)
        await old.emit(.closed(reason: "fixture disconnect"))
        await Task.yield()
        service.start(owner: .kilnSelf, target: "127.0.0.1:18002", sub: "fixture")
        await fulfillment(of: [newStarted], timeout: 2)
        let oldActive = await old.lifetimeIsActive()
        let newActive = await replacement.lifetimeIsActive()
        XCTAssertFalse(oldActive)
        XCTAssertTrue(newActive)
        await replacement.emit(.ready(url: "https://fixture.invalid/new"))
        await old.emit(.ready(url: "https://fixture.invalid/old"))
        await old.emit(.closed(reason: "late close"))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(creations, 2)
        XCTAssertEqual(service.tunnels["self"]?.target, "127.0.0.1:18002")
        XCTAssertEqual(service.tunnels["self"]?.status, .ready(url: "https://fixture.invalid/new"))
        XCTAssertTrue(service.isActive(owner: .kilnSelf))
    }

    @MainActor func testClaimForSupersededConfigurationIsDiscarded() async throws {
        let requested = expectation(description: "claim requested")
        var continuation: CheckedContinuation<(Data, URLResponse), Error>?
        var callbacks = 0
        let service = WardenTunnelService(testingConfig: WardenConfig(), makeClient: {
            XCTFail("claim must not open a tunnel by itself")
            return WardenTestConnection()
        }, claimRequest: { _ in
            try await withCheckedThrowingContinuation {
                continuation = $0
                requested.fulfill()
            }
        })
        service.onConfigurationReady = { callbacks += 1 }
        let claim = Task { await service.claimIfNeeded(sub: "fixture") }
        await fulfillment(of: [requested], timeout: 2)
        service.config.server = "replacement.invalid"
        let body = try JSONSerialization.data(withJSONObject: ["token": "fixture-only", "sub": "fixture"])
        let response = HTTPURLResponse(url: URL(string: "https://fixture.invalid/claim")!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
        continuation?.resume(returning: (body, response))
        await claim.value
        XCTAssertTrue(service.config.bearerToken.isEmpty)
        XCTAssertEqual(service.config.server, "replacement.invalid")
        XCTAssertEqual(callbacks, 0)
        XCTAssertFalse(service.claimInFlight)
    }

    @MainActor func testAutomaticRetryPreservesBackoffUntilReadiness() async throws {
        let firstStarted = expectation(description: "first client started")
        let retryStarted = expectation(description: "automatic retry started")
        let first = WardenTestConnection(started: firstStarted)
        let retry = WardenTestConnection(started: retryStarted)
        var creations = 0
        var config = WardenConfig()
        config.bearerToken = "fixture-only"
        let service = WardenTunnelService(testingConfig: config, makeClient: {
            creations += 1
            return creations == 1 ? first : retry
        }, claimRequest: { _ in throw URLError(.unsupportedURL) })
        defer { service.stopAll() }
        service.start(owner: .kilnSelf, target: "127.0.0.1:18001", sub: "fixture")
        await fulfillment(of: [firstStarted], timeout: 2)
        await first.emit(.closed(reason: "first failure"))
        XCTAssertEqual(service.tunnels["self"]?.recent.last?.line, "reconnecting in 1.0s")
        await fulfillment(of: [retryStarted], timeout: 3)
        await retry.emit(.closed(reason: "second failure"))
        XCTAssertEqual(service.tunnels["self"]?.recent.last?.line, "reconnecting in 2.0s")
        await retry.emit(.ready(url: "https://fixture.invalid/new"))
        await retry.emit(.closed(reason: "new outage"))
        XCTAssertEqual(service.tunnels["self"]?.recent.last?.line, "reconnecting in 1.0s")
    }

    @MainActor func testCurrentClaimReconcilesStoredPreferenceAfterSaving() async throws {
        let body = try JSONSerialization.data(withJSONObject: ["token": "fixture-only", "sub": "fixture"])
        let response = HTTPURLResponse(url: URL(string: "https://fixture.invalid/claim")!, statusCode: 200,
                                       httpVersion: nil, headerFields: nil)!
        let service = WardenTunnelService(testingConfig: WardenConfig(), makeClient: { WardenTestConnection() },
                                         claimRequest: { _ in (body, response) })
        var ready = false
        service.onConfigurationReady = {
            XCTAssertEqual(service.config.bearerToken, "fixture-only")
            XCTAssertEqual(service.config.claimedSub, "fixture")
            ready = true
        }
        await service.claimIfNeeded(sub: "fixture")
        XCTAssertTrue(ready)
    }
}
