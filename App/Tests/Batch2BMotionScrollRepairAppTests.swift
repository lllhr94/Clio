@testable import Clio
import Foundation
import Prose
import XCTest

@MainActor
final class Batch2BMotionScrollRepairAppTests: XCTestCase {
    // MARK: - ChatScrollStateMachine Verified Handoff Vectors (SCR-01 .. SCR-04) + Tweak 2

    func testShortFirstReplyNeverFalsePinsTopEdge() {
        // SCR-01: total content fits inside viewport -> must stay .followingBottom with zero jump pill.
        var sm = ChatScrollStateMachine<String>()
        let vp = ViewportMetrics(visibleHeight: 800, contentHeight: 48, contentOffsetY: -60, topSafeInset: 60, bottomSafeInset: 80)
        let decision = sm.onStreamingGeometryUpdate(viewport: vp, activeReplyID: "msg-1", activeReplyMinY: 0)
        XCTAssertEqual(decision.mode, .followingBottom)
        XCTAssertEqual(decision.targetContentOffsetY, -60)
        XCTAssertFalse(decision.deferStreamingRelayout)
        XCTAssertFalse(decision.showJumpToBottomControl)
    }

    func testLongReplyOverflowLocksTopEdgeAtSafeReadingLine() {
        // SCR-02: streaming reply overflows viewport and reaches topSafeInset + 16pt -> lock top edge & show jump pill.
        var sm = ChatScrollStateMachine<String>()
        let vp = ViewportMetrics(visibleHeight: 800, contentHeight: 1100, contentOffsetY: 320, topSafeInset: 60, bottomSafeInset: 80)
        let decision = sm.onStreamingGeometryUpdate(viewport: vp, activeReplyID: "msg-42", activeReplyMinY: 420)
        XCTAssertEqual(decision.mode, .pinningReplyTop("msg-42"))
        XCTAssertEqual(decision.targetContentOffsetY, 344)
        XCTAssertFalse(decision.deferStreamingRelayout)
        XCTAssertTrue(decision.showJumpToBottomControl)
    }

    func testSettleTimeLiveAnchorRestoresZeroJumpAfterDeferredFlush() {
        // SCR-03: live top visible anchor captured right before flush as named SettleAnchor struct.
        var sm = ChatScrollStateMachine<String>()
        sm.onUserDragBegan()
        let vpBefore = ViewportMetrics(visibleHeight: 800, contentHeight: 4000, contentOffsetY: 120, topSafeInset: 60, bottomSafeInset: 80)
        let visible = [
            VisibleItemMetric(id: "msg-09", minY: 40, maxY: 145),
            VisibleItemMetric(id: "msg-10", minY: 150, maxY: 260),
            VisibleItemMetric(id: "msg-11", minY: 270, maxY: 400),
        ]
        let anchor = sm.prepareSettleFlush(viewport: vpBefore, visibleItems: visible)
        XCTAssertEqual(anchor, SettleAnchor(id: "msg-10", screenOffsetY: 30))

        let vpAfter = ViewportMetrics(visibleHeight: 800, contentHeight: 4085, contentOffsetY: 120, topSafeInset: 60, bottomSafeInset: 80)
        let restored = sm.didFlushDeferredLayout(viewportAfter: vpAfter, updatedAnchorMinY: 235)
        XCTAssertEqual(restored, 205)
        XCTAssertNil(sm.settleAnchor)
    }

    func testHeaderCollapseCompensatesOffsetAndResetsToFollowingBottomWhenNoLongerOverflowing() {
        // SCR-04: collapse above reading line shifts contentOffsetY by exact height delta.
        var sm = ChatScrollStateMachine<String>()
        sm.onUserDragBegan()
        let vpBefore = ViewportMetrics(visibleHeight: 800, contentHeight: 2800, contentOffsetY: 500, topSafeInset: 60, bottomSafeInset: 80)
        _ = sm.prepareSettleFlush(viewport: vpBefore, visibleItems: [VisibleItemMetric(id: "msg-1", minY: 520, maxY: 700)])
        let comp = sm.compensateCollapse(viewportAfter: vpBefore, collapsedItemMinY: 420, oldHeight: 220, newHeight: 44)
        XCTAssertEqual(comp, 324)

        // Tweak 2: when collapsing shrinks content below viewport height (no longer overflows),
        // mode must reset cleanly to .followingBottom and return maxY (-topSafeInset).
        let vpShort = ViewportMetrics(visibleHeight: 800, contentHeight: 300, contentOffsetY: 20, topSafeInset: 60, bottomSafeInset: 80)
        let resetOffset = sm.compensateCollapse(viewportAfter: vpShort, collapsedItemMinY: 10, oldHeight: 700, newHeight: 200)
        XCTAssertEqual(sm.mode, .followingBottom)
        XCTAssertEqual(resetOffset, -60)
    }

    // MARK: - MotionPolicyCore Verified Handoff Vectors (MOT-01) & Send-Flight Policy

    func testThermalFairRetains120HzAndThrottlesUnderSeriousLowPowerCritical() {
        XCTAssertEqual(MotionPolicyCore.preferredFrameRate(thermal: .nominal, isLowPowerMode: false).preferredHz, 120)
        XCTAssertEqual(MotionPolicyCore.preferredFrameRate(thermal: .fair, isLowPowerMode: false).preferredHz, 120)
        XCTAssertFalse(MotionPolicyCore.preferredFrameRate(thermal: .fair, isLowPowerMode: false).disableContinuousEffects)
        XCTAssertEqual(MotionPolicyCore.preferredFrameRate(thermal: .serious, isLowPowerMode: false).preferredHz, 60)
        XCTAssertEqual(MotionPolicyCore.preferredFrameRate(thermal: .nominal, isLowPowerMode: true).preferredHz, 60)
        XCTAssertEqual(MotionPolicyCore.preferredFrameRate(thermal: .critical, isLowPowerMode: false).preferredHz, 30)

        let delta = MotionPolicyCore.additivePositionDelta(oldCenter: (x: 200, y: 720), newCenter: (x: 280, y: 520))
        XCTAssertEqual(delta.dx, -80)
        XCTAssertEqual(delta.dy, 200)
    }

    func testSendFlightPolicyDegradesOnAttachmentsAndReduceMotion() {
        XCTAssertEqual(
            ChatSendFlightPolicy.resolve(hasText: true, hasAttachments: false, reduceMotion: false, simplifyMotion: false),
            .overlayFlyIn
        )
        XCTAssertEqual(
            ChatSendFlightPolicy.resolve(hasText: true, hasAttachments: true, reduceMotion: false, simplifyMotion: false),
            .subtleFadeRise
        )
        XCTAssertEqual(
            ChatSendFlightPolicy.resolve(hasText: true, hasAttachments: false, reduceMotion: false, simplifyMotion: true),
            .subtleFadeRise
        )
        XCTAssertEqual(
            ChatSendFlightPolicy.resolve(hasText: true, hasAttachments: false, reduceMotion: true, simplifyMotion: false),
            .instant
        )
    }

    func testTableSpreadWidthsNeverExceedAvailableWidthDueToCeilingRounding() {
        // Available room = 301 + 2*20 (colGap) + 2*16 (padH) = 373 -> inner available = 301 across 3 equal columns.
        let widths = ChatTableBlockView.spreadWidths(
            [180, 180, 180],
            minTokenWidths: [60, 60, 60],
            availableRoom: 373,
            padH: 16
        )
        XCTAssertEqual(widths.count, 3)
        XCTAssertLessThanOrEqual(widths.reduce(0, +), 301.0)
    }
}
