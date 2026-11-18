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
            return Self.splittingThoughts(HTTP.stream(http, decode: Self.decode))
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }

    public func models() async throws -> [String] {
        var http = URLRequest(url: try HTTP.endpoint(baseURL, "/models"))
        http.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let list = try await HTTP.get(http)
        return (list["data"]?.array ?? []).compactMap { $0["id"]?.string }.sorted()
    }

    /// Moves thoughts written between <think> tags out of the answer.
    static func splittingThoughts(_ events: AsyncThrowingStream<StreamEvent, Error>) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                var splitter = ThinkSplitter()
                do {
                    for try await event in events {
                        if case .text(let piece) = event {
                            for split in splitter.feed(piece) { continuation.yield(split) }
                        } else {
                            continuation.yield(event)
                        }
                    }
                    for split in splitter.flush() { continuation.yield(split) }
                    continuation.finish()
                } catch {
                    for split in splitter.flush() { continuation.yield(split) }
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
        if let usage = json["usage"], case .object = usage {
            // DeepSeek says prompt_cache_hit_tokens; OpenAI and most others, prompt_tokens_details.cached_tokens.
            let cached = usage["prompt_cache_hit_tokens"]?.number ?? usage["prompt_tokens_details"]?["cached_tokens"]?.number ?? 0
            events.append(.usage(input: Int(usage["prompt_tokens"]?.number ?? 0), output: Int(usage["completion_tokens"]?.number ?? 0), cached: Int(cached)))
        }
        return events
    }
}
