import XCTest
@testable import AgentKit

final class ProtocolAtomicUnitTests: XCTestCase {
    func testGroupsSignedContinuationAndRepairsMissingAndDuplicateResults() {
        let a = ToolCall(id: "a", name: "read", arguments: "{}")
        let b = ToolCall(id: "b", name: "write", arguments: "{}")
        let foreign = ToolCall(id: "foreign", name: "read", arguments: "{}")
        var thought = Message.assistant("", reasoning: "work")
        thought.reasoningSignature = "signed"
        let calls = Message.assistant("", toolCalls: [a, b])
        let result = Message.toolResult("A", for: a)
        let history: [Message] = [
            .toolResult("before", for: foreign), .user("begin"), thought, calls, result,
            .toolResult("duplicate", for: a), .toolResult("stray", for: foreign), .user("next")
        ]

        let units = ProtocolAtomicUnit.group(history)
        XCTAssertEqual(units.map(\.sourceRange), [1..<2, 2..<7, 7..<8])
        XCTAssertEqual(units[1].sourceIndices, [2, 3, 4, nil])
        XCTAssertEqual(Array(units[1].messages.prefix(3)), [thought, calls, result])
        XCTAssertEqual(units[1].messages.last?.toolCallId, b.id)
        XCTAssertEqual(units[1].messages.last?.isError, true)
    }

    func testTruncationRetainsNewestUserAndWholeToolSequenceAtTinyBudget() {
        let call = ToolCall(id: "a", name: "read", arguments: "{}")
        let history: [Message] = [
            .user("old"), .assistant("old answer"), .user("current"),
            .assistant("", toolCalls: [call], reasoning: "keep this"), .toolResult("answer", for: call)
        ]
        let start = ProtocolAtomicUnit.windowStart(history, maxChars: 1, maxCount: 1)
        XCTAssertEqual(start, 2)
        XCTAssertEqual(ProtocolAtomicUnit.paired(Array(history[start...])), Array(history[2...]))
    }

    func testSignedAssistantContinuationKeepsTextAndResultsFollowCallOrder() {
        var signed = Message.assistant("partial", reasoning: "thinking")
        signed.reasoningSignature = "signed"
        let a = ToolCall(id: "a", name: "read", arguments: "{}")
        let b = ToolCall(id: "b", name: "read", arguments: "{}")
        let calls = Message.assistant("", toolCalls: [a, b])
        let resultA = Message.toolResult("A", for: a)
        let resultB = Message.toolResult("B", for: b)
        let units = ProtocolAtomicUnit.group([signed, calls, resultB, resultA])
        XCTAssertEqual(units.count, 1)
        XCTAssertEqual(units.first?.messages, [signed, calls, resultA, resultB])
        XCTAssertEqual(units.first?.sourceIndices, [0, 1, 3, 2])
    }
}
