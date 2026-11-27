import AgentKit
import Craft
import Foundation
import XCTest

final class MCPDiscoveryContractTests: XCTestCase {
    func testChallengeParserPreservesQuotedCommasEscapesAndUnquotedPointers() {
        let header = #"Basic realm="login", bEaReR ReSoUrCe_MeTaDaTa=https://api.example.com/meta?k=v, Scope="read write", realm="a,\"b", Digest realm="other""#
        let parsed = MCPDiscoveryPolicy.challenges(header)
        XCTAssertEqual(parsed.map(\.scheme), ["basic", "bearer", "digest"])
        XCTAssertEqual(parsed[1].parameters["resource_metadata"], "https://api.example.com/meta?k=v")
        XCTAssertEqual(parsed[1].parameters["scope"], "read write")
        XCTAssertEqual(parsed[1].parameters["realm"], "a,\"b")
        XCTAssertEqual(parsed[2].parameters["realm"], "other")
        XCTAssertEqual(MCPDiscoveryPolicy.challenges(#"Bearer scope="broken"#), [])
    }

    func testDiscoveryOrderingAndCanonicalResource() {
        let resource = URL(string: "https://MCP.example.com:443/v1/a%2Fb?drop=yes#fragment")!
        let pointer = URL(string: "https://meta.example.com/config")!
        XCTAssertEqual(MCPDiscoveryPolicy.protocolVersion, "2025-11-25")
        XCTAssertEqual(MCPDiscoveryPolicy.canonicalResource(resource), "https://mcp.example.com/v1/a%2Fb")
        XCTAssertEqual(MCPDiscoveryPolicy.resourceMetadataCandidates(resource: resource, pointer: pointer).map(\.absoluteString), [
            "https://meta.example.com/config",
            "https://mcp.example.com/.well-known/oauth-protected-resource/v1/a%2Fb",
            "https://mcp.example.com/.well-known/oauth-protected-resource",
        ])
        let issuer = URL(string: "https://accounts.example.com/tenant/")!
        XCTAssertEqual(MCPDiscoveryPolicy.authorizationMetadataCandidates(issuer: issuer).map(\.absoluteString), [
            "https://accounts.example.com/.well-known/oauth-authorization-server/tenant",
            "https://accounts.example.com/.well-known/openid-configuration/tenant",
            "https://accounts.example.com/tenant/.well-known/openid-configuration",
        ])
        let root = URL(string: "https://accounts.example.com/")!
        XCTAssertEqual(MCPDiscoveryPolicy.authorizationMetadataCandidates(issuer: root).count, 2)
        XCTAssertEqual(MCPDiscoveryPolicy.resourceMetadataCandidates(resource: root, pointer: nil).count, 1)
    }

    func testMetadataRequiresMatchingIssuerS256AndPublicHTTPS() throws {
        let issuer = URL(string: "https://accounts.example.com/tenant/")!
        func metadata(issuer: String = "https://accounts.example.com/tenant", methods: [String]? = ["S256"],
                      registration: String = "https://accounts.example.com/register") throws -> MCPDiscoveryPolicy.ServerMetadata {
            var fields: [String: Any] = [
                "issuer": issuer,
                "authorization_endpoint": "https://accounts.example.com/authorize",
                "token_endpoint": "https://accounts.example.com/token",
                "registration_endpoint": registration,
            ]
            if let methods { fields["code_challenge_methods_supported"] = methods }
            return try JSONDecoder().decode(MCPDiscoveryPolicy.ServerMetadata.self,
                                            from: JSONSerialization.data(withJSONObject: fields))
        }
        try MCPDiscoveryPolicy.validate(metadata(), expectedIssuer: issuer)
        for entry in [
            try metadata(methods: nil), try metadata(methods: ["plain"]), try metadata(methods: ["s256"]),
            try metadata(issuer: "https://other.example.com/tenant"),
            try metadata(registration: "https://127.0.0.1/register"),
            try metadata(registration: "https://192.168.2.3/register"),
            try metadata(registration: "http://accounts.example.com/register"),
            try metadata(registration: "https://user@accounts.example.com/register"),
        ] {
            XCTAssertThrowsError(try MCPDiscoveryPolicy.validate(entry, expectedIssuer: issuer)) {
                XCTAssertTrue($0 is MCPDiscoveryPolicy.DiscoveryError)
            }
        }
    }

    func testScopePrecedenceAndCallbackTransport() {
        XCTAssertEqual(MCPDiscoveryPolicy.scope(challenge: "read  write", minimal: "other"), "read write")
        XCTAssertEqual(MCPDiscoveryPolicy.scope(challenge: nil, minimal: "read"), "read")
        XCTAssertNil(MCPDiscoveryPolicy.scope(challenge: nil, minimal: " "))
        let loopback = MCPCallbackTransport.route(URL(string: "http://127.0.0.1:54321/callback")!)
        XCTAssertEqual(loopback, .loopbackSafariVC)
        XCTAssertTrue(loopback.isMCP20251125Subset)
        let legacy = MCPCallbackTransport.route(URL(string: "clio://oauth/mcp")!)
        XCTAssertEqual(legacy, .legacyCustomScheme)
        XCTAssertFalse(legacy.isMCP20251125Subset)
        if case .rejectedHTTPSUnsupported = MCPCallbackTransport.route(URL(string: "https://app.example.com/callback")!) {} else {
            XCTFail("HTTPS requires explicit rejection")
        }
        for raw in ["http://127.0.0.1/callback", "http://localhost:1234/callback", "http://127.0.0.1:1234/other",
                    "http://127.0.0.1:1234/%63allback", "http://192.168.0.2:1234/callback", "clio://oauth/other"] {
            XCTAssertFalse(MCPCallbackTransport.route(URL(string: raw)!).isMCP20251125Subset)
        }
    }

    func testCacheKeyIncludesAllFourFieldsAndRoundTrips() throws {
        let original = MCPDCRCacheKey(issuer: "i", registrationEndpoint: "r", redirectURI: "a", manualStaticClientID: nil)
        let otherKeys = [
            MCPDCRCacheKey(issuer: "j", registrationEndpoint: "r", redirectURI: "a", manualStaticClientID: nil),
            MCPDCRCacheKey(issuer: "i", registrationEndpoint: "s", redirectURI: "a", manualStaticClientID: nil),
            MCPDCRCacheKey(issuer: "i", registrationEndpoint: "r", redirectURI: "b", manualStaticClientID: nil),
            MCPDCRCacheKey(issuer: "i", registrationEndpoint: "r", redirectURI: "a", manualStaticClientID: "static"),
        ]
        XCTAssertEqual(Set([original] + otherKeys).count, 5)
        XCTAssertEqual(try JSONDecoder().decode(MCPDCRCacheKey.self, from: JSONEncoder().encode(original)), original)
    }

    func testPurposesNeverGrantLANOrLiteralFakeIP() async {
        for purpose in [URLAccessPurpose.oauthEndpoint, .skillDownload, .remoteImage] {
            for host in ["127.0.0.1", "10.0.0.1", "service.local", "198.18.2.3", "100.64.1.1"] {
                let allowed = await purpose.allows(URL(string: "https://\(host)")!)
                XCTAssertFalse(allowed)
            }
        }
        let clear = URL(string: "http://images.example.com")!
        XCTAssertTrue(URLAccessPurpose.remoteImage.acceptsURL(clear))
        XCTAssertFalse(URLAccessPurpose.oauthEndpoint.acceptsURL(clear))
        XCTAssertFalse(URLAccessPurpose.skillDownload.acceptsURL(clear))
    }
}
