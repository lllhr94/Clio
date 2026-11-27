import AgentKit
@testable import Clio
import Craft
import Foundation
import XCTest

final class ClioAppPR2CTests: XCTestCase {
    private struct Tokens: Codable, Equatable, Sendable {
        let access: String
        let refresh: String

        init(_ name: String) {
            access = "access-\(name)"
            refresh = "refresh-\(name)"
        }
    }

    private typealias Store = VaultRotationStore<Tokens>

    private final class DiskFixture {
        enum Failure: Error { case write }
        var keychain: [String: Data] = [:]
        var files: [String: Data] = [:]
        var failPrimary = false
        var failIntent = false
        var failStaging = false
        var failRemoval = false
        var useFallback = false
        var writes: [String] = []

        func store() -> Store {
            Store(credentialID: "fixture", backing: .init(
                keychain: { self.keychain[$0] },
                protected: { self.files[$0] },
                writePrimary: { data, key in
                    self.writes.append("primary")
                    if self.failPrimary { throw Failure.write }
                    if self.useFallback {
                        self.files[key] = data
                    } else {
                        self.keychain[key] = data
                        self.files[key] = nil
                    }
                },
                writeProtected: { data, key in
                    let staging = key.hasPrefix("pending_rotation.")
                    self.writes.append(staging ? "stage" : "intent")
                    if staging ? self.failStaging : self.failIntent { throw Failure.write }
                    self.files[key] = data
                },
                removeProtected: { self.files[$0] = nil; return true },
                removePrimary: {
                    guard !self.failRemoval else { return false }
                    self.keychain[$0] = nil
                    self.files[$0] = nil
                    return true
                }
            ))
        }

        func record(_ seq: UInt64, _ name: String, id: String = "fixture") throws -> Data {
            try JSONEncoder().encode(Store.Credential(rotationSeq: seq, credentialID: id, payload: Tokens(name), updatedAt: Date()))
        }
    }

