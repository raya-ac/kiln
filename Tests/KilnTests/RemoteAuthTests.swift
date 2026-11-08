import XCTest
import Security
@testable import Kiln

final class RemoteAuthTests: XCTestCase {
    func testLegacyTokenLookupDistinguishesAbsentAndInvalid() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertNil(try RemoteTokenStore.legacyToken(at: directory.appendingPathComponent("missing")))
        XCTAssertThrowsError(try RemoteTokenStore.legacyToken(at: directory))
        let file = directory.appendingPathComponent("legacy")
        try Data().write(to: file)
        XCTAssertThrowsError(try RemoteTokenStore.legacyToken(at: file))
        try Data("fixture-token\n".utf8).write(to: file)
        XCTAssertEqual(try RemoteTokenStore.legacyToken(at: file), "fixture-token")
    }

    func testCredentialVaultKeepsFailureAndSuccessDistinct() async {
        let rejected = RemoteCredentialVault(restore: { _ in "previous" }, replace: { _ in false })
        let rejectedResult = await rejected.replace("replacement")
        XCTAssertFalse(rejectedResult)
        let original = await rejected.restore(allowInteraction: false)
        XCTAssertEqual(original, "previous")
        let accepted = RemoteCredentialVault(restore: { _ in "fixture" }, replace: { _ in true })
        let empty = await accepted.replace("")
        XCTAssertFalse(empty)
        let saved = await accepted.replace("replacement")
        XCTAssertTrue(saved)
    }

    func testKeychainDenialMustNotRotateTheSavedToken() {
        XCTAssertTrue(RemoteTokenStore.mayCreate(after: errSecItemNotFound))
        for status in [errSecInteractionNotAllowed, errSecAuthFailed, errSecNotAvailable, errSecSuccess] {
            XCTAssertFalse(RemoteTokenStore.mayCreate(after: status))
        }
    }
    private func context(
        method: String = "GET",
        path: String = "/api/state",
        authorization: String? = nil,
        peerIsLoopback: Bool = true,
        accessLevel: RemoteAccessLevel = .loopback,
        tunnelExposed: Bool = false,
        token: String = "secret"
    ) -> RemoteAuth.Context {
        RemoteAuth.Context(method: method, path: path, authorization: authorization,
                           peerIsLoopback: peerIsLoopback, accessLevel: accessLevel,
                           tunnelExposed: tunnelExposed, token: token)
    }

    func testQueryTokenIsNotACredential() {
        XCTAssertEqual(RemoteAuth.bearerToken(from: nil), "")
        XCTAssertEqual(RemoteAuth.bearerToken(from: "Token secret"), "")
        XCTAssertEqual(RemoteAuth.bearerToken(from: "Bearer secret"), "secret")
        XCTAssertEqual(RemoteAuth.bearerToken(from: "bearer secret"), "secret")
        XCTAssertEqual(RemoteAuth.decision(context(authorization: nil)), .unauthorized)
    }

    func testOffLoopbackRequiresBearerEvenWhenTokenWasOptional() {
        let open = context(peerIsLoopback: false, token: "")
        XCTAssertEqual(RemoteAuth.decision(open), .unauthorized)
        XCTAssertTrue(RemoteAuth.leavesMachine(open))
        XCTAssertEqual(RemoteAuth.decision(context(authorization: "Bearer secret", peerIsLoopback: false)), .allow)
        XCTAssertEqual(RemoteAuth.decision(context(authorization: "Bearer wrong", peerIsLoopback: false)), .unauthorized)
    }

    func testTunnelAndLANCountAsOffMachineEvenFromLoopback() {
        XCTAssertEqual(RemoteAuth.decision(context(tunnelExposed: true)), .unauthorized)
        XCTAssertEqual(RemoteAuth.decision(context(accessLevel: .lan)), .unauthorized)
        XCTAssertEqual(RemoteAuth.decision(context(authorization: "Bearer secret", accessLevel: .tailscale)), .allow)
    }

    func testLoopbackShellLoadsAndAPIStaysLocked() {
        XCTAssertEqual(RemoteAuth.decision(context(method: "GET", path: "/", peerIsLoopback: false)), .allow)
        XCTAssertEqual(RemoteAuth.decision(context(token: "")), .unauthorized)
        XCTAssertEqual(RemoteAuth.decision(context()), .unauthorized)
        XCTAssertEqual(RemoteAuth.decision(context(method: "POST", path: "/api/interrupt", token: "")), .unauthorized)
        XCTAssertEqual(RemoteAuth.decision(context(method: "POST", path: "/api/interrupt", authorization: "Bearer secret")), .allow)
    }

    func testLargeBodyCanBeAuthenticatedFromHeadersBeforeRetention() throws {
        let packet = Data("POST /api/attach/upload HTTP/1.1\r\nContent-Length: 40000000\r\nAuthorization: Bearer wrong\r\n\r\n".utf8)
        XCTAssertNil(HTTPRequest.parse(packet))
        let headers = try XCTUnwrap(HTTPRequest.parse(packet, headersOnly: true))
        XCTAssertTrue(headers.body.isEmpty)
        XCTAssertEqual(RemoteAuth.decision(context(method: headers.method, path: headers.path,
                                                  authorization: headers.headers["authorization"], accessLevel: .lan)), .unauthorized)
        XCTAssertEqual(RemoteLimits.ingressStatus(buffer: Data("GET / HTTP/1.1\r\nContent-Length: 40000000\r\n\r\n".utf8)), 400)
        XCTAssertEqual(RemoteLimits.ingressStatus(buffer: Data("gEt / HTTP/1.1\r\nContent-Length: 40000000\r\n\r\n".utf8)), 400)
    }

    func testHeaderAndBodyCapsFailClosed() {
        let slow = Data(repeating: 0x41, count: RemoteLimits.maxHeaderBytes + 1)
        XCTAssertEqual(RemoteLimits.ingressStatus(buffer: slow), 431)

        var headers = Data("POST /api/attach/upload HTTP/1.1\r\nContent-Length: 999999999\r\n\r\n".utf8)
        XCTAssertEqual(RemoteLimits.ingressStatus(buffer: headers, maxBodyBytes: 1024), 413)
        headers = Data("POST /api/send HTTP/1.1\r\nContent-Length: nope\r\n\r\n".utf8)
        XCTAssertEqual(RemoteLimits.ingressStatus(buffer: headers), 400)
        headers = Data("GET /api/state HTTP/1.1\r\nContent-Length: 0\r\n\r\n".utf8)
        XCTAssertNil(RemoteLimits.ingressStatus(buffer: headers))
    }

    func testBinaryBodyIsCompleteAndIngressNeverAccumulatesBeyondItsBudget() throws {
        var packet = Data("POST /api/send HTTP/1.1\r\nContent-Length: 1\r\n\r\n".utf8)
        packet.append(0xff)
        XCTAssertNil(RemoteLimits.ingressStatus(buffer: packet))
        XCTAssertEqual(try XCTUnwrap(HTTPRequest.parse(packet)).body, Data([0xff]))
        packet.append(0xff)
        XCTAssertEqual(RemoteLimits.ingressStatus(buffer: packet), 400)
        XCTAssertEqual(RemoteLimits.ingressStatus(buffer: Data(repeating: 0xff, count: 17), maxHeaderBytes: 8, maxBodyBytes: 8), 413)
        let duplicate = Data("POST /api/send HTTP/1.1\r\nContent-Length: 0\r\nContent-Length: 1\r\n\r\n".utf8)
        XCTAssertEqual(RemoteLimits.ingressStatus(buffer: duplicate), 400)
    }
}
