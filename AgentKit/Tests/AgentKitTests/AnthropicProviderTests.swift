import Foundation
import XCTest
@testable import AgentKit

final class AnthropicProviderTests: XCTestCase {
    private func decodedJSON(_ request: URLRequest) throws -> (body: [String: Any], raw: String) {
        let data = try XCTUnwrap(request.httpBody)
        let raw = try XCTUnwrap(String(data: data, encoding: .utf8))
        let object = try JSONSerialization.jsonObject(with: data)
        let body = try XCTUnwrap(object as? [String: Any])
        return (body, raw)
    }

    func testDirectInitDefaultsAndDynamicBaseURLAndPromptCacheEvaluation() throws {
        let prefix = "你是「小克」。\n\n做事：\n固定规则。"
        let system = prefix + "\n\n现在是 10:00。"
        let tool = ToolSpec(name: "echo", description: "d", parameters: .object(["type": .string("object")]))
        let request = ModelRequest(model: "claude-sonnet-4-6", system: system, messages: [.user("hi")], tools: [tool])

        let officialDefault = AnthropicProvider(apiKey: "fixture-key", stableSystemPrefix: prefix)
        XCTAssertEqual(officialDefault.baseURL, "https://api.anthropic.com")
        XCTAssertNil(officialDefault.promptCache)
        XCTAssertEqual(officialDefault.stableSystemPrefix, prefix)
        let officialBody = try decodedJSON(try officialDefault.urlRequest(request))
        let officialBlocks = try XCTUnwrap(officialBody.body["system"] as? [[String: Any]])
        XCTAssertEqual(officialBlocks.count, 2)
        XCTAssertEqual(officialBlocks[0]["cache_control"] as? [String: String], ["type": "ephemeral"])

        // Mutating baseURL with promptCache == nil re-evaluates Self.caches(baseURL) at request time.
        var dynamicProvider = AnthropicProvider(
            baseURL: "https://relay.example.com/claude",
            apiKey: "fixture-key",
            stableSystemPrefix: prefix
        )
        XCTAssertNil(dynamicProvider.promptCache)
        let relayDefaultDecoded = try decodedJSON(try dynamicProvider.urlRequest(request))
        XCTAssertEqual(relayDefaultDecoded.body["system"] as? String, system)
        XCTAssertFalse(relayDefaultDecoded.raw.contains("cache_control"))

        dynamicProvider.baseURL = "https://api.anthropic.com"
        let switchedOfficial = try decodedJSON(try dynamicProvider.urlRequest(request))
        let switchedBlocks = try XCTUnwrap(switchedOfficial.body["system"] as? [[String: Any]])
        XCTAssertEqual(switchedBlocks.count, 2)
        XCTAssertEqual(switchedBlocks[0]["cache_control"] as? [String: String], ["type": "ephemeral"])

        // Explicit promptCache overrides dynamically regardless of baseURL.
        dynamicProvider.promptCache = false
        let officialDisabled = try decodedJSON(try dynamicProvider.urlRequest(request))
        XCTAssertEqual(officialDisabled.body["system"] as? String, system)
        XCTAssertFalse(officialDisabled.raw.contains("cache_control"))

        dynamicProvider.baseURL = "https://relay.example.com/claude"
        dynamicProvider.promptCache = true
        let relayEnabled = try decodedJSON(try dynamicProvider.urlRequest(request))
        let relayBlocks = try XCTUnwrap(relayEnabled.body["system"] as? [[String: Any]])
        XCTAssertEqual(relayBlocks.count, 2)
        XCTAssertEqual(relayBlocks[0]["cache_control"] as? [String: String], ["type": "ephemeral"])
    }

