import XCTest
@testable import AgentKit

final class PrivateNetworkTests: XCTestCase {
    private func makePolicy(_ suiteSuffix: String) -> (policy: PrivateNetworkPolicy, defaults: UserDefaults, suite: String) {
        let suite = "clio.tests.privatenet.\(suiteSuffix).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (PrivateNetworkPolicy(defaults: defaults), defaults, suite)
    }

    func testFiveDomainAddressClassification() {
        XCTAssertEqual(LocalAddress.classifyLiteral(URL(string: "https://8.8.8.8/")!), .publicAddress)
        XCTAssertEqual(LocalAddress.classifyLiteral(URL(string: "https://example.com/")!), .publicAddress)
        XCTAssertEqual(LocalAddress.classifyLiteral(URL(string: "https://198.18.0.5/")!), .fakeIPRange)
        XCTAssertEqual(LocalAddress.classifyLiteral(URL(string: "https://198.19.255.254/")!), .fakeIPRange)
        XCTAssertEqual(LocalAddress.classifyLiteral(URL(string: "https://192.168.1.10/")!), .privateLAN)
        XCTAssertEqual(LocalAddress.classifyLiteral(URL(string: "https://10.0.0.1/")!), .privateLAN)
        XCTAssertEqual(LocalAddress.classifyLiteral(URL(string: "https://172.16.0.1/")!), .privateLAN)
        XCTAssertEqual(LocalAddress.classifyLiteral(URL(string: "https://nas.local/")!), .privateLAN)
        XCTAssertEqual(LocalAddress.classifyLiteral(URL(string: "https://[fc00::1]/")!), .privateLAN)
        XCTAssertEqual(LocalAddress.classifyLiteral(URL(string: "https://100.64.0.5/")!), .cgnatMesh)
        XCTAssertEqual(LocalAddress.classifyLiteral(URL(string: "https://host.ts.net/")!), .cgnatMesh)
        XCTAssertEqual(LocalAddress.classifyLiteral(URL(string: "https://127.0.0.1/")!), .loopbackOrMetadata)
        XCTAssertEqual(LocalAddress.classifyLiteral(URL(string: "https://169.254.169.254/latest/meta-data/")!), .loopbackOrMetadata)
        XCTAssertEqual(LocalAddress.classifyLiteral(URL(string: "https://[::1]/")!), .loopbackOrMetadata)
        XCTAssertEqual(LocalAddress.classifyLiteral(URL(string: "https://[fe80::1]/")!), .loopbackOrMetadata)
        XCTAssertEqual(LocalAddress.classifyLiteral(URL(string: "https://[fd00:ec2::254]/")!), .loopbackOrMetadata)
        XCTAssertEqual(LocalAddress.classifyLiteral(URL(string: "https://[::ffff:198.18.0.1]/")!), .fakeIPRange)
        XCTAssertEqual(LocalAddress.classifyLiteral(URL(string: "https://[64:ff9b::169.254.169.254]/")!), .loopbackOrMetadata)
        XCTAssertEqual(LocalAddress.classifyLiteral(URL(string: "http://user:pass@example.com/")!), .loopbackOrMetadata)
    }

    func testFakeIPCompatAndMixedDNSAnomaly() {
        let ctx = makePolicy("fakeip")
        defer { ctx.defaults.removePersistentDomain(forName: ctx.suite) }
        let policy = ctx.policy

        let publicURL = URL(string: "https://example.com/data")!
        let off = policy.evaluate(url: publicURL, action: .read, allowAuthorizedPrivate: false, resolvedKinds: [.fakeIPRange])
        XCTAssertFalse(off.allowed)
        XCTAssertEqual(off.domain, .fakeIPProxy)
        XCTAssertEqual(off.diagnostic, .fakeIPPlaceholder)

        policy.fakeIPCompatEnabled = true
        let onHTTPS = policy.evaluate(url: publicURL, action: .read, allowAuthorizedPrivate: false, resolvedKinds: [.fakeIPRange])
        XCTAssertTrue(onHTTPS.allowed)
        XCTAssertEqual(onHTTPS.domain, .fakeIPProxy)
        XCTAssertNil(onHTTPS.diagnostic)

        // Literal 198.18.x must NEVER be bypassed even with Fake-IP compat enabled.
        let literalFake = URL(string: "https://198.18.0.1/")!
        let literalResult = policy.evaluate(url: literalFake, action: .read, allowAuthorizedPrivate: true, resolvedKinds: [])
        XCTAssertFalse(literalResult.allowed)
        XCTAssertEqual(literalResult.diagnostic, .fakeIPPlaceholder)

        // Mixed DNS responses mixing Fake-IP and LAN/Loopback are rejected.
        let mixedLAN = policy.evaluate(url: publicURL, action: .read, allowAuthorizedPrivate: true, resolvedKinds: [.fakeIPRange, .privateLAN])
        XCTAssertFalse(mixedLAN.allowed)
        XCTAssertEqual(mixedLAN.diagnostic, .mixedDNSAnomaly)

        let mixedLoopback = policy.evaluate(url: publicURL, action: .read, allowAuthorizedPrivate: true, resolvedKinds: [.fakeIPRange, .loopbackOrMetadata])
        XCTAssertFalse(mixedLoopback.allowed)
        XCTAssertEqual(mixedLoopback.diagnostic, .mixedDNSAnomaly)
    }

