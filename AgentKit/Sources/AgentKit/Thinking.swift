import Foundation

/// How hard the model should think before it answers. `auto` sends nothing and leaves it to the model.
public enum Thinking: String, Codable, CaseIterable, Sendable {
    case auto, off, low, medium, high, max

    /// 默认 · 不想 · 浅想 · 想一想 · 深想 · 想到底
    public var title: String {
        switch self {
        case .auto: return "默认"
        case .off: return "不想"
        case .low: return "浅想"
        case .medium: return "想一想"
        case .high: return "深想"
        case .max: return "想到底"
        }
    }

    public var line: String {
        switch self {
        case .auto: return "模型自己定，不额外设置"
        case .off: return "直接回答，最快最省"
        case .low: return "稍微想想，快"
        case .medium: return "一般的事够用"
        case .high: return "难题、写代码、做计划"
        case .max: return "能想多久想多久，慢，也更费钱"
        }
    }

    public var symbol: String {
        switch self {
        case .auto: return "brain"
        case .off: return "bolt"
        case .low: return "lightbulb"
        case .medium: return "lightbulb.max"
        case .high: return "brain.head.profile"
        case .max: return "brain.filled.head.profile"
        }
    }
}

/// How a service wants to be told about thinking. Every service spells it differently; most newer ones take
/// `reasoning_effort`, the ones here are the exceptions and the ones that also have an on-off switch.
public enum ThinkingStyle: String, Codable, CaseIterable, Sendable {
    /// `reasoning_effort` (none … xhigh): OpenAI and most services that copied it; the guess for an unknown service.
    case effort
    /// `thinking.type` plus `reasoning_effort` low / high / max.
    case deepseek
    /// `reasoning_effort` low / high / max; it always thinks.
    case kimi
    /// `enable_thinking` plus `thinking_budget`: 通义千问, 硅基流动.
    case qwen
    /// `thinking.type` plus `reasoning_effort`: 智谱.
    case glm
    /// `thinking.type` enabled / disabled, plus `reasoning_effort`: 豆包.
    case doubao
    /// Always thinks; asks for the thoughts apart from the answer.
    case minimax
    /// `reasoning: {effort}`.
    case openrouter
    /// `reasoning_effort` none / low / medium / high.
    case gemini
    /// `reasoning_effort` low / high, only some models.
    case grok
    /// Sends nothing about thinking.
    case none

    public var title: String {
        switch self {
        case .effort: return "通用（reasoning_effort）"
        case .deepseek: return "DeepSeek"
        case .kimi: return "Kimi"
        case .qwen: return "通义千问 / 硅基流动（enable_thinking）"
        case .glm: return "智谱"
        case .doubao: return "豆包"
        case .minimax: return "MiniMax"
        case .openrouter: return "OpenRouter"
        case .gemini: return "Gemini"
        case .grok: return "Grok"
        case .none: return "不设置"
        }
    }

    /// The service keeps a model's earlier thoughts when they are sent back (and some refuse a tool call without them).
    public var echoesReasoning: Bool {
        switch self {
        case .effort, .deepseek, .kimi, .qwen, .glm, .doubao, .minimax: return true
        case .openrouter, .gemini, .grok, .none: return false
        }
    }

    /// Can thinking be turned off on this service.
    public var canStop: Bool {
        switch self {
        case .kimi, .minimax, .grok: return false
        default: return true
        }
    }

    /// The levels this service really tells apart, for a model that thinks: a level that sends exactly what an
    /// earlier one sends is the same level under another name (DeepSeek's 想一想 and 深想 both ask for "high"),
    /// and 不想 is left out where the model cannot stop thinking. 默认 is always there.
    public func levels(thinks: Bool) -> [Thinking] {
        guard thinks, self != .none else { return [.auto] }
        var offered: [Thinking] = [.auto]
        var sent: [NSDictionary] = []
        for level in [Thinking.off, .low, .medium, .high, .max] {
            if level == .off, !canStop { continue }
            let fields = fields(level) as NSDictionary
            guard fields.count > (self == .minimax ? 1 : 0), !sent.contains(where: { $0.isEqual(fields) }) else { continue }
            sent.append(fields)
            offered.append(level)
        }
        return offered
    }

