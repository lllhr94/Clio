import Foundation

/// Prompt caching tier for Anthropic Messages API.
public enum PromptCacheTier: String, Codable, Equatable, Hashable, Sendable, CaseIterable {
    case off
    case fiveMinutes = "5m"
    case oneHour = "1h"

    public var isEnabled: Bool { self != .off }

    public var cacheControl: [String: String]? {
        switch self {
        case .off: return nil
        case .fiveMinutes: return ["type": "ephemeral"]
        case .oneHour: return ["type": "ephemeral", "ttl": "1h"]
        }
    }
}

/// Per-model capability description for Claude Messages API, replacing blind regex + `budget + 8192` math.
public struct AnthropicModelCapabilities: Equatable, Sendable {
    public enum ThinkingMode: Equatable, Sendable {
        case adaptive
        case budgeted
        case unsupported
    }

    public let thinkingMode: ThinkingMode
    public let canDisableThinking: Bool
    public let defaultMaxOutputTokens: Int
    public let maxOutputTokensCap: Int
    public let minBudgetTokens: Int
    public let maxBudgetTokens: Int
    public let supportedEfforts: [String]
    public let allowsTemperatureWithThinking: Bool
    public let supportsParallelTools: Bool

    public init(
        thinkingMode: ThinkingMode,
        canDisableThinking: Bool = true,
        defaultMaxOutputTokens: Int = 8192,
        maxOutputTokensCap: Int = 64_000,
        minBudgetTokens: Int = 1024,
        maxBudgetTokens: Int = 32_000,
        supportedEfforts: [String] = [],
        allowsTemperatureWithThinking: Bool = false,
        supportsParallelTools: Bool = true
    ) {
        self.thinkingMode = thinkingMode
        self.canDisableThinking = canDisableThinking
        self.defaultMaxOutputTokens = defaultMaxOutputTokens
        self.maxOutputTokensCap = maxOutputTokensCap
        self.minBudgetTokens = minBudgetTokens
        self.maxBudgetTokens = maxBudgetTokens
        self.supportedEfforts = supportedEfforts
        self.allowsTemperatureWithThinking = allowsTemperatureWithThinking
        self.supportsParallelTools = supportsParallelTools
    }

    public static func resolve(for model: String) -> AnthropicModelCapabilities {
        let name = model.lowercased()
        if AnthropicProvider.adaptive(name) {
            return AnthropicModelCapabilities(
                thinkingMode: .adaptive,
                canDisableThinking: true,
                defaultMaxOutputTokens: 16_384,
                maxOutputTokensCap: 64_000,
                minBudgetTokens: 1024,
                maxBudgetTokens: 32_000,
                supportedEfforts: ["low", "medium", "high", "max"],
                allowsTemperatureWithThinking: false,
                supportsParallelTools: true
            )
        }
        // Claude 3.5 / 3.0 legacy models without extended thinking.
        if name.contains("claude-3-5") || name.contains("claude-3.5")
            || name.contains("claude-3-haiku") || name.contains("claude-3-opus") || name.contains("claude-3-sonnet") {
            return AnthropicModelCapabilities(
                thinkingMode: .unsupported,
                canDisableThinking: true,
                defaultMaxOutputTokens: 8192,
                maxOutputTokensCap: 8192,
                minBudgetTokens: 0,
                maxBudgetTokens: 0,
                supportedEfforts: [],
                allowsTemperatureWithThinking: true,
                supportsParallelTools: true
            )
        }
        // Claude 4 / 4.5 / 3.7 budgeted extended thinking models.
        let isOpus4Legacy = name.contains("opus-4") && !name.contains("4-5") && !name.contains("4.5")
        let maxCap = isOpus4Legacy ? 32_000 : 64_000
        return AnthropicModelCapabilities(
            thinkingMode: .budgeted,
            canDisableThinking: true,
            defaultMaxOutputTokens: 8192,
            maxOutputTokensCap: maxCap,
            minBudgetTokens: 1024,
            maxBudgetTokens: min(32_000, maxCap - 4096),
            supportedEfforts: [],
            allowsTemperatureWithThinking: false,
            supportsParallelTools: true
        )
    }
}

