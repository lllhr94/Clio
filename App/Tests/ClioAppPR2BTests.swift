import AgentKit
import Craft
import Foundation
import XCTest
@testable import Clio

@MainActor
final class ClioAppPR2BTests: XCTestCase {
    private var cleanupKeys: [String] = []

    @MainActor
    override func tearDown() async throws {
        for key in cleanupKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        cleanupKeys.removeAll()
        try await super.tearDown()
    }

    private func setDefault(_ value: Any?, forKey key: String) {
        cleanupKeys.append(key)
        UserDefaults.standard.set(value, forKey: key)
    }

    func testEndpointProviderWiresResponsesCodexCacheTierHeadersAndPause() throws {
        let respID = "ep-resp-\(UUID().uuidString)"
        let codexID = "ep-codex-\(UUID().uuidString)"
        let claudeID = "ep-claude-\(UUID().uuidString)"

        let respEndpoint = Endpoint(
            id: respID,
            name: "OpenAI Responses",
            kind: .openaiResponses,
            baseURL: "https://api.openai.com/v1",
            models: ["gpt-5"]
        )
        let headersData = try JSONEncoder().encode(["HTTP-Referer": "https://clio.app", "Authorization": "Bearer evil"])
        setDefault(headersData, forKey: "clio.endpoint.customHeaders.\(respID)")

        let respProvider = try XCTUnwrap(respEndpoint.provider(key: "sk-test") as? OpenAIResponsesProvider)
        XCTAssertFalse(respProvider.isCodex)
        XCTAssertTrue(respProvider.fixedRoute)
        XCTAssertEqual(respProvider.customHeaders["HTTP-Referer"], "https://clio.app")

        // Pausing the endpoint returns DisabledProtocolProvider and excludes it from dispatchable resolution.
        setDefault(true, forKey: "clio.endpoint.paused.\(respID)")
        XCTAssertTrue(respEndpoint.isPaused)
        XCTAssertFalse(respEndpoint.isDispatchable)
        XCTAssertTrue(respEndpoint.provider(key: "sk-test") is DisabledProtocolProvider)

        // Codex endpoint wires isCodex == true.
        let codexEndpoint = Endpoint(
            id: codexID,
            name: "Codex",
            kind: .openaiCodex,
            baseURL: "https://api.openai.com/v1",
            models: ["gpt-5-codex"]
        )
        let codexProvider = try XCTUnwrap(codexEndpoint.provider(key: "sk-codex") as? OpenAIResponsesProvider)
        XCTAssertTrue(codexProvider.isCodex)

        // Anthropic endpoint honors 3-tier cache key ("1h").
        setDefault("1h", forKey: "clio.endpoint.cacheTier.\(claudeID)")
        let claudeEndpoint = Endpoint(
            id: claudeID,
            name: "Claude",
            kind: .anthropic,
            baseURL: "https://api.anthropic.com",
            models: ["claude-sonnet-4-6"]
        )
        let claudeProvider = try XCTUnwrap(claudeEndpoint.provider(key: "sk-ant") as? AnthropicProvider)
        XCTAssertEqual(claudeProvider.effectiveCacheTier, .oneHour)
    }

