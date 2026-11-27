import XCTest
@testable import AgentKit

final class ThinkingRuleResolverTests: XCTestCase {
    private func makeFixtureSnapshot() throws -> ModelsDevCatalogSnapshot {
        let json: [String: Any] = [
            "schemaVersion": 2,
            "upstream": "https://models.dev/api.json",
            "generatedAt": "2026-11-27T00:00:00Z",
            "services": [
                "deepseek": [
                    "models": [
                        "deepseek-flash": [
                            "reasoning": true,
                            "reasoning_options": [
                                ["type": "toggle"],
                                ["type": "effort", "values": ["low", "high", "max"]],
                            ],
                            "interleaved": ["field": "reasoning_content"],
                            "tool_call": true,
                            "attachment": true,
                            "modalities": ["input": ["text", "image"]],
                            "limit": ["context": 1_048_576, "output": 393_216],
                        ],
                        "deepseek-v4-pro": [
                            "reasoning": true,
                            "reasoning_options": [
                                ["type": "toggle"],
                                ["type": "effort", "values": ["low", "high", "max"]],
                            ],
                            "interleaved": ["field": "reasoning_content"],
                            "tool_call": true,
                            "attachment": false,
                            "modalities": ["input": ["text"]],
                            "limit": ["context": 1_048_576, "output": 393_216],
                        ],
                    ],
                ],
                "openai": [
                    "models": [
                        "gpt-5": [
                            "reasoning": true,
                            "reasoning_options": [
                                ["type": "effort", "values": ["minimal", "low", "medium", "high"]],
                            ],
                            "tool_call": true,
                            "modalities": ["input": ["text", "image"]],
                            "limit": ["context": 400_000, "output": 128_000],
                        ],
                        "gpt-5.2": [
                            "reasoning": true,
                            "reasoning_options": [
                                ["type": "effort", "values": ["none", "low", "medium", "high", "xhigh"]],
                            ],
                            "tool_call": true,
                            "modalities": ["input": ["text", "image"]],
                            "limit": ["context": 400_000, "output": 128_000],
                        ],
                        "gpt-4o": [
                            "reasoning": false,
                            "tool_call": true,
                            "modalities": ["input": ["text", "image"]],
                            "limit": ["context": 128_000, "output": 16_384],
                        ],
                    ],
                ],
                "anthropic": [
                    "models": [
                        "claude-opus-4-6": [
                            "reasoning": true,
                            "reasoning_options": [
                                ["type": "toggle"],
                                ["type": "effort", "values": ["low", "medium", "high", "max"]],
                                ["type": "budget_tokens", "min": 1024],
                            ],
                            "tool_call": true,
                            "modalities": ["input": ["text", "image", "pdf"]],
                            "limit": ["context": 1_000_000, "output": 128_000],
                        ],
                        "claude-opus-5-5": [
                            "reasoning": true,
                            "reasoning_options": [
                                ["type": "effort", "values": ["low", "medium", "high", "xhigh", "max"]],
                            ],
                            "tool_call": true,
                            "modalities": ["input": ["text", "image", "pdf"]],
                            "limit": ["context": 1_000_000, "output": 128_000],
                        ],
                        "claude-sonnet-4-5": [
                            "reasoning": true,
                            "reasoning_options": [
                                ["type": "toggle"],
                                ["type": "budget_tokens", "min": 1024],
                            ],
                            "tool_call": true,
                            "modalities": ["input": ["text", "image", "pdf"]],
                            "limit": ["context": 200_000, "output": 64_000],
                        ],
                    ],
                ],
                "openrouter": [
                    "models": [
                        "aion-labs/aion-3.5": [
                            "reasoning": true,
                            "reasoning_options": [
                                ["type": "effort", "values": ["low", "high", "max"]],
                            ],
                            "tool_call": true,
                            "modalities": ["input": ["text"]],
                            "limit": ["context": 262_144, "output": 32_768],
                        ],
                        "deepseek/deepseek-flash": [
                            "reasoning": true,
                            "reasoning_options": [
                                ["type": "toggle"],
                                ["type": "effort", "values": ["low", "high", "max"]],
                            ],
                            "interleaved": ["field": "reasoning_content"],
                            "tool_call": true,
                            "modalities": ["input": ["text", "image"]],
                            "limit": ["context": 1_048_576, "output": 393_216],
                        ],
                    ],
                ],
                "alibaba-cn": [
                    "models": [
                        "qwen3-235b": [
                            "reasoning": true,
                            "reasoning_options": [
                                ["type": "toggle"],
                                ["type": "budget_tokens", "min": 1024],
                            ],
                            "interleaved": ["field": "reasoning_content"],
                            "tool_call": true,
                            "modalities": ["input": ["text"]],
                            "limit": ["context": 131_072, "output": 16_384],
                        ],
                        "deepseek-v4-flash-0731": [
                            "reasoning": true,
                            "reasoning_options": [
                                ["type": "toggle"],
                                ["type": "effort", "values": ["low", "high", "max"]],
                            ],
                            "interleaved": ["field": "reasoning_content"],
                            "tool_call": true,
                            "modalities": ["input": ["text"]],
                            "limit": ["context": 1_000_000, "output": 384_000],
                        ],
                    ],
                ],
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let policy = ModelsDevCatalogSnapshot.ValidationPolicy(
            maxBytes: 1_000_000,
            minProviders: 3,
            maxProviders: 50,
            minModels: 5,
            maxModels: 500,
            minReasoningOptionsModels: 5,
            minInterleavedModels: 3,
            minValidModelFieldRatio: 0.7
        )
        return try ModelsDevCatalogSnapshot.parseAndValidate(data: data, generation: 7, policy: policy)
    }

    func testStrictValidationBoundaryRejectsCapabilityDegradationAndBadSchema() throws {
        var services: [String: Any] = [:]
        for p in 0..<12 {
            var models: [String: Any] = [:]
            for m in 0..<12 {
                // Structurally valid JSON, but `reasoning_options` and `interleaved` stripped completely.
                models["model-\(p)-\(m)"] = [
                    "reasoning": true,
                    "tool_call": true,
                    "modalities": ["input": ["text"]],
                    "limit": ["context": 128_000, "output": 8192],
                ]
            }
            services["provider-\(p)"] = ["models": models]
        }
        let degraded = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 2,
            "services": services,
        ])
        XCTAssertThrowsError(try ModelsDevCatalogSnapshot.parseAndValidate(data: degraded)) { error in
            guard case CatalogValidationError.capabilityDegradation(let ro, let il) = error else {
                return XCTFail("Expected capabilityDegradation, got \(error)")
            }
            XCTAssertEqual(ro, 0)
            XCTAssertEqual(il, 0)
        }

        let futureSchema = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 99,
            "services": services,
        ])
        XCTAssertThrowsError(try ModelsDevCatalogSnapshot.parseAndValidate(data: futureSchema)) { error in
            XCTAssertEqual(error as? CatalogValidationError, .unsupportedSchemaVersion(99))
        }

        let tinyPolicy = ModelsDevCatalogSnapshot.ValidationPolicy(maxBytes: 16)
        XCTAssertThrowsError(try ModelsDevCatalogSnapshot.parseAndValidate(data: degraded, policy: tinyPolicy)) { error in
            guard case CatalogValidationError.oversize = error else {
                return XCTFail("Expected oversize, got \(error)")
            }
        }
    }

    func testDeepSeekOfficialContractAndLegacyArchiveCompat() throws {
        let snapshot = try makeFixtureSnapshot()
        for model in ["deepseek-flash", "deepseek-v4-pro", "deepseek-reasoner"] {
            let key = EndpointContractKey(
                origin: "https://api.deepseek.com",
                protocolKind: "openai",
                route: "/chat/completions",
                modelID: model
            )
            let contract = ThinkingRuleResolver.contract(for: key, style: .deepseek, snapshot: snapshot)
            XCTAssertTrue(contract.isConfirmedOfficialOrigin)
            XCTAssertTrue(contract.isKnownContract)
            XCTAssertTrue(contract.canExplicitlyDisable)
            XCTAssertEqual(contract.interleavedField, "reasoning_content")
            XCTAssertEqual(
                contract.offeredSelections,
                [.inheritDefault, .explicitOff, .effort("low"), .effort("high"), .effort("max")]
            )

            let offRes = ThinkingRuleResolver.resolve(selection: .explicitOff, contract: contract, style: .deepseek)
            XCTAssertEqual(offRes.fulfillment, .fulfilled(effective: .explicitOff, migratedFrom: nil, note: nil))
            XCTAssertEqual(offRes.bodyFields["thinking"], .object(["type": .string("disabled")]))
            XCTAssertNil(offRes.bodyFields["reasoning_effort"])

            // Legacy `.medium` and `xhigh` both migrate cleanly to `high` on confirmed DeepSeek official contract.
            let medRes = ThinkingRuleResolver.resolve(selection: .effort("medium"), contract: contract, style: .deepseek)
            guard case .fulfilled(let effMed, let fromMed, _) = medRes.fulfillment else {
                return XCTFail("Expected fulfilled migration for medium on \(model)")
            }
            XCTAssertEqual(effMed, .effort("high"))
            XCTAssertEqual(fromMed, .effort("medium"))
            XCTAssertEqual(medRes.bodyFields["reasoning_effort"], .string("high"))

            let xhighRes = ThinkingRuleResolver.resolve(selection: .effort("xhigh"), contract: contract, style: .deepseek)
            guard case .fulfilled(let effXH, _, _) = xhighRes.fulfillment else {
                return XCTFail("Expected fulfilled migration for xhigh on \(model)")
            }
            XCTAssertEqual(effXH, .effort("high"))
        }
    }

    func testOpenAIFidelityAndExplicitOffDistinction() throws {
        let snapshot = try makeFixtureSnapshot()
        let gpt5Key = EndpointContractKey(
            origin: "https://api.openai.com",
            protocolKind: "openai",
            route: "/v1/chat/completions",
            modelID: "gpt-5"
        )
        let gpt5Contract = ThinkingRuleResolver.contract(for: gpt5Key, style: .effort, snapshot: snapshot)
        XCTAssertFalse(gpt5Contract.canExplicitlyDisable, "gpt-5 has minimal..high without none/toggle")
        XCTAssertEqual(
            gpt5Contract.offeredSelections,
            [.inheritDefault, .effort("minimal"), .effort("low"), .effort("medium"), .effort("high")]
        )
        let gpt5Off = ThinkingRuleResolver.resolve(selection: .explicitOff, contract: gpt5Contract, style: .effort)
        guard case .unfulfilledExplicitOff = gpt5Off.fulfillment else {
            return XCTFail("gpt-5 must block explicitOff locally rather than omitting fields")
        }
        XCTAssertTrue(gpt5Off.bodyFields.isEmpty)

        // Internal low-latency intent omits safely instead of blocking.
        let gpt5LowLatency = ThinkingRuleResolver.resolve(
            selection: .explicitOff,
            contract: gpt5Contract,
            style: .effort,
            intent: .preferLowLatency
        )
        XCTAssertEqual(gpt5LowLatency.fulfillment, .fulfilled(effective: .inheritDefault, migratedFrom: nil, note: nil))

        let gpt52Key = EndpointContractKey(
            origin: "https://api.openai.com",
            protocolKind: "openai",
            route: "/v1/chat/completions",
            modelID: "gpt-5.2"
        )
        let gpt52Contract = ThinkingRuleResolver.contract(for: gpt52Key, style: .effort, snapshot: snapshot)
        XCTAssertTrue(gpt52Contract.canExplicitlyDisable, "gpt-5.2 declares `none` effort")
        XCTAssertTrue(gpt52Contract.offeredSelections.contains(.effort("xhigh")))
        let gpt52XHigh = ThinkingRuleResolver.resolve(selection: .effort("xhigh"), contract: gpt52Contract, style: .effort)
        XCTAssertEqual(gpt52XHigh.bodyFields["reasoning_effort"], .string("xhigh"))
        let gpt52Off = ThinkingRuleResolver.resolve(selection: .explicitOff, contract: gpt52Contract, style: .effort)
        XCTAssertEqual(gpt52Off.bodyFields["reasoning_effort"], .string("none"))
    }

    func testAlibabaBailianNeverEmitsConflictingEffortAndBudget() throws {
        let snapshot = try makeFixtureSnapshot()
        let qwenKey = EndpointContractKey(
            origin: "https://dashscope.aliyuncs.com",
            protocolKind: "openai",
            route: "/compatible-mode/v1/chat/completions",
            modelID: "qwen3-235b"
        )
        let qwenContract = ThinkingRuleResolver.contract(for: qwenKey, style: .qwen, snapshot: snapshot)
        let qwenRes = ThinkingRuleResolver.resolve(selection: .effort("high"), contract: qwenContract, style: .qwen)
        XCTAssertEqual(qwenRes.bodyFields["enable_thinking"], .bool(true))
        XCTAssertNotNil(qwenRes.bodyFields["thinking_budget"])
        XCTAssertNil(qwenRes.bodyFields["reasoning_effort"], "Bailian must never send both reasoning_effort and thinking_budget")

        let dsBailianKey = EndpointContractKey(
            origin: "https://dashscope.aliyuncs.com",
            protocolKind: "openai",
            route: "/compatible-mode/v1/chat/completions",
            modelID: "deepseek-v4-flash-0731"
        )
        let dsContract = ThinkingRuleResolver.contract(for: dsBailianKey, style: .qwen, snapshot: snapshot)
        let dsRes = ThinkingRuleResolver.resolve(selection: .effort("high"), contract: dsContract, style: .qwen)
        XCTAssertEqual(dsRes.bodyFields["enable_thinking"], .bool(true))
        XCTAssertEqual(dsRes.bodyFields["reasoning_effort"], .string("high"))
        XCTAssertNil(dsRes.bodyFields["thinking_budget"], "Bailian must never send both reasoning_effort and thinking_budget")
    }

    func testOpenRouterPerModelToggleVsEffortOnly() throws {
        let snapshot = try makeFixtureSnapshot()
        let nonToggleKey = EndpointContractKey(
            origin: "https://openrouter.ai",
            protocolKind: "openai",
            route: "/api/v1/chat/completions",
            modelID: "aion-labs/aion-3.5"
        )
        let nonToggle = ThinkingRuleResolver.contract(for: nonToggleKey, style: .openrouter, snapshot: snapshot)
        XCTAssertFalse(nonToggle.canExplicitlyDisable)
        XCTAssertEqual(nonToggle.offeredSelections, [.inheritDefault, .effort("low"), .effort("high"), .effort("max")])

        let toggleKey = EndpointContractKey(
            origin: "https://openrouter.ai",
            protocolKind: "openai",
            route: "/api/v1/chat/completions",
            modelID: "deepseek/deepseek-flash"
        )
        let toggleable = ThinkingRuleResolver.contract(for: toggleKey, style: .openrouter, snapshot: snapshot)
        XCTAssertTrue(toggleable.canExplicitlyDisable)
        let offRes = ThinkingRuleResolver.resolve(selection: .explicitOff, contract: toggleable, style: .openrouter)
        XCTAssertEqual(offRes.bodyFields["reasoning"], .object(["enabled": .bool(false)]))
    }

    func testUnknownRelayNeverSmugglesExplicitOffAndManualRuleRequiresExactContractMatch() throws {
        let snapshot = try makeFixtureSnapshot()
        let relayKey = EndpointContractKey(
            origin: "https://my-relay.example.com",
            protocolKind: "openai",
            route: "/v1/chat/completions",
            modelID: "deepseek-flash"
        )
        let relayContract = ThinkingRuleResolver.contract(for: relayKey, style: .deepseek, snapshot: snapshot)
        XCTAssertFalse(relayContract.isConfirmedOfficialOrigin)
        XCTAssertFalse(relayContract.isKnownContract)
        XCTAssertFalse(relayContract.canExplicitlyDisable)
        XCTAssertEqual(relayContract.matchResult.confidence, .bareHint)

        let offRes = ThinkingRuleResolver.resolve(selection: .explicitOff, contract: relayContract, style: .deepseek)
        guard case .unfulfilledExplicitOff = offRes.fulfillment else {
            return XCTFail("Unknown relay must never silently pass explicitOff by omitting fields")
        }

        // Validated manual rule matching the exact contract enables explicitOff.
        let manual = ManualThinkingRule(
            contract: relayKey,
            canDisable: true,
            supportedEfforts: ["low", "high"],
            wireStyle: .deepseek
        )
        let confirmedRelay = ThinkingRuleResolver.contract(
            for: relayKey,
            style: .deepseek,
            manualRule: manual,
            snapshot: snapshot
        )
        XCTAssertTrue(confirmedRelay.isKnownContract)
        XCTAssertTrue(confirmedRelay.canExplicitlyDisable)

        // Changing origin invalidates the manual rule.
        let movedKey = EndpointContractKey(
            origin: "https://other-relay.example.com",
            protocolKind: "openai",
            route: "/v1/chat/completions",
            modelID: "deepseek-flash"
        )
        let movedContract = ThinkingRuleResolver.contract(
            for: movedKey,
            style: .deepseek,
            manualRule: manual,
            snapshot: snapshot
        )
        XCTAssertFalse(movedContract.isKnownContract)
        XCTAssertFalse(movedContract.canExplicitlyDisable)
    }

    func testThinkingSelectionV2ReadWriteOrderAndTolerantDecoding() throws {
        // Locked read order: v2 takes precedence over legacy.
        XCTAssertEqual(
            ThinkingSelection.readEffective(v2: .effort("xhigh"), legacy: .low),
            .effort("xhigh")
        )
        XCTAssertEqual(
            ThinkingSelection.readEffective(v2: nil, legacy: .high),
            .effort("high")
        )

        // Locked write order: non-expressible `minimal` / `xhigh` / `explicitOn` do NOT write wrong legacy mirror.
        let xhighPair = ThinkingSelection.writePair(.effort("xhigh"))
        XCTAssertEqual(xhighPair.v2, .effort("xhigh"))
        XCTAssertNil(xhighPair.legacy)

        let minimalPair = ThinkingSelection.writePair(.effort("minimal"))
        XCTAssertEqual(minimalPair.v2, .effort("minimal"))
        XCTAssertNil(minimalPair.legacy)

        let highPair = ThinkingSelection.writePair(.effort("high"))
        XCTAssertEqual(highPair.v2, .effort("high"))
        XCTAssertEqual(highPair.legacy, .high)

        let defaultPair = ThinkingSelection.writePair(.inheritDefault)
        XCTAssertNil(defaultPair.v2)
        XCTAssertNil(defaultPair.legacy)

        // Tolerant decoding of future unknown selection JSON never throws.
        let futureJSON = Data(#"{"version":9,"kind":"adaptive_beam","value":"ultra","budget":4096,"extra":true}"#.utf8)
        let decoded = try JSONDecoder().decode(ThinkingSelection.self, from: futureJSON)
        XCTAssertEqual(decoded, .unknown(kind: "adaptive_beam", value: "ultra", budget: 4096))
    }

    func testGatheringOfferingsIntersection() throws {
        let snapshot = try makeFixtureSnapshot()
        let dsContract = ThinkingRuleResolver.contract(
            for: EndpointContractKey(
                origin: "https://api.deepseek.com",
                protocolKind: "openai",
                route: "/chat/completions",
                modelID: "deepseek-flash"
            ),
            style: .deepseek,
            snapshot: snapshot
        )
        let gpt5Contract = ThinkingRuleResolver.contract(
            for: EndpointContractKey(
                origin: "https://api.openai.com",
                protocolKind: "openai",
                route: "/v1/chat/completions",
                modelID: "gpt-5"
            ),
            style: .effort,
            snapshot: snapshot
        )
        let intersected = ThinkingRuleResolver.intersectOfferings([dsContract, gpt5Contract])
        XCTAssertEqual(intersected, [.inheritDefault, .effort("low"), .effort("high")])
    }

    func testResolvedBodyFieldsReachOpenAIWireBodyWithoutLossyDowngrade() throws {
        let snapshot = try makeFixtureSnapshot()

        // gpt-5 `minimal` stays `"minimal"` on the wire (never downgraded to `"low"`).
        let gpt5Contract = ThinkingRuleResolver.contract(
            for: EndpointContractKey(
                origin: "https://api.openai.com",
                protocolKind: "openai",
                route: "/v1/chat/completions",
                modelID: "gpt-5"
            ),
            style: .effort,
            snapshot: snapshot
        )
        let minRes = ThinkingRuleResolver.resolve(selection: .effort("minimal"), contract: gpt5Contract, style: .effort)
        let minReq = ModelRequest(
            model: "gpt-5",
            system: "",
            messages: [.user("hi")],
            thinking: .low,
            thinkingBodyFields: minRes.bodyFields
        )
        let minBody = OpenAIProvider.body(minReq, style: .effort)
        XCTAssertEqual(minBody["reasoning_effort"] as? String, "minimal")

        // gpt-5.2 `xhigh` stays `"xhigh"` on the wire (never downgraded to `"high"`).
        let gpt52Contract = ThinkingRuleResolver.contract(
            for: EndpointContractKey(
                origin: "https://api.openai.com",
                protocolKind: "openai",
                route: "/v1/chat/completions",
                modelID: "gpt-5.2"
            ),
            style: .effort,
            snapshot: snapshot
        )
        let xhRes = ThinkingRuleResolver.resolve(selection: .effort("xhigh"), contract: gpt52Contract, style: .effort)
        let xhReq = ModelRequest(
            model: "gpt-5.2",
            system: "",
            messages: [.user("hi")],
            thinking: .high,
            thinkingBodyFields: xhRes.bodyFields
        )
        let xhBody = OpenAIProvider.body(xhReq, style: .effort)
        XCTAssertEqual(xhBody["reasoning_effort"] as? String, "xhigh")

        // Bailian effort model sends `reasoning_effort` without `thinking_budget` on actual wire body.
        let dsBailianContract = ThinkingRuleResolver.contract(
            for: EndpointContractKey(
                origin: "https://dashscope.aliyuncs.com",
                protocolKind: "openai",
                route: "/compatible-mode/v1/chat/completions",
                modelID: "deepseek-v4-flash-0731"
            ),
            style: .qwen,
            snapshot: snapshot
        )
        let bailianRes = ThinkingRuleResolver.resolve(selection: .effort("high"), contract: dsBailianContract, style: .qwen)
        let bailianReq = ModelRequest(
            model: "deepseek-v4-flash-0731",
            system: "",
            messages: [.user("hi")],
            thinking: .high,
            thinkingBodyFields: bailianRes.bodyFields
        )
        let bailianBody = OpenAIProvider.body(bailianReq, style: .qwen)
        XCTAssertEqual(bailianBody["enable_thinking"] as? Bool, true)
        XCTAssertEqual(bailianBody["reasoning_effort"] as? String, "high")
        XCTAssertNil(bailianBody["thinking_budget"])
    }

    func testUnlistedOfficialModelDoesNotClaimDisableAndManualRuleToleratesUnknownWireStyle() throws {
        let snapshot = try makeFixtureSnapshot()

        // Unlisted model on OpenRouter must NOT gain `canExplicitlyDisable` from generic `.openrouter.canStop`.
        let unlistedKey = EndpointContractKey(
            origin: "https://openrouter.ai",
            protocolKind: "openai",
            route: "/api/v1/chat/completions",
            modelID: "vendor/unlisted-thinking-model"
        )
        let unlistedContract = ThinkingRuleResolver.contract(for: unlistedKey, style: .openrouter, snapshot: snapshot)
        XCTAssertFalse(unlistedContract.isKnownContract)
        XCTAssertFalse(unlistedContract.canExplicitlyDisable)
        let offAttempt = ThinkingRuleResolver.resolve(selection: .explicitOff, contract: unlistedContract, style: .openrouter)
        guard case .unfulfilledExplicitOff = offAttempt.fulfillment else {
            return XCTFail("Unlisted OpenRouter model must reject explicitOff without model-level evidence")
        }

        // ManualThinkingRule with future unknown `wireStyle` decodes tolerantly, preserves raw string, and stays inactive.
        let rawRuleJSON = Data("""
        {
          "contract": {
            "origin": "https://relay.example.com",
            "protocolKind": "openai",
            "route": "/v1/chat/completions",
            "modelID": "demo"
          },
          "canDisable": true,
          "supportedEfforts": ["low", "high"],
          "wireStyle": "future_style_v9",
          "ruleGeneration": 2
        }
        """.utf8)
        let decoded = try JSONDecoder().decode(ManualThinkingRule.self, from: rawRuleJSON)
        XCTAssertNil(decoded.wireStyle)
        XCTAssertEqual(decoded.unknownWireStyleRaw, "future_style_v9")
        XCTAssertTrue(decoded.isDisabledByUnknownStyle)
        XCTAssertFalse(decoded.isValid(for: decoded.contract))
        let reencoded = try JSONEncoder().encode(decoded)
        let roundTrip = try JSONDecoder().decode(ManualThinkingRule.self, from: reencoded)
        XCTAssertEqual(roundTrip.unknownWireStyleRaw, "future_style_v9")
    }

    func testEmptyOptionsAndRelativeDegradationAreRejectedByCatalogValidator() throws {
        // Empty `reasoning_options: [{}]` and empty `limit: {}` must NOT satisfy validation thresholds.
        var emptyFieldsServices: [String: Any] = [:]
        for p in 0..<12 {
            var models: [String: Any] = [:]
            for m in 0..<10 {
                models["m-\(p)-\(m)"] = [
                    "modalities": [:],
                    "limit": [:],
                    "reasoning_options": [[:]],
                ]
            }
            emptyFieldsServices["p-\(p)"] = ["models": models]
        }
        let emptyPayload = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 2,
            "services": emptyFieldsServices,
        ])
        XCTAssertThrowsError(try ModelsDevCatalogSnapshot.parseAndValidate(data: emptyPayload)) { error in
            guard case CatalogValidationError.missingRequiredFields = error else {
                return XCTFail("Expected missingRequiredFields for empty limit/modalities, got \(error)")
            }
        }

        // Relative degradation: when previous healthy snapshot had 100 reasoning_options and 60 interleaved,
        // a refresh dropping to 25 reasoning_options and 12 interleaved must be rejected even though above absolute floor.
        var prevEntries: [String: [String: CatalogModelEntry]] = [:]
        var modelsMap: [String: CatalogModelEntry] = [:]
        for i in 0..<100 {
            modelsMap["m-\(i)"] = CatalogModelEntry(
                rawModelID: "m-\(i)",
                catalogProviderKey: "p0",
                canonicalModelID: "m-\(i)",
                normalizedAliases: ["m-\(i)"],
                sees: false,
                tools: true,
                reasoning: true,
                reasoningMode: .effortSet,
                canToggleOff: true,
                supportedEfforts: ["low", "high"],
                interleavedField: i < 60 ? "reasoning_content" : nil,
                contextWindow: 128_000,
                outputLimit: 8192
            )
        }
        prevEntries["p0"] = modelsMap
        let healthyPrevious = ModelsDevCatalogSnapshot(generation: 1, entriesByProvider: prevEntries)

        var degradedServices: [String: Any] = [:]
        var idx = 0
        for p in 0..<12 {
            var models: [String: Any] = [:]
            for m in 0..<10 {
                var item: [String: Any] = [
                    "reasoning": true,
                    "tool_call": true,
                    "modalities": ["input": ["text"]],
                    "limit": ["context": 128_000, "output": 8192],
                ]
                if idx < 25 {
                    item["reasoning_options"] = [["type": "toggle"]]
                }
                if idx < 12 {
                    item["interleaved"] = ["field": "reasoning_content"]
                }
                models["m-\(p)-\(m)"] = item
                idx += 1
            }
            degradedServices["svc-\(p)"] = ["models": models]
        }
        let relativeDegraded = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 2,
            "services": degradedServices,
        ])
        XCTAssertThrowsError(
            try ModelsDevCatalogSnapshot.parseAndValidate(data: relativeDegraded, previous: healthyPrevious)
        ) { error in
            guard case CatalogValidationError.capabilityDegradation = error else {
                return XCTFail("Expected relative capabilityDegradation, got \(error)")
            }
        }
    }

    func testCustomRelayEmitsWireFieldsForOfferedEffortsWhileStillBlockingExplicitOff() throws {
        let snapshot = try makeFixtureSnapshot()
        let relayKey = EndpointContractKey(
            origin: "https://my-relay.example.com",
            protocolKind: "openai",
            route: "/v1/chat/completions",
            modelID: "deepseek-flash"
        )
        // Custom relay with nil explicit style still offers non-off hint efforts from catalog match.
        let relayContract = ThinkingRuleResolver.contract(for: relayKey, style: nil, snapshot: snapshot)
        XCTAssertFalse(relayContract.isKnownContract)
        XCTAssertFalse(relayContract.canExplicitlyDisable)
        XCTAssertEqual(
            relayContract.offeredSelections,
            [.inheritDefault, .effort("low"), .effort("high"), .effort("max")]
        )

        // Selecting an offered effort on the relay MUST compile real wire fields (never an empty dict).
        let highRes = ThinkingRuleResolver.resolve(selection: .effort("high"), contract: relayContract, style: .deepseek)
        guard case .fulfilled(let eff, _, _) = highRes.fulfillment else {
            return XCTFail("Expected fulfilled high effort on relay, got \(highRes.fulfillment)")
        }
        XCTAssertEqual(eff, .effort("high"))
        XCTAssertEqual(highRes.bodyFields["reasoning_effort"], .string("high"))
        XCTAssertEqual(highRes.bodyFields["thinking"], .object(["type": .string("enabled")]))

        let wireReq = ModelRequest(
            model: "deepseek-flash",
            system: "",
            messages: [.user("hi")],
            thinking: .high,
            thinkingBodyFields: highRes.bodyFields
        )
        let wireBody = OpenAIProvider.body(wireReq, style: .deepseek)
        XCTAssertEqual(wireBody["reasoning_effort"] as? String, "high")

        // Explicit OFF on unconfirmed relay MUST remain blocked with empty bodyFields.
        let offRes = ThinkingRuleResolver.resolve(selection: .explicitOff, contract: relayContract, style: .deepseek)
        guard case .unfulfilledExplicitOff = offRes.fulfillment else {
            return XCTFail("Expected unfulfilledExplicitOff on unconfirmed relay")
        }
        XCTAssertTrue(offRes.bodyFields.isEmpty)

        // Explicit ThinkingStyle.none ("不设置") on relay MUST NOT offer hint efforts or allow explicitOff even via manual rule.
        let noneContract = ThinkingRuleResolver.contract(for: relayKey, style: ThinkingStyle.none, snapshot: snapshot)
        XCTAssertEqual(noneContract.offeredSelections, [.inheritDefault])
        let bogusManual = ManualThinkingRule(
            contract: relayKey,
            canDisable: true,
            supportedEfforts: ["low", "high"],
            wireStyle: ThinkingStyle.none
        )
        let noneManualContract = ThinkingRuleResolver.contract(
            for: relayKey,
            style: ThinkingStyle.none,
            manualRule: bogusManual,
            snapshot: snapshot
        )
        XCTAssertFalse(noneManualContract.canExplicitlyDisable)
        XCTAssertEqual(noneManualContract.offeredSelections, [.inheritDefault])
        let noneOff = ThinkingRuleResolver.resolve(selection: .explicitOff, contract: noneManualContract, style: ThinkingStyle.none)
        guard case .unfulfilledExplicitOff = noneOff.fulfillment else {
            return XCTFail("ThinkingStyle.none must never pass explicitOff preflight")
        }
        XCTAssertTrue(noneOff.bodyFields.isEmpty)
    }

    func testIntersectOfferingsIsOrderInvariantAcrossPermutations() throws {
        let snapshot = try makeFixtureSnapshot()
        let dsContract = ThinkingRuleResolver.contract(
            for: EndpointContractKey(
                origin: "https://api.deepseek.com",
                protocolKind: "openai",
                route: "/chat/completions",
                modelID: "deepseek-flash"
            ),
            style: .deepseek,
            snapshot: snapshot
        )
        let gpt5Contract = ThinkingRuleResolver.contract(
            for: EndpointContractKey(
                origin: "https://api.openai.com",
                protocolKind: "openai",
                route: "/v1/chat/completions",
                modelID: "gpt-5"
            ),
            style: .effort,
            snapshot: snapshot
        )
        let claudeContract = ThinkingRuleResolver.contract(
            for: EndpointContractKey(
                origin: "https://api.anthropic.com",
                protocolKind: "anthropic",
                route: "/v1/messages",
                modelID: "claude-opus-4-6"
            ),
            style: nil,
            snapshot: snapshot
        )

        // Reversing [ds, gpt5] -> [gpt5, ds] MUST produce identical intersection without leaking DeepSeek alias `medium`.
        let forward = ThinkingRuleResolver.intersectOfferings([dsContract, gpt5Contract])
        let reverse = ThinkingRuleResolver.intersectOfferings([gpt5Contract, dsContract])
        XCTAssertEqual(forward, [.inheritDefault, .effort("low"), .effort("high")])
        XCTAssertEqual(reverse, forward)

        // All 6 permutations of 3 heterogeneous contracts must match identically.
        let permutations: [[ThinkingRuleResolver.ConfirmedContract]] = [
            [dsContract, gpt5Contract, claudeContract],
            [dsContract, claudeContract, gpt5Contract],
            [gpt5Contract, dsContract, claudeContract],
            [gpt5Contract, claudeContract, dsContract],
            [claudeContract, dsContract, gpt5Contract],
            [claudeContract, gpt5Contract, dsContract],
        ]
        for perm in permutations {
            XCTAssertEqual(
                ThinkingRuleResolver.intersectOfferings(perm),
                [.inheritDefault, .effort("low"), .effort("high")]
            )
        }
    }
}