    func testStablePrefixSplitsSystemIntoCachedPrefixAndUncachedVolatileTail() throws {
        let prefix = "你是「小克」。\n\n你记得的关于用户的事：\n- 喜欢乌龙茶\n\n做事：\n保持真实。"
        let tail1 = "\n\n现在是 2026-11-24 10:00，Asia/Shanghai。\n\n这段对话的工作地点是书案。"
        let tail2 = "\n\n现在是 2026-11-24 11:45，America/Los_Angeles。\n\n前情提要：刚才聊了茶。"
        let tool = ToolSpec(name: "web_search", description: "search", parameters: .object(["type": .string("object")]))
        let call = ToolCall(id: "tu_1", name: "web_search", arguments: #"{"query":"tea"}"#)
        let messages: [Message] = [
            .user("早"),
            .assistant("我查一下", toolCalls: [call]),
            .toolResult("结果", for: call),
            .user("继续"),
        ]

        let provider = AnthropicProvider(
            baseURL: "https://api.anthropic.com",
            apiKey: "fixture-key",
            promptCache: true,
            stableSystemPrefix: prefix
        )

        let req1 = ModelRequest(model: "claude-sonnet-4-6", system: prefix + tail1, messages: messages, tools: [tool])
        let res1 = try decodedJSON(try provider.urlRequest(req1))
        let blocks1 = try XCTUnwrap(res1.body["system"] as? [[String: Any]])
        XCTAssertEqual(blocks1.count, 2)
        XCTAssertEqual(blocks1[0]["type"] as? String, "text")
        XCTAssertEqual(blocks1[0]["text"] as? String, prefix)
        XCTAssertEqual(blocks1[0]["cache_control"] as? [String: String], ["type": "ephemeral"])
        XCTAssertEqual(blocks1[1]["type"] as? String, "text")
        XCTAssertEqual(blocks1[1]["text"] as? String, tail1)
        XCTAssertNil(blocks1[1]["cache_control"])
        let combined1 = blocks1.compactMap { $0["text"] as? String }.joined()
        XCTAssertEqual(combined1, req1.system)

        let req2 = ModelRequest(model: "claude-sonnet-4-6", system: prefix + tail2, messages: messages, tools: [tool])
        let res2 = try decodedJSON(try provider.urlRequest(req2))
        let blocks2 = try XCTUnwrap(res2.body["system"] as? [[String: Any]])
        XCTAssertEqual(blocks2.count, 2)
        XCTAssertEqual(blocks2[0]["text"] as? String, blocks1[0]["text"] as? String)
        XCTAssertEqual(blocks2[0]["cache_control"] as? [String: String], ["type": "ephemeral"])
        XCTAssertEqual(blocks2[1]["text"] as? String, tail2)
        XCTAssertNil(blocks2[1]["cache_control"])
        let combined2 = blocks2.compactMap { $0["text"] as? String }.joined()
        XCTAssertEqual(combined2, req2.system)

        let tools = try XCTUnwrap(res1.body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.last?["cache_control"] as? [String: String], ["type": "ephemeral"])
        let turns = try XCTUnwrap(res1.body["messages"] as? [[String: Any]])
        let lastBlocks = try XCTUnwrap(turns.last?["content"] as? [[String: Any]])
        XCTAssertEqual(lastBlocks.last?["cache_control"] as? [String: String], ["type": "ephemeral"])
    }

    func testPromptCacheToggleControlsBothOfficialAndRelayEndpoints() throws {
        let prefix = "你是「小克」。\n\n做事：\n固定规则。"
        let system = prefix + "\n\n现在是 10:00。"
        let tool = ToolSpec(name: "echo", description: "d", parameters: .object(["type": .string("object")]))
        let call = ToolCall(id: "tu_1", name: "echo", arguments: "{}")
        let request = ModelRequest(
            model: "claude-sonnet-4-6",
            system: system,
            messages: [.user("hi"), .assistant("", toolCalls: [call]), .toolResult("ok", for: call)],
            tools: [tool]
        )

        let relayOn = AnthropicProvider(
            baseURL: "https://relay.example.com/claude",
            apiKey: "fixture-key",
            promptCache: true,
            stableSystemPrefix: prefix
        )
        let relayOnDecoded = try decodedJSON(try relayOn.urlRequest(request))
        let relayBlocks = try XCTUnwrap(relayOnDecoded.body["system"] as? [[String: Any]])
        XCTAssertEqual(relayBlocks.count, 2)
        XCTAssertEqual(relayBlocks[0]["cache_control"] as? [String: String], ["type": "ephemeral"])
        XCTAssertNil(relayBlocks[1]["cache_control"])

        let relayDefault = AnthropicProvider(
            baseURL: "https://relay.example.com/claude",
            apiKey: "fixture-key",
            stableSystemPrefix: prefix
        )
        let relayDefaultDecoded = try decodedJSON(try relayDefault.urlRequest(request))
        XCTAssertEqual(relayDefaultDecoded.body["system"] as? String, system)
        XCTAssertFalse(relayDefaultDecoded.raw.contains("cache_control"))

        for url in ["https://api.anthropic.com", "https://relay.example.com/claude"] {
            let disabled = AnthropicProvider(
                baseURL: url,
                apiKey: "fixture-key",
                promptCache: false,
                stableSystemPrefix: prefix
            )
            let decoded = try decodedJSON(try disabled.urlRequest(request))
            XCTAssertEqual(decoded.body["system"] as? String, system)
            XCTAssertFalse(decoded.raw.contains("cache_control"), "cache_control must be omitted when promptCache is false for \(url)")
            let tools = try XCTUnwrap(decoded.body["tools"] as? [[String: Any]])
            XCTAssertTrue(tools.allSatisfy { $0["cache_control"] == nil })
            let turns = try XCTUnwrap(decoded.body["messages"] as? [[String: Any]])
            for turn in turns {
                let blocks = try XCTUnwrap(turn["content"] as? [[String: Any]])
                XCTAssertTrue(blocks.allSatisfy { $0["cache_control"] == nil })
            }
        }
    }

    func testEmptyOrWhitespaceTailAndWhitespacePrefixFallBackCleanly() throws {
        let prefix = "你是「小克」。\n\n做事：\n规则。"

        let exactProvider = AnthropicProvider(apiKey: "k", promptCache: true, stableSystemPrefix: prefix)
        let exactBody = try decodedJSON(try exactProvider.urlRequest(ModelRequest(model: "claude-sonnet-4-6", system: prefix, messages: [.user("hi")]))).body
        let exactBlocks = try XCTUnwrap(exactBody["system"] as? [[String: Any]])
        XCTAssertEqual(exactBlocks.count, 1)
        XCTAssertEqual(exactBlocks[0]["text"] as? String, prefix)
        XCTAssertEqual(exactBlocks[0]["cache_control"] as? [String: String], ["type": "ephemeral"])

        let wsTailSystem = prefix + "\n\n   "
        let wsTailBody = try decodedJSON(try exactProvider.urlRequest(ModelRequest(model: "claude-sonnet-4-6", system: wsTailSystem, messages: [.user("hi")]))).body
        let wsTailBlocks = try XCTUnwrap(wsTailBody["system"] as? [[String: Any]])
        XCTAssertEqual(wsTailBlocks.count, 1)
        XCTAssertEqual(wsTailBlocks[0]["text"] as? String, wsTailSystem)
        XCTAssertEqual(wsTailBlocks[0]["cache_control"] as? [String: String], ["type": "ephemeral"])

        let wsPrefixProvider = AnthropicProvider(apiKey: "k", promptCache: true, stableSystemPrefix: "   \n ")
        let wsPrefixBody = try decodedJSON(try wsPrefixProvider.urlRequest(ModelRequest(model: "claude-sonnet-4-6", system: wsTailSystem, messages: [.user("hi")]))).body
        let wsPrefixBlocks = try XCTUnwrap(wsPrefixBody["system"] as? [[String: Any]])
        XCTAssertEqual(wsPrefixBlocks.count, 1)
        XCTAssertEqual(wsPrefixBlocks[0]["text"] as? String, wsTailSystem)
    }

    func testPerRequestSystemCachePrefixKeepsSplitActiveAcrossMidTurnRememberAndDeletion() throws {
        let startPrefix = "你是「小克」。\n\n你记得的关于用户的事：\n- 住在上海浦东\n- 喜欢乌龙茶\n\n做事：\n规则。"
        let tail = "\n\n现在是 2026-11-24 10:00，Asia/Shanghai。"
        let afterRememberPrefix = "你是「小克」。\n\n你记得的关于用户的事：\n- 住在上海浦东\n- 喜欢乌龙茶\n- 在写 Swift\n\n做事：\n规则。"
        let afterDeletePrefix = "你是「小克」。\n\n你记得的关于用户的事：\n- 喜欢乌龙茶\n- 在写 Swift\n\n做事：\n规则。"

        let provider = AnthropicProvider(
            baseURL: "https://api.anthropic.com",
            apiKey: "fixture-key",
            promptCache: true,
            stableSystemPrefix: startPrefix
        )

        // 1. Mid-turn `remember` updates both `system` and `systemCachePrefix`: 2-block split stays active with new prefix.
        let rememberedRequest = ModelRequest(
            model: "claude-sonnet-4-6",
            system: afterRememberPrefix + tail,
            messages: [.user("记住我在写 Swift")],
            systemCachePrefix: afterRememberPrefix
        )
        let remembered = try decodedJSON(try provider.urlRequest(rememberedRequest))
        let rememberedBlocks = try XCTUnwrap(remembered.body["system"] as? [[String: Any]])
        XCTAssertEqual(rememberedBlocks.count, 2)
        XCTAssertEqual(rememberedBlocks[0]["text"] as? String, afterRememberPrefix)
        XCTAssertEqual(rememberedBlocks[0]["cache_control"] as? [String: String], ["type": "ephemeral"])
        XCTAssertEqual(rememberedBlocks[1]["text"] as? String, tail)
        XCTAssertNil(rememberedBlocks[1]["cache_control"])

        // 2. Mid-turn deletion updates atomic snapshot: deleted memory disappears while remaining prefix stays split.
        let deletedWithSnapshot = ModelRequest(
            model: "claude-sonnet-4-6",
            system: afterDeletePrefix + tail,
            messages: [.user("删掉上海那条")],
            systemCachePrefix: afterDeletePrefix
        )
        let deleted = try decodedJSON(try provider.urlRequest(deletedWithSnapshot))
        let deletedBlocks = try XCTUnwrap(deleted.body["system"] as? [[String: Any]])
        XCTAssertEqual(deletedBlocks.count, 2)
        XCTAssertEqual(deletedBlocks[0]["text"] as? String, afterDeletePrefix)
        XCTAssertEqual(deletedBlocks[0]["cache_control"] as? [String: String], ["type": "ephemeral"])
        XCTAssertEqual(deletedBlocks[1]["text"] as? String, tail)
        XCTAssertNil(deletedBlocks[1]["cache_control"])
        XCTAssertFalse(deleted.raw.contains("住在上海浦东"), "Deleted memory must not appear in payload")
        XCTAssertTrue(deleted.raw.contains("喜欢乌龙茶"))

        // 3. Even without per-request `systemCachePrefix`, stale `stableSystemPrefix` never leaks deleted memory.
        let deletedWithoutSnapshot = ModelRequest(
            model: "claude-sonnet-4-6",
            system: afterDeletePrefix + tail,
            messages: [.user("再确认一次")]
        )
        let fallback = try decodedJSON(try provider.urlRequest(deletedWithoutSnapshot))
        let fallbackBlocks = try XCTUnwrap(fallback.body["system"] as? [[String: Any]])
        XCTAssertEqual(fallbackBlocks.count, 1)
        XCTAssertEqual(fallbackBlocks[0]["text"] as? String, afterDeletePrefix + tail)
        XCTAssertEqual(fallbackBlocks[0]["cache_control"] as? [String: String], ["type": "ephemeral"])
        XCTAssertFalse(fallback.raw.contains("住在上海浦东"), "Deleted memory must never be re-injected from stableSystemPrefix")
    }
}
