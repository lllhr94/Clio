import AgentKit
import Craft
import XCTest
@testable import Clio

@MainActor
final class R1CUIFixesAppTests: XCTestCase {
    override func tearDown() {
        ModelsDev.resetForTesting()
        super.tearDown()
    }

    func testManualThinkingToggleAndManualRuleRefreshContractAndWireFields() {
        ModelsDev.resetForTesting()
        _ = ModelsDev.currentSnapshot()

        let team = TeamModel()
        let relay = Endpoint(
            id: "custom-relay",
            name: "My Relay",
            kind: .openai,
            baseURL: "https://my-custom-relay.example.com/v1",
            models: ["corp-private-model"]
        )
        team.settings.endpoints = [relay]
        team.settings.defaultModel = "custom-relay/corp-private-model"

        // Unknown custom model initially offers only `.inheritDefault`.
        let initialContract = team.thinkingContract(for: team.settings.endpoints[0], model: "corp-private-model")
        XCTAssertEqual(initialContract.offeredSelections, [.inheritDefault])

        // Manually toggling "会思考" ON immediately refreshes offered levels & emits wire fields.
        var manualTraits = team.settings.endpoints[0].traits("corp-private-model")
        manualTraits.thinks = true
        manualTraits.thinksSource = .userManual
        team.setTraits("custom-relay", model: "corp-private-model", manualTraits)

        let toggledContract = team.thinkingContract(for: team.settings.endpoints[0], model: "corp-private-model")
        XCTAssertTrue(toggledContract.supportsThinking)
        XCTAssertGreaterThan(toggledContract.offeredSelections.count, 1)
        XCTAssertTrue(toggledContract.offeredSelections.contains(.effort("high")))
        XCTAssertFalse(toggledContract.canExplicitlyDisable)

        let chatKey = "bot-relay-test"
        team.setThinkingSelection(.effort("high"), in: chatKey)
        let res = team.resolvedThinking(for: chatKey, endpoint: team.settings.endpoints[0], model: "corp-private-model")
        guard case .fulfilled(let eff, _, _) = res.fulfillment else {
            return XCTFail("Expected fulfilled high effort after manual thinks toggle, got \(res.fulfillment)")
        }
        XCTAssertEqual(eff, .effort("high"))
        XCTAssertEqual(res.bodyFields["reasoning_effort"], .string("high"))

        // Saving an explicit ManualThinkingRule enables user-confirmed `.explicitOff` + exact efforts.
        let key = team.settings.endpoints[0].contractKey(for: "corp-private-model")!
        let rule = ManualThinkingRule(
            contract: key,
            canDisable: true,
            supportedEfforts: ["low", "high"],
            wireStyle: .effort
        )
        team.setManualThinkingRule(rule, for: "corp-private-model", in: "custom-relay")

        let ruledContract = team.thinkingContract(for: team.settings.endpoints[0], model: "corp-private-model")
        XCTAssertTrue(ruledContract.isKnownContract)
        XCTAssertTrue(ruledContract.canExplicitlyDisable)
        XCTAssertEqual(ruledContract.offeredSelections, [.inheritDefault, .explicitOff, .effort("low"), .effort("high")])

        team.setThinkingSelection(.explicitOff, in: chatKey)
        let offRes = team.resolvedThinking(for: chatKey, endpoint: team.settings.endpoints[0], model: "corp-private-model")
        XCTAssertEqual(offRes.fulfillment, .fulfilled(effective: .explicitOff, migratedFrom: nil, note: nil))
        XCTAssertEqual(offRes.bodyFields["reasoning_effort"], .string("none"))
    }

