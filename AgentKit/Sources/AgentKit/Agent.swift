import Foundation

/// What a tool needs the user to agree to before it runs.
public struct ApprovalAsk: Equatable, Sendable {
    /// What will happen, in a few words: 「新建日程」.
    public var title: String
    /// Why, or the thing itself: 「明天 15:00 牙医」.
    public var reason: String
    public var detail: String?
    /// Full command or payload to show in a scrollable code box without truncation.
    public var code: String?
    /// Must be asked even where the person said 「以后都允许」 or 「这段絮语都放行」: the turn read text from the web,
    /// which may carry instructions aimed at the model.
    public var forced: Bool

    public init(title: String, reason: String, detail: String? = nil, code: String? = nil, forced: Bool = false) {
        self.title = title
        self.reason = reason
        self.detail = detail
        self.code = code
        self.forced = forced
    }
}

/// Scopes a unique identifier to a single `Agent.perform(_:)` tool invocation via `@TaskLocal`
/// so single-use approval receipts bind strictly to one call and never leak across calls or chats.
public enum ToolInvocation {
    @TaskLocal public static var currentID: String?
    /// True only while executing inside a parallel read-only batch (`Agent.performConcurrentBatch`).
    @TaskLocal public static var isConcurrentBatch = false
}

public struct ToolOutput: Equatable, Sendable {
    public var text: String
    public var isError: Bool
    /// Pictures the tool brings back, for models that can see: a page's screenshot, a photo from the desk.
    public var images: [ImagePart]
    /// For the person only, never sent to the model: the full comparison of a changed file, say.
    public var detail: String?
    /// An existing image to rehydrate instead of creating another stored copy.
    public var loadedMediaReference: String?
    public var loadedMediaSourceTool: String?

    public init(
        _ text: String, isError: Bool = false, images: [ImagePart] = [], detail: String? = nil,
        loadedMediaReference: String? = nil, loadedMediaSourceTool: String? = nil
    ) {
        self.text = text
        self.isError = isError
        self.images = images
        self.detail = detail
        self.loadedMediaReference = loadedMediaReference
        self.loadedMediaSourceTool = loadedMediaSourceTool
    }
}

public protocol AgentTool: Sendable {
    var spec: ToolSpec { get }
    /// Whether calling this tool has zero side effects and can safely run concurrently with other read-only tools.
    var isReadOnlySafe: Bool { get }
    /// Whether a completed call can change state. An otherwise read-only tool can still require serial execution.
    var hasSideEffects: Bool { get }
    /// What the user sees while it runs: 「搜索：重庆天气」.
    func label(for arguments: JSONValue) -> String
    /// Nil: runs without asking.
    func approval(for arguments: JSONValue) -> ApprovalAsk?
    func run(_ arguments: JSONValue) async throws -> ToolOutput
}

public extension AgentTool {
    var isReadOnlySafe: Bool { false }
    var hasSideEffects: Bool { !isReadOnlySafe }
    func approval(for arguments: JSONValue) -> ApprovalAsk? { nil }
}

public enum AgentEvent: Equatable, Sendable {
    case text(String)
    case reasoning(String)
    case toolStarted(id: String, name: String, label: String)
    /// The model is still writing a long tool call's arguments: how many characters so far. At most every 150 ms.
    case toolWriting(name: String, characters: Int)
    /// The request failed before anything came back, in a way that usually passes; asking again (1, 2…).
    case retrying(attempt: Int)
    /// The service refused the thinking setting; the rest of this turn goes without it.
    case thinkingRefused(Thinking, reason: String)
    case toolFinished(id: String, ok: Bool)
    /// The model's turn ended without a full answer, and why: worth a word to the user, not to the model.
    case cutShort(CutShort)
    /// A finished message, to keep.
    case message(Message)
    case usage(input: Int, output: Int, cached: Int = 0)
}

/// Why an answer came back missing or short (after Open Minis, which found users reading every one of these as
/// "the model said nothing").
public enum CutShort: Equatable, Sendable {
    /// The stream ended without the service closing it: the connection dropped.
    case dropped
    /// It thought (this many characters) but wrote no answer.
    case thoughtOnly(Int)
    /// The service's content filter stopped it.
    case filtered
    /// The answer reached the length limit and stops mid-way.
    case truncated
    /// Nothing at all, and the service said it was done.
    case empty
}

