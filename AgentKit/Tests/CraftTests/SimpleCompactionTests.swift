import AgentKit
import Craft
import XCTest

final class SimpleCompactionTests: XCTestCase {
    private struct Entry: Equatable {
        var id: String
        var message: Message
        var tainted = false
    }

    func testCompactionPreservesPairingSignatureReferenceAndUndo() throws {
        let first = ToolCall(id: "read", name: "read", arguments: "{}")
        let second = ToolCall(id: "image", name: "screenshot", arguments: "{}")
        let third = ToolCall(id: "edit", name: "edit", arguments: "{}")
        let text = String(repeating: "long output ", count: 100)
        var reply = Message.assistant("", toolCalls: [first, second, third], reasoning: "signed reasoning")
        reply.reasoningSignature = "signature"
        var ref = Message.toolResult(text, for: second)
        ref.mediaReferences = ["opaque"]
        var edit = Message.toolResult(text, for: third)
        edit.detail = "undoable edit"
        let entries = [
            Entry(id: "start", message: .user("old")),
            Entry(id: "a", message: reply),
            Entry(id: "b", message: .toolResult(text, for: first), tainted: true),
            Entry(id: "c", message: ref),
            Entry(id: "d", message: edit),
            Entry(id: "e", message: .user("recent")),
            Entry(id: "f", message: .assistant("", toolCalls: [first])),
            Entry(id: "g", message: .toolResult(text, for: first))
        ]
        let result = SimpleCompaction.compact(entries, message: \.message, keepingRecentTurns: 1, maxToolOutputCharacters: 40)
        XCTAssertFalse(result.undo.isEmpty)
        XCTAssertEqual(result.records[1], entries[1])
        XCTAssertEqual(result.records[2].message.toolCallId, first.id)
        XCTAssertLessThanOrEqual(result.records[2].message.text.count, 40)
        XCTAssertTrue(result.records[2].tainted)
        XCTAssertEqual(Array(result.records[3...]), Array(entries[3...]))
        XCTAssertEqual(Conversation.paired(result.records.map(\.message)), result.records.map(\.message))

        let appended = Entry(id: "new", message: .user("next"))
        XCTAssertEqual(result.undo.restore(in: result.records + [appended]), entries + [appended])
        var changed = result.records
        changed[2].message.text = "edited while compressed"
        XCTAssertNil(result.undo.restore(in: changed))
    }
}
