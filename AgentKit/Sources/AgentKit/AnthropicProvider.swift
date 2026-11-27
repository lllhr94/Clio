import Foundation

/// Claude's Messages API.
public struct AnthropicProvider: ModelProvider {
    public var baseURL: String
    public var apiKey: String
    public var promptCache: Bool?
    public let stableSystemPrefix: String?
    private let fixedRoute: Bool

    public init(
        baseURL: String = "https://api.anthropic.com",
        apiKey: String,
        promptCache: Bool? = nil,
        stableSystemPrefix: String? = nil,
        fixedRoute: Bool = false
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.promptCache = promptCache
        self.stableSystemPrefix = stableSystemPrefix
        self.fixedRoute = fixedRoute
    }

    private func signed(_ url: URL) -> URLRequest {
        var http = URLRequest(url: url)
        http.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        http.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return http
    }

    func urlRequest(_ request: ModelRequest) throws -> URLRequest {
        var http = signed(try HTTP.endpoint(baseURL, "/v1/messages"))
        http.httpMethod = "POST"
        let cache = promptCache ?? Self.caches(baseURL)
        http.httpBody = try HTTP.json(Self.body(request, cache: cache, stableSystemPrefix: stableSystemPrefix))
        return http
    }

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        do {
            let session = fixedRoute ? FixedModelRoute.session : HTTP.session
            return HTTP.stream(try urlRequest(request), session: session, decode: Self.decode)
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }

    public func models() async throws -> [String] {
        let list = try await HTTP.get(signed(try HTTP.endpoint(baseURL, "/v1/models?limit=100")))
        return (list["data"]?.array ?? []).compactMap { $0["id"]?.string }
    }

    /// Anthropic's own service keeps a prompt it has seen for a few minutes and charges a tenth for reading it back.
    /// Kept for checking official Anthropic domains; explicit `promptCache` overrides this per endpoint.
    public static func caches(_ baseURL: String) -> Bool {
        guard let host = URL(string: baseURL)?.host?.lowercased() else { return false }
        return host == "anthropic.com" || host.hasSuffix(".anthropic.com")
    }