/// One Bot's turn: asks the model, runs the tools it calls, and asks again until it answers.
public struct Agent: Sendable {
    public var provider: ModelProvider
    public var model: String
    public var system: String
    public var tools: [AgentTool]
    public var maxSteps: Int
    public var approve: @Sendable (ApprovalAsk, String) async -> Bool
    public var temperature: Double?
    public var outputLimit: Int?
    /// Converts native reply images to caller-owned text (for example local Markdown links).
    public var renderReplyImages: (@Sendable ([ReplyImage]) async throws -> String)?
    /// Converts tool imagery to caller-owned references before it can enter model history or persisted messages.
    public var prepareToolResult: (@Sendable (Message) async -> Message)?

    /// How hard to think.
    public var thinking: Thinking = .auto
    /// Optional pre-resolved v2 thinking wire fields (from `ThinkingRuleResolver`).
    public var thinkingBodyFields: [String: ThinkingWireValue]? = nil
    /// Immutable target contract identity stamped onto protocol continuation payloads.
    public var contractKey: EndpointContractKey? = nil
    /// Speaker or thread isolation scope for multi-companion gatherings.
    public var speakerOrThreadID: String? = nil
    /// Non-secret custom headers forwarded to the provider.
    public var customHeaders: [String: String] = [:]
    /// Split streaming timeout configuration (TTFB / heartbeat-immune idle / total).
    public var streamTimeouts: StreamTimeouts = .default
    /// True when the user explicitly chose thinking OFF (enforces zero-fallback terminal semantics).
    public var isExplicitOff: Bool = false
    /// When true, `ProtocolAtomicUnit` keeps non-tool reasoning turns indivisible as well.
    public var preserveNonToolReasoningTurns: Bool = false
    /// Seconds to wait before each new try of a request that failed on the way; one entry per try.
    public var retryDelays: [Double] = [1, 3]
    /// What the person said while the turn was at work (插话): read between steps, before the model is asked again.
    public var inbox: (@Sendable () async -> [String])?
    /// Applied to every tool result before the model reads it: hides kept secrets and trims what is far too long. One
    /// place for every tool, so a web page, an MCP service or a browser field showing a password is covered too.
    public var screen: (@Sendable (String) -> String)?

    public init(provider: ModelProvider, model: String, system: String, tools: [AgentTool] = [], maxSteps: Int = 16, approve: @escaping @Sendable (ApprovalAsk, String) async -> Bool = { _, _ in false }) {
        self.provider = provider
        self.model = model
        self.system = system
        self.tools = tools
        self.maxSteps = maxSteps
        self.approve = approve
    }

