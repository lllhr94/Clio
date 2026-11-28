@testable import Craft
import Foundation
import XCTest

final class NetworkRoutingTests: XCTestCase {
    func testUnconfiguredSettingsAreCompletelyDirectAndNeedNoLocalEntry() {
        let settings = NetworkRoutingSettings.default
        XCTAssertTrue(settings.routingEnabled)
        XCTAssertEqual(settings.defaultRoute, .direct)
        XCTAssertFalse(settings.needsLocalEntry)
        XCTAssertEqual(
            NetworkRouteDecision.decide(settings: settings, scope: .shell, host: "38.39.24.229").kind,
            .direct
        )
        XCTAssertEqual(
            NetworkShellConfig.environment(settings: settings, socksPort: 1080, httpPort: 8080, entryPassword: "secret"),
            [:]
        )
        XCTAssertFalse(
            NetworkShellConfig.renderSSHConfig(settings: settings, proxyActive: true).contains("ProxyCommand")
        )
    }

    func testLoopbackIsAlwaysDirectEvenWhenProxyIsDefault() {
        let proxy = ProxyProfile(id: "P1", name: "HK", kind: .socks5, host: "10.0.0.2", port: 1080)
        let settings = NetworkRoutingSettings(
            routingEnabled: true,
            defaultRoute: .proxy("P1"),
            proxies: [proxy]
        )

        for host in ["localhost", "api.localhost", "127.0.0.1", "127.255.0.1", "::1", "[::1]", "0.0.0.0"] {
            let decision = NetworkRouteDecision.decide(settings: settings, scope: .shell, host: host)
            XCTAssertEqual(decision.kind, .direct, "Expected loopback \(host) to go direct")
            XCTAssertEqual(decision.rule, .loopback)
        }
    }

    func testBypassSupportsExactHostWildcardIPAndCIDR() {
        let proxy = ProxyProfile(
            id: "P1",
            name: "SG",
            kind: .http,
            host: "proxy.example.com",
            port: 8080,
            bypass: ["38.39.24.229", "*.cn", ".internal.corp", "10.0.0.0/8", "192.168.1.0/24", "fc00::/7"]
        )
        let settings = NetworkRoutingSettings(
            routingEnabled: true,
            defaultRoute: .proxy("P1"),
            proxies: [proxy]
        )

        XCTAssertEqual(NetworkRouteDecision.decide(settings: settings, scope: .shell, host: "38.39.24.229").rule, .bypass)
        XCTAssertEqual(NetworkRouteDecision.decide(settings: settings, scope: .shell, host: "api.deepseek.cn").rule, .bypass)
        XCTAssertEqual(NetworkRouteDecision.decide(settings: settings, scope: .shell, host: "cn").rule, .bypass)
        XCTAssertEqual(NetworkRouteDecision.decide(settings: settings, scope: .shell, host: "git.internal.corp").rule, .bypass)
        XCTAssertEqual(NetworkRouteDecision.decide(settings: settings, scope: .shell, host: "10.23.45.67").rule, .bypass)
        XCTAssertEqual(NetworkRouteDecision.decide(settings: settings, scope: .shell, host: "192.168.1.99").rule, .bypass)
        XCTAssertEqual(NetworkRouteDecision.decide(settings: settings, scope: .shell, host: "fd12:3456::1").rule, .bypass)

        let proxied = NetworkRouteDecision.decide(settings: settings, scope: .shell, host: "api.anthropic.com")
        XCTAssertEqual(proxied.kind, .proxy(proxy))
        XCTAssertEqual(proxied.rule, .route)

        let outsideCIDR = NetworkRouteDecision.decide(settings: settings, scope: .shell, host: "192.168.2.1")
        XCTAssertEqual(outsideCIDR.kind, .proxy(proxy))
    }

    func testMasterSwitchOverridesAllRoutesAndDisablesLocalEntry() {
        let proxy = ProxyProfile(id: "P1", name: "US", kind: .socks5, host: "1.2.3.4", port: 1080)
        let settings = NetworkRoutingSettings(
            routingEnabled: false,
            defaultRoute: .proxy("P1"),
            scopeRoutes: ["shell": .proxy("P1")],
            serviceRoutes: ["openai": .proxy("P1")],
            proxies: [proxy]
        )

        XCTAssertFalse(settings.needsLocalEntry)
        let decision = NetworkRouteDecision.decide(settings: settings, scope: .service("openai"), host: "api.openai.com")
        XCTAssertEqual(decision.kind, .direct)
        XCTAssertEqual(decision.rule, .masterOff)
    }

