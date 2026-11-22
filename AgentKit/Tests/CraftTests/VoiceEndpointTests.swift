import Craft
import Foundation
import XCTest

final class VoiceEndpointTests: XCTestCase {
    func testHTTPAllowedOnlyForExplicitPrivateOrLoopbackIPLiterals() {
        let allowed = [
            "http://127.0.0.1:8000/v1",
            "http://10.0.0.5:8080/v1",
            "http://172.16.1.2/v1",
            "http://172.31.255.1:9000/v1",
            "http://192.168.1.42:8000",
            "http://169.254.1.5:8000/v1",
            "http://[::1]:8000/v1",
            "http://[fd00::1]:8000/v1",
            "http://[fe80::1]:8000/v1",
            "https://api.groq.com/openai/v1",
            "https://whisper.local/v1",
        ]
        for raw in allowed {
            switch VoiceEndpoint.validate(raw) {
            case .success: break
            case .failure(let err): XCTFail("Expected allowed for \(raw), got \(err)")
            }
        }

        let rejected: [(String, VoiceEndpointError)] = [
            ("http://api.groq.com/openai/v1", .requiresHTTPS),
            ("http://whisper.local/v1", .requiresHTTPS),
            ("http://localhost:8000/v1", .requiresHTTPS),
            ("http://router/v1", .requiresHTTPS),
            ("http://8.8.8.8/v1", .requiresHTTPS),
            ("http://172.32.0.1/v1", .requiresHTTPS),
            ("http://[2001:db8::1]/v1", .requiresHTTPS),
            ("http://127.1/v1", .requiresHTTPS),
            ("https://user:secret@api.groq.com/openai/v1", .embeddedCredentials),
            ("http://user:secret@127.0.0.1:8000/v1", .embeddedCredentials),
            ("https://api.groq.com/openai/v1?api_key=secret", .queryOrFragmentNotAllowed),
            ("http://192.168.1.50:8000/v1?token=abc", .queryOrFragmentNotAllowed),
            ("https://api.groq.com/openai/v1?", .queryOrFragmentNotAllowed),
            ("https://api.groq.com/openai/v1#secret", .queryOrFragmentNotAllowed),
            ("ftp://api.groq.com/v1", .invalidFormat),
        ]
        for (raw, expected) in rejected {
            switch VoiceEndpoint.parse(raw) {
            case .success(let parsed):
                XCTFail("Expected rejection (\(expected)) for \(raw), got \(parsed)")
            case .failure(let err):
                XCTAssertEqual(err, expected, "Unexpected error for \(raw)")
            }
        }
    }

    func testURLComponentsNormalizationBuildsCanonicalBaseAndEndpoint() throws {
        let root = try VoiceEndpoint.parse("https://api.openai.com/").get()
        XCTAssertEqual(root.baseURL, "https://api.openai.com")
        XCTAssertEqual(root.endpoint.absoluteString, "https://api.openai.com/v1/audio/transcriptions")

        let groq = try VoiceEndpoint.parse("HTTPS://api.groq.com/openai/v1/").get()
        XCTAssertEqual(groq.baseURL, "https://api.groq.com/openai/v1")
        XCTAssertEqual(groq.endpoint.absoluteString, "https://api.groq.com/openai/v1/audio/transcriptions")

        let full = try VoiceEndpoint.parse("https://example.com/proxy/audio/transcriptions/").get()
        XCTAssertEqual(full.baseURL, "https://example.com/proxy/audio/transcriptions")
        XCTAssertEqual(full.endpoint.absoluteString, "https://example.com/proxy/audio/transcriptions")

        let ipv6 = try VoiceEndpoint.parse("http://[::1]:8000/v1/").get()
        XCTAssertEqual(ipv6.baseURL, "http://[::1]:8000/v1")
        XCTAssertEqual(ipv6.endpoint.absoluteString, "http://[::1]:8000/v1/audio/transcriptions")
        XCTAssertEqual(ipv6.originKey, "http://[::1]:8000")
    }

    func testRedirectsEnforceSameOriginAndTransportPolicy() {
        let groq = URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!
        XCTAssertTrue(VoiceEndpoint.allowsRedirect(from: groq, to: URL(string: "https://api.groq.com/openai/v2/audio/transcriptions")!))
        XCTAssertTrue(VoiceEndpoint.allowsRedirect(from: groq, to: URL(string: "https://API.GROQ.COM:443/audio/transcriptions")!))
        // Cross-origin HTTPS redirect must be rejected so audio and Bearer key never go to another service.
        XCTAssertFalse(VoiceEndpoint.allowsRedirect(from: groq, to: URL(string: "https://evil.example.com/audio/transcriptions")!))
        // Protocol downgrade to HTTP must be rejected.
        XCTAssertFalse(VoiceEndpoint.allowsRedirect(from: groq, to: URL(string: "http://api.groq.com/openai/v1/audio/transcriptions")!))
        // Different port is a different origin.
        XCTAssertFalse(VoiceEndpoint.allowsRedirect(from: groq, to: URL(string: "https://api.groq.com:8443/openai/v1/audio/transcriptions")!))
        // Embedded credentials, query strings, or fragments in redirect target must be rejected.
        XCTAssertFalse(VoiceEndpoint.allowsRedirect(from: groq, to: URL(string: "https://u:p@api.groq.com/openai/v1/audio/transcriptions")!))
        XCTAssertFalse(VoiceEndpoint.allowsRedirect(from: groq, to: URL(string: "https://api.groq.com/openai/v1/audio/transcriptions?key=leak")!))
        XCTAssertFalse(VoiceEndpoint.allowsRedirect(from: groq, to: URL(string: "https://api.groq.com/openai/v1/audio/transcriptions#frag")!))

        let lan = URL(string: "http://192.168.1.50:8000/v1/audio/transcriptions")!
        XCTAssertTrue(VoiceEndpoint.allowsRedirect(from: lan, to: URL(string: "http://192.168.1.50:8000/v2/audio/transcriptions")!))
        XCTAssertFalse(VoiceEndpoint.allowsRedirect(from: lan, to: URL(string: "http://192.168.1.51:8000/v1/audio/transcriptions")!))
        XCTAssertFalse(VoiceEndpoint.allowsRedirect(from: lan, to: URL(string: "http://api.groq.com/v1/audio/transcriptions")!))
    }

    func testOriginKeysIsolateCredentialsAcrossServices() {
        let groq = try! VoiceEndpoint.validate("https://api.groq.com/openai/v1").get()
        let openai = try! VoiceEndpoint.validate("https://api.openai.com/v1").get()
        let groqAltPort = try! VoiceEndpoint.validate("https://api.groq.com:8443/openai/v1").get()
        let lan = try! VoiceEndpoint.validate("http://192.168.1.50:8000").get()

        let keys = Set([
            VoiceEndpoint.originKey(for: groq),
            VoiceEndpoint.originKey(for: openai),
            VoiceEndpoint.originKey(for: groqAltPort),
            VoiceEndpoint.originKey(for: lan),
        ].compactMap { $0 })
        XCTAssertEqual(keys.count, 4)
    }
}