    func testSecretsAreExtractedFromAllVaultEncodings() throws {
        let encoder = JSONEncoder()
        let raw = Data(#"{"access":"access-test","payload":{"refresh_token":"refresh-test","inner":{"client_secret":"client-test"}},"name":"public-label"}"#.utf8)
        let wanted: Set<String> = ["access-test", "refresh-test", "client-test"]
        XCTAssertEqual(Set(Vault.extractSecrets(from: raw)), wanted)
        XCTAssertEqual(Set(Vault.extractSecrets(from: try encoder.encode(raw))), wanted)

        let key = Data((0..<32).map { UInt8(255 - $0) })
        XCTAssertEqual(Vault.extractSecrets(from: try encoder.encode(key)), [key.base64EncodedString()])
        XCTAssertEqual(Vault.extractSecrets(from: try encoder.encode("plain-api-key!")), ["plain-api-key!"])
        XCTAssertEqual(Set(Vault.extractSecrets(from: try encoder.encode("YXBp"))), ["YXBp", "api"])
    }

    func testPreflightMustWriteIntentAndColdStartCannotReuseOldRefresh() throws {
        let disk = DiskFixture()
        let store = disk.store()
        try store.replace(Tokens("old"))
        guard case .current(let old) = store.load() else { return XCTFail("Missing primary") }
        disk.failIntent = true
        XCTAssertThrowsError(try store.begin(old))
        XCTAssertEqual(store.load(), .current(old))

        disk.failIntent = false
        try store.begin(old)
        XCTAssertEqual(disk.store().load(), .reauthRequired)
        XCTAssertEqual(disk.store().load(legacy: { Tokens("legacy") }), .reauthRequired)
        try store.replace(Tokens("signed-in-again"))
        guard case .current(let current) = store.load() else { return XCTFail("Missing new sign-in") }
        XCTAssertGreaterThan(current.rotationSeq, old.rotationSeq)
        XCTAssertEqual(current.payload, Tokens("signed-in-again"))
    }

    func testRotationWriteOrderAndStageOnlyRecovery() throws {
        let disk = DiskFixture()
        let store = disk.store()
        try store.replace(Tokens("old"))
        guard case .current(let old) = store.load() else { return XCTFail("Missing primary") }
        disk.writes.removeAll()
        try store.begin(old)
        disk.failPrimary = true
        let newer = try store.finish(Tokens("new"), replacing: old)
        XCTAssertEqual(disk.writes, ["intent", "stage", "primary"])
        XCTAssertNotNil(disk.files[store.intentKey])
        XCTAssertNotNil(disk.files[store.pendingKey])
        XCTAssertEqual(disk.store().load(), .recovered(newer))
        XCTAssertThrowsError(try store.begin(newer))

        disk.failPrimary = false
        XCTAssertEqual(disk.store().load(), .recovered(newer))
        XCTAssertNil(disk.files[store.intentKey])
        XCTAssertNil(disk.files[store.pendingKey])
        XCTAssertEqual(disk.store().load(), .current(newer))
    }

    func testPrimaryOnlyFallbackAndTotalWriteFailure() throws {
        let disk = DiskFixture()
        let store = disk.store()
        try store.replace(Tokens("old"))
        guard case .current(let old) = store.load() else { return XCTFail("Missing primary") }
        try store.begin(old)
        disk.failStaging = true
        disk.useFallback = true
        let newer = try store.finish(Tokens("new"), replacing: old)
        XCTAssertNotNil(disk.keychain[store.credentialID])
        XCTAssertNotNil(disk.files[store.credentialID])
        XCTAssertEqual(store.load(), .current(newer))
        XCTAssertNil(disk.files[store.pendingKey])
        XCTAssertNil(disk.files[store.intentKey])

        try store.begin(newer)
        disk.failPrimary = true
        XCTAssertThrowsError(try store.finish(Tokens("lost"), replacing: newer)) {
            guard let error = $0 as? Store.StorageError, case .reauthRequired = error else {
                return XCTFail("Expected reauthorization")
            }
        }
        XCTAssertEqual(disk.store().load(), .reauthRequired)
    }

    func testColdStartConsidersAllCopiesAndIgnoresWrongCredentialID() throws {
        for (keychain, fallback, staging, wanted) in [(8, 6, 5, 8), (5, 8, 6, 8), (5, 6, 8, 8)] {
            let disk = DiskFixture()
            let store = disk.store()
            disk.keychain[store.credentialID] = try disk.record(4, "old")
            guard case .current(let old) = store.load() else { return XCTFail("Missing primary") }
            try store.begin(old)
            disk.keychain[store.credentialID] = try disk.record(UInt64(keychain), "chain")
            disk.files[store.credentialID] = try disk.record(UInt64(fallback), "file")
            disk.files[store.pendingKey] = try disk.record(UInt64(staging), "stage")
            guard case .recovered(let credential) = disk.store().load() else { return XCTFail("Did not recover") }
            XCTAssertEqual(credential.rotationSeq, UInt64(wanted))
            XCTAssertEqual(store.load(), .current(credential))
        }

        let disk = DiskFixture()
        let store = disk.store()
        try store.replace(Tokens("old"))
        guard case .current(let old) = store.load() else { return XCTFail("Missing primary") }
        try store.begin(old)
        disk.files[store.pendingKey] = try disk.record(99, "wrong", id: "another-account")
        XCTAssertEqual(store.load(), .reauthRequired)
    }

    func testTransientRefreshAbandonsIntentWithoutLosingSession() throws {
        let store = DiskFixture().store()
        try store.replace(Tokens("old"))
        guard case .current(let old) = store.load() else { return XCTFail("Missing primary") }
        try store.begin(old)
        store.abandonRetryableRefresh()
        XCTAssertEqual(store.load(), .current(old))
        try store.begin(old)
        let next = try store.finish(Tokens("rotated"), replacing: old)
        XCTAssertEqual(next.rotationSeq, old.rotationSeq + 1)
    }

    func testSignOutMarkerPreventsRecoveryWhenKeychainDeletionFails() throws {
        let disk = DiskFixture()
        let store = disk.store()
        try store.replace(Tokens("old"))
        disk.failRemoval = true
        store.remove()
        XCTAssertNotNil(disk.keychain[store.credentialID])
        XCTAssertEqual(disk.store().load(legacy: { Tokens("legacy") }), .missing)
        try store.replace(Tokens("new"))
        guard case .current(let current) = store.load() else { return XCTFail("Missing new sign-in") }
        XCTAssertEqual(current.payload, Tokens("new"))
    }

    func testAuthorizationAndTokenFormUseSameResource() throws {
        let endpoint = URL(string: "https://auth.example.com/authorize?scope=all&resource=wrong&extra=kept")!
        let redirect = URL(string: "http://127.0.0.1:49152/callback")!
        let resource = "https://mcp.example.com/tenant"
        let url = try MCPAuth.authorizationURL(endpoint: endpoint, client: "client", redirect: redirect,
                                               resource: resource, scope: nil, state: "state", verifier: "verifier")
        let fields = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(fields.filter { $0.name == "resource" }.map(\.value), [resource])
        XCTAssertEqual(fields.first { $0.name == "code_challenge_method" }?.value, "S256")
        XCTAssertEqual(fields.first { $0.name == "extra" }?.value, "kept")
        XCTAssertFalse(fields.contains { $0.name == "scope" })
        let body = MCPAuth.tokenForm(["grant_type": "refresh_token", "refresh_token": "x&=+"], resource: resource)
        XCTAssertEqual(String(decoding: body, as: UTF8.self),
                       "grant_type=refresh_token&refresh_token=x%26%3D%2B&resource=https%3A%2F%2Fmcp.example.com%2Ftenant")
        let exchange = MCPAuth.tokenForm(["grant_type": "authorization_code", "code_verifier": "abc"], resource: resource)
        XCTAssertEqual(String(decoding: exchange, as: UTF8.self),
                       "code_verifier=abc&grant_type=authorization_code&resource=https%3A%2F%2Fmcp.example.com%2Ftenant")
    }

    func testCallbackChecksRegisteredOriginPathAndUniqueStateBeforeOAuthError() throws {
        let redirect = URL(string: "http://127.0.0.1:49152/callback")!
        XCTAssertEqual(try MCPAuth.callbackCode(URL(string: redirect.absoluteString + "?state=s&code=ok")!,
                                                redirect: redirect, state: "s"), "ok")
        // Reverse iOS OAuth scheme comparison must be case-insensitive (Google Client IDs may carry uppercase letters).
        let mixedRedirect = URL(string: "com.googleusercontent.apps.123-ABC:/oauth2redirect")!
        let lowerCallback = URL(string: "com.googleusercontent.apps.123-abc:/oauth2redirect?state=s&code=ok")!
        XCTAssertEqual(try MCPAuth.callbackCode(lowerCallback, redirect: mixedRedirect, state: "s"), "ok")
        for raw in [
            "http://127.0.0.1:49153/callback?state=s&code=ok",
            "http://127.0.0.1:49152/other?state=s&code=ok",
            "http://127.0.0.1:49152/callback?state=s&state=s&code=ok",
            "http://127.0.0.1:49152/callback?state=wrong&error=untrusted_payload",
        ] {
            XCTAssertThrowsError(try MCPAuth.callbackCode(URL(string: raw)!, redirect: redirect, state: "s")) {
                XCTAssertFalse($0.localizedDescription.contains("untrusted_payload"))
            }
        }
        XCTAssertThrowsError(try MCPAuth.configuredRedirect("https://example.com/callback"))
    }

    @MainActor
    func testConnectorOnlyProbesUnauthorizedOrExpiredCredentials() async {
        XCTAssertTrue(Connecting.needsOAuthProbe(MCPClient.MCPError.http(401, "").localizedDescription))
        XCTAssertTrue(Connecting.needsOAuthProbe(MCPAuth.LoginError.reauthRequired.localizedDescription))
        for code in [403, 429, 500, 502] {
            XCTAssertFalse(Connecting.needsOAuthProbe(MCPClient.MCPError.http(code, "401").localizedDescription))
        }
        XCTAssertFalse(Connecting.needsOAuthProbe(URLError(.dnsLookupFailed).localizedDescription))
        XCTAssertFalse(Connecting.needsOAuthProbe(URLError(.timedOut).localizedDescription))
    }

    func testOAuthHTTPErrorKeepsStatusAndRemovesUntrustedResponseBody() throws {
        let response = try XCTUnwrap(HTTPURLResponse(url: URL(string: "https://auth.example.com/token")!,
                                                     statusCode: 502, httpVersion: nil, headerFields: nil))
        let error = OAuthHTTPError(response: response, data: Data("<html>token=secret-value</html>".utf8))
        XCTAssertEqual(error.kind, .transient)
        XCTAssertTrue(error.localizedDescription.contains("502"))
        XCTAssertFalse(error.localizedDescription.contains("secret-value"))
    }
}
