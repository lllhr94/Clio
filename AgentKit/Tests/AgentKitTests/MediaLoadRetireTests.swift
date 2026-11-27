import AgentKit
import Foundation
import XCTest

final class MediaLoadRetireTests: XCTestCase {
    private let reference = "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA.jpg"
    private let image = ImagePart(data: Data([1, 2, 3]))

    private func result() -> Message {
        var message = Message.toolResult("浏览器截图", for: ToolCall(id: "call", name: "browser_screenshot", arguments: "{}"))
        message.images = [image]
        return message
    }

    func testSavedImageBecomesCompactReopenableResultWithoutChangingItsCall() throws {
        let saved = try MediaLoadRetire.save(result(), write: { _ in reference }, remove: { _ in XCTFail() })
        XCTAssertEqual(saved.mediaReferences, [reference])
        XCTAssertEqual(saved.images, [image])
        XCTAssertTrue(saved.text.hasSuffix(MediaLoadRetire.availableMarker([reference])))

        let record = MediaReference(ref: reference, note: "右侧是提交按钮", sourceTool: "browser_screenshot", turnIndex: 4)
        let retained = MediaLoadRetire.project(saved, references: [record], includeImages: true)
        XCTAssertEqual(retained, saved)
        let retired = MediaLoadRetire.project(saved, references: [record], includeImages: false)
        XCTAssertTrue(retired.images.isEmpty)
        XCTAssertEqual(retired.toolCallId, "call")
        XCTAssertEqual(retired.role, .tool)
        XCTAssertEqual(retired.text, "浏览器截图\n[image_ref: \(reference) | note: 右侧是提交按钮]")
        XCTAssertTrue(MediaLoadRetire.retainImage(turnAge: 0))
        XCTAssertTrue(MediaLoadRetire.retainImage(turnAge: 1))
        XCTAssertFalse(MediaLoadRetire.retainImage(turnAge: 2))
    }

    func testPartialSaveRollsBackAndReopenedReferencesDoNotWriteAgain() throws {
        enum SaveError: Error { case noSpace }
        var original = result()
        original.images.append(image)
        var writes = 0
        var removed: [String] = []
        XCTAssertThrowsError(try MediaLoadRetire.save(original, write: { _ in
            writes += 1
            if writes == 2 { throw SaveError.noSpace }
            return reference
        }, remove: { removed.append($0) }))
        XCTAssertEqual(removed, [reference])
        XCTAssertNil(original.mediaReferences)

        original.mediaReferences = [reference]
        let reopened = try MediaLoadRetire.save(original, write: { _ in
            XCTFail("Reopened images already have a file")
            return ""
        }, remove: { _ in XCTFail() })
        XCTAssertEqual(reopened, original)
    }

    func testInvalidReferencesNeverReachTheReaderAndMissingFilesExpire() {
        let malicious = MediaReference(ref: "../\(reference)", sourceTool: "browser_screenshot", turnIndex: 0)
        let refused = MediaLoadRetire.load(malicious) { _ in
            XCTFail("An invalid reference must not reach the reader")
            return nil
        }
        XCTAssertNil(refused.image)
        XCTAssertTrue(refused.reference.expired)

        let record = MediaReference(ref: reference, sourceTool: "browser_screenshot", turnIndex: 1)
        let unloaded = MediaLoadRetire.load(record) { _ in nil }
        XCTAssertTrue(unloaded.reference.expired)
        XCTAssertEqual(unloaded.reference.marker, "［截图已过期：\(reference)］")
        let png = Data([137, 80, 78, 71, 13, 10, 26, 10])
        let loaded = MediaLoadRetire.load(record) { _ in png }
        XCTAssertFalse(loaded.reference.expired)
        XCTAssertEqual(loaded.image, ImagePart(mediaType: "image/png", data: png))
    }

    func testNoteParserAndLegacyMessageCoding() throws {
        let noteText = MediaLoadRetire.noteMarker(reference) + "红色角标"
        let note = Message.toolResult(noteText, for: ToolCall(id: "note", name: "image_note", arguments: "{}"))
        XCTAssertEqual(MediaLoadRetire.note(in: note)?.reference, reference)
        XCTAssertEqual(MediaLoadRetire.note(in: note)?.text, "红色角标")
        XCTAssertNil(MediaLoadRetire.note(in: .assistant(noteText)))

        let data = Data("""
        {"role":"tool","text":"old","images":[],"toolCalls":[],"toolCallId":"a","toolName":"view_image","isError":false}
        """.utf8)
        let legacy = try JSONDecoder().decode(Message.self, from: data)
        XCTAssertNil(legacy.mediaReferences)
        XCTAssertNil(legacy.mediaSourceTool)
        XCTAssertEqual(legacy.toolName, "view_image")
    }
}
