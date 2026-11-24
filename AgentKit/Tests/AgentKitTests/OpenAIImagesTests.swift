import Foundation
import XCTest
@testable import AgentKit

final class OpenAIImagesTests: XCTestCase {
    func testImageRequestKeepsServicePathAndSendsOneImage() throws {
        let provider = OpenAIProvider(baseURL: "https://image.example/relay/v1/", apiKey: "fixture-key")
        let request = try provider.imageRequest(model: "vendor/flux", prompt: "一张图", size: "1024x1024")
        XCTAssertEqual(request.url?.absoluteString, "https://image.example/relay/v1/images/generations")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "vendor/flux")
        XCTAssertEqual(json["prompt"] as? String, "一张图")
        XCTAssertEqual(json["size"] as? String, "1024x1024")
        XCTAssertEqual(json["n"] as? Int, 1)
    }

    func testImageGenerationAcceptsEitherResponseFormat() async throws {
        let encoded = try await generate("encoded")
        XCTAssertEqual(encoded, Data([1, 2, 3]))
        let linked = try await generate("linked")
        XCTAssertEqual(linked, Data([4, 5, 6]))
    }

    func testImageGenerationMapsProviderFailures() async {
        for (host, expected) in [
            ("quota", ImageGenerationError.insufficientQuota),
            ("moderation", .contentRejected), ("timeout", .timeout), ("bad-url", .invalidResponse),
            ("local-link", .invalidResponse),
        ] {
            do {
                _ = try await generate(host)
                XCTFail("Expected \(expected), received an image.")
            } catch {
                XCTAssertEqual(error as? ImageGenerationError, expected)
            }
        }
    }

    private func generate(_ host: String) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ImageFixtureProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let provider = OpenAIProvider(baseURL: "https://\(host).example/v1", apiKey: "fixture-key")
        return try await provider.generateImage(model: "image", prompt: "一张图", size: "1024x1024", session: session)
    }
}

private final class ImageFixtureProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let status: Int
        let body: Data
        switch url.host {
        case "encoded.example":
            status = 200
            body = Data(#"{"data":[{"b64_json":"AQID"}]}"#.utf8)
        case "linked.example":
            status = 200
            body = Data(#"{"data":[{"url":"https://download.example/image.png"}]}"#.utf8)
        case "download.example":
            status = request.value(forHTTPHeaderField: "Authorization") == nil && request.httpMethod == "GET" ? 200 : 400
            body = Data([4, 5, 6])
        case "local-link.example":
            status = 200
            body = Data(#"{"data":[{"url":"http://192.168.1.1/router.png"}]}"#.utf8)
        case "quota.example":
            status = 429
            body = Data(#"{"error":{"code":"insufficient_quota"}}"#.utf8)
        case "moderation.example":
            status = 400
            body = Data(#"{"error":{"code":"content_policy_violation"}}"#.utf8)
        case "timeout.example":
            status = 504
            body = Data()
        default:
            status = 200
            body = Data(#"{"data":[{"url":"file:///image.png"}]}"#.utf8)
        }
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
