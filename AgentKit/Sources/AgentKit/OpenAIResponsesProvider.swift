import Foundation

/// OpenAI Responses API (`/responses`), stateless (`store: false`) with contract-verified reasoning item continuation,
/// split stream timeouts, and `CatalogReportingProvider` support for both `.openaiResponses` and `.openaiCodex`.
public struct OpenAIResponsesProvider: ModelProvider, CatalogReportingProvider {
    public var baseURL: String
    public var apiKey: String
    public var isCodex: Bool
    public var customHeaders: [String: String]
    public var fixedRoute: Bool

    public init(
        baseURL: String,
        apiKey: String,
        isCodex: Bool = false,
        customHeaders: [String: String] = [:],
        fixedRoute: Bool = false
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.isCodex = isCodex
        self.customHeaders = customHeaders
        self.fixedRoute = fixedRoute
    }

    public var protocolKind: String {
        isCodex ? "openai_codex" : "openai_responses"
    }

    /// Derives the authoritative contract strictly from the actual target URL, protocol, and model.
    public func effectiveContractKey(for model: String, endpointURL: URL? = nil) -> EndpointContractKey {
        let resolvedURL = endpointURL ?? (try? HTTP.endpoint(baseURL, "/responses"))
        let route = resolvedURL?.path.isEmpty == false ? resolvedURL!.path : "/responses"
        return EndpointContractKey(origin: baseURL, protocolKind: protocolKind, route: route, modelID: model)
    }

    func urlRequest(_ request: ModelRequest) throws -> URLRequest {
        let url = try HTTP.endpoint(baseURL, "/responses")
        let contract = effectiveContractKey(for: request.model, endpointURL: url)
        if let supplied = request.contractKey, !supplied.matches(contract) {
            throw ProviderError("请求契约与当前 Responses 服务地址或协议不匹配，已阻止发送。")
        }
        var http = URLRequest(url: url)
        http.httpMethod = "POST"
        http.setValue("application/json", forHTTPHeaderField: "Content-Type")
        http.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        var mergedHeaders = customHeaders
        for (k, v) in request.customHeaders { mergedHeaders[k] = v }
        HTTP.applyNonSecretHeaders(mergedHeaders, to: &http)
        http.httpBody = try HTTP.json(Self.body(request, contractKey: contract, isCodex: isCodex))
        return http
    }

    public func stream(_ request: ModelRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        stream(request, session: nil)
    }

    func stream(_ request: ModelRequest, session: URLSession?) -> AsyncThrowingStream<StreamEvent, Error> {
        do {
            let url = try HTTP.endpoint(baseURL, "/responses")
            let contract = effectiveContractKey(for: request.model, endpointURL: url)
            // Fail closed with explicit non-continuable status if active-turn reasoning continuation payloads are incompatible.
            let hasActiveBoundPayloads = {
                let turnStart = request.messages.lastIndex(where: { $0.role == .user }) ?? 0
                return request.messages.enumerated().contains { idx, msg in
                    idx > turnStart && msg.role == .assistant && !msg.toolCalls.isEmpty
                        && (msg.continuationPayloads?.isEmpty == false)
                }
            }()
            if hasActiveBoundPayloads,
               case .missingOrIncompatible(let reason) = Self.verifyContinuation(
                   request.messages,
                   contractKey: contract,
                   speakerOrThreadID: request.speakerOrThreadID,
                   requiresStatelessReasoning: true
               ) {
                throw ProviderError(reason)
            }
            let http = try urlRequest(request)
            let activeSession = session ?? (fixedRoute ? FixedModelRoute.session : nil)
            let decoder = Self.makeDecoder(contractKey: contract, speakerOrThreadID: request.speakerOrThreadID)
            return HTTP.stream(
                http,
                acceptsJSON: false,
                session: activeSession,
                rejectAllRedirects: fixedRoute,
                timeouts: request.streamTimeouts,
                stopOnFinishEvent: true,
                decode: decoder
            )
        } catch {
            return AsyncThrowingStream { $0.finish(throwing: error) }
        }
    }

    public func models() async throws -> [String] {
        try await catalog().ids
    }

    public func catalog() async throws -> (ids: [String], windows: [String: Int]) {
        try await catalog(session: nil)
    }

