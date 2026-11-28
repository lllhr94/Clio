@testable import Clio
import UIKit
import XCTest

@MainActor
final class ChatTimelineDataSourceTests: XCTestCase {
    func testPrependingRetainsSameGroupRowsAndUpdatesTurnIndexes() {
        let timeline = ChatTimelineDataSource()
        let question = row("q", .user)
        let reply = row("r", .bot)
        timeline.replace(items: [.line("q"), .line("r"), .bottomSpacer], rows: [question, reply])
        let oldRows = timeline.rowByID
        let oldNeighbors = timeline.neighbors
        let earlier = row("earlier", .user)
        timeline.replace(items: [.line("earlier"), .line("q"), .line("r"), .bottomSpacer], rows: [earlier, question, reply])
        XCTAssertTrue(timeline.hasUnchangedRow("r", previousRows: oldRows, previousNeighbors: oldNeighbors))
        XCTAssertFalse(timeline.hasUnchangedRow("earlier", previousRows: oldRows, previousNeighbors: oldNeighbors))
        XCTAssertEqual(timeline.itemIndexByID[.line("r")], 2)
        XCTAssertEqual(timeline.turnUserIDBySection, ["earlier", "q", "q", "q"])
        XCTAssertEqual(timeline.firstUserRowID, "earlier")
    }

    func testChangedGroupOrRowCannotReuseOldHeight() {
        let timeline = ChatTimelineDataSource()
        let before = row("r", .bot)
        timeline.replace(items: [.line("r")], rows: [before])
        let oldRows = timeline.rowByID
        let oldNeighbors = timeline.neighbors
        timeline.updateRows(["r": row("r", .bot, opens: true)])
        XCTAssertFalse(timeline.hasUnchangedRow("r", previousRows: oldRows, previousNeighbors: oldNeighbors))
        timeline.updateRows(["r": row("r", .user)])
        XCTAssertEqual(timeline.turnUserIDBySection, ["r"])
    }

    func testFrameProjectionIsBoundedAndDoesNotMoveStationaryAnchor() {
        XCTAssertEqual(ChatMotionFrameProjection.nextValue(presented: 12, model: 12, now: 10, target: 11, frameDuration: 1), 12)
        XCTAssertEqual(ChatMotionFrameProjection.nextValue(presented: 0, model: 40, now: 10, target: 11, frameDuration: 1), 10)
        XCTAssertEqual(ChatMotionFrameProjection.nextValue(presented: 0, model: 40, now: 10, target: 9, frameDuration: 1), 0)
    }

    func testCompactThinkingReservesOnlyTheHeader() {
        XCTAssertLessThan(ChatLiveThinkingCell.fixedHeight(compact: true), ChatLiveThinkingCell.fixedHeight(compact: false))
    }

    func testToolTailSummaryKeepsLatestOutputWithoutMutatingHistory() {
        let lines = [ToolTail.Line(text: "first"), ToolTail.Line(text: "last")]
        XCTAssertEqual(ChatLiveToolTailCell.displayedLines(lines, compact: true).map(\.text), ["last"])
        XCTAssertEqual(ChatLiveToolTailCell.displayedLines(lines, compact: false), lines)
    }

    private func row(_ id: String, _ kind: ChatLine.Kind, opens: Bool = false) -> ChatListRowItem {
        ChatListRowItem(line: ChatLine(id: id, kind: kind, text: id), opens: opens, lit: false,
                        isFirst: false, isFreshWriting: false, freshShown: nil, isLatestBot: false,
                        isLatestNote: false, isLastLine: false, endsTurn: false, timeGap: nil,
                        isEditing: false, faces: false, isRoom: false, historyInView: false,
                        speakerBot: nil, defaultBotName: "", lineMeta: nil, lookbackNote: nil,
                        lookbackRest: "", showThinking: true, showStats: false, hitStepLimit: false,
                        working: false, speakingText: nil)
    }
}