    func testProbeRejectsEmptyAndThinkingOnlyStreams() async throws {
        let emptyStream = AsyncThrowingStream<StreamEvent, Error> { continuation in
            continuation.finish()
        }
        let emptyCollected = try await TeamModel.collectProbeStream(emptyStream)
        let emptyOutcome = TeamModel.formatProbeOutcome(
            model: "demo-model",
            text: emptyCollected.text,
            reasoningChars: emptyCollected.reasoningChars,
            elapsed: 0.4
        )
        XCTAssertFalse(emptyOutcome.ok, "Empty stream must never report probe success")

        let thinkingOnlyStream = AsyncThrowingStream<StreamEvent, Error> { continuation in
            continuation.yield(.reasoning("让我先仔细思考一下这个问题……"))
            continuation.finish()
        }
        let thinkingCollected = try await TeamModel.collectProbeStream(thinkingOnlyStream)
        XCTAssertEqual(thinkingCollected.text, "")
        XCTAssertGreaterThan(thinkingCollected.reasoningChars, 0)
        let thinkingOutcome = TeamModel.formatProbeOutcome(
            model: "demo-model",
            text: thinkingCollected.text,
            reasoningChars: thinkingCollected.reasoningChars,
            elapsed: 0.9
        )
        XCTAssertFalse(thinkingOutcome.ok, "Thinking-only stream with no visible text must not report probe success")
        XCTAssertTrue(thinkingOutcome.note.contains("思考过程"))

        let validStream = AsyncThrowingStream<StreamEvent, Error> { continuation in
            continuation.yield(.reasoning("先想一下"))
            continuation.yield(.text("好"))
            continuation.finish()
        }
        let validCollected = try await TeamModel.collectProbeStream(validStream)
        let validOutcome = TeamModel.formatProbeOutcome(
            model: "demo-model",
            text: validCollected.text,
            reasoningChars: validCollected.reasoningChars,
            elapsed: 0.5
        )
        XCTAssertTrue(validOutcome.ok)
        XCTAssertTrue(validOutcome.note.contains("好"))
    }

    func testHillsAsyncRefreshDiscardsResultsIfServerDeletedOrReconfiguredMidFlight() async {
        let hills = Hills.shared
        let serverID = "test-mcp-race-\(UUID().uuidString)"
        let server = Hills.Server(id: serverID, name: "TempMCP", url: "https://temp-mcp.example.com/mcp")
        hills.save(server, token: nil)
        defer {
            hills.fetchMCPToolsOverrideForTesting = nil
            hills.remove(server)
        }

        final class Gate: @unchecked Sendable {
            private let lock = NSLock()
            private var startedContinuation: CheckedContinuation<Void, Never>?
            private var releaseContinuation: CheckedContinuation<Void, Never>?
            private var started = false
            private var released = false

            func markStartedAndWaitRelease() async {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    let decision: (startedWaiting: CheckedContinuation<Void, Never>?, resumeNow: Bool) = lock.withLock {
                        started = true
                        let waiting = startedContinuation
                        startedContinuation = nil
                        if released {
                            return (waiting, true)
                        }
                        releaseContinuation = cont
                        return (waiting, false)
                    }
                    decision.startedWaiting?.resume()
                    if decision.resumeNow {
                        cont.resume()
                    }
                }
            }

            func waitUntilStarted() async {
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    let alreadyStarted = lock.withLock { () -> Bool in
                        if started { return true }
                        startedContinuation = cont
                        return false
                    }
                    if alreadyStarted { cont.resume() }
                }
            }