    func catalog(session: URLSession?) async throws -> (ids: [String], windows: [String: Int]) {
        var http = URLRequest(url: try HTTP.endpoint(baseURL, "/models"))
        http.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        HTTP.applyNonSecretHeaders(customHeaders, to: &http)
        let activeSession = session ?? (fixedRoute ? FixedModelRoute.session : nil)
        let list = try await HTTP.get(http, session: activeSession, rejectAllRedirects: fixedRoute)
        var windows: [String: Int] = [:]
        var ids: [String] = []
        for entry in list["data"]?.array ?? [] {
            guard let id = entry["id"]?.string else { continue }
            ids.append(id)
            if let window = OpenAIProvider.reportedWindow(entry) { windows[id] = window }
        }
        return (ids.sorted(), windows)
    }

    /// Checks whether a target Responses contract that requires stateless encrypted reasoning continuation
    /// has compatible payloads available instead of missing/cross-origin/cross-speaker state.
    public static func verifyContinuation(
        _ messages: [Message],
        contractKey: EndpointContractKey,
        speakerOrThreadID: String? = nil,
        requiresStatelessReasoning: Bool
    ) -> ContinuationProjectionStatus {
        guard requiresStatelessReasoning else { return .notRequired }
        let turnStart = messages.lastIndex(where: { $0.role == .user }) ?? 0
        for (index, message) in messages.enumerated() where index > turnStart && message.role == .assistant {
            let hadReasoningOrPayloads = (message.reasoning?.isEmpty == false)
                || (message.continuationPayloads?.isEmpty == false)
            guard hadReasoningOrPayloads || !message.toolCalls.isEmpty else { continue }
            let compatible = (message.continuationPayloads ?? []).filter {
                $0.wireKind == "responses_reasoning_item"
                    && $0.isCompatible(with: contractKey, speakerOrThreadID: speakerOrThreadID)
            }
            if compatible.isEmpty {
                return .missingOrIncompatible(
                    reason: "当前 Responses 端点要求完整无状态推理续传项，但历史消息缺少与当前源站/协议/发言者匹配的加密推理载荷。"
                )
            }
        }
        return .compatible
    }

    /// Projects canonical conversation history into stateless OpenAI Responses API JSON body.
    static func body(
        _ request: ModelRequest,
        contractKey: EndpointContractKey? = nil,
        isCodex: Bool = false
    ) -> [String: Any] {
        let targetContract = contractKey ?? EndpointContractKey(
            origin: "https://api.openai.com",
            protocolKind: isCodex ? "openai_codex" : "openai_responses",
            route: "/responses",
            modelID: request.model
        )

        var input: [[String: Any]] = []
        var heldToolImages: [ImagePart] = []

        func releaseToolImages() {
            guard !heldToolImages.isEmpty else { return }
            var parts: [[String: Any]] = heldToolImages.map { image in
                [
                    "type": "input_image",
                    "image_url": "data:\(image.mediaType);base64,\(image.data.base64EncodedString())",
                ]
            }
            parts.append(["type": "input_text", "text": "（上面是工具带回来的图片。）"])
            input.append(["type": "message", "role": "user", "content": parts])
            heldToolImages.removeAll()
        }

        for message in request.messages {
            if message.role != .tool { releaseToolImages() }
            switch message.role {
            case .user:
                var parts: [[String: Any]] = []
                for image in message.images {
                    parts.append([
                        "type": "input_image",
                        "image_url": "data:\(image.mediaType);base64,\(image.data.base64EncodedString())",
                    ])
                }
                if !message.text.isEmpty || parts.isEmpty {
                    parts.append(["type": "input_text", "text": message.text])
                }
                input.append(["type": "message", "role": "user", "content": parts])

            case .assistant:
                // Project ONLY immutable contract-verified & speaker-compatible Responses reasoning items.
                if let payloads = message.continuationPayloads, !payloads.isEmpty {
                    let matching = payloads
                        .filter {
                            $0.wireKind == "responses_reasoning_item"
                                && $0.isCompatible(with: targetContract, speakerOrThreadID: request.speakerOrThreadID)
                        }
                        .sorted { $0.blockOrder < $1.blockOrder }
                    for payload in matching {
                        if let data = payload.opaqueData.data(using: .utf8),
                           let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                           (raw["type"] as? String) == "reasoning" {
                            input.append(raw)
                        }
                    }
                }
                if !message.text.isEmpty {
                    // Use EasyInputMessage with string content so multi-turn history never omits required output_message fields (`id`, `status`, `annotations`).
                    input.append([
                        "type": "message",
                        "role": "assistant",
                        "content": message.text,
                    ])
                }
                for call in message.toolCalls {
                    input.append([
                        "type": "function_call",
                        "call_id": call.id,
                        "name": call.name,
                        "arguments": call.arguments.isEmpty ? "{}" : call.arguments,
                    ])
                }

            case .tool:
                input.append([
                    "type": "function_call_output",
                    "call_id": message.toolCallId ?? "",
                    "output": message.text.isEmpty ? "（空）" : message.text,
                ])
                heldToolImages += message.images
            }
        }
        releaseToolImages()

        var body: [String: Any] = [
            "model": request.model,
            "input": input,
            "stream": true,
            "store": false,
            "max_output_tokens": request.outputLimit ?? request.maxTokens,
        ]

        if !request.system.isEmpty {
            body["instructions"] = request.system
        }

        // Thinking / reasoning configuration.
        let explicitOff = request.isExplicitOff || request.thinking == .off
        var reasoningObject: [String: Any]?
        if let resolvedFields = request.thinkingBodyFields {
            if let existing = resolvedFields["reasoning"]?.foundationValue as? [String: Any] {
                reasoningObject = existing
            } else if let effort = resolvedFields["reasoning_effort"]?.foundationValue as? String {
                reasoningObject = ["effort": effort]
            }
            for (field, value) in resolvedFields where field != "reasoning" && field != "reasoning_effort" {
                body[field] = value.foundationValue
            }
        } else {
            switch request.thinking {
            case .auto:
                break
            case .off:
                reasoningObject = ["effort": "none"]
            case .low:
                reasoningObject = ["effort": "low", "summary": "auto"]
            case .medium:
                reasoningObject = ["effort": "medium", "summary": "auto"]
            case .high:
                reasoningObject = ["effort": "high", "summary": "auto"]
            case .max:
                reasoningObject = ["effort": "xhigh", "summary": "auto"]
            }
        }

        if var reasoning = reasoningObject {
            let effort = (reasoning["effort"] as? String)?.lowercased()
            if effort != "none", reasoning["summary"] == nil {
                reasoning["summary"] = "auto"
            }
            body["reasoning"] = reasoning
        }

        if !explicitOff {
            body["include"] = ["reasoning.encrypted_content"]
        }

        let thinkingActive = !explicitOff && (reasoningObject != nil && (reasoningObject?["effort"] as? String)?.lowercased() != "none")
        if let temperature = request.temperature, !thinkingActive {
            body["temperature"] = temperature
        }

        if !request.tools.isEmpty {
            body["tools"] = request.tools.map { tool in
                [
                    "type": "function",
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": tool.parameters.any,
                ]
            }
        }

        return body
    }

