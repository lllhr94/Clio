import Craft
import Foundation
import XCTest

final class SessionTokenGateOAuthTests: XCTestCase {
    private actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    private actor RefreshBarrier {
        private var waiting: CheckedContinuation<Void, Never>?
        private var arrived: CheckedContinuation<Void, Never>?

        func pause() async {
            await withCheckedContinuation { waiting = $0; arrived?.resume(); arrived = nil }
        }

        func waitForRefresh() async {
            if waiting != nil { return }
            await withCheckedContinuation { arrived = $0 }
        }

        func resume() { waiting?.resume(); waiting = nil }
    }

    private static func output(_ token: String) -> SessionTokenGate.RefreshOutput {
        .init(token: token, expiresAt: .distantFuture)
    }

    func testParallelCallersShareRefreshButOtherScopesDoNot() async throws {
        let root = SessionTokenGate()
        let gate = root.scoped(account: "a", issuer: "issuer", resource: "resource")
        let otherAccount = root.scoped(account: "b", issuer: "issuer", resource: "resource")
        let otherIssuer = root.scoped(account: "a", issuer: "issuer-2", resource: "resource")
        let otherResource = root.scoped(account: "a", issuer: "issuer", resource: "resource-2")
        let count = Counter()
        let result = try await withThrowingTaskGroup(of: SessionTokenGate.Lease.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    try await gate.access { _ in
                        await count.increment()
                        return Self.output("shared")
                    }
                }
            }
            var results: [SessionTokenGate.Lease] = []
            for try await lease in group { results.append(lease) }
            return results
        }
        let calls = await count.value
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(Set(result.map(\.token)), ["shared"])
        XCTAssertEqual(gate.sessionKey(), SessionTokenKey(account: "a", issuer: "issuer", resource: "resource", epoch: 0))
        for other in [otherAccount, otherIssuer, otherResource] {
            let lease = try await other.access { _ in Self.output("different") }
            XCTAssertEqual(lease.token, "different")
        }
    }

    func testLateRefreshAnd401CannotWriteAfterSignIn() async throws {
        let gate = SessionTokenGate()
        let barrier = RefreshBarrier()
        let oldEpoch = gate.currentEpoch()
        let running = Task {
            try await gate.access { epoch in
                await barrier.pause()
                return try gate.withCurrentEpoch(epoch) { _ in
                    XCTFail("A late refresh reached durable storage")
                    return Self.output("old")
                }
            }
        }
        await barrier.waitForRefresh()
        let attempt = gate.beginSignIn()
        var writes = 0
        let next = try XCTUnwrap(gate.commitSignIn(attempt) { writes += 1 })
        XCTAssertEqual(writes, 1)
        XCTAssertGreaterThan(next, oldEpoch)
        await gate.store(token: "new", expiresAt: .distantFuture, epoch: next)
        await barrier.resume()
        do {
            _ = try await running.value
            XCTFail("The old refresh returned a lease")
        } catch { XCTAssertEqual(error as? SessionTokenGate.GateError, .sessionChanged) }

        await gate.invalidateCached(token: "old", epoch: oldEpoch)
        do {
            _ = try await gate.access(forceRefresh: true, expectedEpoch: oldEpoch) { _ in
                XCTFail("The old 401 refreshed a new login")
                return Self.output("bad")
            }
            XCTFail("The old 401 returned a lease")
        } catch { XCTAssertEqual(error as? SessionTokenGate.GateError, .sessionChanged) }
        let lease = try await gate.access { _ in Self.output("unexpected") }
        XCTAssertEqual(lease.token, "new")
    }

    func testSignOutFencesPendingLoginAndFailedWritePreservesEpoch() throws {
        enum Failure: Error { case disk }
        let gate = SessionTokenGate()
        let attempt = gate.beginSignIn()
        XCTAssertThrowsError(try gate.commitSignIn(attempt) { throw Failure.disk })
        XCTAssertTrue(gate.isSignInActive(attempt))
        let signOutEpoch = gate.invalidateSession {}
        XCTAssertGreaterThan(signOutEpoch, attempt.baseEpoch)
        XCTAssertNil(gate.commitSignIn(attempt) { XCTFail("The old sign-in reached storage") })
    }

    func testLeaseRequiresExactHTTPSOriginAndRejectsUserInfo() {
        let allowed: Set<String> = ["https://api.example.com", "https://extra.example.com:8443"]
        for raw in ["https://API.example.com:443/v1", "https://extra.example.com:8443"] {
            XCTAssertTrue(SessionTokenGate.validateLeaseOrigin(URL(string: raw)!, allowedHTTPSOrigins: allowed))
        }
        for raw in ["http://api.example.com", "https://api.example.com:444", "https://sub.api.example.com",
                    "https://api.example.com.evil.example", "https://user@api.example.com", "https://api.example.com@evil.example"] {
            XCTAssertFalse(SessionTokenGate.validateLeaseOrigin(URL(string: raw)!, allowedHTTPSOrigins: allowed))
        }
    }
}