    func testPrivateNetworkGrantValidationScopingAndRevocation() {
        XCTAssertFalse(PrivateNetworkGrant.isValidPattern(""))
        XCTAssertFalse(PrivateNetworkGrant.isValidPattern("*"))
        XCTAssertFalse(PrivateNetworkGrant.isValidPattern("*.*"))
        XCTAssertFalse(PrivateNetworkGrant.isValidPattern("localhost"))
        XCTAssertFalse(PrivateNetworkGrant.isValidPattern("127.0.0.1"))
        XCTAssertFalse(PrivateNetworkGrant.isValidPattern("169.254.169.254"))
        XCTAssertFalse(PrivateNetworkGrant.isValidPattern("198.18.0.1"))
        XCTAssertFalse(PrivateNetworkGrant.isValidPattern("8.8.8.8"))
        XCTAssertFalse(PrivateNetworkGrant.isValidPattern("*.com"))

        XCTAssertTrue(PrivateNetworkGrant.isValidPattern("192.168.1.10"))
        XCTAssertTrue(PrivateNetworkGrant.isValidPattern("10.0.0.5"))
        XCTAssertTrue(PrivateNetworkGrant.isValidPattern("100.64.0.1"))
        XCTAssertTrue(PrivateNetworkGrant.isValidPattern("nas.local"))
        XCTAssertTrue(PrivateNetworkGrant.isValidPattern("*.ts.net"))
        XCTAssertTrue(PrivateNetworkGrant.isValidPattern("fd12:3456::1"))

        let ctx = makePolicy("grants")
        defer { ctx.defaults.removePersistentDomain(forName: ctx.suite) }
        let policy = ctx.policy

        let grant = PrivateNetworkGrant(
            id: "nas-1",
            label: "家庭 NAS",
            hostPattern: "192.168.1.10",
            port: 5000,
            allowPlainHTTP: true,
            maxAction: .read
        )
        XCTAssertTrue(policy.addGrant(grant))

        let nasReadURL = URL(string: "http://192.168.1.10:5000/api")!
        let nasWrongPort = URL(string: "http://192.168.1.10:8080/api")!

        XCTAssertTrue(policy.evaluate(url: nasReadURL, action: .read, allowAuthorizedPrivate: true).allowed)
        XCTAssertFalse(policy.evaluate(url: nasReadURL, action: .read, allowAuthorizedPrivate: false).allowed)
        XCTAssertFalse(policy.evaluate(url: nasWrongPort, action: .read, allowAuthorizedPrivate: true).allowed)

        // Action escalation beyond .read must be rejected.
        let writeEval = policy.evaluate(url: nasReadURL, action: .write, allowAuthorizedPrivate: true)
        XCTAssertFalse(writeEval.allowed)
        XCTAssertEqual(writeEval.diagnostic, .scopeEscalationBlocked)

        // Credentials over plain HTTP must be rejected.
        let credHTTP = policy.evaluate(url: nasReadURL, action: .read, allowAuthorizedPrivate: true, hasCredentials: true)
        XCTAssertFalse(credHTTP.allowed)
        XCTAssertEqual(credHTTP.diagnostic, .scopeEscalationBlocked)

        // Immediate block after revoke.
        policy.revokeGrant(id: "nas-1")
        let afterRevoke = policy.evaluate(url: nasReadURL, action: .read, allowAuthorizedPrivate: true)
        XCTAssertFalse(afterRevoke.allowed)
        XCTAssertEqual(afterRevoke.diagnostic, .unauthorizedPrivate)
    }

    func testAllSixDiagnosticCategoriesHaveDistinctMessages() {
        let categories: [NetworkDiagnosticCategory] = [
            .fakeIPPlaceholder,
            .unauthorizedPrivate,
            .scopeEscalationBlocked,
            .unreachableOrLocalNet,
            .tlsCertificateMismatch,
            .mixedDNSAnomaly,
        ]
        let messages = Set(categories.map(\.userMessage))
        XCTAssertEqual(messages.count, 6)
        for msg in messages {
            XCTAssertFalse(msg.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }
}
