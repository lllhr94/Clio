import Foundation

/// Tracks stalled tool batches within a turn. Changes in parameters or read results can show progress.
struct ToolLoopDetector {
    enum Decision: Equatable {
        case `continue`
        case nudge(String)
        case stop(String)
    }

    static let nudgeMessage = "［连续几步没有新进展。请换一种做法、回答已有结果，或说明卡在哪里。不要再重复同样的操作。］"
    static let stopMessage = "（连续几步都在重复同样的操作没有新进展，我先停在这里。要接着试或换个做法就说一声。）"

    struct CallKey: Hashable, Sendable {
        let name: String
        let arguments: String

        init(_ call: ToolCall) {
            name = call.name
            let source = call.arguments.trimmingCharacters(in: .whitespacesAndNewlines)
            if let parsed = JSONValue.parse(source.isEmpty ? "{}" : source) {
                let (arguments, _) = Agent.untitled(parsed)
                self.arguments = "json:" + arguments.compact
            } else {
                arguments = "raw:" + source
            }
        }
    }

    private struct Outcome: Equatable {
        let isError: Bool
        let text: String
        let detail: String?
        let images: [ImagePart]
        let mediaReferences: [String]?

        init(_ result: Message, repeatedWrite: Bool) {
            isError = result.isError
            var text = result.text
            if !result.images.isEmpty, let references = result.mediaReferences {
                let marker = MediaLoadRetire.availableMarker(references)
                if text.hasSuffix(marker) { text.removeLast(marker.count) }
            }
            // A successful write often gets a new receipt even though it repeated the same effect.
            self.text = repeatedWrite ? "" : text.trimmingCharacters(in: .whitespacesAndNewlines)
            detail = repeatedWrite ? nil : result.detail?.trimmingCharacters(in: .whitespacesAndNewlines)
            images = repeatedWrite ? [] : result.images
            mediaReferences = repeatedWrite || !result.images.isEmpty ? nil : result.mediaReferences
        }
    }

    private struct Step: Equatable {
        let call: CallKey
        let outcome: Outcome
    }

    private var lastBatch: [Step] = []
    private var repeats = 0

    mutating func record(calls: [ToolCall], results: [Message], mutatingTools: Set<String>) -> Decision {
        guard !calls.isEmpty, calls.count == results.count else {
            self = ToolLoopDetector()
            return .continue
        }
        let batch = zip(calls, results).map { call, result in
            let repeatedWrite = mutatingTools.contains(call.name) && !result.isError && !Self.isProgressQuery(call.name)
            return Step(call: CallKey(call), outcome: Outcome(result, repeatedWrite: repeatedWrite))
        }.sorted { lhs, rhs in
            (lhs.call.name, lhs.call.arguments) < (rhs.call.name, rhs.call.arguments)
        }
        let transient = zip(calls, results).allSatisfy { call, result in
            !mutatingTools.contains(call.name) && Self.transient(result)
        }
        if batch == lastBatch {
            repeats += 1
        } else {
            lastBatch = batch
            repeats = 1
        }
        // Give an explicitly temporary failure two additional chances to clear.
        let stopAfter = transient ? 5 : 3
        if repeats >= stopAfter { return .stop(Self.stopMessage) }
        if repeats == stopAfter - 1 { return .nudge(Self.nudgeMessage) }
        return .continue
    }

    private static func isProgressQuery(_ tool: String) -> Bool {
        let name = tool.lowercased()
        return name.hasPrefix("poll_") || name.hasSuffix("_status")
    }

    private static func transient(_ result: Message) -> Bool {
        guard result.isError, !result.text.hasPrefix(Agent.unknownMark) else { return false }
        let words = result.text.lowercased()
        return ["temporarily unavailable", "try again later", "timed out", "timeout", "rate limit",
                "暂时不可用", "稍后再试", "超时", "请求太频繁"].contains(where: words.contains)
    }
}
