@testable import Clio
import Foundation
import XCTest

final class ClioAppPR2DTests: XCTestCase {
    func testServiceExtrasUseSharedPersistenceKeys() throws {
        try withDefaults { defaults in
            XCTAssertFalse(ServiceExtras.isPaused("a", defaults: defaults))
            ServiceExtras.setPaused(true, for: "a", defaults: defaults)
            XCTAssertTrue(defaults.bool(forKey: "clio.endpoint.paused.a"))
            XCTAssertTrue(ServiceExtras.isPaused("a", defaults: defaults))
            XCTAssertFalse(ServiceExtras.isPaused("b", defaults: defaults))
            ServiceExtras.setPaused(false, for: "a", defaults: defaults)
            XCTAssertFalse(ServiceExtras.isPaused("a", defaults: defaults))

            XCTAssertEqual(ServiceCacheTier.allCases.map(\.rawValue), ["off", "5m", "1h"])
            XCTAssertEqual(ServiceExtras.cacheTier("a", defaults: defaults), .off)
            XCTAssertEqual(ServiceExtras.cacheTier("a", fallback: .fiveMinutes, defaults: defaults), .fiveMinutes)
            for tier in ServiceCacheTier.allCases {
                ServiceExtras.setCacheTier(tier, for: "a", defaults: defaults)
                XCTAssertEqual(ServiceExtras.cacheTier("a", defaults: defaults), tier)
                XCTAssertEqual(defaults.string(forKey: "clio.endpoint.cacheTier.a"), tier.rawValue)
            }
        }
    }

    func testNonSecretHeadersAreSanitizedOnReadAndWrite() throws {
        try withDefaults { defaults in
            let allowed = ["HTTP-Referer": "https://example.com", "X-Title": "Clio", "X-Custom-Tag": "test"]
            let denied = [
                "Authorization", "proxy-authorization", "x-api-key", "api-key", "Cookie", "Set-Cookie",
                "x-auth-token", "X-Secret-Token", "X-Plain-Key", "X-Password", "x-credential-label",
                " X-Title", "X-Title\nOther", "Host",
            ]
            var unsafe = allowed
            for name in denied { unsafe[name] = "fixture" }
            unsafe["X-Custom-Line"] = "one\r\ntwo"
            unsafe["X-Custom-Auth"] = "Bearer example"
            ServiceExtras.setCustomHeaders(unsafe, for: "a", defaults: defaults)

            let key = "clio.endpoint.customHeaders.a"
            let stored = try XCTUnwrap(defaults.data(forKey: key))
            XCTAssertEqual(try JSONDecoder().decode([String: String].self, from: stored), allowed)
            defaults.set(try JSONEncoder().encode(unsafe), forKey: key)
            XCTAssertEqual(ServiceExtras.customHeaders("a", defaults: defaults), allowed)
        }
    }

    @MainActor
    func testRecentModelsOnlyReturnsUniqueActiveRefs() throws {
        try withDefaults { defaults in
            for ref in ["a/old", "a/first", "b/company/second", "a/third", "a/first"] {
                RecentModelsStore.record(ref, defaults: defaults)
            }
            let key = "clio.models.recent"
            let data = try XCTUnwrap(defaults.data(forKey: key))
            XCTAssertEqual(try JSONDecoder().decode([String].self, from: data), ["a/first", "a/third", "b/company/second"])

            let a = Endpoint(id: "a", name: "A", kind: .openai, baseURL: "https://example.com", models: ["first"])
            let b = Endpoint(id: "b", name: "B", kind: .openai, baseURL: "https://example.com", models: ["company/second"])
            XCTAssertEqual(RecentModelsStore.recent(in: [a, b], defaults: defaults), ["a/first", "b/company/second"])
            XCTAssertEqual(RecentModelsStore.recent(in: [b], defaults: defaults), ["b/company/second"])
            ServiceExtras.setPaused(true, for: "b", defaults: defaults)
            XCTAssertEqual(RecentModelsStore.recent(in: [a, b], defaults: defaults), ["a/first"])
            XCTAssertEqual(ModelChoices.selectableEndpoints(in: [a, b], defaults: defaults).map(\.id), ["a"])
        }
    }

