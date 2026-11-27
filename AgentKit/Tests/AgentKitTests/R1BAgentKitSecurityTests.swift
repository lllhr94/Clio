@testable import AgentKit
import Foundation
import XCTest

final class R1BAgentKitSecurityTests: XCTestCase {
    // MARK: - CLIO-001: Deferred MCP tool_invoke whitespace normalization

    private struct ApprovalRequiringTool: AgentTool {
        let spec: ToolSpec
        let ask: ApprovalAsk

        func label(for arguments: JSONValue) -> String {
            "执行 \(spec.name)"
        }

        func approval(for arguments: JSONValue) -> ApprovalAsk? {
            ask
        }

        func run(_ arguments: JSONValue) async throws -> ToolOutput {
            ToolOutput("executed")
        }
    }

    func testDeferredMCPInvokeNormalizesWhitespaceBeforeApprovalAndLabel() async throws {
        let inner = ApprovalRequiringTool(
            spec: ToolSpec(name: "mcp_demo_delete", description: "Delete demo item", parameters: .object([:])),
            ask: ApprovalAsk(title: "删除演示数据", reason: "测试审批", forced: true)
        )
        let entry = DeferredMCPTools.Entry(
            stableID: "mcp_demo_delete",
            serverID: "srv-1",
            serverName: "Demo",
            tool: inner
        )
        let policy = DeferredMCPTools.Policy(
            connectorGeneration: 1,
            currentGeneration: { 1 },
            isPermitted: { _, _ in true }
        )
        let metaTools = DeferredMCPTools.assemble(
            builtInTools: [],
            mcpEntries: [entry],
            policy: policy,
            threshold: 0
        )
        let invoke = try XCTUnwrap(metaTools.first { $0.spec.name == "tool_invoke" })
        let help = try XCTUnwrap(metaTools.first { $0.spec.name == "tool_help" })

        for padded in [" mcp_demo_delete", "mcp_demo_delete ", "  mcp_demo_delete\n\t"] {
            let args: JSONValue = .object(["tool": .string(padded), "arguments": .object([:])])
            let ask = invoke.approval(for: args)
            XCTAssertNotNil(ask, "Padded tool name \(padded.debugDescription) must still trigger approval")
            XCTAssertEqual(ask?.title, "删除演示数据")
            XCTAssertEqual(ask?.forced, true)
            XCTAssertEqual(invoke.label(for: args), "执行 mcp_demo_delete")
            XCTAssertEqual(help.label(for: args), "查看工具说明：mcp_demo_delete")
        }
    }

    // MARK: - CLIO-008: WebFetch StayPublic cross-zone redirect & scheme downgrade stripping

    func testStayPublicBlocksPublicToAuthorizedPrivateRedirect() async {
        let policy = PrivateNetworkPolicy.shared
        let grantID = "test-r1b-\(UUID().uuidString)"
        let grant = PrivateNetworkGrant(
            id: grantID,
            label: "Home NAS",
            hostPattern: "192.168.50.10",
            port: 443,
            allowPlainHTTP: false,
            maxAction: .read
        )
        XCTAssertTrue(policy.addGrant(grant))
        defer {
            policy.revokeGrant(id: grantID)
        }

        // Sanity check: direct authorized private access is allowed.
        let privateURL = URL(string: "https://192.168.50.10/api/status")!
        let directEval = await policy.evaluateAsync(url: privateURL, action: .read, allowAuthorizedPrivate: true)
        XCTAssertTrue(directEval.allowed)
        XCTAssertEqual(directEval.domain, .authorizedPrivate)

        // But a 302 redirect originating from publicWeb must NEVER pivot into authorizedPrivate.
        XCTAssertTrue(WebFetch.StayPublic.isCrossZoneEscalation(from: .publicWeb, to: .authorizedPrivate))
        XCTAssertTrue(WebFetch.StayPublic.isCrossZoneEscalation(from: .fakeIPProxy, to: .privateMesh))
        XCTAssertFalse(WebFetch.StayPublic.isCrossZoneEscalation(from: .publicWeb, to: .publicWeb))
        XCTAssertFalse(WebFetch.StayPublic.isCrossZoneEscalation(from: .authorizedPrivate, to: .authorizedPrivate))

        let delegate = WebFetch.StayPublic(allowAuthorizedPrivate: true, initialDomain: .publicWeb)
        let originURL = URL(string: "https://attacker.example/start")!
        let redirectResponse = HTTPURLResponse(
            url: originURL,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": privateURL.absoluteString]
        )!
        let session = URLSession(configuration: .ephemeral)
        let dummyTask = session.dataTask(with: originURL)
        let redirected = await delegate.urlSession(
            session,
            task: dummyTask,
            willPerformHTTPRedirection: redirectResponse,
            newRequest: URLRequest(url: privateURL)
        )
        XCTAssertNil(redirected, "Public-origin 302 redirect to an authorized private LAN host must be rejected")

        // A private-origin request that redirects to public web must not be allowed to pivot back to private LAN.
        let pivotDelegate = WebFetch.StayPublic(allowAuthorizedPrivate: true, initialDomain: .authorizedPrivate)
        let publicHopURL = URL(string: "https://example.com/bounce")!
        let firstHopResponse = HTTPURLResponse(
            url: privateURL,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": publicHopURL.absoluteString]
        )!
        let firstHop = await pivotDelegate.urlSession(
            session,
            task: dummyTask,
            willPerformHTTPRedirection: firstHopResponse,
            newRequest: URLRequest(url: publicHopURL)
        )
        XCTAssertNotNil(firstHop)
        let bounceBackResponse = HTTPURLResponse(
            url: publicHopURL,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": privateURL.absoluteString]
        )!
        let bounceBack = await pivotDelegate.urlSession(
            session,
            task: dummyTask,
            willPerformHTTPRedirection: bounceBackResponse,
            newRequest: URLRequest(url: privateURL)
        )
        XCTAssertNil(bounceBack, "Once a redirect chain enters public web it must not bounce back into private LAN")
        session.invalidateAndCancel()
    }

