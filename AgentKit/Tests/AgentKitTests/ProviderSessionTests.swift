@testable import AgentKit
import Foundation
import XCTest

final class ProviderSessionTests: XCTestCase {
    private final class FlagBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func setTrue() {
            lock.withLock { value = true }
        }

        func isTrue() -> Bool {
            lock.withLock { value }
        }
    }

    private final class StringBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String

        init(_ value: String) {
            self.value = value
        }

        func get() -> String {
            lock.withLock { value }
        }

        func set(_ newValue: String) {
            lock.withLock { value = newValue }
        }
    }

    private final class MockURLProtocol: URLProtocol {
        nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
        private static let urlsLock = NSLock()
        nonisolated(unsafe) private static var _recordedURLs: [URL] = []

        static var recordedURLs: [URL] {
            get { urlsLock.withLock { _recordedURLs } }
            set { urlsLock.withLock { _recordedURLs = newValue } }
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            if let url = request.url {
                Self.urlsLock.withLock { Self._recordedURLs.append(url) }
            }
            guard let handler = Self.handler else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            do {
                let (response, data) = try handler(request)
                if (300..<400).contains(response.statusCode),
                   let location = response.value(forHTTPHeaderField: "Location"),
                   let target = URL(string: location, relativeTo: request.url)?.absoluteURL {
                    var redirected = URLRequest(url: target)
                    redirected.allHTTPHeaderFields = request.allHTTPHeaderFields
                    client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
                }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                if !data.isEmpty {
                    client?.urlProtocol(self, didLoad: data)
                }
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    private func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        MockURLProtocol.recordedURLs = []
        super.tearDown()
    }

    func testRedirectPolicyBlocksCrossOriginAndHTTPSDowngrade() {
        let origin = URL(string: "https://api.example.com/v1/chat/completions")!

        XCTAssertTrue(
            HTTP.RedirectGuardDelegate.shouldAllowRedirect(
                from: origin,
                to: URL(string: "https://api.example.com:443/v2/chat/completions")!
            )
        )
        XCTAssertFalse(
            HTTP.RedirectGuardDelegate.shouldAllowRedirect(
                from: origin,
                to: URL(string: "https://evil.example.com/v1/chat/completions")!
            )
        )
        XCTAssertFalse(
            HTTP.RedirectGuardDelegate.shouldAllowRedirect(
                from: origin,
                to: URL(string: "http://api.example.com/v1/chat/completions")!
            )
        )
        XCTAssertFalse(
            HTTP.RedirectGuardDelegate.shouldAllowRedirect(
                from: origin,
                to: URL(string: "https://api.example.com:8443/v1/chat/completions")!
            )
        )
    }

    func testHTTPGetBlocksCrossOriginRedirectBeforeFetchingTarget() async {
        let session = makeMockSession()
        MockURLProtocol.recordedURLs = []
        MockURLProtocol.handler = { request in
            let url = request.url!
            if url.host == "api.example.com" {
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: 302,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Location": "https://evil.example.com/steal"]
                )!
                return (response, Data())
            }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (response, Data(#"{"data":[]}"#.utf8))
        }

        var request = URLRequest(url: URL(string: "https://api.example.com/v1/models")!)
        request.setValue("Bearer secret-token", forHTTPHeaderField: "Authorization")

        do {
            _ = try await HTTP.get(request, session: session)
            XCTFail("Expected cross-origin redirect to be rejected")
        } catch {
            // Expected HTTP failure on 302 after delegate refused following redirect.
        }

        XCTAssertEqual(MockURLProtocol.recordedURLs.map(\.host), ["api.example.com"])
    }

    func testSessionPoolRotatesOnSignatureChangeWithoutKillingInFlightTasks() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]

        let pool = HTTP.SessionPool(initialSignature: "wifi:en0", startMonitor: false) { _ in
            URLSession(configuration: config)
        }

        let initialSession = pool.currentSession
        XCTAssertFalse(pool.rotateIfNeeded(for: "wifi:en0"))
        XCTAssertEqual(pool.generation, 0)
        XCTAssertTrue(pool.currentSession === initialSession)

        let streamStarted = FlagBox()
        let releaseStream = DispatchSemaphore(value: 0)
        MockURLProtocol.handler = { request in
            streamStarted.setTrue()
            _ = releaseStream.wait(timeout: .now() + 5)
            let payload = "data: {\"choices\":[{\"delta\":{\"content\":\"ok\"}}]}\n\ndata: [DONE]\n\n"
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            return (response, Data(payload.utf8))
        }

        let request = URLRequest(url: URL(string: "https://api.example.com/v1/chat/completions")!)
        let stream = HTTP.stream(request, session: initialSession, decode: OpenAIProvider.decode)

        let collectTask = Task { () -> String in
            var receivedText = ""
            for try await event in stream {
                if case .text(let chunk) = event {
                    receivedText += chunk
                }
            }
            return receivedText
        }

        // Wait until the request is genuinely in-flight before rotating & invalidating the retired session.
        let deadline = Date().addingTimeInterval(3)
        while !streamStarted.isTrue() {
            if Date() >= deadline {
                releaseStream.signal()
                XCTFail("Timed out waiting for in-flight request to start")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        // Rotate pool to a new session while the stream on the retired session is actively paused mid-flight.
        XCTAssertTrue(pool.rotateIfNeeded(for: "cell:pdp_ip0|proxy=SOCKSEnable=1"))
        XCTAssertEqual(pool.generation, 1)
        XCTAssertEqual(pool.retiredSessionCount, 1)
        XCTAssertFalse(pool.currentSession === initialSession)

        releaseStream.signal()
        let receivedText = try await collectTask.value
        XCTAssertEqual(receivedText, "ok")
    }

    func testSessionPoolRotatesOnProxyChangeAndDefersRetirementDuringLease() {
        let proxyBox = StringBox("none")
        let config = URLSessionConfiguration.ephemeral

        let pool = HTTP.SessionPool(
            initialSignature: "wifi:en0",
            startMonitor: false,
            proxySignatureProvider: { proxyBox.get() },
            factory: { _ in URLSession(configuration: config) }
        )

        let lease = pool.acquireLease()
        XCTAssertEqual(lease.generation, 0)
        XCTAssertEqual(pool.pendingRetirementCount, 0)

        proxyBox.set("HTTPEnable=1;HTTPProxy=127.0.0.1;HTTPPort=8888")
        let rotatedSession = pool.currentSession
        XCTAssertEqual(pool.generation, 1)
        XCTAssertFalse(rotatedSession === lease.session)
        XCTAssertEqual(pool.pendingRetirementCount, 1)

        // Release lease after task setup completes cleanly; triggers deferred finishTasksAndInvalidate().
        pool.releaseLease(lease)
        XCTAssertEqual(pool.pendingRetirementCount, 0)
    }
}
