import AgentKit
import Foundation

/// How a conversation is cut and mended before it goes to the model.
public enum Conversation {
    /// Where the part sent to the model begins: the newest messages that fit in `maxChars` (and `maxCount`, when above 0),
    /// moved forward to the next message the user wrote, so the model never starts in the middle of a step.
    /// When no user message follows (a group, where the last word is another companion's), it reaches back to the one before instead,
    /// so the window is never empty.
    public static func windowStart(_ messages: [Message], maxChars: Int, maxCount: Int) -> Int {
        var start = messages.count
        var size = 0
        while start > 0 {
            let message = messages[start - 1]
            size += message.text.count + message.toolCalls.reduce(0) { $0 + $1.arguments.count }
            if size > maxChars, start < messages.count - 1 { break }
            if maxCount > 0, messages.count - start >= maxCount { break }
            start -= 1
        }
        var forward = start
        while forward < messages.count, messages[forward].role != .user { forward += 1 }
        if forward < messages.count || messages.isEmpty { return forward }
        var back = min(start, messages.count - 1)
        while back > 0, messages[back].role != .user { back -= 1 }
        return back
    }

    /// Every tool call gets its answer, even one cut off when a turn was stopped; stray answers are dropped.
    public static func paired(_ messages: [Message]) -> [Message] {
        var out: [Message] = []
        var index = 0
        while index < messages.count {
            let message = messages[index]
            index += 1
            if message.role == .tool { continue }
            out.append(message)
            guard message.role == .assistant, !message.toolCalls.isEmpty else { continue }
            var answered = Set<String>()
            while index < messages.count, messages[index].role == .tool {
                if let id = messages[index].toolCallId, message.toolCalls.contains(where: { $0.id == id }), !answered.contains(id) {
                    answered.insert(id)
                    out.append(messages[index])
                }
                index += 1
            }
            for call in message.toolCalls where !answered.contains(call.id) {
                out.append(.toolResult("（这一步没有完成）", for: call, isError: true))
            }
        }
        return out
    }
}