    /// `cache`: marks the instructions, the tools and the conversation so far as reusable. A turn calls the model
    /// several times (each tool step is another call); with the marks, everything before the newest step is read
    /// from Anthropic's cache instead of paid for again in full.
    /// `stableSystemPrefix`: when caching is enabled and `request.system` begins with this prefix, splits `system`
    /// into a cached stable prefix block followed by an uncached volatile tail block.
    static func body(
        _ request: ModelRequest,
        cache: Bool = false,
        stableSystemPrefix: String? = nil
    ) -> [String: Any] {
        // Claude wants turns to alternate, and tool results inside a user turn.
        var turns: [(role: String, blocks: [[String: Any]])] = []
        func add(_ role: String, _ blocks: [[String: Any]]) {
            guard !blocks.isEmpty else { return }
            if let last = turns.last, last.role == role {
                turns[turns.count - 1].blocks.append(contentsOf: blocks)
            } else {
                turns.append((role, blocks))
            }
        }
        // With thinking on, Claude wants its signed thoughts back in front of what it said; without, they are left out.
        let thinking = request.thinking != .auto && request.thinking != .off
        for message in request.messages {
            switch message.role {
            case .user:
                var blocks: [[String: Any]] = message.images.map { image in
                    ["type": "image", "source": ["type": "base64", "media_type": image.mediaType, "data": image.data.base64EncodedString()]]
                }
                if !message.text.isEmpty { blocks.append(["type": "text", "text": message.text]) }
                add("user", blocks)
            case .assistant:
                var blocks: [[String: Any]] = []
                if thinking, let rawSignature = message.reasoningSignature, !rawSignature.isEmpty {
                    let unpacked = Self.unpackSignature(rawSignature)
                    if let thought = message.reasoning, !unpacked.signature.isEmpty {
                        blocks.append(["type": "thinking", "thinking": thought, "signature": unpacked.signature])
                    }
                    for data in unpacked.redacted {
                        blocks.append(["type": "redacted_thinking", "data": data])
                    }
                }
                let hasNonWhitespaceText = !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if !message.text.isEmpty, (hasNonWhitespaceText || message.toolCalls.isEmpty) {
                    blocks.append(["type": "text", "text": message.text])
                }
                for call in message.toolCalls {
                    var input: Any = [String: Any]()
                    if let parsed = JSONValue.parse(call.arguments), case .object = parsed { input = parsed.any }
                    blocks.append(["type": "tool_use", "id": call.id, "name": call.name, "input": input])
                }
                add("assistant", blocks)
            case .tool:
                var block: [String: Any] = ["type": "tool_result", "tool_use_id": message.toolCallId ?? "", "content": message.text.isEmpty ? "（空）" : message.text]
                if !message.images.isEmpty {
                    var content: [[String: Any]] = [["type": "text", "text": message.text.isEmpty ? "（图片）" : message.text]]
                    content += message.images.map { image in
                        ["type": "image", "source": ["type": "base64", "media_type": image.mediaType, "data": image.data.base64EncodedString()]]
                    }
                    block["content"] = content
                }
                if message.isError { block["is_error"] = true }
                add("user", [block])
            }
        }
        var body: [String: Any] = [
            "model": request.model,
            "max_tokens": request.outputLimit ?? request.maxTokens,
            "stream": true,
            "messages": turns.map { ["role": $0.role, "content": $0.blocks] },
        ]
        if !request.system.isEmpty {
            let canCacheSystem = cache && !request.system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if canCacheSystem {
                let effectivePrefix = request.systemCachePrefix ?? stableSystemPrefix
                body["system"] = Self.cachedSystemBlocks(request.system, stablePrefix: effectivePrefix)
            } else {
                body["system"] = request.system
            }
        }
        if let temperature = request.temperature, !thinking { body["temperature"] = min(1, temperature) }
        switch request.thinking {
        case .auto:
            break
        case .off:
            body["thinking"] = ["type": "disabled"]
        case .low, .medium, .high, .max:
            if adaptive(request.model) {
                body["thinking"] = ["type": "adaptive"]
                let effort: [Thinking: String] = [.low: "low", .medium: "medium", .high: "high", .max: "max"]
                body["output_config"] = ["effort": effort[request.thinking] ?? "high"]
            } else {
                // Older models think within a budget, and the budget has to fit under max_tokens.
                let budgets: [Thinking: Int] = [.low: 2048, .medium: 6000, .high: 12000, .max: 20000]
                let budget = budgets[request.thinking] ?? 6000
                body["thinking"] = ["type": "enabled", "budget_tokens": budget] as [String: Any]
                body["max_tokens"] = Swift.max(request.outputLimit ?? request.maxTokens, budget + 8192)
            }
        }
        if !request.tools.isEmpty {
            var tools: [[String: Any]] = request.tools.map { ["name": $0.name, "description": $0.description, "input_schema": $0.parameters.any] }
            if cache { tools[tools.count - 1]["cache_control"] = ["type": "ephemeral"] }
            body["tools"] = tools
        }
        // The newest block of the conversation: the next call starts from here, so all of it up to here is reused.
        if cache, var last = turns.last, let index = last.blocks.lastIndex(where: { block in
            let type = block["type"] as? String ?? ""
            if type == "text" {
                let text = block["text"] as? String ?? ""
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return ["image", "tool_result", "tool_use"].contains(type)
        }) {
            last.blocks[index]["cache_control"] = ["type": "ephemeral"]
            turns[turns.count - 1] = last
            body["messages"] = turns.map { ["role": $0.role, "content": $0.blocks] }
        }
        return body
    }

    private static func cachedSystemBlocks(_ system: String, stablePrefix: String?) -> [[String: Any]] {
        if let prefix = stablePrefix,
           !prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           system.hasPrefix(prefix) {
            let volatileTail = String(system.dropFirst(prefix.count))
            if volatileTail.isEmpty {
                let prefixBlock: [String: Any] = ["type": "text", "text": prefix, "cache_control": ["type": "ephemeral"]]
                return [prefixBlock]
            }
            if !volatileTail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let prefixBlock: [String: Any] = ["type": "text", "text": prefix, "cache_control": ["type": "ephemeral"]]
                let tailBlock: [String: Any] = ["type": "text", "text": volatileTail]
                return [prefixBlock, tailBlock]
            }
        }
        let wholeBlock: [String: Any] = ["type": "text", "text": system, "cache_control": ["type": "ephemeral"]]
        return [wholeBlock]
    }

