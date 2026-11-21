import Foundation

/// Chat Completions, as DeepSeek, OpenAI and most other services speak it.
public struct OpenAIProvider: ModelProvider {
    public var baseURL: String
    public var apiKey: String
    /// How this service wants to hear about thinking.
    public var style: ThinkingStyle

    public init(baseURL: String, apiKey: String, style: ThinkingStyle? = nil) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.style = style ?? ThinkingStyle.guess(baseURL: baseURL)
    }

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        do {
            var http = URLRequest(url: try HTTP.endpoint(baseURL, "/chat/completions"))
            http.httpMethod = "POST"
            http.setValue("application/json", forHTTPHeaderField: "Content-Type")
            http.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            http.httpBody = try HTTP.json(Self.body(request, style: style))
            return Self.splittingThoughts(HTTP.stream(http, acceptsJSON: true, decode: Self.decode))
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }

    public func models() async throws -> [String] { try await catalog().ids }

    /// The models a service lists, and the context window it reports for each where it says (relays such as
    /// OpenRouter or one-api write it under different names). A reported window beats Clio's guess from the name.
    public func catalog() async throws -> (ids: [String], windows: [String: Int]) {
        var http = URLRequest(url: try HTTP.endpoint(baseURL, "/models"))
        http.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let list = try await HTTP.get(http)
        var windows: [String: Int] = [:]
        var ids: [String] = []
        for entry in list["data"]?.array ?? [] {
            guard let id = entry["id"]?.string else { continue }
            ids.append(id)
            if let window = Self.reportedWindow(entry) { windows[id] = window }
        }
        return (ids.sorted(), windows)
    }

    static func reportedWindow(_ entry: JSONValue) -> Int? {
        let names = ["context_length", "context_window", "max_context_length", "max_model_len", "max_input_tokens",
                     "input_token_limit", "inputTokenLimit", "max_context_tokens"]
        for name in names {
            if let value = entry[name]?.number, value >= 1024 { return Int(value) }
        }
        if let value = entry["top_provider"]?["context_length"]?.number, value >= 1024 { return Int(value) }
        return nil
    }

    /// Moves thoughts written between <think> tags out of the answer.
    static func splittingThoughts(_ events: AsyncThrowingStream<StreamEvent, Error>) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var splitter = ThinkSplitter()
                var images = ReplyImageText()
                func send(_ event: StreamEvent) {
                    if case .text(let text) = event {
                        for piece in images.feed(text) { continuation.yield(piece) }
                    } else {
                        continuation.yield(event)
                    }
                }
                do {
                    for try await event in events {
                        if case .text(let piece) = event {
                            for split in splitter.feed(piece) { send(split) }
                        } else {
                            continuation.yield(event)
                        }
                    }
                    for split in splitter.flush() { send(split) }
                    for piece in images.flush() { continuation.yield(piece) }
                    continuation.finish()
                } catch {
                    for split in splitter.flush() { send(split) }
                    for piece in images.flush() { continuation.yield(piece) }
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func body(_ request: ModelRequest, style: ThinkingStyle = .effort) -> [String: Any] {
        var messages: [[String: Any]] = []
        if !request.system.isEmpty { messages.append(["role": "system", "content": request.system]) }
        // Services that keep a model's thoughts want all of them back once tools are in play (DeepSeek refuses a
        // tool call without them); the others need them only inside the turn still running.
        let turnStart = (style.echoesReasoning && !request.tools.isEmpty) ? -1 : (request.messages.lastIndex { $0.role == .user } ?? 0)
        // Tool messages carry text only here; pictures a tool brought back follow as a user message after them.
        var held: [ImagePart] = []
        func release() {
            guard !held.isEmpty else { return }
            var parts: [[String: Any]] = held.map { image in
                ["type": "image_url", "image_url": ["url": "data:\(image.mediaType);base64,\(image.data.base64EncodedString())"]]
            }
            parts.append(["type": "text", "text": "（上面是工具带回来的图片。）"])
            messages.append(["role": "user", "content": parts])
            held = []
        }
        for (index, message) in request.messages.enumerated() {
            if message.role != .tool { release() }
            switch message.role {
            case .user:
                if message.images.isEmpty {
                    messages.append(["role": "user", "content": message.text])
                } else {
                    var parts: [[String: Any]] = message.images.map { image in
                        ["type": "image_url", "image_url": ["url": "data:\(image.mediaType);base64,\(image.data.base64EncodedString())"]]
                    }
                    if !message.text.isEmpty { parts.append(["type": "text", "text": message.text]) }
                    messages.append(["role": "user", "content": parts])
                }
            case .assistant:
                var item: [String: Any] = ["role": "assistant", "content": message.text]
                if !message.toolCalls.isEmpty {
                    item["tool_calls"] = message.toolCalls.map { call in
                        ["id": call.id, "type": "function", "function": ["name": call.name, "arguments": call.arguments.isEmpty ? "{}" : call.arguments]]
                    }
                }
                if index > turnStart, let reasoning = message.reasoning, !reasoning.isEmpty {
                    item["reasoning_content"] = reasoning
                }
                messages.append(item)
            case .tool:
                messages.append(["role": "tool", "tool_call_id": message.toolCallId ?? "", "content": message.text])
                held += message.images
            }
        }
        release()
        var body: [String: Any] = [
            "model": request.model,
            "messages": messages,
            "stream": true,
            "stream_options": ["include_usage": true],
        ]
        if let temperature = request.temperature { body["temperature"] = temperature }
        for (field, value) in style.fields(request.thinking) { body[field] = value }
        if let limit = request.outputLimit { body["max_tokens"] = limit }
        if !request.tools.isEmpty {
            body["tools"] = request.tools.map { tool in
                ["type": "function", "function": ["name": tool.name, "description": tool.description, "parameters": tool.parameters.any]]
            }
        }
        return body
    }

    static func decode(_ payload: String) throws -> [StreamEvent] {
        guard let json = JSONValue.parse(payload) else { return [] }
        if let error = json["error"] {
            throw ProviderError(error["message"]?.string ?? error.compact)
        }
        var events: [StreamEvent] = []
        if let choice = json["choices"]?.array?.first {
            let delta = choice["delta"] ?? choice["message"] ?? .null
            if let reasoning = (delta["reasoning_content"] ?? delta["reasoning"])?.string, !reasoning.isEmpty {
                events.append(.reasoning(reasoning))
            }
            if let text = delta["content"]?.string, !text.isEmpty { events.append(.text(text)) }
            for part in delta["content"]?.array ?? [] {
                if let text = part["text"]?.string, !text.isEmpty { events.append(.text(text)) }
                if let image = replyImage(part) { events.append(.image(image)) }
            }
            let images = (delta["images"]?.array ?? []) + (choice["images"]?.array ?? [])
            events += images.compactMap(replyImage).map(StreamEvent.image)
            for (position, call) in (delta["tool_calls"]?.array ?? []).enumerated() {
                let index = call["index"]?.number.map { Int($0) } ?? position
                let function = call["function"] ?? .null
                if let id = call["id"]?.string, !id.isEmpty {
                    events.append(.toolCallStart(index: index, id: id, name: function["name"]?.string ?? ""))
                }
                if let arguments = function["arguments"]?.string, !arguments.isEmpty {
                    events.append(.toolCallArguments(index: index, delta: arguments))
                }
            }
            if let reason = choice["finish_reason"]?.string { events.append(.finish(reason: reason)) }
        }
        events += (json["images"]?.array ?? []).compactMap(replyImage).map(StreamEvent.image)
        if let usage = json["usage"], case .object = usage {
            // DeepSeek says prompt_cache_hit_tokens; OpenAI and most others, prompt_tokens_details.cached_tokens.
            let cached = usage["prompt_cache_hit_tokens"]?.number ?? usage["prompt_tokens_details"]?["cached_tokens"]?.number ?? 0
            events.append(.usage(input: Int(usage["prompt_tokens"]?.number ?? 0), output: Int(usage["completion_tokens"]?.number ?? 0), cached: Int(cached)))
        }
        return events
    }

    private static func replyImage(_ part: JSONValue) -> ReplyImage? {
        let field = part["image_url"]
        let source = part.string ?? field?["url"]?.string ?? field?.string
        if let url = source ?? part["url"]?.string, let image = ReplyImage.source(url) { return image }
        if let base64 = part["b64_json"]?.string {
            return ReplyImage.base64(base64[...], mediaType: part["mime_type"]?.string ?? "image/png")
        }
        return nil
    }
}
