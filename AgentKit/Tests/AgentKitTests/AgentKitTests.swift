import XCTest
@testable import AgentKit

final class ProviderTests: XCTestCase {
    func testSSEPayload() {
        XCTAssertEqual(SSE.payload(of: "data: {\"a\":1}"), "{\"a\":1}")
        XCTAssertEqual(SSE.payload(of: "data:{\"a\":1}"), "{\"a\":1}")
        XCTAssertNil(SSE.payload(of: "event: ping"))
        XCTAssertNil(SSE.payload(of: ": keep-alive"))
    }

    func testOpenAIDecodesTextReasoningAndUsage() throws {
        XCTAssertEqual(try OpenAIProvider.decode(#"{"choices":[{"index":0,"delta":{"content":"你好"},"finish_reason":null}]}"#), [.text("你好")])
        XCTAssertEqual(try OpenAIProvider.decode(#"{"choices":[{"delta":{"reasoning_content":"想一想","content":null}}]}"#), [.reasoning("想一想")])
        XCTAssertEqual(try OpenAIProvider.decode(#"{"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":12,"completion_tokens":3}}"#), [.finish(reason: "stop"), .usage(input: 12, output: 3)])
        XCTAssertEqual(try OpenAIProvider.decode(#"{"choices":[],"usage":null}"#), [])
    }

    func testOpenAIDecodesToolCalls() throws {
        XCTAssertEqual(
            try OpenAIProvider.decode(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"web_search","arguments":""}}]}}]}"#),
            [.toolCallStart(index: 0, id: "call_1", name: "web_search")]
        )
        XCTAssertEqual(
            try OpenAIProvider.decode(#"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"query\":"}}]}}]}"#),
            [.toolCallArguments(index: 0, delta: "{\"query\":")]
        )
    }

    func testOpenAIReplyImagesFromMessageAndDelta() throws {
        let chat = #"{"choices":[{"message":{"content":[{"type":"text","text":"第一张"},{"type":"image_url","image_url":{"url":"data:image/png;base64,AQID"}}],"images":[{"image_url":"https://cdn.example/out.png"}]}}]}"#
        let inline = ReplyImage.embedded(ImagePart(mediaType: "image/png", data: Data([1, 2, 3])))
        let remote = ReplyImage.remote(try XCTUnwrap(URL(string: "https://cdn.example/out.png")))
        XCTAssertEqual(try OpenAIProvider.decode(chat), [.text("第一张"), .image(inline), .image(remote)])
        let delta = #"{"choices":[{"delta":{"images":[{"b64_json":"AQID"},{"url":"file:///tmp/out.png"}]}}]}"#
        XCTAssertEqual(try OpenAIProvider.decode(delta), [.image(inline)])
    }

    func testOpenAIKeepsChunkedDataURLsOutOfVisibleText() {
        var splitter = ReplyImageText()
        let chunks = ["图片：!", "[预览](", "data:im", "age/png;base", "64,AQI", "D)\n", "完成", " data:image/webp;base64,BAUG"]
        var events = chunks.flatMap { splitter.feed($0) }
        events += splitter.flush()
        let text = events.compactMap { if case .text(let piece) = $0 { return piece } else { return nil } }.joined()
        let images = events.compactMap { if case .image(let image) = $0 { return image } else { return nil } }
        XCTAssertEqual(text, "图片：\n完成 ")
        XCTAssertEqual(images, [
            .embedded(ImagePart(mediaType: "image/png", data: Data([1, 2, 3]))),
            .embedded(ImagePart(mediaType: "image/webp", data: Data([4, 5, 6]))),
        ])
    }

    func testOrdinaryMarkdownRemainsText() {
        var splitter = ReplyImageText()
        var events = splitter.feed("原文！ ![封面](") + splitter.feed("https://example.com/pic.png) 和 d")
        events += splitter.flush()
        XCTAssertEqual(events.compactMap { if case .text(let piece) = $0 { return piece } else { return nil } }.joined(),
                       "原文！ ![封面](https://example.com/pic.png) 和 d")
    }

    func testOpenAIErrorInStream() {
        XCTAssertThrowsError(try OpenAIProvider.decode(#"{"error":{"message":"bad"}}"#))
    }

    func testOpenAIBody() throws {
        let call = ToolCall(id: "c1", name: "web_search", arguments: "{\"query\":\"x\"}")
        let request = ModelRequest(
            model: "deepseek-chat",
            system: "你是助手",
            messages: [
                .user("早"),
                .assistant("早上好", reasoning: "旧的想法"),
                .user("搜一下", images: [ImagePart(data: Data([1, 2, 3]))]),
                .assistant("", toolCalls: [call], reasoning: "要搜"),
                .toolResult("结果", for: call),
            ],
            tools: [WebSearchTool().spec]
        )
        // A service that does not keep thoughts gets them back only inside the running turn.
        let plain = try XCTUnwrap(OpenAIProvider.body(request, style: .gemini)["messages"] as? [[String: Any]])
        XCTAssertNil(plain[2]["reasoning_content"])
        XCTAssertEqual(plain[4]["reasoning_content"] as? String, "要搜")
        // DeepSeek wants every earlier thought back once tools are in play.
        let body = OpenAIProvider.body(request, style: .deepseek)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 6)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[2]["reasoning_content"] as? String, "旧的想法")
        XCTAssertEqual(messages[4]["reasoning_content"] as? String, "要搜")
        XCTAssertNil(body["thinking"], "nothing about thinking unless asked")
        let parts = try XCTUnwrap(messages[3]["content"] as? [[String: Any]])
        XCTAssertEqual(parts.first?["type"] as? String, "image_url")
        XCTAssertEqual(((parts.first?["image_url"] as? [String: Any])?["url"] as? String), "data:image/jpeg;base64,AQID")
        let calls = try XCTUnwrap(messages[4]["tool_calls"] as? [[String: Any]])
        XCTAssertEqual((calls[0]["function"] as? [String: Any])?["name"] as? String, "web_search")
        XCTAssertEqual(messages[5]["role"] as? String, "tool")
        XCTAssertEqual(messages[5]["tool_call_id"] as? String, "c1")
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.count, 1)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: body))
    }

