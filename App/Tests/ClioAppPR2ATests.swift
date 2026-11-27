import AgentKit
import Craft
import XCTest
@testable import Clio

@MainActor
final class ClioAppPR2ATests: XCTestCase {
    override func tearDown() {
        ModelsDev.resetForTesting()
        super.tearDown()
    }

    func testOfflineBundledCatalogLoadsValidatesAndInjectsIntoResolver() throws {
        ModelsDev.resetForTesting()
        let bundleData = try XCTUnwrap(ModelsDev.bundledSnapshotData(), "App/Resources/models-dev-catalog.json must be bundled")
        XCTAssertLessThan(bundleData.count, 300 * 1024, "Bundled trimmed snapshot must stay under 300 KB")

        let snapshot = ModelsDev.currentSnapshot()
        XCTAssertEqual(snapshot.schemaVersion, ModelsDevCatalogSnapshot.currentSchemaVersion)
        XCTAssertGreaterThanOrEqual(snapshot.totalProviders, 20)
        XCTAssertGreaterThanOrEqual(snapshot.totalModels, 1000)
        XCTAssertGreaterThanOrEqual(snapshot.modelsWithReasoningOptions, 500)
        XCTAssertGreaterThanOrEqual(snapshot.modelsWithInterleaved, 200)
        XCTAssertEqual(ThinkingRuleResolver.currentSnapshot().totalModels, snapshot.totalModels)

        let deepseekFlash = try XCTUnwrap(ModelsDev.lookup("deepseek-flash", providerKey: "deepseek"))
        XCTAssertTrue(deepseekFlash.sees)
        XCTAssertTrue(deepseekFlash.thinks)
        XCTAssertTrue(deepseekFlash.canToggleOff)
        XCTAssertEqual(deepseekFlash.supportedEfforts, ["low", "high", "max"])
        XCTAssertEqual(deepseekFlash.interleavedField, "reasoning_content")
    }