    func testMultiLevelBackupChainSkipsPausedAndStopsOnExplicitOff() async throws {
        let epPrimary = Endpoint(id: "p1", name: "Primary", kind: .openai, baseURL: "https://primary.example.com/v1", models: ["m1"])
        let epPaused = Endpoint(id: "p2", name: "Paused", kind: .openai, baseURL: "https://paused.example.com/v1", models: ["m2"])
        let epB2 = Endpoint(id: "p3", name: "Backup2", kind: .openai, baseURL: "https://b2.example.com/v1", models: ["m3"])
        let epB3 = Endpoint(id: "p4", name: "Backup3", kind: .openai, baseURL: "https://b3.example.com/v1", models: ["m4"])

        setDefault(true, forKey: "clio.endpoint.paused.p2")

        let team = TeamModel(keeping: false)
        team.settings.endpoints = [epPrimary, epPaused, epB2, epB3]
        team.settings.defaultModel = "p1/m1"
        team.settings.setBackupModelsList(["p2/m2", "p3/m3", "p4/m4"])

        let candidates = team.backupCandidates(excluding: ["p1/m1"])
        XCTAssertEqual(candidates.map(\.ref), ["p3/m3", "p4/m4"], "Paused backup p2/m2 must be skipped cleanly")

        final class RecordingProvider: ModelProvider, @unchecked Sendable {
            let result: Result<String, ProviderError>
            let onCall: @Sendable () -> Void
            init(_ result: Result<String, ProviderError>, onCall: @escaping @Sendable () -> Void) {
                self.result = result
                self.onCall = onCall
            }
            func stream(_ request: ModelRequest) -> AsyncThrowingStream<StreamEvent, Error> {
                onCall()
                return AsyncThrowingStream { continuation in
                    switch result {
                    case .success(let text):
                        continuation.yield(.text(text))
                        continuation.yield(.finish(reason: "stop"))
                        continuation.finish()
                    case .failure(let err):
                        continuation.finish(throwing: err)
                    }
                }
            }
            func models() async throws -> [String] { [] }
        }

        let bot = BotInfo(id: "bot-b2b", name: "Tester", role: nil, instructions: "hi", model: "p1/m1")
        team.bots = [bot]
        let chatKey = TeamModel.key(bot: bot.id)
        team.entries[chatKey] = [Entry(id: UUID().uuidString, at: Now.ms, message: .user("hello"))]

        let lock = NSLock()
        var called: [String] = []
        team.turnProviderOverrideForTesting = { endpoint, model, _ in
            let ref = "\(endpoint.id)/\(model)"
            if ref == "p1/m1" || ref == "p3/m3" {
                return RecordingProvider(.failure(ProviderError(status: 402, "insufficient balance"))) {
                    lock.withLock { called.append(ref) }
                }
            }
            return RecordingProvider(.success("answered-by-\(model)")) {
                lock.withLock { called.append(ref) }
            }
        }

        let ok = await team.turn(bot, in: chatKey, room: nil)
        XCTAssertTrue(ok)
        let visited = lock.withLock { called }
        XCTAssertTrue(visited.contains("p1/m1"))
        XCTAssertFalse(visited.contains("p2/m2"))
        XCTAssertTrue(visited.contains("p3/m3"))
        XCTAssertTrue(visited.contains("p4/m4"))

        // Explicit-off preflight gate blocks ALL network calls and backup handoffs (0 calls made).
        lock.withLock { called.removeAll() }
        var opts = team.options(chatKey)
        opts.setThinkingSelection(.explicitOff)
        team.setOptions(chatKey, opts)
        let blocked = await team.turn(bot, in: chatKey, room: nil)
        XCTAssertFalse(blocked)
        XCTAssertEqual(lock.withLock { called }, [], "Unconfirmed relay explicitOff must terminate locally with zero network requests and zero backup hops")
    }

    func testHillsDeferredMCPPolicyInvalidatesOnGenerationBump() async throws {
        struct StubTool: AgentTool {
            let name: String
            var isReadOnlySafe: Bool { true }
            var spec: ToolSpec { ToolSpec(name: name, description: "desc", parameters: .object(["type": .string("object")])) }
            func label(for arguments: JSONValue) -> String { name }
            func run(_ arguments: JSONValue) async throws -> ToolOutput { ToolOutput("ok:\(name)") }
        }

        let box = Hills.ConnectorAccessBox()
        box.update(
            servers: ["srv_a": .init(enabled: true, url: "https://mcp.example.com", tunnelHost: nil)],
            bumpGeneration: false
        )
        let captured = box.generation
        let policy = DeferredMCPTools.Policy(
            connectorGeneration: captured,
            isGenerationCurrent: { box.generation == captured },
            atomicCheck: { serverID, _ in
                box.snapshotGenerationAndCheck(expectedGeneration: captured, serverID: serverID)
            }
        )

        let entries = (1...26).map { i in
            DeferredMCPTools.Entry(stableID: "mcp_srv__t\(i)", serverID: "srv_a", serverName: "SrvA", tool: StubTool(name: "mcp_srv__t\(i)"))
        }
        let assembled = DeferredMCPTools.assemble(builtInTools: [StubTool(name: "web_search")], mcpEntries: entries, policy: policy)
        let help = try XCTUnwrap(assembled.first { $0.spec.name == "tool_help" })
        let invoke = try XCTUnwrap(assembled.first { $0.spec.name == "tool_invoke" })

        let okHelp = try await help.run(.object(["tool": .string("mcp_srv__t1")]))
        XCTAssertFalse(okHelp.isError)

        // Mutating connector configuration bumps generation and revokes access immediately.
        box.update(servers: [:], bumpGeneration: true)
        let deniedHelp = try await help.run(.object(["tool": .string("mcp_srv__t1")]))
        let deniedInvoke = try await invoke.run(.object(["tool": .string("mcp_srv__t1")]))
        XCTAssertTrue(deniedHelp.isError)
        XCTAssertTrue(deniedInvoke.isError)
    }
}
