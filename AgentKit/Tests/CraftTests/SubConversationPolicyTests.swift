import Craft
import XCTest

final class SubConversationPolicyTests: XCTestCase {
    private let origin = SubConversationOrigin(sourceChatKey: "bot-a", sourceEntryID: "entry-1", selectedQuote: "原文")

    func testInheritedPlanAndTaintAreStickyAndKeepQuote() {
        var record = SubConversationRecord(origin: origin, inheritedPlanMode: true, inheritedTaint: true)
        record.inheritParent(planMode: false, tainted: false)
        record.append(.init(question: "追问", reply: "答复"), tainted: false)
        XCTAssertTrue(record.inheritedPlanMode)
        XCTAssertTrue(record.inheritedTaint)
        XCTAssertFalse(record.taintedOut)
        XCTAssertEqual(record.origin, origin)
    }

    func testReturningPropagatesTaintInBothDirections() {
        var parentWasClean = SubConversationRecord(origin: origin, inheritedPlanMode: false, inheritedTaint: false)
        parentWasClean.append(.init(question: "追问", reply: "答复"), tainted: true)
        let outward = SubConversationPolicy.returnToParent(&parentWasClean, summary: "结论", parentPlanMode: true, parentTainted: false)
        XCTAssertTrue(outward.tainted)
        XCTAssertTrue(outward.inheritedPlanMode)
        XCTAssertEqual(outward.summary, "结论")
        XCTAssertEqual(outward.origin, origin)

        var sideWasClean = SubConversationRecord(origin: origin, inheritedPlanMode: false, inheritedTaint: false)
        let inward = SubConversationPolicy.returnToParent(&sideWasClean, summary: "结论", parentPlanMode: false, parentTainted: true)
        XCTAssertTrue(sideWasClean.inheritedTaint)
        XCTAssertTrue(inward.tainted)
        XCTAssertFalse(sideWasClean.taintedOut)
    }

    func testPromotionPreservesPlanOriginAndTaintUnion() {
        for inherited in [false, true] {
            for output in [false, true] {
                var record = SubConversationRecord(origin: origin, inheritedPlanMode: true, inheritedTaint: inherited)
                record.append(.init(question: "追问", reply: "答复"), tainted: output)
                let promoted = SubConversationPolicy.promoteToIndependentChat(record, summary: "答复")
                XCTAssertEqual(promoted.origin, origin)
                XCTAssertTrue(promoted.inheritedPlanMode)
                XCTAssertEqual(promoted.tainted, inherited || output)
            }
        }
    }
}
