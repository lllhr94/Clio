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

    func testRevealUnitsNewlyRevealedSpawnsEachGlyphStrictlyOnce() {
        let attr = NSAttributedString(
            string: "雨伞，下午三点后有雨",
            attributes: [.font: UIFont.systemFont(ofSize: 17)]
        )
        let snap = ChatRevealLayoutSnapshot.build(
            attributed: attr,
            width: 320,
            height: 60,
            topInset: 0,
            bottomInset: 0,
            sourceRenderToken: 1
        )
        let allUnits = snap.lines.flatMap(\.units)
        XCTAssertFalse(allUnits.isEmpty)

        var spawnedLocations: [Int] = []
        var cursor: Double = 0
        while cursor < Double(snap.totalPoints) {
            let next = min(Double(snap.totalPoints), cursor + 5.0)
            let groups = snap.unitsNewlyRevealed(from: cursor, to: next)
            for group in groups {
                spawnedLocations.append(contentsOf: group.units.map(\.utf16Location))
            }
            cursor = next
        }
        XCTAssertEqual(spawnedLocations, allUnits.map(\.utf16Location))
    }

    func testMessageRevealCoordinatorPreservesActiveLocalOffsetWhenPrefixWeightUpgrades() {
        let coord = MessageRevealCoordinator(
            slices: [
                .init(id: "rt0", kind: .richText, weightPoints: 200),
                .init(id: "rt1", kind: .richText, weightPoints: 300),
            ],
            initialCursorPoints: 240,
            finalizeImmediately: false,
            pace: .balanced,
            now: 1.0
        )
        // Before upgrade: active slice is rt1 at localPoints = 40.
        if case .revealing(let localBefore, _) = coord.sliceState(at: 1) {
            XCTAssertEqual(localBefore, 40.0, accuracy: 0.001)
        } else {
            XCTFail("Expected rt1 revealing before prefix weight upgrade")
        }

        // Prefix slice rt0 upgrades from estimated 200 -> exact CoreText 340 (+140).
        coord.update(
            slices: [
                .init(id: "rt0", kind: .richText, weightPoints: 340),
                .init(id: "rt1", kind: .richText, weightPoints: 300),
            ],
            isLive: true,
            pace: .balanced,
            now: 1.02
        )
        if case .revealing(let localAfter, _) = coord.sliceState(at: 1) {
            XCTAssertEqual(localAfter, 40.0, accuracy: 0.001)
        } else {
            XCTFail("Expected rt1 to remain at localPoints=40 without jumping backward")
        }
    }

    func testStreamingResizeDuringActiveRevealIsMonotonicAndDamped() {
        var arbiter = ChatScrollArbiterCore(isPinnedToBottom: true)
        let epoch = arbiter.interactionEpoch

        // Backward target (target 420 < current 450, within maxY 600) MUST NOT bounce downward.
        let backwardMetrics = ChatScrollArbiterCore.FrameMetrics(
            currentOffsetY: 450,
            contentHeight: 1300,
            boundsHeight: 800,
            topInset: 100,
            bottomInset: 100,
            revealedBottomOffsetY: 420,
            anchorTargetOffsetY: nil
        )
        let backDecision = arbiter.resolveWrite(source: .streamingResize(epoch: epoch), metrics: backwardMetrics)
        XCTAssertFalse(backDecision.wroteOffset)

        // Forward jump (target 550 > current 450) MUST glide with 0.24 damping instead of hard-snapping +100pt in 1 frame.
        let forwardMetrics = ChatScrollArbiterCore.FrameMetrics(
            currentOffsetY: 450,
            contentHeight: 1300,
            boundsHeight: 800,
            topInset: 100,
            bottomInset: 100,
            revealedBottomOffsetY: 550,
            anchorTargetOffsetY: nil
        )
        let fwdDecision = arbiter.resolveWrite(source: .streamingResize(epoch: epoch), metrics: forwardMetrics)
        XCTAssertTrue(fwdDecision.wroteOffset)
        XCTAssertEqual(fwdDecision.targetOffsetY ?? 0, 474.0, accuracy: 0.5)
    }

    func testMessageRevealCoordinatorNeverRewindsWhenTailSliceMergesIntoSealedSlice() {
        // Before seal: rt0 (102pt) + rt1 (300pt), cursor is mid-way through rt1 at 380pt.
        let coord = MessageRevealCoordinator(
            slices: [
                .init(id: "s#rt0", kind: .richText, weightPoints: 102),
                .init(id: "s#rt1", kind: .richText, weightPoints: 300),
            ],
            initialCursorPoints: 380,
            finalizeImmediately: false,
            pace: .balanced,
            now: 1.0
        )

        // Seal event: rt1 merges into rt0, tail temporarily withheld, rt0's estimate is momentarily 360pt (< 380pt).
        coord.update(
            slices: [.init(id: "s#rt0", kind: .richText, weightPoints: 360)],
            isLive: true,
            pace: .balanced,
            now: 1.02
        )
        XCTAssertGreaterThanOrEqual(coord.cursorPoints, 380.0, "Live stream merge must never rewind cursor backward")

        // Exact CoreText tile returns (580pt): reveal continues monotonically from >= 380pt, never re-playing from 102pt!
        coord.update(
            slices: [.init(id: "s#rt0", kind: .richText, weightPoints: 580)],
            isLive: true,
            pace: .balanced,
            now: 1.04
        )
        XCTAssertGreaterThanOrEqual(coord.cursorPoints, 380.0)
    }

    func testKeyboardInsetStepSolverTracksDockedDismissToSafeAreaWithZeroEndSnap() {
        // iPhone 17 Pro geometry: hostHeight=874, safeAreaBottom=34 -> restingBottomY=840.
        // Composer=72, extra=12 -> resting closed inset = 34 + 72 + 0 + 12 = 118.
        // Open keyboard topY=538 -> occlusion=302 -> open inset = 420.
        let atStart = ChatKeyboardInsetStepSolver.step(.init(
            currentBottomInset: 420,
            targetBottomInset: 118,
            hostMinY: 0,
            hostMaxY: 874,
            hostHeight: 874,
            safeAreaBottom: 34,
            restingComposerHeight: 72,
            appliedComposerHeight: 72,
            extraBottomPadding: 12,
            mode: .hardwareOrNone,
            presentationGuideTopY: 538,
            hasActivePresentationAnimation: true,
            isInteractiveDragging: false,
            isPostDragGraceActive: false,
            inKeyboardTransitionWindow: true,
            elapsedSinceTransitionStart: 0.01,
            dt: 1.0 / 120.0,
            fallbackDuration: 0.38,
            reduceMotion: false
        ))
        XCTAssertEqual(atStart.nextBottomInset, 420, accuracy: 0.01)

        // When keyboardLayoutGuide reaches resting safeAreaLayoutGuide.bottomAnchor (840pt, NOT 874pt),
        // the computed bottom inset MUST reach 118.0 with 0.0pt deficit (no 34pt end-snap!).
        let atEnd = ChatKeyboardInsetStepSolver.step(.init(
            currentBottomInset: 122,
            targetBottomInset: 118,
            hostMinY: 0,
            hostMaxY: 874,
            hostHeight: 874,
            safeAreaBottom: 34,
            restingComposerHeight: 72,
            appliedComposerHeight: 72,
            extraBottomPadding: 12,
            mode: .hardwareOrNone,
            presentationGuideTopY: 840,
            hasActivePresentationAnimation: true,
            isInteractiveDragging: false,
            isPostDragGraceActive: false,
            inKeyboardTransitionWindow: true,
            elapsedSinceTransitionStart: 0.35,
            dt: 1.0 / 120.0,
            fallbackDuration: 0.38,
            reduceMotion: false
        ))
        XCTAssertEqual(atEnd.nextBottomInset, 118.0, accuracy: 0.01)
    }

    func testKeyboardInsetStepSolverPostDragGraceNeverSnapsBackToStaleKeyboardOpenInset() {
        // User interactively dragged keyboard halfway down (probeTopY=778 -> live inset=180pt),
        // then lifted their finger BEFORE keyboardWillChangeFrame arrived (targetBottomInset is still stale 420pt!).
        let afterLift = ChatKeyboardInsetStepSolver.step(.init(
            currentBottomInset: 180,
            targetBottomInset: 420,
            hostMinY: 0,
            hostMaxY: 874,
            hostHeight: 874,
            safeAreaBottom: 34,
            restingComposerHeight: 72,
            appliedComposerHeight: 72,
            extraBottomPadding: 12,
            mode: .docked,
            presentationGuideTopY: 778,
            hasActivePresentationAnimation: false,
            isInteractiveDragging: false,
            isPostDragGraceActive: true,
            inKeyboardTransitionWindow: false,
            elapsedSinceTransitionStart: 0.25,
            dt: 1.0 / 120.0,
            fallbackDuration: 0.25,
            reduceMotion: false
        ))
        XCTAssertEqual(afterLift.nextBottomInset, 180.0, accuracy: 0.01, "Releasing interactive drag must never snap back to stale 420pt")
        XCTAssertFalse(afterLift.finished)
    }

    func testKeyboardInsetStepSolverRetargetAndComposerCollapseStayContinuous() {
        // Pre-animation hold (< 0.05s before UIKit attaches CAAnimation) keeps inset steady instead of curve-switching.
        let held = ChatKeyboardInsetStepSolver.step(.init(
            currentBottomInset: 420,
            targetBottomInset: 118,
            hostMinY: 0,
            hostMaxY: 874,
            hostHeight: 874,
            safeAreaBottom: 34,
            restingComposerHeight: 72,
            appliedComposerHeight: 72,
            extraBottomPadding: 12,
            mode: .hardwareOrNone,
            presentationGuideTopY: 538,
            hasActivePresentationAnimation: false,
            isInteractiveDragging: false,
            isPostDragGraceActive: false,
            inKeyboardTransitionWindow: true,
            elapsedSinceTransitionStart: 0.016,
            dt: 1.0 / 120.0,
            fallbackDuration: 0.38,
            reduceMotion: false
        ))
        XCTAssertEqual(held.nextBottomInset, 420.0, accuracy: 0.01)

        // Mid-dismiss: IME commits 2-line text -> 1-line (restingComposerHeight drops 96 -> 72) while guide moves 6pt.
        // appliedComposerHeight must ease gradually instead of teleporting -24pt in one frame.
        let midDismiss = ChatKeyboardInsetStepSolver.step(.init(
            currentBottomInset: 350,
            targetBottomInset: 118,
            hostMinY: 0,
            hostMaxY: 874,
            hostHeight: 874,
            safeAreaBottom: 34,
            restingComposerHeight: 72,
            appliedComposerHeight: 96,
            extraBottomPadding: 12,
            mode: .hardwareOrNone,
            presentationGuideTopY: 638, // occlusion = 202, +34+12 = 248 + appliedComposer
            hasActivePresentationAnimation: true,
            isInteractiveDragging: false,
            isPostDragGraceActive: false,
            inKeyboardTransitionWindow: true,
            elapsedSinceTransitionStart: 0.12,
            dt: 1.0 / 120.0,
            fallbackDuration: 0.38,
            reduceMotion: false
        ))
        XCTAssertGreaterThan(midDismiss.nextAppliedComposerHeight, 88.0)
        XCTAssertLessThan(midDismiss.nextAppliedComposerHeight, 96.0)
        XCTAssertLessThan(abs(midDismiss.nextBottomInset - 350.0), 15.0)
    }
}