    func testPerScopeAndPerServiceOverridesAndMissingProxyFallback() {
        let p1 = ProxyProfile(id: "P1", name: "JP", kind: .socks5, host: "jp.example.com", port: 1080)
        let p2 = ProxyProfile(id: "P2", name: "US", kind: .https, host: "us.example.com", port: 443)
        var settings = NetworkRoutingSettings(
            routingEnabled: true,
            defaultRoute: .direct,
            scopeRoutes: ["shell": .proxy("P1"), "browser": .proxy("MISSING")],
            serviceRoutes: ["claude": .proxy("P2")],
            proxies: [p1, p2]
        )

        XCTAssertTrue(settings.needsLocalEntry)
        XCTAssertEqual(NetworkRouteDecision.decide(settings: settings, scope: .shell, host: "38.39.24.229").kind, .proxy(p1))
        XCTAssertEqual(NetworkRouteDecision.decide(settings: settings, scope: .service("claude"), host: "api.anthropic.com").kind, .proxy(p2))
        XCTAssertEqual(NetworkRouteDecision.decide(settings: settings, scope: .service("deepseek"), host: "api.deepseek.com").kind, .direct)

        let missing = NetworkRouteDecision.decide(settings: settings, scope: .browser, host: "example.com")
        XCTAssertEqual(missing.kind, .direct)
        XCTAssertEqual(missing.rule, .missingProxy)

        // Removing a proxy clears all routes referencing it back to direct.
        settings = settings.removingProxy(id: "P1")
        XCTAssertEqual(settings.effectiveRoute(for: .shell), .direct)
        XCTAssertEqual(settings.effectiveRoute(for: .service("claude")), .proxy("P2"))
    }

    func testShellEnvironmentAndSSHConfigExcludeBypassAndNeverEmbedSecretsInSSHConfig() {
        let proxy = ProxyProfile(
            id: "P1",
            name: "Clean",
            kind: .socks5,
            host: "198.51.100.10",
            port: 1080,
            bypass: ["38.39.24.229", "*.cn", "10.0.0.0/8", "evil\nhost"]
        )
        let settings = NetworkRoutingSettings(
            routingEnabled: true,
            defaultRoute: .direct,
            scopeRoutes: ["shell": .proxy("P1")],
            proxies: [proxy]
        )

        let env = NetworkShellConfig.environment(
            settings: settings,
            socksPort: 50001,
            httpPort: 50002,
            entryPassword: "deadbeef01234567"
        )
        XCTAssertEqual(env["ALL_PROXY"], "socks5h://shell:deadbeef01234567@127.0.0.1:50001")
        XCTAssertEqual(env["HTTP_PROXY"], "http://shell:deadbeef01234567@127.0.0.1:50002")
        XCTAssertEqual(env["HTTPS_PROXY"], "http://shell:deadbeef01234567@127.0.0.1:50002")
        XCTAssertTrue((env["NO_PROXY"] ?? "").contains("38.39.24.229"))

        let sshConfig = NetworkShellConfig.renderSSHConfig(settings: settings, proxyActive: true)
        XCTAssertTrue(sshConfig.contains("ProxyCommand /etc/clio-net/ssh-proxy %h %p"))
        XCTAssertTrue(sshConfig.contains("!38.39.24.229"))
        XCTAssertTrue(sshConfig.contains("!*.cn"))
        XCTAssertFalse(sshConfig.contains("deadbeef01234567"), "Local entry password must never be written to ssh_config")
        XCTAssertFalse(sshConfig.contains("evil"), "Unsafe whitespace/newline bypass entries must be rejected")
    }

    func testRedactionAndTarpitDiagnosticHints() {
        let raw = "HTTP_PROXY=http://shell:supersecret123@127.0.0.1:9999 upstream=myproxypass"
        let redacted = NetworkRedaction.redact(raw, secrets: ["supersecret123", "myproxypass"])
        XCTAssertFalse(redacted.contains("supersecret123"))
        XCTAssertFalse(redacted.contains("myproxypass"))
        XCTAssertTrue(redacted.contains("<redacted>"))

        let hint = NetworkErrorDiagnostics.hint(for: "Connection timed out during banner exchange")
        XCTAssertNotNil(hint)
        XCTAssertTrue(hint?.contains("网络与代理") == true)
    }

    func testProxyProfileValidationRejectsMalformedHostAndPort() {
        XCTAssertNotNil(ProxyProfile(host: "http://1.2.3.4", port: 1080).validationError())
        XCTAssertNotNil(ProxyProfile(host: "1.2.3.4", port: 0).validationError())
        XCTAssertNotNil(ProxyProfile(host: "1.2.3.4", port: 70000).validationError())
        XCTAssertNil(ProxyProfile(host: "proxy.example.com", port: 7890).validationError())
    }
}