    /// The body fields that ask for `thinking`. Empty for `.auto`, except where a field is always wanted.
    public func fields(_ thinking: Thinking) -> [String: Any] {
        var fields: [String: Any] = [:]
        if self == .minimax { fields["reasoning_split"] = true }
        guard thinking != .auto else { return fields }
        func effort(_ ladder: [Thinking: String]) {
            if let value = ladder[thinking] { fields["reasoning_effort"] = value }
        }
        switch self {
        case .effort:
            effort([.off: "none", .low: "low", .medium: "medium", .high: "high", .max: "xhigh"])
        case .deepseek:
            fields["thinking"] = ["type": thinking == .off ? "disabled" : "enabled"]
            effort([.low: "low", .medium: "high", .high: "high", .max: "max"])
        case .kimi:
            effort([.off: "low", .low: "low", .medium: "high", .high: "high", .max: "max"])
        case .qwen:
            fields["enable_thinking"] = thinking != .off
            let budgets: [Thinking: Int] = [.low: 1024, .medium: 4096, .high: 16384]
            if let budget = budgets[thinking] { fields["thinking_budget"] = budget }
        case .glm:
            fields["thinking"] = ["type": thinking == .off ? "disabled" : "enabled"]
            effort([.low: "low", .medium: "medium", .high: "high", .max: "max"])
        case .doubao:
            fields["thinking"] = ["type": thinking == .off ? "disabled" : "enabled"]
            effort([.low: "low", .medium: "medium", .high: "high", .max: "high"])
        case .minimax:
            break
        case .openrouter:
            if thinking == .off {
                fields["reasoning"] = ["enabled": false] as [String: Any]
            } else {
                let ladder: [Thinking: String] = [.low: "low", .medium: "medium", .high: "high", .max: "xhigh"]
                fields["reasoning"] = ["effort": ladder[thinking] ?? "medium"] as [String: Any]
            }
        case .gemini:
            effort([.off: "none", .low: "low", .medium: "medium", .high: "high", .max: "high"])
        case .grok:
            effort([.low: "low", .medium: "high", .high: "high", .max: "high"])
        case .none:
            break
        }
        return fields
    }

    /// The style a service at `baseURL` most likely wants.
    public static func guess(baseURL: String) -> ThinkingStyle {
        let host = URL(string: baseURL)?.host()?.lowercased() ?? ""
        func on(_ part: String) -> Bool { host == part || host.hasSuffix("." + part) }
        if on("deepseek.com") { return .deepseek }
        if on("moonshot.cn") || on("moonshot.ai") || on("kimi.com") || on("kimi.ai") { return .kimi }
        if on("aliyuncs.com") || on("siliconflow.cn") || on("siliconflow.com") { return .qwen }
        if on("bigmodel.cn") || on("z.ai") { return .glm }
        if on("volces.com") || on("volcengine.com") { return .doubao }
        if on("minimaxi.com") || on("minimax.io") || on("minimax.chat") { return .minimax }
        if on("openrouter.ai") { return .openrouter }
        if on("googleapis.com") { return .gemini }
        if on("x.ai") { return .grok }
        return .effort
    }
}

/// Some services write a model's thoughts inside its answer, between <think> and </think>. This takes them out,
/// even when a tag arrives in pieces. Only a tag at the very start counts, so an answer that talks about the tag is left alone.
struct ThinkSplitter {
    private enum State { case undecided, thinking, answering }
    private var state = State.undecided
    private var held = ""
    /// Just left the thoughts: the blank lines after </think> are not part of the answer.
    private var trimming = false

    private static let open = "<think>"
    private static let close = "</think>"

    mutating func feed(_ piece: String) -> [StreamEvent] {
        switch state {
        case .answering:
            return answer(piece)
        case .undecided:
            held += piece
            let start = held.drop { $0.isWhitespace }
            if start.isEmpty { return [] }
            if start.count < Self.open.count, Self.open.hasPrefix(start) { return [] }
            if start.hasPrefix(Self.open) {
                state = .thinking
                let rest = String(start.dropFirst(Self.open.count))
                held = ""
                return feed(rest)
            }
            state = .answering
            let all = held
            held = ""
            return all.isEmpty ? [] : [.text(all)]
        case .thinking:
            held += piece
            if let end = held.range(of: Self.close) {
                let thought = String(held[..<end.lowerBound])
                let rest = String(held[end.upperBound...])
                held = ""
                state = .answering
                trimming = true
                var events: [StreamEvent] = thought.isEmpty ? [] : [.reasoning(thought)]
                events += answer(rest)
                return events
            }
            // Keep back what could be the start of </think>.
            let keep = min(held.count, Self.close.count - 1)
            let sure = String(held.dropLast(keep))
            held = String(held.suffix(keep))
            return sure.isEmpty ? [] : [.reasoning(sure)]
        }
    }

    private mutating func answer(_ piece: String) -> [StreamEvent] {
        var text = piece
        if trimming {
            text = String(text.drop { $0.isNewline || $0 == " " })
            if text.isEmpty { return [] }
            trimming = false
        }
        return text.isEmpty ? [] : [.text(text)]
    }

    /// What is still held when the stream ends.
    mutating func flush() -> [StreamEvent] {
        defer { held = "" }
        guard !held.isEmpty else { return [] }
        switch state {
        case .thinking: return [.reasoning(held)]
        default: return [.text(held)]
        }
    }
}
