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

    func testBrowserActionScopeHierarchyAndRevocationOnOpenEndpoint() {
        let ctx = makePolicy("browser-scope")
        defer { ctx.defaults.removePersistentDomain(forName: ctx.suite) }
        let policy = ctx.policy

        let httpEndpoint = URL(string: "http://192.168.1.25:8080/control")!
        let httpsEndpoint = URL(string: "https://192.168.1.25:8443/login")!

        // Read-only grant allows .read, blocks .write and .credential.
        XCTAssertTrue(policy.addGrant(PrivateNetworkGrant(
            id: "router-ro",
            label: "路由器只读",
            hostPattern: "192.168.1.25",
            port: nil,
            allowPlainHTTP: true,
            maxAction: .read
        )))
        XCTAssertTrue(policy.evaluate(url: httpEndpoint, action: .read, allowAuthorizedPrivate: true).allowed)

        let writeBlocked = policy.evaluate(url: httpEndpoint, action: .write, allowAuthorizedPrivate: true)
        XCTAssertFalse(writeBlocked.allowed)
        XCTAssertEqual(writeBlocked.diagnostic, .scopeEscalationBlocked)

        let credBlockedOnRO = policy.evaluate(url: httpsEndpoint, action: .credential, allowAuthorizedPrivate: true, hasCredentials: true)
        XCTAssertFalse(credBlockedOnRO.allowed)
        XCTAssertEqual(credBlockedOnRO.diagnostic, .scopeEscalationBlocked)

        // Write grant permits .read and .write, still blocks .credential.
        policy.revokeGrant(id: "router-ro")
        XCTAssertTrue(policy.addGrant(PrivateNetworkGrant(
            id: "router-rw",
            label: "路由器读写",
            hostPattern: "192.168.1.25",
            port: nil,
            allowPlainHTTP: true,
            maxAction: .write
        )))
        XCTAssertTrue(policy.evaluate(url: httpEndpoint, action: .read, allowAuthorizedPrivate: true).allowed)
        XCTAssertTrue(policy.evaluate(url: httpEndpoint, action: .write, allowAuthorizedPrivate: true).allowed)

        let credBlockedOnRW = policy.evaluate(url: httpsEndpoint, action: .credential, allowAuthorizedPrivate: true, hasCredentials: true)
        XCTAssertFalse(credBlockedOnRW.allowed)
        XCTAssertEqual(credBlockedOnRW.diagnostic, .scopeEscalationBlocked)

        // Credential grant allows HTTPS .credential, while plaintext HTTP .credential remains blocked.
        policy.revokeGrant(id: "router-rw")
        XCTAssertTrue(policy.addGrant(PrivateNetworkGrant(
            id: "router-cred",
            label: "路由器登录",
            hostPattern: "192.168.1.25",
            port: nil,
            allowPlainHTTP: true,
            maxAction: .credential
        )))
        XCTAssertTrue(policy.evaluate(url: httpsEndpoint, action: .credential, allowAuthorizedPrivate: true, hasCredentials: true).allowed)

        let httpCredBlocked = policy.evaluate(url: httpEndpoint, action: .credential, allowAuthorizedPrivate: true, hasCredentials: true)
        XCTAssertFalse(httpCredBlocked.allowed)
        XCTAssertEqual(httpCredBlocked.diagnostic, .scopeEscalationBlocked)

        // Revoking immediately blocks every action on previously open endpoints.
        policy.revokeGrant(id: "router-cred")
        for action in [PrivateNetworkAction.read, .write, .credential] {
            let revokedEval = policy.evaluate(
                url: httpsEndpoint,
                action: action,
                allowAuthorizedPrivate: true,
                hasCredentials: action == .credential
            )
            XCTAssertFalse(revokedEval.allowed)
            XCTAssertEqual(revokedEval.diagnostic, .unauthorizedPrivate)
        }
    }

    func testAuthorizedPageIdentityRecheckPreventsNavigationSwap() {
        let initialPage = URL(string: "http://192.168.1.25/status")!
        let swappedPath = URL(string: "http://192.168.1.25/reboot")!
        let swappedHost = URL(string: "http://192.168.1.99/status")!

        XCTAssertTrue(PrivateNetworkPolicy.isSameAuthorizedPage(
            checkedURL: initialPage,
            currentURL: initialPage
        ))
        XCTAssertTrue(PrivateNetworkPolicy.isSameAuthorizedPage(
            checkedURL: initialPage,
            currentURL: initialPage,
            lastReadURL: initialPage,
            requireLastRead: true
        ))

        // Mid-check redirect or navigation must invalidate the action.
        XCTAssertFalse(PrivateNetworkPolicy.isSameAuthorizedPage(
            checkedURL: initialPage,
            currentURL: swappedPath,
            lastReadURL: initialPage,
            requireLastRead: true
        ))
        XCTAssertFalse(PrivateNetworkPolicy.isSameAuthorizedPage(
            checkedURL: initialPage,
            currentURL: swappedHost,
            lastReadURL: initialPage,
            requireLastRead: true
        ))
        XCTAssertFalse(PrivateNetworkPolicy.isSameAuthorizedPage(
            checkedURL: initialPage,
            currentURL: nil,
            lastReadURL: initialPage,
            requireLastRead: true
        ))
        XCTAssertFalse(PrivateNetworkPolicy.isSameAuthorizedPage(
            checkedURL: initialPage,
            currentURL: initialPage,
            lastReadURL: nil,
            requireLastRead: true
        ))
        XCTAssertFalse(PrivateNetworkPolicy.isSameAuthorizedPage(
            checkedURL: initialPage,
            currentURL: initialPage,
            lastReadURL: swappedPath,
            requireLastRead: true
        ))
    }

    func testReadOnlyNavigationLinkClassification() {
        let ctx = makePolicy("ro-links")
        defer { ctx.defaults.removePersistentDomain(forName: ctx.suite) }
        let policy = ctx.policy

        XCTAssertTrue(policy.addGrant(PrivateNetworkGrant(
            id: "router-ro",
            label: "路由器只读",
            hostPattern: "192.168.1.25",
            port: nil,
            allowPlainHTTP: true,
            maxAction: .read
        )))

        let basePage = URL(string: "http://192.168.1.25/index.html")!

        let plainPath = BrowserClickTargetDescriptor(
            tagName: "a",
            rawHref: "/status",
            resolvedHref: "http://192.168.1.25/status"
        )
        let plainDest = PrivateNetworkPolicy.readOnlyNavigationURL(for: plainPath, from: basePage)
        XCTAssertEqual(plainDest, URL(string: "http://192.168.1.25/status"))
        XCTAssertTrue(policy.evaluate(url: plainDest!, action: .read, allowAuthorizedPrivate: true).allowed)

        let relativeDest = PrivateNetworkPolicy.readOnlyNavigationURL(
            for: BrowserClickTargetDescriptor(tagName: "A", rawHref: "network.html"),
            from: basePage
        )
        XCTAssertEqual(relativeDest, URL(string: "http://192.168.1.25/network.html"))

        let queryDest = PrivateNetworkPolicy.readOnlyNavigationURL(
            for: BrowserClickTargetDescriptor(tagName: "a", rawHref: "?tab=wifi"),
            from: basePage
        )
        XCTAssertEqual(queryDest, URL(string: "http://192.168.1.25/index.html?tab=wifi"))

        let hashRouteDest = PrivateNetworkPolicy.readOnlyNavigationURL(
            for: BrowserClickTargetDescriptor(tagName: "a", rawHref: "#/overview"),
            from: basePage
        )
        XCTAssertEqual(hashRouteDest, URL(string: "http://192.168.1.25/index.html#/overview"))

        let menuItemDest = PrivateNetworkPolicy.readOnlyNavigationURL(
            for: BrowserClickTargetDescriptor(tagName: "a", rawHref: "/sys", role: "menuitem"),
            from: basePage
        )
        XCTAssertEqual(menuItemDest, URL(string: "http://192.168.1.25/sys"))

        let tabDest = PrivateNetworkPolicy.readOnlyNavigationURL(
            for: BrowserClickTargetDescriptor(tagName: "a", rawHref: "/wifi", role: "tab"),
            from: basePage
        )
        XCTAssertEqual(tabDest, URL(string: "http://192.168.1.25/wifi"))

        // Navigating to an unauthorized private host must still be rejected by .read policy.
        let otherHostLink = PrivateNetworkPolicy.readOnlyNavigationURL(
            for: BrowserClickTargetDescriptor(tagName: "a", rawHref: "http://192.168.1.99/admin"),
            from: basePage
        )
        XCTAssertEqual(otherHostLink, URL(string: "http://192.168.1.99/admin"))
        XCTAssertFalse(policy.evaluate(url: otherHostLink!, action: .read, allowAuthorizedPrivate: true).allowed)

        // Buttons, stubs, script links, downloads, and mutating links must NOT downgrade to .read.
        let blockedTargets: [BrowserClickTargetDescriptor] = [
            BrowserClickTargetDescriptor(tagName: "button", rawHref: nil),
            BrowserClickTargetDescriptor(tagName: "a", rawHref: "#"),
            BrowserClickTargetDescriptor(tagName: "a", rawHref: ""),
            BrowserClickTargetDescriptor(tagName: "a", rawHref: "javascript:reboot()"),
            BrowserClickTargetDescriptor(tagName: "a", rawHref: "/status", hasOnClick: true),
            BrowserClickTargetDescriptor(tagName: "a", rawHref: "/file.bin", hasDownload: true),
            BrowserClickTargetDescriptor(tagName: "a", rawHref: "/del", hasMutatingAttribute: true),
            BrowserClickTargetDescriptor(tagName: "a", rawHref: "/toggle", role: "button"),
        ]
        for target in blockedTargets {
            XCTAssertNil(PrivateNetworkPolicy.readOnlyNavigationURL(for: target, from: basePage))
        }
        XCTAssertFalse(policy.evaluate(url: basePage, action: .write, allowAuthorizedPrivate: true).allowed)
    }
}