    /// Asks once with no tools and returns the whole answer: for summaries and titles.
    public func ask(_ prompt: String) async throws -> String {
        var request = ModelRequest(
            model: model,
            system: system,
            messages: [.user(prompt)],
            temperature: temperature,
            outputLimit: outputLimit,
            thinking: thinking,
            thinkingBodyFields: thinkingBodyFields,
            contractKey: contractKey,
            speakerOrThreadID: speakerOrThreadID,
            customHeaders: customHeaders,
            streamTimeouts: streamTimeouts,
            isExplicitOff: isExplicitOff || thinking == .off
        )
        let retryArbiter = WholeTurnRetryArbiter()
        var text = ""
        var finished: String?
        var attempt = 0
        while true {
            var hasOutput = false
            do {
                for try await event in provider.stream(request) {
                    try Task.checkCancellation()
                    hasOutput = hasOutput || Self.output(event)
                    if case .text(let piece) = event { text += piece }
                    if case .finish(let reason) = event, finished == nil { finished = reason }
                }
                break
            } catch {
                switch retryArbiter.decide(
                    after: error,
                    requestHasOutput: hasOutput,
                    thinking: request.thinking,
                    canTrimContext: false,
                    hasTransientRetry: attempt < retryDelays.count,
                    hasImages: Self.containsImages(request.messages),
                    isExplicitOff: isExplicitOff || request.thinking == .off
                ) {
                case .retryWithoutThinking:
                    request.thinking = .auto
                    request.thinkingBodyFields = nil
                case .retryTransient:
                    let wait = retryDelays[attempt]
                    attempt += 1
                    if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                case .retryWithoutImages:
                    request.messages = Self.strippingImagesWithPlaceholders(request.messages)
                case .retryShorterContext, .retryRegenerateToolCall, .stop:
                    if WholeTurnRetryArbiter.cancelled(error) { throw CancellationError() }
                    throw error
                }
                finished = nil
            }
        }
        // Half an answer is not an answer: a summary made from it would stand in for everything it covers
        // (the review, #19).
        if finished == nil { throw ProviderError("回答没收完：连接中途断了。") }
        let reason = finished?.lowercased() ?? ""
        if ["length", "max_tokens", "model_length"].contains(reason) { throw ProviderError("回答写到长度上限被截断了。") }
        if ["content_filter", "sensitive", "safety", "refusal"].contains(reason) { throw ProviderError("回答被内容审核拦下了。") }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func output(_ event: StreamEvent) -> Bool {
        switch event {
        case .text(let piece), .reasoning(let piece), .reasoningSignature(let piece):
            return !piece.isEmpty
        case .continuationPayload, .image, .toolCallStart, .toolCallArguments:
            return true
        case .usage, .finish:
            return false
        }
    }

    static func containsImages(_ messages: [Message]) -> Bool {
        messages.contains { !$0.images.isEmpty }
    }

    /// Strips inline image bytes after a 413 payload-too-large failure while preserving explicit missing-image semantics.
    static func strippingImagesWithPlaceholders(_ messages: [Message]) -> [Message] {
        messages.map { message in
            guard !message.images.isEmpty else { return message }
            var copy = message
            let count = copy.images.count
            copy.images = []
            let note = count == 1
                ? "（原消息附带 1 张图片，因请求体超过服务端限制本轮已省略，请按文字上下文作答或提示用户缩小图片。）"
                : "（原消息附带 \(count) 张图片，因请求体超过服务端限制本轮已省略，请按文字上下文作答或提示用户减少图片。）"
            copy.text = copy.text.isEmpty ? note : copy.text + "\n" + note
            return copy
        }
    }

    private static func buildContinuationPayloads(
        collected: [ProtocolContinuationPayload],
        contractKey: EndpointContractKey?,
        speakerOrThreadID: String?,
        reasoning: String,
        signature: String,
        toolCalls: [ToolCall]
    ) -> [ProtocolContinuationPayload]? {
        if !collected.isEmpty { return collected }
        guard let contract = contractKey else { return nil }
        let refs = toolCalls.map(\.id)
        if contract.protocolKind == "anthropic", !signature.isEmpty {
            let unpacked = AnthropicProvider.unpackSignature(signature)
            var result: [ProtocolContinuationPayload] = []
            var order = 0
            if !unpacked.signature.isEmpty {
                let encoded: String
                if let data = try? JSONSerialization.data(
                    withJSONObject: ["thinking": reasoning, "signature": unpacked.signature],
                    options: [.sortedKeys, .withoutEscapingSlashes]
                ) {
                    encoded = String(decoding: data, as: UTF8.self)
                } else {
                    encoded = unpacked.signature
                }
                result.append(ProtocolContinuationPayload(
                    origin: contract.origin,
                    protocolKind: contract.protocolKind,
                    route: contract.route,
                    modelID: contract.modelID,
                    speakerOrThreadID: speakerOrThreadID,
                    wireKind: "anthropic_thinking",
                    blockOrder: order,
                    opaqueData: encoded,
                    toolCallRefs: refs,
                    validScope: "turn"
                ))
                order += 1
            }
            for redacted in unpacked.redacted {
                result.append(ProtocolContinuationPayload(
                    origin: contract.origin,
                    protocolKind: contract.protocolKind,
                    route: contract.route,
                    modelID: contract.modelID,
                    speakerOrThreadID: speakerOrThreadID,
                    wireKind: "anthropic_redacted_thinking",
                    blockOrder: order,
                    opaqueData: redacted,
                    toolCallRefs: refs,
                    validScope: "turn"
                ))
                order += 1
            }
            return result.isEmpty ? nil : result
        }
        if contract.protocolKind == "openai", !reasoning.isEmpty {
            return [
                ProtocolContinuationPayload(
                    origin: contract.origin,
                    protocolKind: contract.protocolKind,
                    route: contract.route,
                    modelID: contract.modelID,
                    speakerOrThreadID: speakerOrThreadID,
                    wireKind: "openai_reasoning_content",
                    blockOrder: 0,
                    opaqueData: reasoning,
                    toolCallRefs: refs,
                    validScope: "turn"
                ),
            ]
        }
        return nil
    }

    static let maxToolConcurrency = 4

    private struct PreparedCall: Sendable {
        let index: Int
        let call: ToolCall
        let sameKey: ToolLoopDetector.CallKey
        let tool: AgentTool
        let arguments: JSONValue
        let title: String?
    }

    public func run(
        history: [Message], retryArbiter: WholeTurnRetryArbiter = WholeTurnRetryArbiter(),
        emit: @escaping @Sendable (AgentEvent) async -> Void
    ) async throws {
        var messages = ProtocolAtomicUnit.paired(history, preserveNonToolReasoningTurns: preserveNonToolReasoningTurns)
        let activeTurnStart = messages.lastIndex(where: { $0.role == .user }) ?? 0
        var retainedStart = 0
        let specs = tools.map { Self.titled($0.spec) }
        let mutatingTools = Set(tools.filter(\.hasSideEffects).map { $0.spec.name })
        var thinking = self.thinking
        var thinkingBodyFields = self.thinkingBodyFields
        let explicitOffRequested = self.isExplicitOff || self.thinking == .off
        var stripImagesForRequest = false
        var uncertain: Set<ToolLoopDetector.CallKey> = []
        var loopDetector = ToolLoopDetector()
        var nudge: String?
        for step in 0..<maxSteps {
            try Task.checkCancellation()
            if step > 0, let inbox {
                var heardAny = false
                for said in await inbox() where !said.isEmpty {
                    let heard = Message.user(said)
                    messages.append(heard)
                    await emit(.message(heard))
                    heardAny = true
                }
                if heardAny {
                    loopDetector = ToolLoopDetector()
                    nudge = nil
                }
            }
            func requestMessages(startingAt start: Int) -> [Message] {
                var outgoing = Array(messages[start...])
                if stripImagesForRequest {
                    outgoing = Self.strippingImagesWithPlaceholders(outgoing)
                }
                if let nudge, let index = outgoing.lastIndex(where: { $0.role == .tool }) {
                    outgoing[index].text += "\n" + nudge
                }
                return outgoing
            }
            var request = ModelRequest(
                model: model, system: system, messages: requestMessages(startingAt: retainedStart),
                tools: specs, temperature: temperature, outputLimit: outputLimit, thinking: thinking,
                thinkingBodyFields: thinkingBodyFields, contractKey: contractKey,
                speakerOrThreadID: speakerOrThreadID, customHeaders: customHeaders,
                streamTimeouts: streamTimeouts, isExplicitOff: explicitOffRequested
            )
            var text = ""
            var images: [ReplyImage] = []
            var seenImages: Set<ReplyImage> = []
            var reasoning = ""
            var signature = ""
            var collectedPayloads: [ProtocolContinuationPayload] = []
            var calls: [Int: ToolCall] = [:]
            var order: [Int] = []
            let clock = ContinuousClock()
            var lastWriting = clock.now
            var attempt = 0
            var finished: String?
            var hasOutput = false
            while true {
                do {
                    for try await event in provider.stream(request) {
                        if !hasOutput, Self.output(event) {
                            hasOutput = true
                            retryArbiter.recordOutput()
                        }
                        switch event {
                        case .text(let piece):
                            text += piece
                            await emit(.text(piece))
                        case .image(let image):
                            if seenImages.insert(image).inserted { images.append(image) }
                        case .reasoning(let piece):
                            reasoning += piece
                            await emit(.reasoning(piece))
                        case .reasoningSignature(let piece):
                            signature += piece
                        case .continuationPayload(let payload):
                            collectedPayloads.append(payload)
                        case .toolCallStart(let index, let id, let name):
                            if calls[index] == nil { order.append(index) }
                            calls[index] = ToolCall(id: id, name: name, arguments: calls[index]?.arguments ?? "")
                        case .toolCallArguments(let index, let delta):
                            if calls[index] == nil {
                                order.append(index)
                                calls[index] = ToolCall(id: "call_\(index)", name: "", arguments: "")
                            }
                            calls[index]?.arguments += delta
                            // A long file being written as arguments can take a while; say how far it got, without a word per piece.
                            if let call = calls[index], clock.now - lastWriting >= .milliseconds(150) {
                                let written = call.arguments.utf16.count
                                if written > 400 {
                                    lastWriting = clock.now
                                    await emit(.toolWriting(name: call.name, characters: written))
                                }
                            }
                        case .usage(let input, let output, let cached):
                            await emit(.usage(input: input, output: output, cached: cached))
                        case .finish(let reason):
                            // The first reason given counts (a later 「done」 must not hide 「length」).
                            if finished == nil { finished = reason }
                        }
                    }

                    // If the model wrote a suspected raw tool call inside its thinking block with zero text or structured tool calls,
                    // allow one arbiter-approved regeneration asking it to invoke the structured tool schema directly.
                    let preliminaryCalls = order.compactMap { calls[$0] }.filter { !$0.name.isEmpty }
                    if !specs.isEmpty,
                       WholeTurnRetryArbiter.looksLikeSuspectedReasoningToolCall(
                           reasoning: reasoning, text: text, toolCallCount: preliminaryCalls.count
                       ),
                       retryArbiter.allowsReasoningToolRegeneration(
                           hasDeliveredTextOrTools: !text.isEmpty || !preliminaryCalls.isEmpty || !images.isEmpty,
                           isExplicitOff: explicitOffRequested
                       ) {
                        text = ""
                        images = []
                        seenImages = []
                        reasoning = ""
                        signature = ""
                        collectedPayloads = []
                        calls = [:]
                        order = []
                        finished = nil
                        hasOutput = false
                        var retryMessages = requestMessages(startingAt: retainedStart)
                        retryMessages.append(.user("（系统提示：请直接通过结构化工具调用发出所需工具，不要把工具调用 JSON 写在思考内容里。）"))
                        request.messages = retryMessages
                        continue
                    }
                    break
                } catch {
                    switch retryArbiter.decide(
                        after: error,
                        requestHasOutput: hasOutput,
                        thinking: thinking,
                        canTrimContext: retainedStart < activeTurnStart,
                        hasTransientRetry: attempt < retryDelays.count,
                        hasImages: Self.containsImages(request.messages),
                        isExplicitOff: explicitOffRequested
                    ) {
                    case .retryTransient:
                        let wait = retryDelays[attempt]
                        attempt += 1
                        await emit(.retrying(attempt: attempt))
                        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                    case .retryWithoutThinking:
                        let reason = (error as? ProviderError)?.message ?? error.localizedDescription
                        await emit(.thinkingRefused(thinking, reason: reason))
                        thinking = .auto
                        thinkingBodyFields = nil
                        request.thinking = .auto
                        request.thinkingBodyFields = nil
                    case .retryShorterContext:
                        retainedStart = activeTurnStart
                        request.messages = requestMessages(startingAt: retainedStart)
                    case .retryWithoutImages:
                        stripImagesForRequest = true
                        request.messages = requestMessages(startingAt: retainedStart)
                    case .retryRegenerateToolCall, .stop:
                        // What was written so far stays.
                        if !text.isEmpty {
                            var partial = Message.assistant(text, reasoning: reasoning.isEmpty ? nil : reasoning)
                            if !signature.isEmpty { partial.reasoningSignature = signature }
                            partial.continuationPayloads = Self.buildContinuationPayloads(
                                collected: collectedPayloads,
                                contractKey: contractKey,
                                speakerOrThreadID: speakerOrThreadID,
                                reasoning: reasoning,
                                signature: signature,
                                toolCalls: []
                            )
                            await emit(.message(partial))
                        }
                        if WholeTurnRetryArbiter.cancelled(error) { throw CancellationError() }
                        throw error
                    }
                    signature = ""
                    collectedPayloads = []
                    finished = nil
                }
            }
            if !images.isEmpty, let renderReplyImages {
                do {
                    try Task.checkCancellation()
                    let attachments = try await renderReplyImages(images)
                    if !attachments.isEmpty { text += (text.isEmpty ? "" : "\n\n") + attachments }
                } catch {
                    let cancelled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
                    if !text.isEmpty {
                        var partial = Message.assistant(text, reasoning: reasoning.isEmpty ? nil : reasoning)
                        if !signature.isEmpty { partial.reasoningSignature = signature }
                        await emit(.message(partial))
                    }
                    if cancelled { throw CancellationError() }
                    throw error
                }
            }
            var made = order.compactMap { calls[$0] }.filter { !$0.name.isEmpty }
            // A stream that stopped without finishing cleanly (dropped, truncated, filtered, or incomplete)
            // may have cut a tool call short: never execute partial/filtered tool calls.
            let finishReasonLower = finished?.lowercased() ?? ""
            let lengthCut = ["length", "max_tokens", "model_length"].contains(finishReasonLower) && !made.isEmpty
            let filteredOrIncomplete = ["content_filter", "sensitive", "safety", "refusal", "incomplete"].contains(finishReasonLower) && !made.isEmpty
            let dropped = finished == nil && !made.isEmpty
            if dropped || lengthCut || filteredOrIncomplete { made = [] }
            var reply = Message.assistant(text, toolCalls: made, reasoning: reasoning.isEmpty ? nil : reasoning)
            if !signature.isEmpty { reply.reasoningSignature = signature }
            reply.continuationPayloads = Self.buildContinuationPayloads(
                collected: collectedPayloads,
                contractKey: contractKey,
                speakerOrThreadID: speakerOrThreadID,
                reasoning: reasoning,
                signature: signature,
                toolCalls: made
            )
            if !text.isEmpty || !made.isEmpty {
                messages.append(reply)
                await emit(.message(reply))
            }
            // Said after the reply, so the note sits under what did come.
            if dropped {
                await emit(.cutShort(.dropped))
            } else if lengthCut {
                await emit(.cutShort(.truncated))
            } else if let short = Self.cutShort(text: text, reasoning: reasoning, images: images.count, calls: made.count, finish: finished) {
                await emit(.cutShort(short))
            }
            if made.isEmpty {
                if Task.isCancelled { throw CancellationError() }
                return
            }
            let outcomes = try await executeToolCalls(
                made, messages: &messages, uncertain: &uncertain, retryArbiter: retryArbiter, emit: emit
            )
            switch loopDetector.record(calls: made, results: outcomes, mutatingTools: mutatingTools) {
            case .continue:
                nudge = nil
            case .nudge(let reminder):
                nudge = reminder
            case .stop(let notice):
                await emit(.message(.assistant(notice)))
                return
            }
        }
        await emit(.message(.assistant("（这件事步骤太多，我先停在这里。要我接着做就说一声。）")))
    }

    private func prepareConcurrentCandidate(_ call: ToolCall, at index: Int, uncertain: Set<ToolLoopDetector.CallKey>) -> PreparedCall? {
        let same = ToolLoopDetector.CallKey(call)
        guard !uncertain.contains(same) else { return nil }
        guard let tool = tools.first(where: { $0.spec.name == call.name }) else { return nil }
        guard tool.isReadOnlySafe else { return nil }
        let source = call.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let given = JSONValue.parse(source.isEmpty ? "{}" : source) else { return nil }
        let (arguments, title) = Self.untitled(given)
        guard tool.approval(for: arguments) == nil else { return nil }
        return PreparedCall(
            index: index,
            call: call,
            sameKey: same,
            tool: tool,
            arguments: arguments,
            title: title
        )
    }

    private func executeToolCalls(
        _ made: [ToolCall],
        messages: inout [Message],
        uncertain: inout Set<ToolLoopDetector.CallKey>,
        retryArbiter: WholeTurnRetryArbiter,
        emit: @escaping @Sendable (AgentEvent) async -> Void
    ) async throws -> [Message] {
        var outcomes: [Message] = []
        outcomes.reserveCapacity(made.count)
        var cursor = 0
        while cursor < made.count {
            try Task.checkCancellation()
            var batch: [PreparedCall] = []
            var lookahead = cursor
            while lookahead < made.count,
                  let candidate = prepareConcurrentCandidate(made[lookahead], at: lookahead, uncertain: uncertain) {
                batch.append(candidate)
                lookahead += 1
            }
            if batch.count >= 2 {
                let results = try await performConcurrentBatch(batch, retryArbiter: retryArbiter, emit: emit)
                for (prepared, result) in zip(batch, results) {
                    if result.isError, result.text.hasPrefix(Self.unknownMark) {
                        uncertain.insert(prepared.sameKey)
                        retryArbiter.recordUnknownOutcome()
                    }
                    messages.append(result)
                    await emit(.message(result))
                    outcomes.append(result)
                }
                try Task.checkCancellation()
                cursor = lookahead
            } else {
                let call = made[cursor]
                let same = ToolLoopDetector.CallKey(call)
                let result: Message
                if uncertain.contains(same) {
                    result = .toolResult("这一步刚才结果未知，同样的事没有再做一次。先查清现在的状态，或问用户要不要重做。", for: call, isError: true)
                } else {
                    result = await perform(call, retryArbiter: retryArbiter, emit: emit)
                    if result.isError, result.text.hasPrefix(Self.unknownMark) {
                        uncertain.insert(same)
                        retryArbiter.recordUnknownOutcome()
                    }
                }
                messages.append(result)
                await emit(.message(result))
                outcomes.append(result)
                try Task.checkCancellation()
                cursor += 1
            }
        }
        return outcomes
    }

    private func performConcurrentBatch(
        _ batch: [PreparedCall],
        retryArbiter: WholeTurnRetryArbiter,
        emit: @escaping @Sendable (AgentEvent) async -> Void
    ) async throws -> [Message] {
        var ordered: [Message?] = Array(repeating: nil, count: batch.count)
        try await withThrowingTaskGroup(of: (offset: Int, message: Message).self) { group in
            var next = 0
            let initial = min(Self.maxToolConcurrency, batch.count)
            while next < initial {
                try Task.checkCancellation()
                let offset = next
                let item = batch[offset]
                next += 1
                group.addTask {
                    try Task.checkCancellation()
                    let message = await self.performPrepared(item, retryArbiter: retryArbiter, emit: emit)
                    return (offset: offset, message: message)
                }
            }
            while let done = try await group.next() {
                ordered[done.offset] = done.message
                if Task.isCancelled {
                    group.cancelAll()
                    throw CancellationError()
                }
                if next < batch.count {
                    let offset = next
                    let item = batch[offset]
                    next += 1
                    group.addTask {
                        try Task.checkCancellation()
                        let message = await self.performPrepared(item, retryArbiter: retryArbiter, emit: emit)
                        return (offset: offset, message: message)
                    }
                }
            }
        }
        try Task.checkCancellation()
        return ordered.compactMap { $0 }
    }

    static func cutShort(text: String, reasoning: String, images: Int, calls: Int, finish: String?) -> CutShort? {
        let reason = finish?.lowercased()
        if calls == 0, ["length", "max_tokens", "model_length"].contains(reason ?? "") { return .truncated }
        // Words came, then the stream stopped without the service closing it: what is there may be half an answer
        // (the review, #19). A filtered answer that still sent words is said to be filtered.
        if calls == 0, ["content_filter", "sensitive", "safety", "refusal"].contains(reason ?? ""), images == 0 { return .filtered }
        if calls == 0, images == 0, finish == nil, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return .dropped }
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, images == 0, calls == 0 else { return nil }
        if ["content_filter", "sensitive", "safety", "refusal"].contains(reason ?? "") { return .filtered }
        if !reasoning.isEmpty { return .thoughtOnly(reasoning.count) }
        return reason == nil ? .dropped : .empty
    }

