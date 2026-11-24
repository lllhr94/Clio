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

public struct ToolOutput: Equatable, Sendable {
    public var text: String
    public var isError: Bool
    /// Pictures the tool brings back, for models that can see: a page's screenshot, a photo from the desk.
    public var images: [ImagePart]
    /// For the person only, never sent to the model: the full comparison of a changed file, say.
    public var detail: String?

    public init(_ text: String, isError: Bool = false, images: [ImagePart] = [], detail: String? = nil) {
        self.text = text
        self.isError = isError
        self.images = images
        self.detail = detail
    }
}

public protocol AgentTool: Sendable {
    var spec: ToolSpec { get }
    /// What the user sees while it runs: 「搜索：重庆天气」.
    func label(for arguments: JSONValue) -> String
    /// Nil: runs without asking.
    func approval(for arguments: JSONValue) -> ApprovalAsk?
    func run(_ arguments: JSONValue) async throws -> ToolOutput
}

public extension AgentTool {
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

    /// How hard to think.
    public var thinking: Thinking = .auto
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
        var request = ModelRequest(model: model, system: system, messages: [.user(prompt)], temperature: temperature, outputLimit: outputLimit, thinking: thinking)
        var text = ""
        var finished: String?
        do {
            for try await event in provider.stream(request) {
                try Task.checkCancellation()
                if case .text(let piece) = event { text += piece }
                if case .finish(let reason) = event, finished == nil { finished = reason }
            }
        } catch let failure as ProviderError where text.isEmpty && request.thinking != .auto && (failure.status == 400 || failure.status == 422) {
            // The model does not take the thinking setting: ask once more without it.
            request.thinking = .auto
            finished = nil
            for try await event in provider.stream(request) {
                try Task.checkCancellation()
                if case .text(let piece) = event { text += piece }
                if case .finish(let reason) = event, finished == nil { finished = reason }
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

    /// Failures that usually pass on their own: a connection dropped or refused on the way, a server that is busy.
    static func passing(_ error: Error) -> Bool {
        if let url = error as? URLError {
            let codes: [URLError.Code] = [.secureConnectionFailed, .networkConnectionLost, .timedOut, .cannotConnectToHost,
                                          .notConnectedToInternet, .dnsLookupFailed, .cannotFindHost, .badServerResponse]
            return codes.contains(url.code)
        }
        if let failure = error as? ProviderError, let status = failure.status { return status == 429 || status >= 500 }
        return false
    }

    public func run(history: [Message], emit: @escaping @Sendable (AgentEvent) async -> Void) async throws {
        var messages = history
        let specs = tools.map { Self.titled($0.spec) }
        var thinking = self.thinking
        var uncertain: Set<String> = []
        for step in 0..<maxSteps {
            try Task.checkCancellation()
            if step > 0, let inbox {
                for said in await inbox() where !said.isEmpty {
                    let heard = Message.user(said)
                    messages.append(heard)
                    await emit(.message(heard))
                }
            }
            var request = ModelRequest(model: model, system: system, messages: messages, tools: specs, temperature: temperature, outputLimit: outputLimit, thinking: thinking)
            var text = ""
            var images: [ReplyImage] = []
            var seenImages: Set<ReplyImage> = []
            var reasoning = ""
            var signature = ""
            var calls: [Int: ToolCall] = [:]
            var order: [Int] = []
            let clock = ContinuousClock()
            var lastWriting = clock.now
            var attempt = 0
            var finished: String?
            while true {
                do {
                    for try await event in provider.stream(request) {
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
                    break
                } catch {
                    let cancelled = Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
                    // Nothing came through yet and the failure looks passing (a dropped or refused connection, a busy server):
                    // ask again, a couple of times, before telling the user.
                    if !cancelled, text.isEmpty, reasoning.isEmpty, images.isEmpty, calls.isEmpty, attempt < retryDelays.count, Self.passing(error) {
                        let wait = retryDelays[attempt]
                        attempt += 1
                        signature = ""
                        finished = nil
                        await emit(.retrying(attempt: attempt))
                        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                        continue
                    }
                    // A model that does not take the thinking setting says so with a 400: go on without it.
                    if !cancelled, thinking != .auto, text.isEmpty, reasoning.isEmpty, images.isEmpty, calls.isEmpty,
                       let failure = error as? ProviderError, failure.status == 400 || failure.status == 422 {
                        await emit(.thinkingRefused(thinking, reason: failure.message))
                        thinking = .auto
                        request.thinking = .auto
                        signature = ""
                        finished = nil
                        continue
                    }
                    // What was written so far stays.
                    if !text.isEmpty {
                        var partial = Message.assistant(text, reasoning: reasoning.isEmpty ? nil : reasoning)
                        if !signature.isEmpty { partial.reasoningSignature = signature }
                        await emit(.message(partial))
                    }
                    if cancelled { throw CancellationError() }
                    throw error
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
            // A stream that stopped without the service saying it was done may have cut a tool call short: its
            // arguments can parse and still be half of what was meant. Nothing is run then (the review, #2).
            // Same for a reply stopped at the length limit in the middle of writing a call.
            let lengthCut = ["length", "max_tokens", "model_length"].contains(finished?.lowercased() ?? "") && !made.isEmpty
            let dropped = finished == nil && !made.isEmpty
            if dropped || lengthCut { made = [] }
            var reply = Message.assistant(text, toolCalls: made, reasoning: reasoning.isEmpty ? nil : reasoning)
            if !signature.isEmpty { reply.reasoningSignature = signature }
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
            for call in made {
                // Stopped: no further step starts (the review, #2).
                try Task.checkCancellation()
                let same = call.name + "\u{1}" + call.arguments
                let result: Message
                if uncertain.contains(same) {
                    result = .toolResult("这一步刚才结果未知，同样的事没有再做一次。先查清现在的状态，或问用户要不要重做。", for: call, isError: true)
                } else {
                    result = await perform(call, emit: emit)
                    if result.isError, result.text.hasPrefix(Self.unknownMark) { uncertain.insert(same) }
                }
                messages.append(result)
                await emit(.message(result))
                try Task.checkCancellation()
            }
        }
        await emit(.message(.assistant("（这件事步骤太多，我先停在这里。要我接着做就说一声。）")))
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

    private func perform(_ call: ToolCall, emit: @Sendable (AgentEvent) async -> Void) async -> Message {
        guard let tool = tools.first(where: { $0.spec.name == call.name }) else {
            return .toolResult("没有叫 \(call.name) 的工具。", for: call, isError: true)
        }
        let source = call.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let given = JSONValue.parse(source.isEmpty ? "{}" : source) else {
            return .toolResult("参数不是合法的 JSON：\(call.arguments.prefix(200))", for: call, isError: true)
        }
        // The model's own words for this step, for the person; the tool never sees them.
        let (arguments, title) = Self.untitled(given)
        await emit(.toolStarted(id: call.id, name: call.name, label: Self.label(tool.label(for: arguments), title: title)))
        let asked = tool.approval(for: arguments) != nil
        if let ask = tool.approval(for: arguments) {
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
        do {
            let output = try await tool.run(arguments)
            await emit(.toolFinished(id: call.id, ok: !output.isError))
            var result = Message.toolResult(screen?(output.text) ?? output.text, for: call, isError: output.isError)
            result.images = output.images
            result.detail = output.detail.map { screen?($0) ?? $0 }
            return result
        } catch {
            await emit(.toolFinished(id: call.id, ok: false))
            // A step that changes things and broke off on the way may or may not have happened.
            if asked, Self.unsure(error) {
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