    func testOpenRouterPKCEAndLoopbackCallback() throws {
        let verifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
        let attempt = OpenRouterKeyOAuth.Attempt(verifier: verifier, state: "fixture")
        let ports: [UInt16] = [41729, 56813]
        for port in ports {
            let url = try XCTUnwrap(OpenRouterKeyOAuth.authorizationURL(port: port, attempt: attempt))
            let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
            let query = Dictionary(uniqueKeysWithValues: try XCTUnwrap(parts.queryItems).map { ($0.name, $0.value ?? "") })
            XCTAssertEqual(parts.scheme, "https")
            XCTAssertEqual(parts.host, "openrouter.ai")
            XCTAssertEqual(parts.path, "/auth")
            XCTAssertEqual(query["callback_url"], "http://127.0.0.1:\(port)/callback")
            XCTAssertEqual(query["state"], "fixture")
            XCTAssertEqual(query["code_challenge_method"], "S256")
            XCTAssertEqual(query["code_challenge"], "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
            XCTAssertFalse(url.absoluteString.contains("localhost:3000"))
        }
        let valid = "http://127.0.0.1:41729/callback?state=fixture&code=auth-code"
        XCTAssertEqual(OpenRouterKeyOAuth.callbackCode(try XCTUnwrap(URL(string: valid)), port: 41729, state: "fixture"), "auth-code")
        for wrong in [
            valid + "&code=duplicate", valid + "&state=fixture", valid + "#fragment",
            valid.replacingOccurrences(of: "127.0.0.1", with: "192.168.1.3"),
            valid.replacingOccurrences(of: "fixture", with: "wrong"),
        ] {
            XCTAssertNil(OpenRouterKeyOAuth.callbackCode(try XCTUnwrap(URL(string: wrong)), port: 41729, state: "fixture"))
        }
        XCTAssertNil(OpenRouterKeyOAuth.authorizationURL(port: 0, attempt: attempt))
        XCTAssertEqual(try OpenRouterKeyOAuth.parseKey(Data(#"{"key":"fixture-key"}"#.utf8)), "fixture-key")
        XCTAssertThrowsError(try OpenRouterKeyOAuth.parseKey(Data(#"{"key":" "}"#.utf8)))
        XCTAssertThrowsError(try OpenRouterKeyOAuth.parseKey(Data(#"{"error":"bad response"}"#.utf8)))
    }

    func testKimiDeviceCodeAndPollingStates() throws {
        let fixture = #"{"device_code":"device","user_code":"ABCD-ZYXW","verification_uri":"https://auth.kimi.com/activate","verification_uri_complete":"https://auth.kimi.com/activate?user_code=ABCD-ZYXW","expires_in":600}"#
        let grant = try KimiDeviceOAuth.parseAuthorization(Data(fixture.utf8))
        XCTAssertEqual(grant.userCode, "ABCD-ZYXW")
        XCTAssertEqual(grant.deviceCode, "device")
        XCTAssertEqual(grant.pollingInterval, 5)
        XCTAssertEqual(grant.expiresIn, 600)
        XCTAssertEqual(grant.browserURL.query, "user_code=ABCD-ZYXW")
        for replacement in ["http://auth.kimi.com", "https://127.0.0.1", "https://auth.kimi.com.evil.example"] {
            let invalid = fixture.replacingOccurrences(of: "https://auth.kimi.com", with: replacement)
            XCTAssertThrowsError(try KimiDeviceOAuth.parseAuthorization(Data(invalid.utf8)))
        }
        let states: [(String, KimiDeviceOAuth.Poll)] = [
            ("authorization_pending", .pending), ("slow_down", .slowDown),
            ("expired_token", .expired), ("access_denied", .denied),
        ]
        for (error, expected) in states {
            let data = Data("{\"error\":\"\(error)\"}".utf8)
            XCTAssertEqual(try KimiDeviceOAuth.parsePoll(data, status: 400), expected)
            XCTAssertThrowsError(try KimiDeviceOAuth.parsePoll(data, status: 302))
        }
        let response = Data(#"{"access_token":"fixture","token_type":"bearer","expires_in":180,"refresh_token":"refresh-fixture"}"#.utf8)
        guard case .success(let token) = try KimiDeviceOAuth.parsePoll(response, status: 200) else {
            return XCTFail("Expected a token")
        }
        XCTAssertEqual(token.accessToken, "fixture")
        XCTAssertEqual(token.expiresIn, 180)
    }

    func testPresetsAndExperimentalRegistration() throws {
        let expected = Set(["zhipu-coding", "minimax-coding", "stepfun", "modelscope", "opencode-go", "aihubmix", "kimi-code"])
        XCTAssertEqual(Set(Service.catalog.filter { $0.category == .codingPlan }.map(\.id)), expected)
        XCTAssertEqual(Set(Service.catalog.map(\.id)).count, Service.catalog.count)
        XCTAssertEqual(Set(Service.catalog.map(\.category)), Set(Service.Category.allCases))
        for id in expected {
            let preset = try XCTUnwrap(Service.byID[id])
            for address in preset.addresses {
                XCTAssertEqual(URL(string: address.url)?.scheme, "https", id)
                XCTAssertNotNil(URL(string: address.url)?.host, id)
            }
            XCTAssertTrue(preset.kind.isSupportedProtocol, id)
        }
        XCTAssertFalse(ExperimentalOAuth.initiallyExpanded)
        XCTAssertEqual(ExperimentalOAuth.providers.count, 4)
        XCTAssertNotNil(ExperimentalOAuth.Registration(clientID: "fixture", callback: try XCTUnwrap(OAuthLoopbackAddress.callback(port: 41729))))
        let lan = try XCTUnwrap(URL(string: "http://192.168.0.2:41729/callback"))
        XCTAssertNil(ExperimentalOAuth.Registration(clientID: "fixture", callback: lan))
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let suite = "ClioAppPR2DTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try body(defaults)
    }
}