    /// Every tool takes one more, optional argument: a short line in the model's words for what this step does.
    static let titleKey = "step_title"

    static func titled(_ spec: ToolSpec) -> ToolSpec {
        guard case .object(var schema) = spec.parameters else { return spec }
        var properties: [String: JSONValue] = [:]
        if case .object(let existing)? = schema["properties"] { properties = existing }
        properties[titleKey] = .object(["type": .string("string"), "description": .string("一句话告诉用户这一步在做什么，十几个字，比如：查明天重庆的天气")])
        schema["properties"] = .object(properties)
        var titled = spec
        titled.parameters = .object(schema)
        return titled
    }

    static func untitled(_ arguments: JSONValue) -> (JSONValue, String?) {
        guard case .object(var fields) = arguments else { return (arguments, nil) }
        let title = fields.removeValue(forKey: titleKey)?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (.object(fields), title?.isEmpty == false ? String(title!.prefix(40)) : nil)
    }

    /// 「搜索：重庆天气」 with the model's title in place of the words after the colon.
    static func label(_ label: String, title: String?) -> String {
        guard let title else { return label }
        guard let colon = label.firstIndex(of: "：") else { return label.isEmpty ? title : "\(label)：\(title)" }
        return "\(label[..<colon])：\(title)"
    }

