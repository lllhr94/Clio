import Foundation
import XCTest
@testable import AgentKit

final class ToolLoopDetectorTests: XCTestCase {
    func testCanonicalCallsNudgeBeforeStoppingAndIgnoreNewWriteReceipts() {
        let calls = [
            ToolCall(id: "1", name: "write", arguments: #"{"b":2,"a":1,"step_title":"doing"}"#),
            ToolCall(id: "2", name: "write", arguments: #"{"a":1,"b":2,"step_title":"still doing"}"#),
            ToolCall(id: "3", name: "write", arguments: #"{"b":2,"a":1}"#)
        ]
        var detector = ToolLoopDetector()
        let results = calls.map { call in
            detector.record(calls: [call], results: [.toolResult("receipt \(call.id)", for: call)], mutatingTools: ["write"])
        }
        XCTAssertEqual(results, [.continue, .nudge(ToolLoopDetector.nudgeMessage), .stop(ToolLoopDetector.stopMessage)])
    }

    func testPaginationAndAdvancingPollingResultsShowProgress() {
        var detector = ToolLoopDetector()
        for page in 1...5 {
            let call = ToolCall(id: "list", name: "list", arguments: #"{"page":\#(page)}"#)
            XCTAssertEqual(
                detector.record(calls: [call], results: [.toolResult("data", for: call)], mutatingTools: []),
                .continue
            )
        }
        let call = ToolCall(id: "poll", name: "poll_job", arguments: #"{"job":"a"}"#)
        for progress in 1...5 {
            XCTAssertEqual(
                detector.record(calls: [call], results: [.toolResult("\(progress)%", for: call)], mutatingTools: ["poll_job"]),
                .continue
            )
        }
    }

    func testTemporaryReadErrorGetsMoreTimeThanStableError() {
        let call = ToolCall(id: "read", name: "read", arguments: "{}")
        var detector = ToolLoopDetector()
        let temporary = Message.toolResult("temporarily unavailable", for: call, isError: true)
        let stalled = (1...5).map { _ in
            detector.record(calls: [call], results: [temporary], mutatingTools: [])
        }
        XCTAssertEqual(stalled, [.continue, .continue, .continue,
                                 .nudge(ToolLoopDetector.nudgeMessage), .stop(ToolLoopDetector.stopMessage)])

        let permanent = Message.toolResult("not found", for: call, isError: true)
        let failed = (1...3).map { _ in
            detector.record(calls: [call], results: [permanent], mutatingTools: [])
        }
        XCTAssertEqual(failed, [.continue, .nudge(ToolLoopDetector.nudgeMessage), .stop(ToolLoopDetector.stopMessage)])
    }

    func testIdenticalImagesDoNotShowProgressJustBecauseTheirStorageIDsChange() {
        var detector = ToolLoopDetector()
        let call = ToolCall(id: "screenshot", name: "screenshot", arguments: "{}")
        let image = ImagePart(data: Data([1, 2, 3]))
        let decisions = ["first", "second", "third"].map { id in
            var result = Message.toolResult("image" + MediaLoadRetire.availableMarker([id]), for: call)
            result.images = [image]
            result.mediaReferences = [id]
            return detector.record(calls: [call], results: [result], mutatingTools: [])
        }
        XCTAssertEqual(decisions, [.continue, .nudge(ToolLoopDetector.nudgeMessage), .stop(ToolLoopDetector.stopMessage)])
    }
}
