import Foundation

/// A sequence that must be kept or dropped together before encoding a provider request.
public struct ProtocolAtomicUnit: Equatable, Sendable {
    public let sourceRange: Range<Int>
    public let messages: [Message]
    /// The original index for each message. A synthesized tool result has no source.
    public let sourceIndices: [Int?]

    /// The text budget used by the conversation window, including tool arguments, continuation payloads, and visual content.
    private var characterCost: Int {
        messages.reduce(0) { total, message in
            let payloadChars = (message.continuationPayloads ?? []).reduce(0) { $0 + $1.opaqueData.count }
            let reasoning = (message.reasoning?.count ?? 0) + (message.reasoningSignature?.count ?? 0) + payloadChars
            let arguments = message.toolCalls.reduce(0) { $0 + $1.arguments.count }
            return total + message.text.count + reasoning + arguments + message.images.count * 2000
        }
    }

    /// Groups adjacent assistant reasoning continuations, tool calls + matching results, and (when
    /// `preserveNonToolReasoningTurns` is enabled) non-tool reasoning turns that a target protocol requires
    /// intact as indivisible atomic units (e.g. DeepSeek prior reasoning turns with tools or Responses stateless items).
    public static func group(
        _ history: [Message],
        preserveNonToolReasoningTurns: Bool = false
    ) -> [ProtocolAtomicUnit] {
        var units: [ProtocolAtomicUnit] = []
        var index = 0
        while index < history.count {
            let start = index
            guard history[index].role != .tool else {
                index += 1
                continue
            }

            // When preserving non-tool reasoning turns, keep a user message paired with its immediate
            // non-tool assistant reasoning response if that assistant reply carries protocol continuation state.
            if preserveNonToolReasoningTurns,
               history[index].role == .user,
               index + 1 < history.count,
               isRequiredNonToolReasoningReply(history[index + 1]) {
                let userMsg = history[index]
                var messages: [Message] = [userMsg]
                var sourceIndices: [Int?] = [index]
                index += 1
                while index < history.count,
                      history[index].role == .assistant,
                      history[index].toolCalls.isEmpty,
                      hasProtocolReasoningState(history[index]) {
                    messages.append(history[index])
                    sourceIndices.append(index)
                    index += 1
                }
                units.append(ProtocolAtomicUnit(sourceRange: start..<index, messages: messages, sourceIndices: sourceIndices))
                continue
            }

            var messages: [Message] = []
            var sourceIndices: [Int?] = []
            while isReasoningContinuation(history[index]),
                  index + 1 < history.count, history[index + 1].role == .assistant {
                messages.append(history[index])
                sourceIndices.append(index)
                index += 1
            }

            let message = history[index]
            messages.append(message)
            sourceIndices.append(index)
            index += 1
            if message.role == .assistant, !message.toolCalls.isEmpty {
                var results: [String: Int] = [:]
                while index < history.count, history[index].role == .tool {
                    if let id = history[index].toolCallId, results[id] == nil {
                        results[id] = index
                    }
                    index += 1
                }
                var answered = Set<String>()
                for call in message.toolCalls where answered.insert(call.id).inserted {
                    let source = results[call.id]
                    messages.append(source.map { history[$0] }
                                    ?? .toolResult("（这一步没有完成）", for: call, isError: true))
                    sourceIndices.append(source)
                }
            }
            units.append(ProtocolAtomicUnit(sourceRange: start..<index, messages: messages, sourceIndices: sourceIndices))
        }
        return units
    }

    public static func paired(_ history: [Message], preserveNonToolReasoningTurns: Bool = false) -> [Message] {
        group(history, preserveNonToolReasoningTurns: preserveNonToolReasoningTurns).flatMap(\.messages)
    }

    /// The newest whole units within the budget, starting at a user message when there is one.
    public static func windowStart(
        _ history: [Message],
        maxChars: Int,
        maxCount: Int,
        preserveNonToolReasoningTurns: Bool = false
    ) -> Int {
        let units = group(history, preserveNonToolReasoningTurns: preserveNonToolReasoningTurns)
        guard let last = units.last else { return history.isEmpty ? 0 : history.startIndex }
        var start = last.sourceRange.lowerBound
        var size = 0
        var count = 0
        for unit in units.reversed() {
            size += unit.characterCost
            count += unit.messages.count
            if count > unit.messages.count, (size > maxChars || (maxCount > 0 && count > maxCount)) { break }
            start = unit.sourceRange.lowerBound
        }
        if let user = units.first(where: { $0.sourceRange.lowerBound >= start && $0.messages.first?.role == .user }) {
            return user.sourceRange.lowerBound
        }
        return units.last(where: { $0.sourceRange.lowerBound < start && $0.messages.first?.role == .user })?.sourceRange.lowerBound
            ?? units.first?.sourceRange.lowerBound ?? start
    }

    private static func hasProtocolReasoningState(_ message: Message) -> Bool {
        if let payloads = message.continuationPayloads, !payloads.isEmpty { return true }
        if let sig = message.reasoningSignature, !sig.isEmpty { return true }
        if let reasoning = message.reasoning, !reasoning.isEmpty { return true }
        return false
    }

    private static func isRequiredNonToolReasoningReply(_ message: Message) -> Bool {
        message.role == .assistant && message.toolCalls.isEmpty && hasProtocolReasoningState(message)
    }

    private static func isReasoningContinuation(_ message: Message) -> Bool {
        message.role == .assistant && message.toolCalls.isEmpty
            && (message.reasoningSignature != nil
                || (message.continuationPayloads?.isEmpty == false)
                || (message.text.isEmpty && message.images.isEmpty && message.reasoning != nil))
    }
}