    func testAnthropicDecode() throws {
        XCTAssertEqual(try AnthropicProvider.decode(#"{"type":"message_start","message":{"usage":{"input_tokens":20,"output_tokens":1}}}"#), [.usage(input: 20, output: 0)])
        XCTAssertEqual(try AnthropicProvider.decode(#"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"web_read","input":{}}}"#), [.toolCallStart(index: 1, id: "toolu_1", name: "web_read")])
        XCTAssertEqual(try AnthropicProvider.decode(#"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"url\""}}"#), [.toolCallArguments(index: 1, delta: "{\"url\"")])
        XCTAssertEqual(try AnthropicProvider.decode(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"嗨"}}"#), [.text("嗨")])
        XCTAssertEqual(try AnthropicProvider.decode(#"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":9}}"#), [.usage(input: 0, output: 9), .finish(reason: "tool_use")])
        XCTAssertEqual(try AnthropicProvider.decode(#"{"type":"ping"}"#), [])
        XCTAssertThrowsError(try AnthropicProvider.decode(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#))
    }

    func testAnthropicBodyMergesToolResultsIntoUserTurns() throws {
        let first = ToolCall(id: "t1", name: "a", arguments: "{\"x\":1}")
        let second = ToolCall(id: "t2", name: "b", arguments: "")
        let request = ModelRequest(model: "claude", system: "sys", messages: [
            .user("hi"),
            .assistant("ok", toolCalls: [first, second]),
            .toolResult("one", for: first),
            .toolResult("", for: second, isError: true),
            .user("再来"),
        ])
        let body = AnthropicProvider.body(request)
        XCTAssertEqual(body["system"] as? String, "sys")
        let turns = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(turns.map { $0["role"] as? String }, ["user", "assistant", "user"])
        let assistant = try XCTUnwrap(turns[1]["content"] as? [[String: Any]])
        XCTAssertEqual(assistant.map { $0["type"] as? String }, ["text", "tool_use", "tool_use"])
        XCTAssertEqual((assistant[1]["input"] as? [String: Any])?["x"] as? Int, 1)
        XCTAssertNotNil(assistant[2]["input"] as? [String: Any])
        let results = try XCTUnwrap(turns[2]["content"] as? [[String: Any]])
        XCTAssertEqual(results.map { $0["type"] as? String }, ["tool_result", "tool_result", "text"])
        XCTAssertEqual(results[1]["is_error"] as? Bool, true)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: body))
    }

    func testAnthropicPromptCachingMarksOnlyAnthropicItself() throws {
        XCTAssertTrue(AnthropicProvider.caches("https://api.anthropic.com"))
        XCTAssertFalse(AnthropicProvider.caches("https://api.moonshot.cn/anthropic"))
        let tool = ToolSpec(name: "t", description: "d", parameters: .object(["type": .string("object")]))
        let request = ModelRequest(model: "claude-sonnet-4-5", system: "sys", messages: [.user("hi")], tools: [tool])
        let plain = AnthropicProvider.body(request)
        XCTAssertEqual(plain["system"] as? String, "sys")
        let cached = AnthropicProvider.body(request, cache: true)
        let system = try XCTUnwrap(cached["system"] as? [[String: Any]])
        XCTAssertNotNil(system.first?["cache_control"])
        let tools = try XCTUnwrap(cached["tools"] as? [[String: Any]])
        XCTAssertNotNil(tools.last?["cache_control"])
        let turns = try XCTUnwrap(cached["messages"] as? [[String: Any]])
        let blocks = try XCTUnwrap(turns.last?["content"] as? [[String: Any]])
        XCTAssertNotNil(blocks.last?["cache_control"])
    }

    func testProviderErrorMessage() {
        let error = HTTP.failure(status: 401, data: Data(#"{"error":{"message":"Authentication Fails"}}"#.utf8))
        XCTAssertEqual(error, ProviderError(status: 401, "Authentication Fails"))
        XCTAssertTrue(error.localizedDescription.contains("密钥"))
    }

    func testEndpointJoin() throws {
        XCTAssertEqual(try HTTP.endpoint("https://api.deepseek.com/", "/chat/completions").absoluteString, "https://api.deepseek.com/chat/completions")
        XCTAssertThrowsError(try HTTP.endpoint("api.deepseek.com", "/models"))
    }
}

/// A model that answers from a script, one reply per request.
private final class ScriptedProvider: ModelProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [[StreamEvent]]
    private(set) var requests: [ModelRequest] = []

    init(_ replies: [[StreamEvent]]) { self.replies = replies }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        lock.lock()
        requests.append(request)
        let reply = replies.isEmpty ? [StreamEvent.text("（没了）")] : replies.removeFirst()
        lock.unlock()
        return AsyncThrowingStream { continuation in
            for event in reply { continuation.yield(event) }
            // A scripted reply ends the way a service's does, saying it is done, unless it already said why.
            if !reply.contains(where: { if case .finish = $0 { return true }; return false }) {
                continuation.yield(.finish(reason: "stop"))
            }
            continuation.finish()
        }
    }

    func models() async throws -> [String] { ["scripted"] }
}

private struct EchoTool: AgentTool {
    var asks = false
    var spec: ToolSpec { ToolSpec(name: "echo", description: "", parameters: ["type": "object"]) }
    func label(for arguments: JSONValue) -> String { "回声：\(arguments["say"]?.string ?? "")" }
    func approval(for arguments: JSONValue) -> ApprovalAsk? { asks ? ApprovalAsk(title: "回声", reason: "要说话") : nil }
    func run(_ arguments: JSONValue) async throws -> ToolOutput { ToolOutput("你说了 \(arguments["say"]?.string ?? "")") }
}

private actor Recorder {
    var events: [AgentEvent] = []
    func add(_ event: AgentEvent) { events.append(event) }
}

final class AgentTests: XCTestCase {
    func testRunsToolThenAnswers() async throws {
        let provider = ScriptedProvider([
            [.text("我查一下"), .toolCallStart(index: 0, id: "c1", name: "echo"), .toolCallArguments(index: 0, delta: "{\"say\":"), .toolCallArguments(index: 0, delta: "\"嗨\"}"), .finish(reason: "tool_calls")],
            [.text("好了"), .finish(reason: "stop")],
        ])
        let recorder = Recorder()
        let agent = Agent(provider: provider, model: "m", system: "s", tools: [EchoTool()])
        try await agent.run(history: [.user("说嗨")]) { await recorder.add($0) }
        let events = await recorder.events
        let messages = events.compactMap { event -> Message? in if case .message(let message) = event { return message } else { return nil } }
        XCTAssertEqual(messages.map(\.role), [.assistant, .tool, .assistant])
        XCTAssertEqual(messages[0].toolCalls, [ToolCall(id: "c1", name: "echo", arguments: "{\"say\":\"嗨\"}")])
        XCTAssertEqual(messages[1].text, "你说了 嗨")
        XCTAssertEqual(messages[2].text, "好了")
        XCTAssertTrue(events.contains(.toolStarted(id: "c1", name: "echo", label: "回声：嗨")))
        XCTAssertTrue(events.contains(.toolFinished(id: "c1", ok: true)))
        XCTAssertEqual(provider.requests.count, 2)
        XCTAssertEqual(provider.requests[1].messages.count, 3)
    }

    func testNativeImageOnlyReplyGetsStoredOnceAndEmitted() async throws {
        let image = ReplyImage.embedded(ImagePart(mediaType: "image/png", data: Data([1, 2, 3])))
        let provider = ScriptedProvider([[.image(image), .image(image), .finish(reason: "stop")]])
        let recorder = Recorder()
        var agent = Agent(provider: provider, model: "m", system: "")
        agent.renderReplyImages = { images in
            XCTAssertEqual(images, [image])
            return "![](书案/图片/first.png)"
        }
        try await agent.run(history: [.user("一张图")]) { await recorder.add($0) }
        let events = await recorder.events
        XCTAssertEqual(events, [.message(.assistant("![](书案/图片/first.png)"))])
    }

    func testNativeImageLinkIsAppendedAfterReplyText() async throws {
        let image = ReplyImage.embedded(ImagePart(mediaType: "image/png", data: Data([1, 2, 3])))
        let provider = ScriptedProvider([[.text("画好了"), .image(image), .finish(reason: "stop")]])
        let recorder = Recorder()
        var agent = Agent(provider: provider, model: "m", system: "")
        agent.renderReplyImages = { _ in "![](书案/图片/first.png)" }
        try await agent.run(history: [.user("一张图")]) { await recorder.add($0) }
        let events = await recorder.events
        XCTAssertEqual(events, [.text("画好了"), .message(.assistant("画好了\n\n![](书案/图片/first.png)"))])
    }

    func testDeclinedApprovalDoesNotRun() async throws {
        let provider = ScriptedProvider([
            [.toolCallStart(index: 0, id: "c1", name: "echo"), .toolCallArguments(index: 0, delta: "{}")],
            [.text("好的，不做了")],
        ])
        let recorder = Recorder()
        let agent = Agent(provider: provider, model: "m", system: "", tools: [EchoTool(asks: true)]) { _, _ in false }
        try await agent.run(history: [.user("说")]) { await recorder.add($0) }
        let results = await recorder.events.compactMap { event -> Message? in
            if case .message(let message) = event, message.role == .tool { return message } else { return nil }
        }
        XCTAssertEqual(results.count, 1)
        XCTAssertTrue(results[0].isError)
        XCTAssertTrue(results[0].text.contains("没有同意"))
    }

    func testBadArgumentsAndUnknownTool() async throws {
        let provider = ScriptedProvider([
            [.toolCallStart(index: 0, id: "a", name: "echo"), .toolCallArguments(index: 0, delta: "{not json"),
             .toolCallStart(index: 1, id: "b", name: "nope"), .toolCallArguments(index: 1, delta: "{}")],
            [.text("抱歉")],
        ])
        let recorder = Recorder()
        try await Agent(provider: provider, model: "m", system: "", tools: [EchoTool()]).run(history: [.user("x")]) { await recorder.add($0) }
        let results = await recorder.events.compactMap { event -> Message? in
            if case .message(let message) = event, message.role == .tool { return message } else { return nil }
        }
        XCTAssertEqual(results.map(\.isError), [true, true])
    }
}

final class WebTextTests: XCTestCase {
    func testSearchFallsBackWhenMainlandBingReturnsUnrelatedPages() async throws {
        let tool = WebSearchTool { url in
            switch url.host {
            case "www.bing.com":
                return "<html></html>"
            case "cn.bing.com":
                return """
                <li class="b_algo"><h2><a href="https://tax.example.org">陕西省电子税务局</a></h2><p>申报查询</p></li>
                """
            default:
                return """
                <div class="result__body"><a class="result__a" href="https://weather.example.org">重庆周末天气预报</a>
                <a class="result__snippet">重庆周六有小雨</a></div>
                """
            }
        }
        let output = try await tool.run(.object(["query": .string("重庆 周六 天气")]))
        XCTAssertTrue(output.text.contains("DuckDuckGo"))
        XCTAssertTrue(output.text.contains("重庆周末天气预报"))
        XCTAssertFalse(output.text.contains("陕西省电子税务局"))
    }

    func testSearchKeepsOnlyRelevantResultsFromTheChosenSource() async throws {
        let tool = WebSearchTool { _ in
            """
            <li class="b_algo"><h2><a href="https://weather.example.org">重庆天气预报</a></h2><p>未来七天</p></li>
            <li class="b_algo"><h2><a href="https://other.example.org">成都天气预报</a></h2><p>未来七天</p></li>
            """
        }
        let output = try await tool.run(.object(["query": .string("重庆 天气")]))
        XCTAssertTrue(output.text.contains("Bing 国际站"))
        XCTAssertTrue(output.text.contains("重庆天气预报"))
        XCTAssertFalse(output.text.contains("成都天气预报"))
    }

    func testSearchExplainsWhenOnlyUnrelatedResultsWereFound() async throws {
        let tool = WebSearchTool { _ in
            """
            <li class="b_algo"><h2><a href="https://ad.example.org">陌陌推广</a></h2><p>推广活动</p></li>
            """
        }
        let output = try await tool.run(.object(["query": .string("苏州博物馆 开放时间")]))
        XCTAssertTrue(output.text.contains("没有找到与搜索词足够相关的结果"))
        XCTAssertFalse(output.text.contains("陌陌"))
        XCTAssertFalse(output.isError)
    }

    func testPageText() {
        let html = """
        <html><head><title>天气 &amp; 预报</title><style>p{}</style></head>
        <body><nav>菜单</nav><h1>重庆</h1><p>今天 <b>晴</b>，18&#8451;。</p><script>var x=1</script>
        <ul><li>早上 12 度</li><li>下午 20 度</li></ul><footer>版权</footer></body></html>
        """
        let page = WebText.page(html)
        XCTAssertEqual(page.title, "天气 & 预报")
        XCTAssertEqual(page.text, "重庆\n\n今天 晴，18℃。\n\n• 早上 12 度\n• 下午 20 度")
    }

    func testBingResults() {
        let html = """
        <ol id="b_results"><li class="b_algo" data-x="1"><h2><a href="https://www.bing.com/ck/a?!&amp;&amp;p=abc&amp;u=a1aHR0cHM6Ly9leGFtcGxlLmNvbS9hP2I9MQ&amp;ntb=1" h="ID=1">示例 <strong>标题</strong></a></h2>
        <div class="b_caption"><p class="b_lineclamp2">这是&nbsp;摘要</p></div></li>
        <li class="b_algo"><h2><a href="https://direct.example.org/x">直接链接</a></h2><p>第二条</p></li></ol>
        """
        let results = WebText.bingResults(html)
        XCTAssertEqual(results, [
            WebText.Result(title: "示例 标题", url: "https://example.com/a?b=1", snippet: "这是 摘要"),
            WebText.Result(title: "直接链接", url: "https://direct.example.org/x", snippet: "第二条"),
        ])
    }

    func testDuckResults() {
        let html = """
        <div class="result__body"><a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fp&amp;rut=1">鸭子</a>
        <a class="result__snippet" href="x">一段 <b>摘要</b></a></div>
        """
        XCTAssertEqual(WebText.duckResults(html), [WebText.Result(title: "鸭子", url: "https://example.com/p", snippet: "一段 摘要")])
    }

    func testDecodesGBK() {
        let gbk = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        let data = "<meta charset=\"gbk\"><p>你好</p>".data(using: gbk)!
        XCTAssertTrue(WebText.decode(data, encodingName: nil).contains("你好"))
        XCTAssertTrue(WebText.decode(data, encodingName: "GBK").contains("你好"))
    }

    func testJSONValue() {
        let value = JSONValue.parse(#"{"a":[1,true,"x",null],"b":{"c":2.5}}"#)
        XCTAssertEqual(value?["a"]?.array?.count, 4)
        XCTAssertEqual(value?["a"]?.array?[1], .bool(true))
        XCTAssertEqual(value?["b"]?["c"]?.number, 2.5)
        XCTAssertEqual(JSONValue.parse(value!.compact), value)
    }
}

final class CachedUsageTests: XCTestCase {
    func testDeepSeekAndOpenAIReportCacheHits() throws {
        XCTAssertEqual(try OpenAIProvider.decode(#"{"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":5,"prompt_cache_hit_tokens":64}}"#), [.usage(input: 100, output: 5, cached: 64)])
        XCTAssertEqual(try OpenAIProvider.decode(#"{"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":5,"prompt_tokens_details":{"cached_tokens":32}}}"#), [.usage(input: 100, output: 5, cached: 32)])
    }

    func testClaudeCountsCacheReadsAndWritesAsInput() throws {
        XCTAssertEqual(try AnthropicProvider.decode(#"{"type":"message_start","message":{"usage":{"input_tokens":20,"cache_read_input_tokens":300,"cache_creation_input_tokens":10,"output_tokens":1}}}"#), [.usage(input: 330, output: 0, cached: 300)])
    }
}

final class LocalAddressTests: XCTestCase {
    private func local(_ address: String) -> Bool { LocalAddress.isLocal(URL(string: address)!) }

    func testLocalAndPrivateAddressesAreRefused() {
        for address in ["http://localhost:8080", "http://127.0.0.1", "http://10.0.0.5/admin", "http://192.168.1.1", "http://172.20.3.4",
                        "http://169.254.169.254/latest", "http://100.100.1.1", "http://0.0.0.0", "http://[::1]:3000", "http://[fe80::1]",
                        "http://[fd12::3]", "http://printer.local", "http://router.lan", "http://nas", "http://2130706433", "http://0x7f.1",
                        "http://[::ffff:192.168.0.1]"] {
            XCTAssertTrue(local(address), address)
        }
    }

    func testPublicAddressesPass() {
        for address in ["https://example.com", "https://www.deepseek.com/a?b=1", "http://8.8.8.8", "http://172.32.0.1", "http://100.128.0.1",
                        "https://[2606:4700::1111]", "https://bbs.nga.cn", "https://cafe.example"] {
            XCTAssertFalse(local(address), address)
        }
    }
}

/// Fails the first `failures` requests the way a dropped connection does, then answers.
private final class FlakyProvider: ModelProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var failures: Int
    private let error: Error
    private(set) var calls = 0

    init(failures: Int, error: Error) {
        self.failures = failures
        self.error = error
    }

    func stream(_ request: ModelRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        lock.lock()
        calls += 1
        let fail = failures > 0
        if fail { failures -= 1 }
        lock.unlock()
        let error = self.error
        return AsyncThrowingStream { continuation in
            if fail {
                continuation.finish(throwing: error)
            } else {
                continuation.yield(.text("到了"))
                continuation.yield(.finish(reason: "stop"))
                continuation.finish()
            }
        }
    }

    func models() async throws -> [String] { [] }
}

final class RetryTests: XCTestCase {
    func testADroppedConnectionIsTriedAgain() async throws {
        let provider = FlakyProvider(failures: 2, error: URLError(.secureConnectionFailed))
        var agent = Agent(provider: provider, model: "m", system: "")
        agent.retryDelays = [0, 0]
        let recorder = Recorder()
        try await agent.run(history: [.user("在吗")]) { await recorder.add($0) }
        let events = await recorder.events
        XCTAssertEqual(provider.calls, 3)
        XCTAssertTrue(events.contains(.retrying(attempt: 1)))
        XCTAssertTrue(events.contains(.retrying(attempt: 2)))
        XCTAssertTrue(events.contains(.message(.assistant("到了"))))
    }

    func testGivesUpAfterTheLastTry() async {
        let provider = FlakyProvider(failures: 5, error: URLError(.timedOut))
        var agent = Agent(provider: provider, model: "m", system: "")
        agent.retryDelays = [0, 0]
        do {
            try await agent.run(history: [.user("在吗")]) { _ in }
            XCTFail("should fail")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .timedOut)
        }
        XCTAssertEqual(provider.calls, 3)
    }

    func testAWrongKeyIsNotTriedAgain() async {
        let provider = FlakyProvider(failures: 1, error: ProviderError(status: 401, "bad key"))
        var agent = Agent(provider: provider, model: "m", system: "")
        agent.retryDelays = [0, 0]
        do {
            try await agent.run(history: [.user("在吗")]) { _ in }
            XCTFail("should fail")
        } catch {}
        XCTAssertEqual(provider.calls, 1)
    }
}

final class ThinkingTests: XCTestCase {
    private func request(_ thinking: Thinking, model: String = "m") -> ModelRequest {
        ModelRequest(model: model, system: "", messages: [.user("你好")], thinking: thinking)
    }

    func testEachServiceSpellsThinkingItsOwnWay() {
        let deepseekOff = OpenAIProvider.body(request(.off), style: .deepseek)
        XCTAssertEqual((deepseekOff["thinking"] as? [String: String])?["type"], "disabled")
        XCTAssertNil(deepseekOff["reasoning_effort"])
        let deepseekMax = OpenAIProvider.body(request(.max), style: .deepseek)
        XCTAssertEqual((deepseekMax["thinking"] as? [String: String])?["type"], "enabled")
        XCTAssertEqual(deepseekMax["reasoning_effort"] as? String, "max")
        XCTAssertEqual(OpenAIProvider.body(request(.medium), style: .deepseek)["reasoning_effort"] as? String, "high")

        let qwen = OpenAIProvider.body(request(.low), style: .qwen)
        XCTAssertEqual(qwen["enable_thinking"] as? Bool, true)
        XCTAssertEqual(qwen["thinking_budget"] as? Int, 1024)
        XCTAssertEqual(OpenAIProvider.body(request(.off), style: .qwen)["enable_thinking"] as? Bool, false)

        XCTAssertEqual(OpenAIProvider.body(request(.off), style: .effort)["reasoning_effort"] as? String, "none")
        XCTAssertEqual(OpenAIProvider.body(request(.high), style: .effort)["reasoning_effort"] as? String, "high")
        XCTAssertEqual(OpenAIProvider.body(request(.off), style: .kimi)["reasoning_effort"] as? String, "low", "Kimi cannot stop thinking")
        XCTAssertEqual((OpenAIProvider.body(request(.high), style: .openrouter)["reasoning"] as? [String: String])?["effort"], "high")
        XCTAssertEqual(OpenAIProvider.body(request(.auto), style: .minimax)["reasoning_split"] as? Bool, true)
        XCTAssertNil(OpenAIProvider.body(request(.auto), style: .effort)["reasoning_effort"])
        XCTAssertNil(OpenAIProvider.body(request(.max), style: .none)["reasoning_effort"])
    }

    func testStyleIsGuessedFromTheAddress() {
        XCTAssertEqual(ThinkingStyle.guess(baseURL: "https://api.deepseek.com"), .deepseek)
        XCTAssertEqual(ThinkingStyle.guess(baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1"), .qwen)
        XCTAssertEqual(ThinkingStyle.guess(baseURL: "https://open.bigmodel.cn/api/paas/v4"), .glm)
        XCTAssertEqual(ThinkingStyle.guess(baseURL: "https://ark.cn-beijing.volces.com/api/v3"), .doubao)
        XCTAssertEqual(ThinkingStyle.guess(baseURL: "https://openrouter.ai/api/v1"), .openrouter)
        XCTAssertEqual(ThinkingStyle.guess(baseURL: "https://example.com/v1"), .effort)
    }

    func testThoughtsInTagsAreTakenOutOfTheAnswer() {
        var splitter = ThinkSplitter()
        var events: [StreamEvent] = []
        for piece in ["<thi", "nk>先想", "想</th", "ink>\n\n答", "案"] { events += splitter.feed(piece) }
        events += splitter.flush()
        let thought = events.compactMap { if case .reasoning(let text) = $0 { return text } else { return nil } }.joined()
        let answer = events.compactMap { if case .text(let text) = $0 { return text } else { return nil } }.joined()
        XCTAssertEqual(thought, "先想想")
        XCTAssertEqual(answer, "答案")
    }

    func testAnAnswerAboutTheTagIsLeftAlone() {
        var splitter = ThinkSplitter()
        var events = splitter.feed("用 <think> 标签")
        events += splitter.flush()
        XCTAssertEqual(events, [.text("用 <think> 标签")])
        var short = ThinkSplitter()
        XCTAssertEqual(short.feed("<"), [])
        XCTAssertEqual(short.feed("b>粗体"), [.text("<b>粗体")])
    }

    func testClaudeTakesEffortOrABudget() throws {
        XCTAssertTrue(AnthropicProvider.adaptive("claude-opus-4-6"))
        XCTAssertTrue(AnthropicProvider.adaptive("anthropic/claude-sonnet-4.6"))
        XCTAssertTrue(AnthropicProvider.adaptive("claude-opus-5"))
        XCTAssertFalse(AnthropicProvider.adaptive("claude-sonnet-4-5-20250929"))
        XCTAssertFalse(AnthropicProvider.adaptive("claude-opus-4-20250514"))
        XCTAssertFalse(AnthropicProvider.adaptive("claude-3-7-sonnet-20250219"))

        var newer = request(.high, model: "claude-opus-4-8")
        newer.temperature = 0.7
        let adaptive = AnthropicProvider.body(newer)
        XCTAssertEqual((adaptive["thinking"] as? [String: String])?["type"], "adaptive")
        XCTAssertEqual((adaptive["output_config"] as? [String: String])?["effort"], "high")
        XCTAssertNil(adaptive["temperature"], "no temperature while thinking")

        let budget = AnthropicProvider.body(request(.medium, model: "claude-sonnet-4-5"))
        let thinking = try XCTUnwrap(budget["thinking"] as? [String: Any])
        XCTAssertEqual(thinking["type"] as? String, "enabled")
        let tokens = try XCTUnwrap(thinking["budget_tokens"] as? Int)
        XCTAssertGreaterThan(try XCTUnwrap(budget["max_tokens"] as? Int), tokens)
        XCTAssertNil(AnthropicProvider.body(request(.auto, model: "claude-opus-4-8"))["thinking"])
    }

    func testClaudeGetsItsSignedThoughtsBack() throws {
        XCTAssertEqual(try AnthropicProvider.decode(#"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"sig"}}"#), [.reasoningSignature("sig")])
        var said = Message.assistant("好", reasoning: "想过了")
        said.reasoningSignature = "sig"
        let request = ModelRequest(model: "claude-opus-4-8", system: "", messages: [.user("问"), said, .user("再问")], thinking: .high)
        let turns = try XCTUnwrap(AnthropicProvider.body(request)["messages"] as? [[String: Any]])
        let blocks = try XCTUnwrap(turns[1]["content"] as? [[String: Any]])
        XCTAssertEqual(blocks.first?["type"] as? String, "thinking")
        XCTAssertEqual(blocks.first?["signature"] as? String, "sig")
        let plain = ModelRequest(model: "claude-opus-4-8", system: "", messages: [.user("问"), said, .user("再问")])
        let plainBlocks = try XCTUnwrap((AnthropicProvider.body(plain)["messages"] as? [[String: Any]])?[1]["content"] as? [[String: Any]])
        XCTAssertEqual(plainBlocks.first?["type"] as? String, "text")
    }

    func testARefusedThinkingSettingIsDropped() async throws {
        final class Picky: ModelProvider, @unchecked Sendable {
            var seen: [Thinking] = []
            func stream(_ request: ModelRequest) -> AsyncThrowingStream<StreamEvent, Error> {
                seen.append(request.thinking)
                return AsyncThrowingStream { continuation in
                    if request.thinking != .auto {
                        continuation.finish(throwing: ProviderError(status: 400, "reasoning_effort not supported"))
                    } else {
                        continuation.yield(.text("好"))
                        continuation.yield(.finish(reason: "stop"))
                        continuation.finish()
                    }
                }
            }
            func models() async throws -> [String] { [] }
        }
        let picky = Picky()
        var agent = Agent(provider: picky, model: "m", system: "")
        agent.thinking = .high
        let heard = Heard()
        try await agent.run(history: [.user("你好")]) { await heard.add($0) }
        XCTAssertEqual(picky.seen, [.high, .auto])
        let events = await heard.events
        XCTAssertTrue(events.contains(.thinkingRefused(.high, reason: "reasoning_effort not supported")))
        XCTAssertTrue(events.contains(.text("好")))
    }
}

private actor Heard {
    var events: [AgentEvent] = []
    func add(_ event: AgentEvent) { events.append(event) }
}

final class StepTitleTests: XCTestCase {
    func testEveryToolTakesATitleThatIsTakenAwayBeforeRunning() {
        let spec = Agent.titled(ToolSpec(name: "web_search", description: "", parameters: ["type": "object", "properties": ["query": ["type": "string"]]]))
        XCTAssertNotNil(spec.parameters["properties"]?[Agent.titleKey])
        XCTAssertNotNil(spec.parameters["properties"]?["query"])
        let (arguments, title) = Agent.untitled(["query": "天气", "step_title": "查明天重庆的天气"])
        XCTAssertEqual(title, "查明天重庆的天气")
        XCTAssertNil(arguments["step_title"])
        XCTAssertEqual(arguments["query"]?.string, "天气")
        XCTAssertEqual(Agent.label("搜索：天气", title: "查明天重庆的天气"), "搜索：查明天重庆的天气")
        XCTAssertEqual(Agent.label("搜索：天气", title: nil), "搜索：天气")
    }
}

private struct TimeoutTool: AgentTool {
    var spec: ToolSpec { ToolSpec(name: "send", description: "", parameters: ["type": "object"]) }
    func label(for arguments: JSONValue) -> String { "发送" }
    func approval(for arguments: JSONValue) -> ApprovalAsk? { ApprovalAsk(title: "发送", reason: "发一封信") }
    func run(_ arguments: JSONValue) async throws -> ToolOutput { throw URLError(.timedOut) }
}

private final class Mailbox: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [String]
    init(_ waiting: [String]) { self.waiting = waiting }
    func take() -> [String] {
        lock.lock(); defer { lock.unlock() }
        let out = waiting
        waiting = []
        return out
    }
}

final class TurnSafetyTests: XCTestCase {
    func testUnknownOutcomeIsSaidAndNotRedone() async throws {
        let call: [StreamEvent] = [.toolCallStart(index: 0, id: "c", name: "send"), .toolCallArguments(index: 0, delta: "{}")]
        let again: [StreamEvent] = [.toolCallStart(index: 0, id: "d", name: "send"), .toolCallArguments(index: 0, delta: "{}")]
        let provider = ScriptedProvider([call, again, [.text("我先查一下有没有发出去")]])
        let recorder = Recorder()
        let agent = Agent(provider: provider, model: "m", system: "", tools: [TimeoutTool()]) { _, _ in true }
        try await agent.run(history: [.user("发信")]) { await recorder.add($0) }
        let results = await recorder.events.compactMap { event -> Message? in
            if case .message(let message) = event, message.role == .tool { return message } else { return nil }
        }
        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results[0].text.hasPrefix(Agent.unknownMark))
        XCTAssertTrue(results[1].text.contains("没有再做一次"))
    }

    func testInterjectionArrivesBetweenSteps() async throws {
        let provider = ScriptedProvider([
            [.toolCallStart(index: 0, id: "c1", name: "echo"), .toolCallArguments(index: 0, delta: "{\"say\":\"一\"}")],
            [.text("好，按你说的改")],
        ])
        let box = Mailbox(["换成二"])
        var agent = Agent(provider: provider, model: "m", system: "", tools: [EchoTool()])
        agent.inbox = { box.take() }
        let recorder = Recorder()
        try await agent.run(history: [.user("说一")]) { await recorder.add($0) }
        XCTAssertEqual(provider.requests.count, 2)
        XCTAssertEqual(provider.requests[1].messages.last?.role, .user)
        XCTAssertEqual(provider.requests[1].messages.last?.text, "换成二")
    }
}

final class CutShortTests: XCTestCase {
    func testReasons() {
        XCTAssertNil(Agent.cutShort(text: "好", reasoning: "", images: 0, calls: 0, finish: "stop"))
        XCTAssertNil(Agent.cutShort(text: "", reasoning: "", images: 0, calls: 1, finish: "tool_calls"))
        XCTAssertEqual(Agent.cutShort(text: "", reasoning: "", images: 0, calls: 0, finish: nil), .dropped)
        XCTAssertEqual(Agent.cutShort(text: "", reasoning: "想", images: 0, calls: 0, finish: "stop"), .thoughtOnly(1))
        XCTAssertEqual(Agent.cutShort(text: "", reasoning: "", images: 0, calls: 0, finish: "content_filter"), .filtered)
        XCTAssertEqual(Agent.cutShort(text: "写了一半", reasoning: "", images: 0, calls: 0, finish: "length"), .truncated)
        XCTAssertEqual(Agent.cutShort(text: "写了一半", reasoning: "", images: 0, calls: 0, finish: nil), .dropped)
        XCTAssertEqual(Agent.cutShort(text: "一点", reasoning: "", images: 0, calls: 0, finish: "content_filter"), .filtered)
        XCTAssertEqual(Agent.cutShort(text: "", reasoning: "", images: 0, calls: 0, finish: "stop"), .empty)
    }
}

final class ThinkingLevelsTests: XCTestCase {
    func testDistinctLevels() {
        XCTAssertEqual(ThinkingStyle.deepseek.levels(thinks: true), [.auto, .off, .low, .medium, .max])
        XCTAssertEqual(ThinkingStyle.kimi.levels(thinks: true), [.auto, .low, .medium, .max])
        XCTAssertEqual(ThinkingStyle.grok.levels(thinks: true), [.auto, .low, .medium])
        XCTAssertEqual(ThinkingStyle.minimax.levels(thinks: true), [.auto])
        XCTAssertEqual(ThinkingStyle.effort.levels(thinks: false), [.auto])
        XCTAssertEqual(ThinkingStyle.effort.levels(thinks: true), [.auto, .off, .low, .medium, .high, .max])
    }
}

final class DroppedStreamTests: XCTestCase {
    /// A stream that stops without the service saying it is done runs no tool, even one whose arguments parse.
    func testDroppedStreamRunsNoTool() async throws {
        final class Dropping: ModelProvider, @unchecked Sendable {
            func stream(_ request: ModelRequest) -> AsyncThrowingStream<StreamEvent, Error> {
                AsyncThrowingStream { continuation in
                    continuation.yield(.toolCallStart(index: 0, id: "c1", name: "count"))
                    continuation.yield(.toolCallArguments(index: 0, delta: "{}"))
                    continuation.finish()
                }
            }
            func models() async throws -> [String] { [] }
        }
        final class Counter: @unchecked Sendable { var runs = 0 }
        let counter = Counter()
        struct Count: AgentTool {
            let counter: Counter
            var spec: ToolSpec { ToolSpec(name: "count", description: "", parameters: ["type": "object"]) }
            func label(for arguments: JSONValue) -> String { "数" }
            func run(_ arguments: JSONValue) async throws -> ToolOutput { counter.runs += 1; return ToolOutput("ok") }
        }
        let agent = Agent(provider: Dropping(), model: "m", system: "", tools: [Count(counter: counter)])
        final class Seen: @unchecked Sendable { var shorts: [CutShort] = [] }
        let seen = Seen()
        try await agent.run(history: [.user("数一下")]) { event in
            if case .cutShort(let short) = event { seen.shorts.append(short) }
        }
        XCTAssertEqual(counter.runs, 0)
        XCTAssertEqual(seen.shorts, [.dropped])
    }
}

final class LocalAddressHardeningTests: XCTestCase {
    func testExpandedIPv6AndSpecialIPv4() {
        let blocked = [
            "http://localhost/test",
            "http://foo.localhost/test",
            "http://127.0.0.1/",
            "http://127.1/",
            "http://2130706433/",
            "http://0x7f.0x1/",
            "http://0x7f000001/",
            "http://127.0.0.0xa/",
            "http://0177.0.0.1/",
            "http://10.0.0.1/",
            "http://172.16.0.1/",
            "http://192.168.1.1/",
            "http://169.254.169.254/latest/meta-data/",
            "http://100.64.0.1/",
            "http://[::1]/",
            "http://[0:0:0:0:0:0:0:1]/",
            "http://[0000::1]/",
            "http://[::0001]/",
            "http://[0:0:0:0:0:0:0:0]/",
            "http://[fe80::1]/",
            "http://[fe90::1]/",
            "http://[febf::1]/",
            "http://[fc00::1]/",
            "http://[fd12:3456::1]/",
            "http://[::ffff:127.0.0.1]/",
            "http://[0:0:0:0:0:ffff:192.168.1.1]/",
            "http://[64:ff9b::10.0.0.1]/",
        ]
        for raw in blocked {
            let url = URL(string: raw)!
            XCTAssertTrue(LocalAddress.isLocal(url), "expected local: \(raw)")
        }
        let allowed = [
            "https://example.com/",
            "https://8.8.8.8/",
            "https://1.1.1.1/",
            "https://[2606:4700:4700::1111]/",
            "https://[::ffff:8.8.8.8]/",
        ]
        for raw in allowed {
            let url = URL(string: raw)!
            XCTAssertFalse(LocalAddress.isLocal(url), "expected public: \(raw)")
        }
    }

    func testDNSResolutionCheck() {
        XCTAssertTrue(LocalAddress.resolvesHostToLocal("localhost"))
    }
}

final class PDFTextTests: XCTestCase {
    func testLooksLikeAndShown() {
        XCTAssertTrue(PDFText.looksLike(Data("%PDF-1.7\n".utf8)))
        XCTAssertFalse(PDFText.looksLike(Data("<html>".utf8)))
        XCTAssertNil(PDFText.read(Data("not a pdf".utf8)))

        let reading = PDFText.Reading(
            title: "测试文档",
            pages: 3,
            read: [
                .init(number: 1, text: "第一页内容"),
                .init(number: 2, text: "   "),
            ]
        )
        XCTAssertEqual(reading.blank, [2])
        let shown = reading.shown(limit: 500)
        XCTAssertTrue(shown.contains("《测试文档》共 3 页，这是第 1–2 页。"))
        XCTAssertTrue(shown.contains("第一页内容"))
        XCTAssertTrue(shown.contains("扫描件或图片"))
        XCTAssertTrue(shown.contains("从第 3 页接着读"))

        let empty = PDFText.Reading(title: nil, pages: 0, read: [])
        XCTAssertTrue(empty.shown(limit: 100).contains("没有页"))
    }

    func testReadsMinimalValidPDF() {
        let pdf = Data("""
        %PDF-1.4
        1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj
        2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj
        3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >> endobj
        4 0 obj << /Length 44 >> stream
        BT /F1 12 Tf 10 100 Td (Hello Clio PDF) Tj ET
        endstream endobj
        5 0 obj << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> endobj
        xref
        0 6
        0000000000 65535 f 
        0000000009 00000 n 
        0000000058 00000 n 
        0000000115 00000 n 
        0000000241 00000 n 
        0000000335 00000 n 
        trailer << /Size 6 /Root 1 0 R >>
        startxref
        405
        %%EOF
        """.utf8)
        XCTAssertTrue(PDFText.looksLike(pdf))
        #if canImport(PDFKit)
        let reading = PDFText.read(pdf, from: 1, count: 5)
        XCTAssertEqual(reading?.pages, 1)
        XCTAssertTrue(reading?.read.first?.text.contains("Hello Clio PDF") == true)
        XCTAssertTrue(PDFText.all(pdf)?.contains("Hello Clio PDF") == true)
        #endif
    }
}

final class WebReadToolTests: XCTestCase {
    func testReadsHTMLRejectsMediaAndLocalRedirects() async throws {
        let htmlTool = WebReadTool(limit: 40) { url in
            let html = "<html><head><title>标题</title></head><body><script>bad()</script><p>\(String(repeating: "正", count: 60))</p></body></html>"
            return (Data(html.utf8), "text/html", "utf-8", url)
        }
        let ok = try await htmlTool.run(["url": "https://example.com/article"])
        XCTAssertFalse(ok.isError)
        XCTAssertTrue(ok.text.contains("标题"))
        XCTAssertTrue(ok.text.contains("太长截断了"))
        XCTAssertFalse(ok.text.contains("bad()"))

        let local = try await htmlTool.run(["url": "http://127.0.0.1/secret"])
        XCTAssertTrue(local.isError)
        XCTAssertEqual(local.text, LocalAddress.refusal)

        let redirectLocal = WebReadTool { _ in
            (Data("secret".utf8), "text/plain", "utf-8", URL(string: "http://192.168.1.1/")!)
        }
        let bounced = try await redirectLocal.run(["url": "https://example.com/bounce"])
        XCTAssertTrue(bounced.isError)
        XCTAssertEqual(bounced.text, LocalAddress.refusal)

        let media = WebReadTool { url in
            (Data([0x89, 0x50]), "image/png", nil, url)
        }
        let rejected = try await media.run(["url": "https://example.com/a.png"])
        XCTAssertTrue(rejected.isError)
        XCTAssertTrue(rejected.text.contains("image/png"))

        let bad = try await htmlTool.run(["url": "ftp://example.com/file"])
        XCTAssertTrue(bad.isError)
    }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class HTTPStreamAndProviderEdgeTests: XCTestCase {
    private func stubSession(_ body: String, status: Int = 200, mime: String = "text/event-stream") -> URLSession {
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": mime])!
            return (response, Data(body.utf8))
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    func testHTTPStreamNormalSSEAndDone() async throws {
        let sse = "data: {\"choices\":[{\"delta\":{\"content\":\"你好\"}}]}\n\ndata: [DONE]\n\n"
        let session = stubSession(sse)
        var events: [StreamEvent] = []
        for try await event in HTTP.stream(URLRequest(url: URL(string: "https://example.com/sse")!), session: session, decode: OpenAIProvider.decode) {
            events.append(event)
        }
        XCTAssertEqual(events, [.text("你好"), .finish(reason: "done")])
    }

    func testHTTPStreamSurfacesHTTP200ErrorJSON() async {
        let errorJSON = "{\"error\":{\"message\":\"quota exceeded\"}}"
        let session = stubSession(errorJSON, status: 200, mime: "text/plain")
        do {
            for try await _ in HTTP.stream(URLRequest(url: URL(string: "https://example.com/sse")!), session: session, decode: OpenAIProvider.decode) {}
            XCTFail("Expected ProviderError for HTTP 200 error JSON")
        } catch let error as ProviderError {
            XCTAssertTrue(error.message.contains("quota exceeded"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testHTTPStreamSurfacesNon200Error() async {
        let session = stubSession("{\"error\":{\"message\":\"invalid key\"}}", status: 401, mime: "application/json")
        do {
            for try await _ in HTTP.stream(URLRequest(url: URL(string: "https://example.com/sse")!), session: session, decode: OpenAIProvider.decode) {}
            XCTFail("Expected ProviderError for HTTP 401")
        } catch let error as ProviderError {
            XCTAssertEqual(error.status, 401)
            XCTAssertTrue(error.message.contains("invalid key"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testOpenAISplitToolCallIdAndNameMerged() async throws {
        let raw = AsyncThrowingStream<StreamEvent, Error> { continuation in
            for line in [
                #"{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_abc","function":{}}]}}]}"#,
                #"{"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"name":"web_search"}}]}}]}"#,
                #"{"choices":[{"delta":{"tool_calls":[{"index":1,"function":{"name":"weather","arguments":"{}"}}]}}]}"#,
            ] {
                if let decoded = try? OpenAIProvider.decode(line) {
                    for e in decoded { continuation.yield(e) }
                }
            }
            continuation.finish()
        }
        var out: [StreamEvent] = []
        for try await event in OpenAIProvider.splittingThoughts(raw) { out.append(event) }
        XCTAssertTrue(out.contains(.toolCallStart(index: 0, id: "call_abc", name: "web_search")))
        XCTAssertTrue(out.contains(.toolCallStart(index: 1, id: "call_1", name: "weather")))
    }

    func testAnthropicRedactedThinkingRoundTrip() throws {
        let decoded = try AnthropicProvider.decode(#"{"type":"content_block_start","index":0,"content_block":{"type":"redacted_thinking","data":"ENC_BLOB_1"}}"#)
        guard case .reasoningSignature(let sig) = decoded.first else {
            return XCTFail("Expected reasoningSignature carrying redacted marker")
        }
        var assistant = Message.assistant("答复")
        assistant.reasoning = "思考"
        assistant.reasoningSignature = "sig_plain" + sig
        let request = ModelRequest(model: "claude-sonnet-4-6", system: "", messages: [.user("问"), assistant, .user("继续")], thinking: .high)
        let body = AnthropicProvider.body(request)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let blocks = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(blocks[0]["type"] as? String, "thinking")
        XCTAssertEqual(blocks[0]["signature"] as? String, "sig_plain")
        XCTAssertEqual(blocks[1]["type"] as? String, "redacted_thinking")
        XCTAssertEqual(blocks[1]["data"] as? String, "ENC_BLOB_1")
    }
}

final class ThinkingStyleMatrixTests: XCTestCase {
    func testEveryStyleAndEveryLevelFields() {
        // auto: every style sends empty except minimax (reasoning_split: true)
        for style in ThinkingStyle.allCases {
            let autoFields = style.fields(.auto)
            if style == .minimax {
                XCTAssertEqual(autoFields["reasoning_split"] as? Bool, true)
                XCTAssertEqual(autoFields.count, 1)
            } else {
                XCTAssertTrue(autoFields.isEmpty, "\(style) auto should be empty")
            }
        }

        // effort
        XCTAssertEqual(ThinkingStyle.effort.fields(.off)["reasoning_effort"] as? String, "none")
        XCTAssertEqual(ThinkingStyle.effort.fields(.low)["reasoning_effort"] as? String, "low")
        XCTAssertEqual(ThinkingStyle.effort.fields(.medium)["reasoning_effort"] as? String, "medium")
        XCTAssertEqual(ThinkingStyle.effort.fields(.high)["reasoning_effort"] as? String, "high")
        XCTAssertEqual(ThinkingStyle.effort.fields(.max)["reasoning_effort"] as? String, "xhigh")

        // deepseek
        XCTAssertEqual((ThinkingStyle.deepseek.fields(.off)["thinking"] as? [String: String])?["type"], "disabled")
        XCTAssertNil(ThinkingStyle.deepseek.fields(.off)["reasoning_effort"])
        XCTAssertEqual((ThinkingStyle.deepseek.fields(.low)["thinking"] as? [String: String])?["type"], "enabled")
        XCTAssertEqual(ThinkingStyle.deepseek.fields(.low)["reasoning_effort"] as? String, "low")
        XCTAssertEqual(ThinkingStyle.deepseek.fields(.medium)["reasoning_effort"] as? String, "high")
        XCTAssertEqual(ThinkingStyle.deepseek.fields(.high)["reasoning_effort"] as? String, "high")
        XCTAssertEqual(ThinkingStyle.deepseek.fields(.max)["reasoning_effort"] as? String, "max")

        // kimi
        XCTAssertEqual(ThinkingStyle.kimi.fields(.off)["reasoning_effort"] as? String, "low")
        XCTAssertEqual(ThinkingStyle.kimi.fields(.low)["reasoning_effort"] as? String, "low")
        XCTAssertEqual(ThinkingStyle.kimi.fields(.medium)["reasoning_effort"] as? String, "high")
        XCTAssertEqual(ThinkingStyle.kimi.fields(.high)["reasoning_effort"] as? String, "high")
        XCTAssertEqual(ThinkingStyle.kimi.fields(.max)["reasoning_effort"] as? String, "max")

        // qwen
        XCTAssertEqual(ThinkingStyle.qwen.fields(.off)["enable_thinking"] as? Bool, false)
        XCTAssertNil(ThinkingStyle.qwen.fields(.off)["thinking_budget"])
        XCTAssertEqual(ThinkingStyle.qwen.fields(.low)["enable_thinking"] as? Bool, true)
        XCTAssertEqual(ThinkingStyle.qwen.fields(.low)["thinking_budget"] as? Int, 1024)
        XCTAssertEqual(ThinkingStyle.qwen.fields(.medium)["thinking_budget"] as? Int, 4096)
        XCTAssertEqual(ThinkingStyle.qwen.fields(.high)["thinking_budget"] as? Int, 16384)
        XCTAssertEqual(ThinkingStyle.qwen.fields(.max)["enable_thinking"] as? Bool, true)
        XCTAssertNil(ThinkingStyle.qwen.fields(.max)["thinking_budget"])

        // glm
        XCTAssertEqual((ThinkingStyle.glm.fields(.off)["thinking"] as? [String: String])?["type"], "disabled")
        XCTAssertEqual((ThinkingStyle.glm.fields(.low)["thinking"] as? [String: String])?["type"], "enabled")
        XCTAssertEqual(ThinkingStyle.glm.fields(.low)["reasoning_effort"] as? String, "low")
        XCTAssertEqual(ThinkingStyle.glm.fields(.medium)["reasoning_effort"] as? String, "medium")
        XCTAssertEqual(ThinkingStyle.glm.fields(.high)["reasoning_effort"] as? String, "high")
        XCTAssertEqual(ThinkingStyle.glm.fields(.max)["reasoning_effort"] as? String, "max")

        // doubao
        XCTAssertEqual((ThinkingStyle.doubao.fields(.off)["thinking"] as? [String: String])?["type"], "disabled")
        XCTAssertEqual((ThinkingStyle.doubao.fields(.low)["thinking"] as? [String: String])?["type"], "enabled")
        XCTAssertEqual(ThinkingStyle.doubao.fields(.low)["reasoning_effort"] as? String, "low")
        XCTAssertEqual(ThinkingStyle.doubao.fields(.medium)["reasoning_effort"] as? String, "medium")
        XCTAssertEqual(ThinkingStyle.doubao.fields(.high)["reasoning_effort"] as? String, "high")
        XCTAssertEqual(ThinkingStyle.doubao.fields(.max)["reasoning_effort"] as? String, "high")

        // minimax
        for level in Thinking.allCases {
            XCTAssertEqual(ThinkingStyle.minimax.fields(level)["reasoning_split"] as? Bool, true)
            XCTAssertEqual(ThinkingStyle.minimax.fields(level).count, 1)
        }

        // openrouter
        XCTAssertEqual((ThinkingStyle.openrouter.fields(.off)["reasoning"] as? [String: Any])?["enabled"] as? Bool, false)
        XCTAssertEqual((ThinkingStyle.openrouter.fields(.low)["reasoning"] as? [String: Any])?["effort"] as? String, "low")
        XCTAssertEqual((ThinkingStyle.openrouter.fields(.medium)["reasoning"] as? [String: Any])?["effort"] as? String, "medium")
        XCTAssertEqual((ThinkingStyle.openrouter.fields(.high)["reasoning"] as? [String: Any])?["effort"] as? String, "high")
        XCTAssertEqual((ThinkingStyle.openrouter.fields(.max)["reasoning"] as? [String: Any])?["effort"] as? String, "xhigh")

        // gemini
        XCTAssertEqual(ThinkingStyle.gemini.fields(.off)["reasoning_effort"] as? String, "none")
        XCTAssertEqual(ThinkingStyle.gemini.fields(.low)["reasoning_effort"] as? String, "low")
        XCTAssertEqual(ThinkingStyle.gemini.fields(.medium)["reasoning_effort"] as? String, "medium")
        XCTAssertEqual(ThinkingStyle.gemini.fields(.high)["reasoning_effort"] as? String, "high")
        XCTAssertEqual(ThinkingStyle.gemini.fields(.max)["reasoning_effort"] as? String, "high")

        // grok
        XCTAssertTrue(ThinkingStyle.grok.fields(.off).isEmpty)
        XCTAssertEqual(ThinkingStyle.grok.fields(.low)["reasoning_effort"] as? String, "low")
        XCTAssertEqual(ThinkingStyle.grok.fields(.medium)["reasoning_effort"] as? String, "high")
        XCTAssertEqual(ThinkingStyle.grok.fields(.high)["reasoning_effort"] as? String, "high")
        XCTAssertEqual(ThinkingStyle.grok.fields(.max)["reasoning_effort"] as? String, "high")

        // none
        for level in Thinking.allCases {
            XCTAssertTrue(ThinkingStyle.none.fields(level).isEmpty)
        }
    }

    func testGuessFromBaseURL() {
        XCTAssertEqual(ThinkingStyle.guess(baseURL: "https://api.deepseek.com/v1"), .deepseek)
        XCTAssertEqual(ThinkingStyle.guess(baseURL: "https://api.moonshot.cn/v1"), .kimi)
        XCTAssertEqual(ThinkingStyle.guess(baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1"), .qwen)
        XCTAssertEqual(ThinkingStyle.guess(baseURL: "https://open.bigmodel.cn/api/paas/v4"), .glm)
        XCTAssertEqual(ThinkingStyle.guess(baseURL: "https://ark.cn-beijing.volces.com/api/v3"), .doubao)
        XCTAssertEqual(ThinkingStyle.guess(baseURL: "https://api.minimaxi.com/v1"), .minimax)
        XCTAssertEqual(ThinkingStyle.guess(baseURL: "https://openrouter.ai/api/v1"), .openrouter)
        XCTAssertEqual(ThinkingStyle.guess(baseURL: "https://generativelanguage.googleapis.com/v1beta/openai"), .gemini)
        XCTAssertEqual(ThinkingStyle.guess(baseURL: "https://api.x.ai/v1"), .grok)
        XCTAssertEqual(ThinkingStyle.guess(baseURL: "https://api.openai.com/v1"), .effort)
    }
}