/// Claude's Messages API.
public struct AnthropicProvider: ModelProvider {
    public var baseURL: String
    public var apiKey: String
    public var promptCache: Bool?
    public var cacheTier: PromptCacheTier?
    public let stableSystemPrefix: String?
    public var customHeaders: [String: String]
    public var networkScope: String
    private let fixedRoute: Bool

    public init(
        baseURL: String = "https://api.anthropic.com",
        apiKey: String,
        promptCache: Bool? = nil,
        stableSystemPrefix: String? = nil,
        fixedRoute: Bool = false,
        cacheTier: PromptCacheTier? = nil,
        customHeaders: [String: String] = [:],
        networkScope: String = "default"
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.promptCache = promptCache
        self.cacheTier = cacheTier
        self.stableSystemPrefix = stableSystemPrefix
        self.fixedRoute = fixedRoute
        self.customHeaders = customHeaders
        self.networkScope = networkScope
    }

    public var effectiveCacheTier: PromptCacheTier {
        if let cacheTier { return cacheTier }
        if let promptCache { return promptCache ? .fiveMinutes : .off }
        return Self.caches(baseURL) ? .fiveMinutes : .off
    }

    private func signed(_ url: URL, requestHeaders: [String: String] = [:]) -> URLRequest {
        var http = URLRequest(url: url)
        http.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        http.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var merged = customHeaders
        for (k, v) in requestHeaders { merged[k] = v }
        HTTP.applyNonSecretHeaders(merged, to: &http)
        return http
    }

    func effectiveContractKey(for model: String, endpointURL: URL? = nil) -> EndpointContractKey {
        let resolvedURL = endpointURL ?? (try? HTTP.endpoint(baseURL, "/v1/messages"))
        let route = resolvedURL?.path.isEmpty == false ? resolvedURL!.path : "/v1/messages"
        return EndpointContractKey(origin: baseURL, protocolKind: "anthropic", route: route, modelID: model)
    }

