@testable import AgentKit
import Foundation
import XCTest

final class PR2BEngineTests: XCTestCase {
    private final class MockURLProtocol: URLProtocol {
        private static let lock = NSLock()
        nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
        nonisolated(unsafe) static var streamingHandler: ((URLRequest, URLProtocol, URLProtocolClient) -> Void)?
        nonisolated(unsafe) private static var _requests: [URLRequest] = []

        static var requests: [URLRequest] {
            get { lock.withLock { _requests } }
            set { lock.withLock { _requests = newValue } }
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.lock.withLock { Self._requests.append(request) }
            if let streamHandler = Self.streamingHandler, let client {
                streamHandler(request, self, client)
                return
            }
            guard let handler = Self.handler else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            do {
                let (response, data) = try handler(request)
                if (300..<400).contains(response.statusCode),
                   let location = response.value(forHTTPHeaderField: "Location"),
                   let target = URL(string: location, relativeTo: request.url)?.absoluteURL {
                    var redirected = URLRequest(url: target)
                    redirected.httpMethod = request.httpMethod
                    redirected.allHTTPHeaderFields = request.allHTTPHeaderFields
                    client?.urlProtocol(self, wasRedirectedTo: redirected, redirectResponse: response)
                }
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                if !data.isEmpty {
                    client?.urlProtocol(self, didLoad: data)
                }
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    private func makeMockSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: config)
    }

    override func tearDown() {
        MockURLProtocol.handler = nil
        MockURLProtocol.streamingHandler = nil
        MockURLProtocol.requests = []
        super.tearDown()
    }

    // MARK: 1. OpenAIResponsesProvider