    /// Claude 4.6 and later choose how long to think themselves and take an effort level; earlier ones take a token budget.
    static func adaptive(_ model: String) -> Bool {
        let name = model.lowercased()
        guard let match = name.range(of: #"(opus|sonnet|haiku)-(\d{1,2})(?:[-.](\d{1,2}))?(?!\d)"#, options: .regularExpression) else { return false }
        let numbers = name[match].split { !$0.isNumber }.compactMap { Int($0) }
        guard let major = numbers.first else { return false }
        let minor = numbers.count > 1 ? numbers[1] : 0
        return major > 4 || (major == 4 && minor >= 6)
    }

    static func decode(_ payload: String) throws -> [StreamEvent] {
        guard let json = JSONValue.parse(payload), let type = json["type"]?.string else { return [] }
        switch type {
        case "message_start":
            let usage = json["message"]?["usage"]
            // Claude counts cache reads and writes apart from input_tokens; the whole prompt is all three.
            if let input = usage?["input_tokens"]?.number {
                let read = usage?["cache_read_input_tokens"]?.number ?? 0
                let written = usage?["cache_creation_input_tokens"]?.number ?? 0
                return [.usage(input: Int(input + read + written), output: 0, cached: Int(read))]
            }
        case "content_block_start":
            let index = (json["index"]?.int ?? 0)
            let block = json["content_block"] ?? .null
            switch block["type"]?.string {
            case "tool_use":
                return [.toolCallStart(index: index, id: block["id"]?.string ?? "", name: block["name"]?.string ?? "")]
            case "redacted_thinking":
                if let data = block["data"]?.string, !data.isEmpty {
                    return [.reasoningSignature(Self.redactedPrefix + data + Self.redactedSuffix)]
                }
            case "text":
                if let text = block["text"]?.string, !text.isEmpty { return [.text(text)] }
            default: break
            }
        case "content_block_delta":
            let index = (json["index"]?.int ?? 0)
            let delta = json["delta"] ?? .null
            switch delta["type"]?.string {
            case "text_delta": if let text = delta["text"]?.string { return [.text(text)] }
            case "input_json_delta": if let part = delta["partial_json"]?.string, !part.isEmpty { return [.toolCallArguments(index: index, delta: part)] }
            case "thinking_delta": if let thought = delta["thinking"]?.string { return [.reasoning(thought)] }
            case "signature_delta": if let signature = delta["signature"]?.string { return [.reasoningSignature(signature)] }
            default: break
            }
        case "message_delta":
            var events: [StreamEvent] = []
            if let output = json["usage"]?["output_tokens"]?.number { events.append(.usage(input: 0, output: Int(output))) }
            if let reason = json["delta"]?["stop_reason"]?.string { events.append(.finish(reason: reason)) }
            return events
        case "error":
            throw ProviderError(json["error"]?["message"]?.string ?? "Claude 报错了")
        default:
            break
        }
        return []
    }

    private static let redactedPrefix = "\u{1E}redacted:"
    private static let redactedSuffix = "\u{1E}"

    static func unpackSignature(_ raw: String) -> (signature: String, redacted: [String]) {
        var plain = ""
        var redacted: [String] = []
        var cursor = raw.startIndex
        while cursor < raw.endIndex {
            guard let start = raw.range(of: redactedPrefix, range: cursor..<raw.endIndex) else {
                plain.append(contentsOf: raw[cursor...])
                break
            }
            plain.append(contentsOf: raw[cursor..<start.lowerBound])
            guard let end = raw.range(of: redactedSuffix, range: start.upperBound..<raw.endIndex) else {
                plain.append(contentsOf: raw[start.lowerBound...])
                break
            }
            let data = String(raw[start.upperBound..<end.lowerBound])
            if !data.isEmpty { redacted.append(data) }
            cursor = end.upperBound
        }
        return (plain, redacted)
    }
}