    func urlRequest(_ request: ModelRequest, overrideCacheTier: PromptCacheTier? = nil) throws -> URLRequest {
        let url = try HTTP.endpoint(baseURL, "/v1/messages")
        let derivedContract = effectiveContractKey(for: request.model, endpointURL: url)
        if let supplied = request.contractKey, !supplied.matches(derivedContract) {
            throw ProviderError("请求契约与当前 Anthropic 服务地址或协议不匹配，已阻止发送。")
        }
        var boundRequest = request
        boundRequest.contractKey = derivedContract
        var http = signed(url, requestHeaders: request.customHeaders)
        http.httpMethod = "POST"
        let tier = overrideCacheTier ?? effectiveCacheTier
        http.httpBody = try HTTP.json(Self.body(boundRequest, cacheTier: tier, stableSystemPrefix: stableSystemPrefix))
        return http
    }

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        stream(request, session: nil)
    }

    func stream(_ request: ModelRequest, session: URLSession?) -> AsyncThrowingStream<StreamEvent, Error> {
        let initialTier = effectiveCacheTier
        let activeSession = session
        let url: URL
        do {
            url = try HTTP.endpoint(baseURL, "/v1/messages")
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
        let contract = effectiveContractKey(for: request.model, endpointURL: url)
        let thinkingActive = !(request.isExplicitOff || request.thinking == .off)
            && (request.thinking != .auto || request.messages.contains { $0.role == .assistant && $0.continuationPayloads?.isEmpty == false })
        if case .missingOrIncompatible(let reason) = Self.verifyContinuation(
            request.messages,
            contractKey: contract,
            speakerOrThreadID: request.speakerOrThreadID,
            thinkingEnabled: thinkingActive
        ) {
            return AsyncThrowingStream { $0.finish(throwing: ProviderError(reason)) }
        }

        let makeDecoder: @Sendable () -> @Sendable (String) throws -> [StreamEvent] = {
            Self.makeStreamDecoder(contractKey: contract, speakerOrThreadID: request.speakerOrThreadID)
        }

        guard initialTier == .oneHour else {
            do {
                let http = try urlRequest(request, overrideCacheTier: initialTier)
                return HTTP.stream(
                    http,
                    session: activeSession,
                    scope: networkScope,
                    rejectAllRedirects: fixedRoute,
                    timeouts: request.streamTimeouts,
                    stopOnFinishEvent: true,
                    decode: makeDecoder()
                )
            } catch {
                return AsyncThrowingStream { $0.finish(throwing: error) }
            }
        }

        // Graceful 1h -> 5m fallback when a relay rejects extended `ttl: "1h"` before delivering any output.
        return AsyncThrowingStream { continuation in
            let task = Task {
                var emittedAny = false
                do {
                    let firstReq = try urlRequest(request, overrideCacheTier: .oneHour)
                    for try await event in HTTP.stream(
                        firstReq,
                        session: activeSession,
                        scope: networkScope,
                        rejectAllRedirects: fixedRoute,
                        timeouts: request.streamTimeouts,
                        stopOnFinishEvent: true,
                        decode: makeDecoder()
                    ) {
                        emittedAny = true
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    if !emittedAny, Self.isOneHourCacheTTLRejection(error) {
                        do {
                            let fallbackReq = try urlRequest(request, overrideCacheTier: .fiveMinutes)
                            for try await event in HTTP.stream(
                                fallbackReq,
                                session: activeSession,
                                scope: networkScope,
                                rejectAllRedirects: fixedRoute,
                                timeouts: request.streamTimeouts,
                                stopOnFinishEvent: true,
                                decode: makeDecoder()
                            ) {
                                continuation.yield(event)
                            }
                            continuation.finish()
                        } catch {
                            continuation.finish(throwing: error)
                        }
                    } else {
                        continuation.finish(throwing: error)
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private final class ThinkingBlockTracker: @unchecked Sendable {
        private let lock = NSLock()
        private var thinkingTextByIndex: [Int: String] = [:]
        private var signatureByIndex: [Int: String] = [:]
        private var activeThinkingIndices: Set<Int> = []

        func startThinking(at index: Int) {
            lock.withLock {
                activeThinkingIndices.insert(index)
                thinkingTextByIndex[index] = ""
                signatureByIndex[index] = ""
            }
        }

        func appendThinking(_ delta: String, at index: Int) {
            lock.withLock {
                activeThinkingIndices.insert(index)
                thinkingTextByIndex[index, default: ""] += delta
            }
        }

        func appendSignature(_ delta: String, at index: Int) {
            lock.withLock {
                activeThinkingIndices.insert(index)
                signatureByIndex[index, default: ""] += delta
            }
        }

        func finishBlock(at index: Int) -> (thinking: String, signature: String)? {
            lock.withLock {
                guard activeThinkingIndices.remove(index) != nil else { return nil }
                let thought = thinkingTextByIndex.removeValue(forKey: index) ?? ""
                let sig = signatureByIndex.removeValue(forKey: index) ?? ""
                guard !sig.isEmpty else { return nil }
                return (thought, sig)
            }
        }
    }

    /// Block-indexed Anthropic SSE decoder that emits intact, individually signed `ProtocolContinuationPayload`
    /// items per SSE block index (preserving multiple `thinking` / `redacted_thinking` blocks in exact order).
    static func makeStreamDecoder(
        contractKey: EndpointContractKey,
        speakerOrThreadID: String? = nil
    ) -> @Sendable (String) throws -> [StreamEvent] {
        let tracker = ThinkingBlockTracker()
        return { payload in
            var events = try Self.decode(payload)
            guard let json = JSONValue.parse(payload), let type = json["type"]?.string else { return events }
            switch type {
            case "content_block_start":
                let index = json["index"]?.int ?? 0
                let block = json["content_block"] ?? .null
                switch block["type"]?.string {
                case "thinking":
                    tracker.startThinking(at: index)
                    if let initial = block["thinking"]?.string, !initial.isEmpty {
                        tracker.appendThinking(initial, at: index)
                    }
                    if let initialSig = block["signature"]?.string, !initialSig.isEmpty {
                        tracker.appendSignature(initialSig, at: index)
                    }
                case "redacted_thinking":
                    if let data = block["data"]?.string, !data.isEmpty {
                        events.append(.continuationPayload(ProtocolContinuationPayload(
                            origin: contractKey.origin,
                            protocolKind: contractKey.protocolKind,
                            route: contractKey.route,
                            modelID: contractKey.modelID,
                            speakerOrThreadID: speakerOrThreadID,
                            wireKind: "anthropic_redacted_thinking",
                            blockOrder: index,
                            opaqueData: data,
                            validScope: "turn"
                        )))
                    }
                default:
                    break
                }
            case "content_block_delta":
                let index = json["index"]?.int ?? 0
                let delta = json["delta"] ?? .null
                switch delta["type"]?.string {
                case "thinking_delta":
                    if let thought = delta["thinking"]?.string { tracker.appendThinking(thought, at: index) }
                case "signature_delta":
                    if let sig = delta["signature"]?.string { tracker.appendSignature(sig, at: index) }
                default:
                    break
                }
            case "content_block_stop":
                let index = json["index"]?.int ?? 0
                if let completed = tracker.finishBlock(at: index),
                   let data = try? JSONSerialization.data(
                       withJSONObject: ["thinking": completed.thinking, "signature": completed.signature],
                       options: [.sortedKeys, .withoutEscapingSlashes]
                   ) {
                    events.append(.continuationPayload(ProtocolContinuationPayload(
                        origin: contractKey.origin,
                        protocolKind: contractKey.protocolKind,
                        route: contractKey.route,
                        modelID: contractKey.modelID,
                        speakerOrThreadID: speakerOrThreadID,
                        wireKind: "anthropic_thinking",
                        blockOrder: index,
                        opaqueData: String(decoding: data, as: UTF8.self),
                        validScope: "turn"
                    )))
                }
            default:
                break
            }
            return events
        }
    }

    static func isOneHourCacheTTLRejection(_ error: Error) -> Bool {
        guard let failure = error as? ProviderError, failure.status == 400 || failure.status == 422 else { return false }
        let lower = failure.message.lowercased()
        return lower.contains("ttl") || lower.contains("1h") || lower.contains("cache_control")
    }

    public func models() async throws -> [String] {
        let list = try await HTTP.get(
            signed(try HTTP.endpoint(baseURL, "/v1/models?limit=100")),
            session: nil,
            scope: networkScope,
            rejectAllRedirects: fixedRoute
        )
        return (list["data"]?.array ?? []).compactMap { $0["id"]?.string }
    }

    /// Verifies whether mandatory signed-thinking continuation is intact for the target Anthropic contract.
    public static func verifyContinuation(
        _ messages: [Message],
        contractKey: EndpointContractKey,
        speakerOrThreadID: String? = nil,
        thinkingEnabled: Bool
    ) -> ContinuationProjectionStatus {
        guard thinkingEnabled else { return .notRequired }
        let turnStart = messages.lastIndex(where: { $0.role == .user }) ?? 0
        for (index, message) in messages.enumerated() where index > turnStart && message.role == .assistant {
            guard !message.toolCalls.isEmpty else { continue }
            if let payloads = message.continuationPayloads, !payloads.isEmpty {
                let compatible = payloads.contains {
                    ($0.wireKind == "anthropic_thinking" || $0.wireKind == "anthropic_redacted_thinking")
                        && $0.isCompatible(with: contractKey, speakerOrThreadID: speakerOrThreadID)
                }
                if !compatible {
                    return .missingOrIncompatible(
                        reason: "历史签名思考块与当前 Anthropic 源站/协议/发言者不匹配，无法安全续接工具轮。"
                    )
                }
            } else if (message.reasoning?.isEmpty == false) && (message.reasoningSignature?.isEmpty ?? true) {
                return .missingOrIncompatible(
                    reason: "历史思考消息缺少 Anthropic 协议签名，严禁伪造或用公开摘要替代。"
                )
            }
        }
        return .compatible
    }

    /// Anthropic's own service keeps a prompt it has seen for a few minutes and charges a tenth for reading it back.
    /// Kept for checking official Anthropic domains; explicit `promptCache`/`cacheTier` overrides this per endpoint.
    public static func caches(_ baseURL: String) -> Bool {
        guard let host = URL(string: baseURL)?.host?.lowercased() else { return false }
        return host == "anthropic.com" || host.hasSuffix(".anthropic.com")
    }

    static func body(
        _ request: ModelRequest,
        cache: Bool = false,
        stableSystemPrefix: String? = nil
    ) -> [String: Any] {
        body(request, cacheTier: cache ? .fiveMinutes : .off, stableSystemPrefix: stableSystemPrefix)
    }

    /// `cacheTier`: 3-tier ordered cache breakpoints (`tools` -> `system` -> `messages`) supporting `.off`, `.fiveMinutes`, `.oneHour`.
    /// `stableSystemPrefix`: when caching is enabled and `request.system` begins with this prefix, splits `system`
    /// into a cached stable prefix block followed by an uncached volatile tail block.
    static func body(
        _ request: ModelRequest,
        cacheTier: PromptCacheTier,
        stableSystemPrefix: String? = nil
    ) -> [String: Any] {
        let capabilities = AnthropicModelCapabilities.resolve(for: request.model)
        let cacheControl = cacheTier.cacheControl
        let explicitOff = request.isExplicitOff || request.thinking == .off
        let explicitThinkingOn = !explicitOff && request.thinking != .auto && capabilities.thinkingMode != .unsupported

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
                if !explicitOff {
                    if let payloads = message.continuationPayloads, !payloads.isEmpty {
                        // Contract-bound continuation payloads: NEVER replay without an explicit matching target contract.
                        if let target = request.contractKey {
                            let matching = payloads
                                .filter { payload in
                                    (payload.wireKind == "anthropic_thinking" || payload.wireKind == "anthropic_redacted_thinking")
                                        && payload.isCompatible(with: target, speakerOrThreadID: request.speakerOrThreadID)
                                }
                                .sorted { $0.blockOrder < $1.blockOrder }
                            for payload in matching {
                                if payload.wireKind == "anthropic_thinking" {
                                    if let data = payload.opaqueData.data(using: .utf8),
                                       let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                                       let thought = parsed["thinking"] as? String,
                                       let sig = parsed["signature"] as? String, !sig.isEmpty {
                                        blocks.append(["type": "thinking", "thinking": thought, "signature": sig])
                                    } else if let thought = message.reasoning, !payload.opaqueData.isEmpty {
                                        blocks.append(["type": "thinking", "thinking": thought, "signature": payload.opaqueData])
                                    }
                                } else if payload.wireKind == "anthropic_redacted_thinking", !payload.opaqueData.isEmpty {
                                    blocks.append(["type": "redacted_thinking", "data": payload.opaqueData])
                                }
                            }
                        }
                    } else if let rawSignature = message.reasoningSignature, !rawSignature.isEmpty,
                              (explicitThinkingOn || (request.thinking == .auto && !message.toolCalls.isEmpty)) {
                        // Legacy signed thoughts: preserve under explicit thinking OR active `.auto` tool-use continuations.
                        let unpacked = Self.unpackSignature(rawSignature)
                        if let thought = message.reasoning, !unpacked.signature.isEmpty {
                            blocks.append(["type": "thinking", "thinking": thought, "signature": unpacked.signature])
                        }
                        for data in unpacked.redacted {
                            blocks.append(["type": "redacted_thinking", "data": data])
                        }
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

        let requestedMax = min(capabilities.maxOutputTokensCap, max(1, request.outputLimit ?? request.maxTokens))
        var body: [String: Any] = [
            "model": request.model,
            "max_tokens": requestedMax,
            "stream": true,
            "messages": turns.map { ["role": $0.role, "content": $0.blocks] },
        ]

        // Ordered cache tier 1: tools (Anthropic evaluates tools -> system -> messages prefix order).
        if !request.tools.isEmpty {
            var tools: [[String: Any]] = request.tools.map { ["name": $0.name, "description": $0.description, "input_schema": $0.parameters.any] }
            if let cacheControl { tools[tools.count - 1]["cache_control"] = cacheControl }
            body["tools"] = tools
        }

        // Ordered cache tier 2: system.
        if !request.system.isEmpty {
            let canCacheSystem = cacheControl != nil && !request.system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if let cacheControl, canCacheSystem {
                let effectivePrefix = request.systemCachePrefix ?? stableSystemPrefix
                body["system"] = Self.cachedSystemBlocks(request.system, stablePrefix: effectivePrefix, cacheControl: cacheControl)
            } else {
                body["system"] = request.system
            }
        }

        // Thinking + capability-clamped budget / output_config.
        var thinkingSentAsActive = false
        if let resolvedFields = request.thinkingBodyFields, !resolvedFields.isEmpty {
            for (field, value) in resolvedFields {
                body[field] = value.foundationValue
            }
            if let thinkingDict = body["thinking"] as? [String: Any],
               let type = thinkingDict["type"] as? String {
                thinkingSentAsActive = (type == "enabled" || type == "adaptive")
                if type == "enabled", let rawBudget = thinkingDict["budget_tokens"] as? Int, capabilities.thinkingMode == .budgeted {
                    let clampedBudget = max(capabilities.minBudgetTokens, min(capabilities.maxBudgetTokens, rawBudget))
                    var updated = thinkingDict
                    updated["budget_tokens"] = clampedBudget
                    body["thinking"] = updated
                    let headroom = min(4096, max(1024, requestedMax / 2))
                    body["max_tokens"] = min(capabilities.maxOutputTokensCap, max(requestedMax, clampedBudget + headroom))
                }
            }
        } else {
            switch request.thinking {
            case .auto:
                break
            case .off:
                if capabilities.canDisableThinking {
                    body["thinking"] = ["type": "disabled"]
                }
            case .low, .medium, .high, .max:
                switch capabilities.thinkingMode {
                case .adaptive:
                    body["thinking"] = ["type": "adaptive"]
                    let effort: [Thinking: String] = [.low: "low", .medium: "medium", .high: "high", .max: "max"]
                    let chosen = effort[request.thinking] ?? "high"
                    let effectiveEffort = capabilities.supportedEfforts.contains(chosen) ? chosen : (capabilities.supportedEfforts.last ?? "high")
                    body["output_config"] = ["effort": effectiveEffort]
                    thinkingSentAsActive = true
                case .budgeted:
                    let budgets: [Thinking: Int] = [.low: 2048, .medium: 6000, .high: 12_000, .max: 20_000]
                    let rawBudget = budgets[request.thinking] ?? 6000
                    let clampedBudget = max(capabilities.minBudgetTokens, min(capabilities.maxBudgetTokens, rawBudget))
                    body["thinking"] = ["type": "enabled", "budget_tokens": clampedBudget] as [String: Any]
                    let headroom = min(4096, max(1024, requestedMax / 2))
                    body["max_tokens"] = min(capabilities.maxOutputTokensCap, max(requestedMax, clampedBudget + headroom))
                    thinkingSentAsActive = true
                case .unsupported:
                    break
                }
            }
        }

        if let temperature = request.temperature,
           (!thinkingSentAsActive || capabilities.allowsTemperatureWithThinking) {
            body["temperature"] = min(1, temperature)
        }

        // Ordered cache tier 3: newest cacheable block of the conversation.
        if let cacheControl, var last = turns.last, let index = last.blocks.lastIndex(where: { block in
            let type = block["type"] as? String ?? ""
            if type == "text" {
                let text = block["text"] as? String ?? ""
                return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return ["image", "tool_result", "tool_use"].contains(type)
        }) {
            last.blocks[index]["cache_control"] = cacheControl
            turns[turns.count - 1] = last
            body["messages"] = turns.map { ["role": $0.role, "content": $0.blocks] }
        }
        return body
    }

    private static func cachedSystemBlocks(
        _ system: String,
        stablePrefix: String?,
        cacheControl: [String: String]
    ) -> [[String: Any]] {
        if let prefix = stablePrefix,
           !prefix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           system.hasPrefix(prefix) {
            let volatileTail = String(system.dropFirst(prefix.count))
            if volatileTail.isEmpty {
                let prefixBlock: [String: Any] = ["type": "text", "text": prefix, "cache_control": cacheControl]
                return [prefixBlock]
            }
            if !volatileTail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let prefixBlock: [String: Any] = ["type": "text", "text": prefix, "cache_control": cacheControl]
                let tailBlock: [String: Any] = ["type": "text", "text": volatileTail]
                return [prefixBlock, tailBlock]
            }
        }
        let wholeBlock: [String: Any] = ["type": "text", "text": system, "cache_control": cacheControl]
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