            func release() {
                let toResume: CheckedContinuation<Void, Never>? = lock.withLock {
                    released = true
                    let waiting = releaseContinuation
                    releaseContinuation = nil
                    return waiting
                }
                toResume?.resume()
            }
        }

        let gate = Gate()
        hills.fetchMCPToolsOverrideForTesting = { _ in
            await gate.markStartedAndWaitRelease()
            return [
                MCPClient.Tool(
                    name: "ghost_tool",
                    description: "Should not be written back after delete",
                    schema: .object(["type": .string("object")]),
                    readOnly: true
                ),
            ]
        }

        let refreshTask = Task { await hills.refreshWithOutcome(server) }
        await gate.waitUntilStarted()
        // Delete server while async MCP tool discovery is still in flight.
        hills.remove(server)
        gate.release()

        let outcome = await refreshTask.value
        XCTAssertEqual(outcome, .stale)
        XCTAssertTrue(hills.tools(of: server).isEmpty, "Deleted MCP server tools must never be written back")
        XCTAssertNil(hills.lastError[server.id])

        // Re-add server and verify reconfiguring URL mid-refresh also discards stale tool results.
        let gate2 = Gate()
        hills.save(server, token: nil)
        hills.fetchMCPToolsOverrideForTesting = { _ in
            await gate2.markStartedAndWaitRelease()
            return [
                MCPClient.Tool(
                    name: "stale_url_tool",
                    description: "Should not be written back after URL change",
                    schema: .object(["type": .string("object")]),
                    readOnly: true
                ),
            ]
        }
        let refreshTask2 = Task { await hills.refreshWithOutcome(server) }
        await gate2.waitUntilStarted()
        var reconfigured = server
        reconfigured.url = "https://other-mcp.example.com/mcp"
        hills.save(reconfigured, token: nil)
        gate2.release()

        let outcome2 = await refreshTask2.value
        XCTAssertEqual(outcome2, .stale)
        XCTAssertTrue(hills.tools(of: reconfigured).isEmpty, "Stale refresh after server URL update must be discarded")

        // Verify modifying the SSH tunnel host mid-refresh also returns `.stale` and invalidates old tools.
        let hostID = "test-tunnel-host-\(UUID().uuidString)"
        let host = Hills.Host(id: hostID, name: "TempHost", address: "10.0.0.1", port: 22, user: "root", useKey: true)
        let tunneledID = "test-tunneled-mcp-\(UUID().uuidString)"
        let tunneled = Hills.Server(id: tunneledID, name: "TunneledMCP", url: "http://127.0.0.1:8931/mcp", tunnelHost: hostID)
        hills.save(host, password: nil)
        hills.save(tunneled, token: nil)
        defer {
            hills.remove(tunneled)
            hills.remove(host)
        }

        let gate3 = Gate()
        hills.fetchMCPToolsOverrideForTesting = { _ in
            await gate3.markStartedAndWaitRelease()
            return [
                MCPClient.Tool(
                    name: "stale_tunnel_tool",
                    description: "Should not survive SSH tunnel host change",
                    schema: .object(["type": .string("object")]),
                    readOnly: true
                ),
            ]
        }
        let refreshTask3 = Task { await hills.refreshWithOutcome(tunneled) }
        await gate3.waitUntilStarted()
        var editedHost = host
        editedHost.address = "10.0.0.2"
        hills.save(editedHost, password: nil)
        gate3.release()

        let outcome3 = await refreshTask3.value
        XCTAssertEqual(outcome3, .stale)
        XCTAssertTrue(hills.tools(of: tunneled).isEmpty, "Stale refresh after tunnel host edit must be discarded")
    }

    func testConnectorsSearchIgnoresHiddenCategoryFilter() {
        // Without search text, category filter restricts strictly to selected group.
        XCTAssertTrue(ConnectorsPage.matchesCategory(group: "开发", selectedKind: "开发", needle: ""))
        XCTAssertFalse(ConnectorsPage.matchesCategory(group: "文档与资料", selectedKind: "开发", needle: ""))
        XCTAssertTrue(ConnectorsPage.matchesCategory(group: "文档与资料", selectedKind: "全部", needle: ""))

        // With active search needle, hidden category filter is bypassed so cross-category connectors remain searchable.
        XCTAssertTrue(ConnectorsPage.matchesCategory(group: "文档与资料", selectedKind: "开发", needle: "notion"))
        XCTAssertTrue(ConnectorsPage.matchesCategory(group: "地图与出行", selectedKind: "谷歌", needle: "高德"))
    }
}