    func testDegradedCatalogRefreshIsRejectedWithoutCorruptingActiveSnapshot() throws {
        ModelsDev.resetForTesting()
        let initial = ModelsDev.currentSnapshot()
        XCTAssertGreaterThan(initial.totalModels, 100)

        // Valid JSON with enough providers/models, but `reasoning_options` and `interleaved` stripped.
        var services: [String: Any] = [:]
        for p in 0..<15 {
            var models: [String: Any] = [:]
            for m in 0..<10 {
                models["m-\(p)-\(m)"] = [
                    "reasoning": true,
                    "tool_call": true,
                    "modalities": ["input": ["text"]],
                    "limit": ["context": 128_000, "output": 8192],
                ]
            }
            services["svc-\(p)"] = ["models": models]
        }
        let degradedData = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 2,
            "services": services,
        ])
        XCTAssertThrowsError(try ModelsDev.applyValidatedRefreshData(degradedData, writeCache: false))
        XCTAssertEqual(ModelsDev.currentSnapshot().totalModels, initial.totalModels)
        XCTAssertEqual(ThinkingRuleResolver.currentSnapshot().totalModels, initial.totalModels)
    }

    func testTolerantUnknownKindAndStyleDecodeWithoutBreakingTeamSettings() throws {
        let json = """
        {
          "endpoints": [
            {
              "id": "ep-future-proto",
              "name": "Future Proto",
              "kind": "future_proto_v9",
              "baseURL": "https://future.example.com/v1",
              "models": ["future-1"]
            },
            {
              "id": "ep-future-style",
              "name": "Future Style",
              "kind": "openai",
              "baseURL": "https://style.example.com/v1",
              "models": ["style-1"],
              "style": "future_thinking_v9"
            },
            {
              "id": "ep-responses",
              "name": "OpenAI Responses",
              "kind": "openai_responses",
              "baseURL": "https://api.openai.com/v1",
              "models": ["gpt-5.2"]
            }
          ],
          "defaultModel": "ep-responses/gpt-5.2"
        }
        """
        let settings = try JSONDecoder().decode(TeamSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.endpoints.count, 3)

        let futureProto = settings.endpoints[0]
        XCTAssertEqual(futureProto.kind, .unknown("future_proto_v9"))
        XCTAssertTrue(futureProto.isDisabledByUnknownProtocol)
        XCTAssertNil(futureProto.recipientIdentity)
        XCTAssertTrue(futureProto.provider(key: "sk-secret") is DisabledProtocolProvider)

        let futureStyle = settings.endpoints[1]
        XCTAssertEqual(futureStyle.kind, .openai)
        XCTAssertNil(futureStyle.style)
        XCTAssertEqual(futureStyle.unknownStyleRaw, "future_thinking_v9")
        XCTAssertTrue(futureStyle.isDisabledByUnknownProtocol)
        XCTAssertNil(futureStyle.recipientIdentity)
        XCTAssertTrue(futureStyle.provider(key: "sk-secret") is DisabledProtocolProvider)

        let responses = settings.endpoints[2]
        XCTAssertEqual(responses.kind, .openaiResponses)
        XCTAssertTrue(responses.isActiveProtocol)
        XCTAssertTrue(responses.kind.usesResponsesAPI)
        XCTAssertTrue(responses.kind.supportsImages)
        XCTAssertEqual(responses.recipientIdentity?.route, "/v1/responses")
        XCTAssertTrue(
            responses.provider(key: "sk-secret") is DisabledProtocolProvider,
            "Responses/Codex must never silently misroute to /chat/completions before PR 2B wires OpenAIResponsesProvider"
        )

        // Disabled endpoints are excluded from active resolution and first-preferred selection.
        XCTAssertNil(TeamModel.resolveActive("ep-future-proto/future-1", in: settings.endpoints))
        XCTAssertNil(TeamModel.resolveActive("ep-future-style/style-1", in: settings.endpoints))
        XCTAssertNotNil(TeamModel.resolveActive("ep-responses/gpt-5.2", in: settings.endpoints))
        XCTAssertEqual(TeamModel.firstPreferredModel(in: settings.endpoints), "ep-responses/gpt-5.2")

        // Re-encoding preserves unknown kind & style raw strings losslessly.
        let reencoded = try JSONEncoder().encode(settings)
        let roundTrip = try JSONDecoder().decode(TeamSettings.self, from: reencoded)
        XCTAssertEqual(roundTrip.endpoints[0].kind, .unknown("future_proto_v9"))
        XCTAssertEqual(roundTrip.endpoints[1].unknownStyleRaw, "future_thinking_v9")
    }

    func testBackupModelsDistinguishesNilFallbackVsExplicitEmpty() throws {
        // Legacy archive with only `backupModel` falls back cleanly.
        var legacy = try JSONDecoder().decode(
            TeamSettings.self,
            from: Data(#"{"endpoints":[],"backupModel":"ep/m1"}"#.utf8)
        )
        XCTAssertNil(legacy.backupModels)
        XCTAssertEqual(legacy.effectiveBackupModels, ["ep/m1"])

        // Explicitly cleared `backupModels: []` does NOT fall back to legacy `backupModel`.
        let cleared = try JSONDecoder().decode(
            TeamSettings.self,
            from: Data(#"{"endpoints":[],"backupModel":"ep/m1","backupModels":[]}"#.utf8)
        )
        XCTAssertEqual(cleared.backupModels, [])
        XCTAssertEqual(cleared.effectiveBackupModels, [])

        // Pruning and rewriting keep both fields consistent.
        legacy.setBackupModelsList(["ep-a/m1", "ep-b/m2"])
        XCTAssertEqual(legacy.backupModel, "ep-a/m1")
        XCTAssertEqual(legacy.effectiveBackupModels, ["ep-a/m1", "ep-b/m2"])
        legacy.rewriteBackupModels { $0.hasPrefix("ep-a/") ? "ep-z/" + $0.dropFirst(5) : $0 }
        XCTAssertEqual(legacy.effectiveBackupModels, ["ep-z/m1", "ep-b/m2"])
        legacy.pruneBackupModels { $0.hasPrefix("ep-z/") }
        XCTAssertEqual(legacy.effectiveBackupModels, ["ep-b/m2"])
        XCTAssertEqual(legacy.backupModel, "ep-b/m2")
    }

    func testUnknownLegacyOverrideDoesNotSuppressConfirmedDeepSeekCatalogAndManualRulesRevalidate() {
        ModelsDev.resetForTesting()
        _ = ModelsDev.currentSnapshot()

        var endpoint = Endpoint(
            id: "ds",
            name: "DeepSeek",
            kind: .openai,
            baseURL: "https://api.deepseek.com",
            models: ["deepseek-flash"],
            service: "deepseek"
        )
        // Simulate 401e396 legacy override without provenance marking thinks=false.
        endpoint.overrides = [
            "deepseek-flash": ModelTraits(sees: true, tools: true, thinks: false, window: 1_048_576, levels: nil)
        ]
        let resolution = endpoint.traitsResolution("deepseek-flash")
        XCTAssertTrue(resolution.traits.thinks, "unknownLegacy thinks=false must not suppress confirmed DeepSeek contract")
        XCTAssertTrue(resolution.hasLegacyConflict)

        // Manual rule bound to DeepSeek official contract stays valid while origin/route match,
        // and is dropped upon revalidation if baseURL changes (e.g. after backup restore to another origin).
        let key = endpoint.contractKey(for: "deepseek-flash")!
        endpoint.manualThinkingRules = [
            "deepseek-flash": ManualThinkingRule(contract: key, canDisable: true, supportedEfforts: ["low", "high"])
        ]
        XCTAssertEqual(endpoint.revalidateManualThinkingRules(), 0)
        XCTAssertNotNil(endpoint.validatedManualThinkingRule(for: "deepseek-flash"))

        endpoint.baseURL = "https://other-relay.example.com/v1"
        XCTAssertNil(endpoint.validatedManualThinkingRule(for: "deepseek-flash"))
        XCTAssertEqual(endpoint.revalidateManualThinkingRules(), 1)
        XCTAssertNil(endpoint.manualThinkingRules)
    }

    func testNonDestructiveModelSwitchAndGatheringOverridePrecedence() {
        ModelsDev.resetForTesting()
        _ = ModelsDev.currentSnapshot()

        let team = TeamModel()
        let ds = Endpoint(
            id: "ds",
            name: "DeepSeek",
            kind: .openai,
            baseURL: "https://api.deepseek.com",
            models: ["deepseek-flash"],
            service: "deepseek"
        )
        let openai = Endpoint(
            id: "oa",
            name: "OpenAI",
            kind: .openai,
            baseURL: "https://api.openai.com/v1",
            models: ["gpt-5", "gpt-4o"],
            service: "openai"
        )
        team.settings.endpoints = [ds, openai]
        team.settings.defaultModel = "ds/deepseek-flash"

        let botA = BotInfo(id: "bot-a", name: "甲", model: "ds/deepseek-flash")
        let botB = BotInfo(id: "bot-b", name: "乙", model: "oa/gpt-5")
        let room = RoomInfo(id: "room-1", name: "雅集", members: ["bot-a", "bot-b"])
        team.bots = [botA, botB]
        team.rooms = [room]

        // 1:1 chat: switching to a non-thinking model (gpt-4o) MUST NOT wipe saved `ThinkingSelection`.
        let chatKey = TeamModel.key(bot: botA.id)
        let chat = ChatModel(bot: botA, team: team)
        let notice = ChatComposerNotice()
        team.setThinkingSelection(.effort("xhigh"), in: chatKey)
        ChatPage.selectModel("oa/gpt-4o", in: chat, team: team, bot: botA, notice: notice)
        XCTAssertEqual(
            team.options(chatKey).effectiveThinkingSelection,
            .effort("xhigh"),
            "Model switch must preserve saved ThinkingSelection without wiping to .auto"
        )

        // Gathering room: when `options.model == nil`, offerings intersect botA (DeepSeek: off/low/high/max)
        // and botB (gpt-5: minimal/low/medium/high, cannot disable) -> `[inheritDefault, low, high]`.
        let roomKey = TeamModel.key(room: room.id)
        let intersected = team.offeredThinkingSelections(in: roomKey, roomId: room.id, fallback: botA)
        XCTAssertEqual(intersected, [.inheritDefault, .effort("low"), .effort("high")])

        // When gathering has conversation-level model override (`options.model != nil`), override wins directly!
        team.setModel("ds/deepseek-flash", in: roomKey)
        let overridden = team.offeredThinkingSelections(in: roomKey, roomId: room.id, fallback: botA)
        XCTAssertEqual(
            overridden,
            [.inheritDefault, .explicitOff, .effort("low"), .effort("high"), .effort("max")]
        )
    }
}