    private final class DecoderState: @unchecked Sendable {
        private let lock = NSLock()
        private var slotByItemID: [String: Int] = [:]
        private var startedSlots: Set<Int> = []
        private var nextSlot = 0
        private var blockOrder = 0

        func slot(for itemID: String, fallbackOutputIndex: Int?) -> Int {
            lock.lock()
            defer { lock.unlock() }
            if !itemID.isEmpty, let existing = slotByItemID[itemID] {
                return existing
            }
            let assigned = fallbackOutputIndex ?? nextSlot
            nextSlot = max(nextSlot, assigned + 1)
            if !itemID.isEmpty { slotByItemID[itemID] = assigned }
            return assigned
        }

        func markStarted(_ slot: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return startedSlots.insert(slot).inserted
        }

        func nextBlockOrder() -> Int {
            lock.lock()
            defer { lock.unlock() }
            let current = blockOrder
            blockOrder += 1
            return current
        }
    }

    static func makeDecoder(
        contractKey: EndpointContractKey,
        speakerOrThreadID: String? = nil
    ) -> @Sendable (String) throws -> [StreamEvent] {
        let state = DecoderState()
        return { payload in
            guard let json = JSONValue.parse(payload) else { return [] }
            if let error = json["error"], error != .null {
                throw ProviderError(error["message"]?.string ?? error.compact)
            }
            guard let type = json["type"]?.string else { return [] }

            switch type {
            case "response.output_text.delta":
                if let delta = json["delta"]?.string, !delta.isEmpty {
                    return [.text(delta)]
                }
                return []

            case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
                if let delta = json["delta"]?.string, !delta.isEmpty {
                    return [.reasoning(delta)]
                }
                return []

            case "response.output_item.added":
                guard let item = json["item"], item["type"]?.string == "function_call" else { return [] }
                let itemID = item["id"]?.string ?? ""
                let callID = item["call_id"]?.string ?? itemID
                let name = item["name"]?.string ?? ""
                let slot = state.slot(for: itemID.isEmpty ? callID : itemID, fallbackOutputIndex: json["output_index"]?.int)
                var events: [StreamEvent] = []
                if state.markStarted(slot) || !name.isEmpty {
                    events.append(.toolCallStart(index: slot, id: callID.isEmpty ? "call_\(slot)" : callID, name: name))
                }
                if let args = item["arguments"]?.string, !args.isEmpty {
                    events.append(.toolCallArguments(index: slot, delta: args))
                }
                return events

            case "response.function_call_arguments.delta":
                let itemID = json["item_id"]?.string ?? ""
                let slot = state.slot(for: itemID, fallbackOutputIndex: json["output_index"]?.int)
                if let delta = json["delta"]?.string, !delta.isEmpty {
                    return [.toolCallArguments(index: slot, delta: delta)]
                }
                return []

            case "response.output_item.done":
                guard let item = json["item"] else { return [] }
                switch item["type"]?.string {
                case "reasoning":
                    let encrypted = item["encrypted_content"]?.string ?? ""
                    let itemID = item["id"]?.string
                    // Only persist stateless continuation payload when encrypted_content or structured reasoning item exists.
                    guard !encrypted.isEmpty else { return [] }
                    var wireItem: [String: Any] = [
                        "type": "reasoning",
                        "encrypted_content": encrypted,
                    ]
                    if let itemID, !itemID.isEmpty { wireItem["id"] = itemID }
                    if let summary = item["summary"]?.any {
                        wireItem["summary"] = summary
                    } else {
                        wireItem["summary"] = []
                    }
                    guard let encoded = try? JSONSerialization.data(withJSONObject: wireItem, options: [.sortedKeys, .withoutEscapingSlashes]) else {
                        return []
                    }
                    let continuation = ProtocolContinuationPayload(
                        origin: contractKey.origin,
                        protocolKind: contractKey.protocolKind,
                        route: contractKey.route,
                        modelID: contractKey.modelID,
                        speakerOrThreadID: speakerOrThreadID,
                        responseItemID: itemID,
                        wireKind: "responses_reasoning_item",
                        blockOrder: state.nextBlockOrder(),
                        opaqueData: String(decoding: encoded, as: UTF8.self),
                        validScope: "stateless_item"
                    )
                    return [.continuationPayload(continuation)]

                case "function_call":
                    let itemID = item["id"]?.string ?? ""
                    let callID = item["call_id"]?.string ?? itemID
                    let name = item["name"]?.string ?? ""
                    let slot = state.slot(for: itemID.isEmpty ? callID : itemID, fallbackOutputIndex: json["output_index"]?.int)
                    var events: [StreamEvent] = []
                    if state.markStarted(slot) {
                        events.append(.toolCallStart(index: slot, id: callID.isEmpty ? "call_\(slot)" : callID, name: name))
                        if let args = item["arguments"]?.string, !args.isEmpty {
                            events.append(.toolCallArguments(index: slot, delta: args))
                        }
                    }
                    return events

                default:
                    return []
                }

            case "response.completed", "response.incomplete":
                var events: [StreamEvent] = []
                let resp = json["response"] ?? .null
                if let usage = resp["usage"], case .object = usage {
                    let input = usage["input_tokens"]?.int ?? 0
                    let output = usage["output_tokens"]?.int ?? 0
                    let cached = usage["input_tokens_details"]?["cached_tokens"]?.int ?? 0
                    events.append(.usage(input: input, output: output, cached: cached))
                }
                let reason: String
                if type == "response.incomplete" || resp["status"]?.string == "incomplete" {
                    let detail = resp["incomplete_details"]?["reason"]?.string?.lowercased() ?? ""
                    if detail.contains("max_output_tokens") || detail.contains("length") {
                        reason = "length"
                    } else if detail.contains("content_filter") || detail.contains("safety") {
                        reason = "content_filter"
                    } else {
                        reason = detail.isEmpty ? "length" : detail
                    }
                } else {
                    reason = "stop"
                }
                events.append(.finish(reason: reason))
                return events

            case "response.failed":
                let message = json["response"]?["error"]?["message"]?.string
                    ?? json["error"]?["message"]?.string
                    ?? "Responses 请求失败。"
                throw ProviderError(message)

            case "error":
                let message = json["message"]?.string
                    ?? json["error"]?["message"]?.string
                    ?? "Responses 流出错。"
                throw ProviderError(message)

            // Lifecycle / heartbeat events emit zero stream events so they never mask an idle stall.
            default:
                return []
            }
        }
    }
}