    func testResponsesProviderBodyIsStatelessAndProjectsOnlyCompatiblePayloads() throws {
        let contractA = EndpointContractKey(
            origin: "https://api.openai.com/v1",
            protocolKind: "openai_responses",
            route: "/responses",
            modelID: "gpt-5"
        )
        let matchingPayload = ProtocolContinuationPayload(
            origin: "https://api.openai.com/v1",
            protocolKind: "openai_responses",
            route: "/responses",
            modelID: "gpt-5",
            speakerOrThreadID: "bot-a",
            responseItemID: "rs_1",
            wireKind: "responses_reasoning_item",
            blockOrder: 0,
            opaqueData: #"{"id":"rs_1","type":"reasoning","encrypted_content":"enc_abc","summary":[]}"#,
            validScope: "stateless_item"
        )
        let foreignOriginPayload = ProtocolContinuationPayload(
            origin: "https://evil-relay.example.com/v1",
            protocolKind: "openai_responses",
            route: "/responses",
            modelID: "gpt-5",
            speakerOrThreadID: "bot-a",
            responseItemID: "rs_bad",
            wireKind: "responses_reasoning_item",
            blockOrder: 1,
            opaqueData: #"{"id":"rs_bad","type":"reasoning","encrypted_content":"enc_leak","summary":[]}"#,
            validScope: "stateless_item"
        )
        let otherSpeakerPayload = ProtocolContinuationPayload(
            origin: "https://api.openai.com/v1",
            protocolKind: "openai_responses",
            route: "/responses",
            modelID: "gpt-5",
            speakerOrThreadID: "bot-b",
            responseItemID: "rs_other",
            wireKind: "responses_reasoning_item",
            blockOrder: 2,
            opaqueData: #"{"id":"rs_other","type":"reasoning","encrypted_content":"enc_other","summary":[]}"#,
            validScope: "stateless_item"
        )

        var assistant = Message.assistant("working", toolCalls: [ToolCall(id: "fc_1", name: "lookup", arguments: #"{"q":"swift"}"#)], reasoning: "private")
        assistant.continuationPayloads = [matchingPayload, foreignOriginPayload, otherSpeakerPayload]

        let request = ModelRequest(
            model: "gpt-5",
            system: "You are concise.",
            messages: [.user("hi"), assistant, .toolResult("ok", for: ToolCall(id: "fc_1", name: "lookup", arguments: "{}"))],
            tools: [ToolSpec(name: "lookup", description: "Search", parameters: .object(["type": .string("object")]))],
            maxTokens: 4096,
            thinking: .high,
            contractKey: contractA,
            speakerOrThreadID: "bot-a"
        )

        let body = OpenAIResponsesProvider.body(request, contractKey: contractA)
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["max_output_tokens"] as? Int, 4096)
        XCTAssertEqual(body["instructions"] as? String, "You are concise.")
        XCTAssertEqual(body["include"] as? [String], ["reasoning.encrypted_content"])
        let reasoning = try XCTUnwrap(body["reasoning"] as? [String: Any])
        XCTAssertEqual(reasoning["effort"] as? String, "high")

        let input = try XCTUnwrap(body["input"] as? [[String: Any]])
        let reasoningItems = input.filter { ($0["type"] as? String) == "reasoning" }
        XCTAssertEqual(reasoningItems.count, 1)
        XCTAssertEqual(reasoningItems.first?["id"] as? String, "rs_1")
        XCTAssertEqual(reasoningItems.first?["encrypted_content"] as? String, "enc_abc")
        XCTAssertTrue(input.contains { ($0["type"] as? String) == "function_call" && ($0["call_id"] as? String) == "fc_1" })
        XCTAssertTrue(input.contains { ($0["type"] as? String) == "function_call_output" && ($0["call_id"] as? String) == "fc_1" })

        // Verify continuation status flags missing/incompatible payloads cleanly.
        let badStatus = OpenAIResponsesProvider.verifyContinuation(
            [.user("hi"), Message(role: .assistant, text: "", reasoning: "public summary only", toolCalls: [ToolCall(id: "c1", name: "t", arguments: "{}")])],
            contractKey: contractA,
            speakerOrThreadID: "bot-a",
            requiresStatelessReasoning: true
        )
        if case .missingOrIncompatible = badStatus {} else {
            XCTFail("Expected missingOrIncompatible when stateless reasoning payload is missing")
        }
    }

    func testResponsesProviderDecodesSSEAndReportsCatalogWindows() async throws {
        let contract = EndpointContractKey(
            origin: "https://api.openai.com/v1",
            protocolKind: "openai_responses",
            route: "/responses",
            modelID: "gpt-5"
        )
        let decoder = OpenAIResponsesProvider.makeDecoder(contractKey: contract, speakerOrThreadID: "bot-1")

        // Heartbeat / lifecycle events emit zero events.
        XCTAssertEqual(try decoder(#"{"type":"response.in_progress","response":{"id":"resp_1"}}"#), [])
        XCTAssertEqual(try decoder(#"{"type":"response.reasoning_summary_text.delta","delta":"Step 1"}"#), [.reasoning("Step 1")])
        XCTAssertEqual(try decoder(#"{"type":"response.output_text.delta","delta":"Hello"}"#), [.text("Hello")])
        XCTAssertEqual(
            try decoder(#"{"type":"response.output_item.added","output_index":1,"item":{"id":"item_fc","type":"function_call","call_id":"call_9","name":"search"}}"#),
            [.toolCallStart(index: 1, id: "call_9", name: "search")]
        )
        XCTAssertEqual(
            try decoder(#"{"type":"response.function_call_arguments.delta","item_id":"item_fc","output_index":1,"delta":"{\"q\":\"clio\"}"}"#),
            [.toolCallArguments(index: 1, delta: #"{"q":"clio"}"#)]
        )

        let doneReasoning = try decoder(#"{"type":"response.output_item.done","item":{"id":"rs_9","type":"reasoning","encrypted_content":"enc_999","summary":[{"type":"summary_text","text":"Step 1"}]}}"#)
        XCTAssertEqual(doneReasoning.count, 1)
        if case .continuationPayload(let payload) = doneReasoning.first {
            XCTAssertEqual(payload.wireKind, "responses_reasoning_item")
            XCTAssertEqual(payload.responseItemID, "rs_9")
            XCTAssertTrue(payload.isCompatible(with: contract, speakerOrThreadID: "bot-1"))
            XCTAssertFalse(payload.isCompatible(with: contract, speakerOrThreadID: "bot-2"))
        } else {
            XCTFail("Expected continuationPayload event")
        }

        let completed = try decoder(#"{"type":"response.completed","response":{"status":"completed","usage":{"input_tokens":120,"output_tokens":30,"input_tokens_details":{"cached_tokens":80}}}}"#)
        XCTAssertEqual(completed, [.usage(input: 120, output: 30, cached: 80), .finish(reason: "stop")])

        let incomplete = try decoder(#"{"type":"response.incomplete","response":{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"}}}"#)
        XCTAssertEqual(incomplete, [.finish(reason: "length")])

        // CatalogReportingProvider window reporting works without downcasting to OpenAIProvider.
        let session = makeMockSession()
        MockURLProtocol.handler = { req in
            let response = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            let json = #"{"data":[{"id":"gpt-5","context_length":400000},{"id":"gpt-image-1"}]}"#
            return (response, Data(json.utf8))
        }
        let provider = OpenAIResponsesProvider(baseURL: "https://api.openai.com/v1", apiKey: "k", isCodex: true)
        let catalog = try await provider.catalog(session: session)
        XCTAssertEqual(catalog.ids, ["gpt-5", "gpt-image-1"])
        XCTAssertEqual(catalog.windows["gpt-5"], 400_000)

        let probe = await provider.probeCodexImageCapabilities(session: session)
        XCTAssertTrue(probe.supported)
        XCTAssertEqual(probe.supportedModels, ["gpt-image-1"])
    }

    // MARK: 2. OpenAIProvider Bugfix & Header Hygiene

    func testOpenAIProviderDoesNotEchoReasoningWhenStyleDisablesEchoOrContractMismatches() throws {
        let thoughtMsg = Message.assistant("answer", toolCalls: [ToolCall(id: "c1", name: "f", arguments: "{}")], reasoning: "secret thoughts")
        let reqOpenRouter = ModelRequest(
            model: "deepseek/deepseek-r1",
            system: "",
            messages: [.user("q"), thoughtMsg, .toolResult("r", for: ToolCall(id: "c1", name: "f", arguments: "{}"))]
        )
        let orBody = OpenAIProvider.body(reqOpenRouter, style: .openrouter)
        let orMessages = try XCTUnwrap(orBody["messages"] as? [[String: Any]])
        XCTAssertNil(orMessages[1]["reasoning_content"], "echoesReasoning == false must NEVER emit reasoning_content")

        // Contract mismatch blocks replay even on DeepSeek.
        let foreignPayload = ProtocolContinuationPayload(
            origin: "https://other-relay.example.com/v1",
            protocolKind: "openai",
            route: "/chat/completions",
            modelID: "deepseek-v4-pro",
            speakerOrThreadID: "bot-a",
            wireKind: "openai_reasoning_content",
            opaqueData: "foreign-thought"
        )
        var msgWithForeign = Message.assistant("ok", reasoning: "public-thought")
        msgWithForeign.continuationPayloads = [foreignPayload]
        let deepseekContract = EndpointContractKey(
            origin: "https://api.deepseek.com/v1",
            protocolKind: "openai",
            route: "/chat/completions",
            modelID: "deepseek-v4-pro"
        )
        let reqDS = ModelRequest(
            model: "deepseek-v4-pro",
            system: "",
            messages: [.user("q"), msgWithForeign],
            contractKey: deepseekContract,
            speakerOrThreadID: "bot-a"
        )
        let dsBody = OpenAIProvider.body(reqDS, style: .deepseek)
        let dsMessages = try XCTUnwrap(dsBody["messages"] as? [[String: Any]])
        XCTAssertNil(dsMessages[1]["reasoning_content"], "Incompatible contract payload must not fall back to public reasoning")

        // Header sanitizer strips secret/auth/CRLF headers while keeping benign headers.
        var http = URLRequest(url: URL(string: "https://api.example.com/v1/chat/completions")!)
        http.setValue("Bearer real-key", forHTTPHeaderField: "Authorization")
        HTTP.applyNonSecretHeaders([
            "Authorization": "Bearer hijacked",
            "X-API-Key": "leak",
            "X-Custom-Token": "leak",
            "Cookie": "sid=1",
            "X-Injected": "ok\r\nEvil: 1",
            "HTTP-Referer": "https://clio.app",
            "X-Title": "Clio",
        ], to: &http)
        XCTAssertEqual(http.value(forHTTPHeaderField: "Authorization"), "Bearer real-key")
        XCTAssertNil(http.value(forHTTPHeaderField: "X-API-Key"))
        XCTAssertNil(http.value(forHTTPHeaderField: "X-Custom-Token"))
        XCTAssertNil(http.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(http.value(forHTTPHeaderField: "X-Injected"))
        XCTAssertEqual(http.value(forHTTPHeaderField: "HTTP-Referer"), "https://clio.app")
        XCTAssertEqual(http.value(forHTTPHeaderField: "X-Title"), "Clio")
    }

    // MARK: 3. Anthropic Capabilities, 3-Tier 1h Cache Fallback & .auto Signed Thoughts

    func testAnthropicCapabilitiesThreeTierCacheAndOneHourFallback() async throws {
        // Capability-bounded budget never blindly exceeds model cap.
        let cap35 = AnthropicModelCapabilities.resolve(for: "claude-3-5-sonnet-20241022")
        XCTAssertEqual(cap35.thinkingMode, .unsupported)
        XCTAssertEqual(cap35.maxOutputTokensCap, 8192)

        let cap45 = AnthropicModelCapabilities.resolve(for: "claude-sonnet-4-5-20250929")
        XCTAssertEqual(cap45.thinkingMode, .budgeted)
        let budgetBody = AnthropicProvider.body(
            ModelRequest(model: "claude-sonnet-4-5-20250929", system: "sys", messages: [.user("hi")], maxTokens: 64_000, thinking: .max),
            cacheTier: .oneHour
        )
        XCTAssertLessThanOrEqual(try XCTUnwrap(budgetBody["max_tokens"] as? Int), cap45.maxOutputTokensCap)

        // 1h cache control appears across tools, system, and messages.
        let tool = ToolSpec(name: "ping", description: "d", parameters: .object(["type": .string("object")]))
        let oneHourBody = AnthropicProvider.body(
            ModelRequest(model: "claude-sonnet-4-6", system: "sys", messages: [.user("hi")], tools: [tool]),
            cacheTier: .oneHour
        )
        let tools = try XCTUnwrap(oneHourBody["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.last?["cache_control"] as? [String: String], ["type": "ephemeral", "ttl": "1h"])
        let sysBlocks = try XCTUnwrap(oneHourBody["system"] as? [[String: Any]])
        XCTAssertEqual(sysBlocks.first?["cache_control"] as? [String: String], ["type": "ephemeral", "ttl": "1h"])

        // Relay rejecting 1h TTL gracefully downgrades to 5m before output.
        let session = makeMockSession()
        MockURLProtocol.requests = []
        MockURLProtocol.handler = { req in
            let bodyData = req.httpBody ?? Data()
            let bodyText = String(decoding: bodyData, as: UTF8.self)
            if bodyText.contains(#""ttl":"1h""#) {
                let err = HTTPURLResponse(url: req.url!, statusCode: 400, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (err, Data(#"{"error":{"message":"cache_control ttl 1h is not supported on this relay"}}"#.utf8))
            }
            let ok = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!
            let sse = """
            data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"fallback-ok"}}

            data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":5}}

            """
            return (ok, Data(sse.utf8))
        }
        let provider = AnthropicProvider(baseURL: "https://relay.example.com", apiKey: "k", cacheTier: .oneHour)
        var text = ""
        for try await event in provider.stream(ModelRequest(model: "claude-sonnet-4-6", system: "sys", messages: [.user("hi")]), session: session) {
            if case .text(let chunk) = event { text += chunk }
        }
        XCTAssertEqual(text, "fallback-ok")
        XCTAssertEqual(MockURLProtocol.requests.count, 2)
    }

    func testAnthropicPreservesCompatibleSignedThoughtsUnderAutoAndBlocksCrossOrigin() throws {
        let contract = EndpointContractKey(
            origin: "https://api.anthropic.com",
            protocolKind: "anthropic",
            route: "/v1/messages",
            modelID: "claude-sonnet-4-6"
        )
        let validPayload = ProtocolContinuationPayload(
            origin: "https://api.anthropic.com",
            protocolKind: "anthropic",
            route: "/v1/messages",
            modelID: "claude-sonnet-4-6",
            speakerOrThreadID: "bot-a",
            wireKind: "anthropic_thinking",
            blockOrder: 0,
            opaqueData: #"{"signature":"sig_ok","thinking":"deep thought"}"#
        )
        var signedMsg = Message.assistant("answer", reasoning: "deep thought")
        signedMsg.continuationPayloads = [validPayload]

        let autoReq = ModelRequest(
            model: "claude-sonnet-4-6",
            system: "",
            messages: [.user("ask"), signedMsg, .user("next")],
            thinking: .auto,
            contractKey: contract,
            speakerOrThreadID: "bot-a"
        )
        let turns = try XCTUnwrap(AnthropicProvider.body(autoReq, cacheTier: .off)["messages"] as? [[String: Any]])
        let blocks = try XCTUnwrap(turns[1]["content"] as? [[String: Any]])
        XCTAssertEqual(blocks.first?["type"] as? String, "thinking")
        XCTAssertEqual(blocks.first?["signature"] as? String, "sig_ok")

        // Cross-origin request must NOT replay the signed thinking payload.
        let otherContract = EndpointContractKey(
            origin: "https://relay.example.com",
            protocolKind: "anthropic",
            route: "/v1/messages",
            modelID: "claude-sonnet-4-6"
        )
        var foreignReq = autoReq
        foreignReq.contractKey = otherContract
        let foreignTurns = try XCTUnwrap(AnthropicProvider.body(foreignReq, cacheTier: .off)["messages"] as? [[String: Any]])
        let foreignBlocks = try XCTUnwrap(foreignTurns[1]["content"] as? [[String: Any]])
        XCTAssertEqual(foreignBlocks.first?["type"] as? String, "text")
    }

    // MARK: 4. FixedModelRoute Rejects ALL Redirects (Including Same-Origin) & Split Stream Timeouts

    func testFixedRouteRejectsEvenSameOriginRedirectWithZeroBodyDeliveredToTarget() async {
        let session = makeMockSession()
        MockURLProtocol.requests = []
        MockURLProtocol.handler = { req in
            if req.url?.path == "/v1/responses" {
                let redirect = HTTPURLResponse(
                    url: req.url!,
                    statusCode: 307,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Location": "https://api.openai.com/v2/responses"]
                )!
                return (redirect, Data())
            }
            let ok = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (ok, Data())
        }

        let provider = OpenAIResponsesProvider(baseURL: "https://api.openai.com/v1", apiKey: "secret", fixedRoute: true)
        do {
            for try await _ in provider.stream(ModelRequest(model: "gpt-5", system: "", messages: [.user("hi")]), session: session) {}
            XCTFail("Expected 307 redirect to fail when fixedRoute == true")
        } catch let failure as ProviderError {
            XCTAssertEqual(failure.status, 307)
        } catch {
            // Also acceptable if URLSession reports error on refused redirect.
        }
        XCTAssertEqual(MockURLProtocol.requests.map(\.url?.path), ["/v1/responses"])
    }

    func testStreamIdleTimeoutIsImmuneToSSEHeartbeats() async {
        let session = makeMockSession()
        let keepRunning = DispatchSemaphore(value: 0)
        MockURLProtocol.streamingHandler = { req, proto, client in
            let response = HTTPURLResponse(
                url: req.url!,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"]
            )!
            client.urlProtocol(proto, didReceive: response, cacheStoragePolicy: .notAllowed)
            // Send 1 meaningful delta, then spam SSE comments / empty heartbeats while stalling.
            client.urlProtocol(proto, didLoad: Data("data: {\"type\":\"response.output_text.delta\",\"delta\":\"hi\"}\n\n".utf8))
            DispatchQueue.global().async {
                for _ in 0..<8 {
                    Thread.sleep(forTimeInterval: 0.04)
                    client.urlProtocol(proto, didLoad: Data(": keepalive\n\ndata: {\"type\":\"response.in_progress\"}\n\n".utf8))
                }
                keepRunning.signal()
            }
        }

        let provider = OpenAIResponsesProvider(baseURL: "https://api.openai.com/v1", apiKey: "k")
        let req = ModelRequest(
            model: "gpt-5",
            system: "",
            messages: [.user("hi")],
            streamTimeouts: StreamTimeouts(ttfb: 1.0, idle: 0.15, total: 5.0)
        )
        var gotText = ""
        do {
            for try await event in provider.stream(req, session: session) {
                if case .text(let chunk) = event { gotText += chunk }
            }
            XCTFail("Expected heartbeat-immune idle timeout")
        } catch let failure as ProviderError {
            XCTAssertEqual(failure.status, 408)
            XCTAssertTrue(failure.message.contains("静默超时"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(gotText, "hi")
        _ = keepRunning.wait(timeout: .now() + 1.0)
    }

    // MARK: 5. Atomic Units, Extended WholeTurnRetryArbiter (413, Reasoning Tool Regen, explicitOff)

    func testAtomicUnitPreservesNonToolReasoningTurnWhenRequired() {
        let payload = ProtocolContinuationPayload(
            origin: "https://api.deepseek.com/v1",
            protocolKind: "openai",
            route: "/chat/completions",
            modelID: "deepseek-v4-pro",
            wireKind: "openai_reasoning_content",
            opaqueData: "chain-of-thought"
        )
        var reasoned = Message.assistant("first answer", reasoning: "chain-of-thought")
        reasoned.continuationPayloads = [payload]
        let history: [Message] = [
            .user("turn 1"),
            reasoned,
            .user("turn 2"),
        ]
        let units = ProtocolAtomicUnit.group(history, preserveNonToolReasoningTurns: true)
        XCTAssertEqual(units.count, 2)
        XCTAssertEqual(units[0].messages.count, 2)
        XCTAssertEqual(units[0].messages[0].role, .user)
        XCTAssertEqual(units[0].messages[1].role, .assistant)
    }

    func testAgentRetries413WithoutImagesAndRegeneratesSuspectedReasoningToolCallOnce() async throws {
        final class ScriptedProvider: ModelProvider, @unchecked Sendable {
            let lock = NSLock()
            var steps: [([StreamEvent], ProviderError?)]
            var seenRequests: [ModelRequest] = []

            init(_ steps: [([StreamEvent], ProviderError?)]) { self.steps = steps }

            func stream(_ request: ModelRequest) -> AsyncThrowingStream<StreamEvent, Error> {
                let (index, step): (Int, ([StreamEvent], ProviderError?)?) = lock.withLock {
                    let i = seenRequests.count
                    seenRequests.append(request)
                    return (i, i < steps.count ? steps[i] : nil)
                }
                return AsyncThrowingStream { continuation in
                    guard let step else {
                        continuation.finish(throwing: ProviderError("unexpected step \(index)"))
                        return
                    }
                    for ev in step.0 { continuation.yield(ev) }
                    continuation.finish(throwing: step.1)
                }
            }

            func models() async throws -> [String] { [] }
        }

        // Case A: 413 image reduction preserves missing-image semantics.
        let img = ImagePart(mediaType: "image/png", data: Data(repeating: 0xAA, count: 64))
        let p413 = ScriptedProvider([
            ([], ProviderError(status: 413, "Request Entity Too Large")),
            ([.text("文字作答"), .finish(reason: "stop")], nil),
        ])
        var agent413 = Agent(provider: p413, model: "m", system: "")
        agent413.retryDelays = [0]
        try await agent413.run(history: [.user("看看这张图", images: [img])]) { _ in }
        XCTAssertEqual(p413.seenRequests.count, 2)
        XCTAssertEqual(p413.seenRequests[0].messages[0].images.count, 1)
        XCTAssertTrue(p413.seenRequests[1].messages[0].images.isEmpty)
        XCTAssertTrue(p413.seenRequests[1].messages[0].text.contains("已省略"))

        // Case B: Suspected tool-call JSON trapped in reasoning triggers 1x structured regen.
        struct EchoTool: AgentTool {
            var spec: ToolSpec { ToolSpec(name: "echo", description: "", parameters: .object(["type": .string("object")])) }
            var isReadOnlySafe: Bool { true }
            func label(for arguments: JSONValue) -> String { "echo" }
            func run(_ arguments: JSONValue) async throws -> ToolOutput { ToolOutput("echoed") }
        }
        let pRegen = ScriptedProvider([
            ([.reasoning(#"I should call <tool_call>{"name":"echo","arguments":{}}</tool_call>"#), .finish(reason: "stop")], nil),
            ([.toolCallStart(index: 0, id: "call_1", name: "echo"), .toolCallArguments(index: 0, delta: "{}"), .finish(reason: "tool_calls")], nil),
            ([.text("done"), .finish(reason: "stop")], nil),
        ])
        let agentRegen = Agent(provider: pRegen, model: "m", system: "", tools: [EchoTool()])
        try await agentRegen.run(history: [.user("run echo")]) { _ in }
        XCTAssertEqual(pRegen.seenRequests.count, 3)

        // Case C: Non-thinking 400 (signature error) does NOT downgrade thinking.
        XCTAssertFalse(WholeTurnRetryArbiter.isThinkingParameterRejection(ProviderError(status: 400, "Invalid signature in thinking block")))
        XCTAssertFalse(WholeTurnRetryArbiter.isThinkingParameterRejection(ProviderError(status: 400, "unexpected tool_use_id")))
        XCTAssertTrue(WholeTurnRetryArbiter.isThinkingParameterRejection(ProviderError(status: 400, "reasoning_effort is not supported")))
    }

    // MARK: 6. DeferredMCPTools (>25 Threshold, Built-in Always Resident, Dual Live Permission & Generation Re-Check)

    func testDeferredMCPToolsThresholdAndLiveRevocationAtHelpAndInvoke() async throws {
        struct StubTool: AgentTool {
            let name: String
            var isReadOnlySafe: Bool { true }
            var spec: ToolSpec { ToolSpec(name: name, description: "Tool \(name)", parameters: .object(["type": .string("object")])) }
            func label(for arguments: JSONValue) -> String { name }
            func run(_ arguments: JSONValue) async throws -> ToolOutput { ToolOutput("ran:\(name)") }
        }

        final class PolicyBox: @unchecked Sendable {
            private let lock = NSLock()
            var generation: UInt64 = 1
            var allowed: Set<String> = ["srv_1"]
            func currentGen() -> UInt64 { lock.withLock { generation } }
            func isPermitted(_ serverID: String, _ stableID: String) -> Bool { lock.withLock { allowed.contains(serverID) } }
            func revoke(_ serverID: String) { lock.withLock { _ = allowed.remove(serverID) } }
            func bumpGen() { lock.withLock { generation += 1 } }
        }

        let builtIns: [AgentTool] = [StubTool(name: "web_search"), StubTool(name: "remember")]
        let box = PolicyBox()
        let policy = DeferredMCPTools.Policy(
            connectorGeneration: 1,
            currentGeneration: { box.currentGen() },
            isPermitted: { box.isPermitted($0, $1) }
        )

        // <= 25 MCP tools: exposed directly alongside built-ins.
        let smallEntries = (1...25).map { idx in
            DeferredMCPTools.Entry(stableID: "mcp_srv_\(idx)", serverID: "srv_1", serverName: "Srv", tool: StubTool(name: "mcp_srv_\(idx)"))
        }
        let smallAssembled = DeferredMCPTools.assemble(builtInTools: builtIns, mcpEntries: smallEntries, policy: policy)
        XCTAssertEqual(smallAssembled.count, 27)
        XCTAssertFalse(smallAssembled.contains { $0.spec.name == "tool_search" })

        // > 25 MCP tools: built-ins 100% resident, MCP tools behind search/help/invoke.
        let largeEntries = (1...26).map { idx in
            DeferredMCPTools.Entry(stableID: "mcp_srv_\(idx)", serverID: "srv_1", serverName: "Srv", tool: StubTool(name: "mcp_srv_\(idx)"))
        }
        let largeAssembled = DeferredMCPTools.assemble(builtInTools: builtIns, mcpEntries: largeEntries, policy: policy)
        let names = largeAssembled.map(\.spec.name)
        XCTAssertTrue(names.contains("web_search"))
        XCTAssertTrue(names.contains("remember"))
        XCTAssertTrue(names.contains("tool_search"))
        XCTAssertTrue(names.contains("tool_help"))
        XCTAssertTrue(names.contains("tool_invoke"))
        XCTAssertEqual(largeAssembled.count, 5)

        let search = try XCTUnwrap(largeAssembled.first { $0.spec.name == "tool_search" })
        let help = try XCTUnwrap(largeAssembled.first { $0.spec.name == "tool_help" })
        let invoke = try XCTUnwrap(largeAssembled.first { $0.spec.name == "tool_invoke" })

        let searchOut = try await search.run(.object(["query": .string("mcp_srv_26")]))
        XCTAssertFalse(searchOut.isError)
        XCTAssertTrue(searchOut.text.contains("mcp_srv_26"))

        let helpOut = try await help.run(.object(["tool": .string("mcp_srv_26")]))
        XCTAssertFalse(helpOut.isError)
        XCTAssertTrue(helpOut.text.contains("参数 Schema"))

        let invokeOut = try await invoke.run(.object(["tool": .string("mcp_srv_26"), "arguments": .object([:])]))
        XCTAssertFalse(invokeOut.isError)
        XCTAssertEqual(invokeOut.text, "ran:mcp_srv_26")

        // Revoking connector permission immediately blocks BOTH tool_help AND tool_invoke.
        box.revoke("srv_1")
        let revokedHelp = try await help.run(.object(["tool": .string("mcp_srv_26")]))
        XCTAssertTrue(revokedHelp.isError)
        let revokedInvoke = try await invoke.run(.object(["tool": .string("mcp_srv_26"), "arguments": .object([:])]))
        XCTAssertTrue(revokedInvoke.isError)

        // Bumping connector generation invalidates stale deferred wrappers even if re-permitted.
        box.bumpGen()
        let staleSearch = try await search.run(.object(["query": .string("mcp_srv_26")]))
        XCTAssertTrue(staleSearch.isError)
    }
}