    private func perform(
        _ call: ToolCall, retryArbiter: WholeTurnRetryArbiter, emit: @Sendable (AgentEvent) async -> Void
    ) async -> Message {
        guard let tool = tools.first(where: { $0.spec.name == call.name }) else {
            return .toolResult("没有叫 \(call.name) 的工具。", for: call, isError: true)
        }
        let source = call.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let given = JSONValue.parse(source.isEmpty ? "{}" : source) else {
            return .toolResult("参数不是合法的 JSON：\(source.prefix(200))", for: call, isError: true)
        }
        // The model's own words for this step, for the person; the tool never sees them.
        let (arguments, title) = Self.untitled(given)
        let invocationID = "\(call.id)-\(UUID().uuidString)"
        return await ToolInvocation.$currentID.withValue(invocationID) {
            await ToolInvocation.$isConcurrentBatch.withValue(false) {
                await executeTool(call: call, tool: tool, arguments: arguments, title: title,
                                  allowApproval: true, retryArbiter: retryArbiter, emit: emit)
            }
        }
    }

    private func performPrepared(
        _ prepared: PreparedCall, retryArbiter: WholeTurnRetryArbiter, emit: @Sendable (AgentEvent) async -> Void
    ) async -> Message {
        let invocationID = "\(prepared.call.id)-\(UUID().uuidString)"
        return await ToolInvocation.$currentID.withValue(invocationID) {
            await ToolInvocation.$isConcurrentBatch.withValue(true) {
                await executeTool(
                    call: prepared.call,
                    tool: prepared.tool,
                    arguments: prepared.arguments,
                    title: prepared.title,
                    allowApproval: false,
                    retryArbiter: retryArbiter,
                    emit: emit
                )
            }
        }
    }

