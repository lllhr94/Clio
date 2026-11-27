import Craft
import Foundation
import XCTest

final class NameCardV3CodecTests: XCTestCase {
    func testRoundTripsAllVersions() throws {
        let v1 = Data(#"{"kind":"clio.namecard","version":1,"name":"青","instructions":"Speak plainly."}"#.utf8)
        let legacy = try NameCardV3Codec.decode(v1)
        XCTAssertEqual(legacy.instructions, "Speak plainly.")
        XCTAssertEqual(try NameCardV3Codec.decode(NameCardV3Codec.encode(legacy, version: 1)), legacy)

        var v2 = legacy
        v2.version = 2
        v2.pet = "pet:builtin-xiaoke"
        v2.petStill = Data([1, 2, 3])
        v2.temper = "clear"
        XCTAssertEqual(try NameCardV3Codec.decode(NameCardV3Codec.encode(v2, version: 2)), v2)

        var v3 = v2
        v3.version = 3
        v3.relationship = "Study partner"
        v3.expressionStyle = "Short paragraphs"
        v3.antiSlop = true
        v3.firstPersonThoughts = false
        v3.expertiseBoundary = "Check sources"
        v3.publicAgentsCard = "Ask me for citations"
        XCTAssertEqual(try NameCardV3Codec.decode(NameCardV3Codec.encodeV3(v3)), v3)
    }

    func testPrivateNotesRequireOptInAndUnknownFieldsDoNotRoundTrip() throws {
        let source = Data(#"{"kind":"clio.namecard","version":3,"name":"青","privateNotes":"private","memories":["memory"],"apiKey":"secret"}"#.utf8)
        let card = try NameCardV3Codec.decode(source)
        let normal = try NameCardV3Codec.encodeV3(card)
        XCTAssertNil(try NameCardV3Codec.decode(normal).privateNotes)
        let optedIn = try NameCardV3Codec.encodeV3(card, includePrivateNotes: true)
        XCTAssertEqual(try NameCardV3Codec.decode(optedIn).privateNotes, "private")
        let json = String(decoding: optedIn, as: UTF8.self)
        XCTAssertFalse(json.contains("memories"))
        XCTAssertFalse(json.contains("apiKey"))
    }

    func testBoundsOnImportAndExport() throws {
        var card = NameCardV3Codec.Card(name: "青")
        card.photo = Data(count: NameCardV3Codec.maxAvatarBytes + 1)
        XCTAssertThrowsError(try NameCardV3Codec.encodeV3(card)) {
            XCTAssertEqual($0 as? NameCardV3Codec.InvalidCard, .avatarTooLarge)
        }
        let fixture = try JSONEncoder().encode(card)
        XCTAssertThrowsError(try NameCardV3Codec.decode(fixture)) {
            XCTAssertEqual($0 as? NameCardV3Codec.InvalidCard, .avatarTooLarge)
        }
        card.photo = nil
        card.relationship = String(repeating: "青", count: NameCardV3Codec.maxTextBytes / 3 + 1)
        XCTAssertThrowsError(try NameCardV3Codec.encodeV3(card)) {
            XCTAssertEqual($0 as? NameCardV3Codec.InvalidCard, .fieldTooLarge)
        }
        XCTAssertThrowsError(try NameCardV3Codec.decode(Data(count: NameCardV3Codec.maxFileBytes + 1))) {
            XCTAssertEqual($0 as? NameCardV3Codec.InvalidCard, .fileTooLarge)
        }
        XCTAssertThrowsError(try NameCardV3Codec.encode(card, version: 4))
    }

    func testReplyCleanupKeepsMarkdownAndLiteralCode() {
        let fence = "```text\nSure!\n\nI hope this helps.\n```"
        let reply = "Of course!\n\n" + fence + "\n\nI hope this helps."
        XCTAssertEqual(ReplySanitizer.sanitizeReply(reply, antiSlop: true), fence)
        XCTAssertEqual(ReplySanitizer.sanitizeReply(reply, antiSlop: false), reply)
        let unclosed = "```text\n\nI hope this helps."
        XCTAssertEqual(ReplySanitizer.sanitizeReply(unclosed, antiSlop: true), unclosed)
        let markdown = "# Heading\n\n- `Sure!`\n- > I hope this helps.\n"
        XCTAssertEqual(ReplySanitizer.sanitizeReply(markdown, antiSlop: true), markdown)
    }

    func testOnlyOptedInDisplayReasoningChanges() {
        let original = "The user wants a summary."
        XCTAssertEqual(ReplySanitizer.formatPublicReasoning(original, firstPerson: false), original)
        XCTAssertEqual(ReplySanitizer.formatPublicReasoning(original, firstPerson: true), "I need to help with a summary.")
        XCTAssertEqual(ReplySanitizer.formatPublicReasoning("用户希望我检查出处。", firstPerson: true), "我需要检查出处。")
    }
}