    func testStayPublicStripsAuthAndCookieOnHTTPSDowngradeAndCrossOrigin() {
        let origin = URL(string: "https://example.com/login")!

        // 1. Same-host HTTPS -> HTTP downgrade must strip Authorization and Cookie.
        var downgradeReq = URLRequest(url: URL(string: "http://example.com/next")!)
        downgradeReq.setValue("Bearer secret-token", forHTTPHeaderField: "Authorization")
        downgradeReq.setValue("sid=secret-cookie", forHTTPHeaderField: "Cookie")
        let sanitizedDowngrade = WebFetch.StayPublic.sanitizeRedirectRequest(downgradeReq, from: origin)
        XCTAssertNil(sanitizedDowngrade.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(sanitizedDowngrade.value(forHTTPHeaderField: "Cookie"))

        // 2. Cross-host redirect must strip Authorization and Cookie.
        var crossHostReq = URLRequest(url: URL(string: "https://other.example/next")!)
        crossHostReq.setValue("Bearer secret-token", forHTTPHeaderField: "Authorization")
        crossHostReq.setValue("sid=secret-cookie", forHTTPHeaderField: "Cookie")
        let sanitizedCrossHost = WebFetch.StayPublic.sanitizeRedirectRequest(crossHostReq, from: origin)
        XCTAssertNil(sanitizedCrossHost.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(sanitizedCrossHost.value(forHTTPHeaderField: "Cookie"))

        // 3. Cross-port redirect must strip Authorization and Cookie.
        var crossPortReq = URLRequest(url: URL(string: "https://example.com:8443/next")!)
        crossPortReq.setValue("Bearer secret-token", forHTTPHeaderField: "Authorization")
        crossPortReq.setValue("sid=secret-cookie", forHTTPHeaderField: "Cookie")
        let sanitizedCrossPort = WebFetch.StayPublic.sanitizeRedirectRequest(crossPortReq, from: origin)
        XCTAssertNil(sanitizedCrossPort.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(sanitizedCrossPort.value(forHTTPHeaderField: "Cookie"))

        // 4. Exact same-origin path redirect keeps headers intact.
        var sameOriginReq = URLRequest(url: URL(string: "https://example.com/dashboard")!)
        sameOriginReq.setValue("Bearer secret-token", forHTTPHeaderField: "Authorization")
        sameOriginReq.setValue("sid=secret-cookie", forHTTPHeaderField: "Cookie")
        let sanitizedSameOrigin = WebFetch.StayPublic.sanitizeRedirectRequest(sameOriginReq, from: origin)
        XCTAssertEqual(sanitizedSameOrigin.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
        XCTAssertEqual(sanitizedSameOrigin.value(forHTTPHeaderField: "Cookie"), "sid=secret-cookie")
    }
}