    private func executeTool(
        call: ToolCall,
        tool: AgentTool,
        arguments: JSONValue,
        title: String?,
        allowApproval: Bool,
        retryArbiter: WholeTurnRetryArbiter,
        emit: @Sendable (AgentEvent) async -> Void
    ) async -> Message {
        await emit(.toolStarted(id: call.id, name: call.name, label: Self.label(tool.label(for: arguments), title: title)))
        let ask = tool.approval(for: arguments)
        if let ask {
            guard allowApproval else {
                await emit(.toolFinished(id: call.id, ok: false))
                return .toolResult("这一步临时需要确认，没有并行执行。", for: call, isError: true)
            }
            guard await approve(ask, call.name) else {
                await emit(.toolFinished(id: call.id, ok: false))
                return .toolResult("用户没有同意这次操作，什么都没做。除非用户再次要求，不要重试。", for: call, isError: true)
            }
        }
        // Stopped while the approval was open: nothing runs, even if it was approved.
        if Task.isCancelled {
            await emit(.toolFinished(id: call.id, ok: false))
            return .toolResult("这一轮已经停下，这一步没有做。", for: call, isError: true)
        }
        if tool.hasSideEffects { retryArbiter.recordSideEffect() }
        do {
            let output = try await tool.run(arguments)
            var result = Message.toolResult(screen?(output.text) ?? output.text, for: call, isError: output.isError)
            result.images = output.images
            result.detail = output.detail.map { screen?($0) ?? $0 }
            result.mediaReferences = output.loadedMediaReference.map { [$0] }
            result.mediaSourceTool = output.loadedMediaSourceTool
            if let prepareToolResult { result = await prepareToolResult(result) }
            await emit(.toolFinished(id: call.id, ok: !result.isError))
            return result
        } catch {
            await emit(.toolFinished(id: call.id, ok: false))
            // A step that changes things and broke off on the way may or may not have happened.
            if tool.hasSideEffects, Self.unsure(error) {
                let rawBody = "这一步可能已经做了，也可能没做（\(error.localizedDescription)）。不要直接再做一次：先查清现在的状态，查不清就问用户。"
                let safeBody = screen?(rawBody) ?? rawBody
                return .toolResult(Self.unknownMark + safeBody, for: call, isError: true)
            }
            let words = "出错了：\(error.localizedDescription)"
            return .toolResult(screen?(words) ?? words, for: call, isError: true)
        }
    }

    /// The start of a tool result whose outcome is not known.
    public static let unknownMark = "结果未知："

    /// Failures after which a step's outcome can't be told: it timed out, the line dropped, or it was stopped.
    static func unsure(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let url = error as? URLError {
            return [.timedOut, .networkConnectionLost, .cancelled, .notConnectedToInternet].contains(url.code)
        }
        let words = error.localizedDescription
        return words.contains("超时") || words.localizedCaseInsensitiveContains("timed out") || words.localizedCaseInsensitiveContains("timeout")
    }
}
