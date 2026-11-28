import CoreText
import XCTest
import UIKit
@testable import Clio

@MainActor
final class ClioAppPR1DTests: XCTestCase {

    // MARK: - 1. 1:1 Telegram 5-Element Streaming Reveal

    func testTrueGlyphWidthPointCostEliminatesDivideByEightDistortion() {
        let narrowCost = ChatRevealPacer.pointCost(forAdvance: 4.0, isWhitespace: false)
        let latinCost = ChatRevealPacer.pointCost(forAdvance: 9.0, isWhitespace: false)
        let cjkCost = ChatRevealPacer.pointCost(forAdvance: 17.0, isWhitespace: false)
        let spaceCost = ChatRevealPacer.pointCost(forAdvance: 5.0, isWhitespace: true)

        XCTAssertEqual(narrowCost, 4)
        XCTAssertEqual(latinCost, 9)
        XCTAssertEqual(cjkCost, 17)
        XCTAssertLessThan(narrowCost, latinCost)
        XCTAssertLessThan(latinCost, cjkCost)
        XCTAssertLessThanOrEqual(spaceCost, 4)
    }

    func testRevealPacerThreeStopsReadingCeilingAndSCurveCatchUp() {
        let gentle = ChatRevealPacer.stepCursor(
            current: 0, controllerTarget: 500, totalPoints: 500,
            elapsed: 0.016, pace: .gentle, hasRateSample: true, isFinalizing: false
        )
        let balanced = ChatRevealPacer.stepCursor(
            current: 0, controllerTarget: 500, totalPoints: 500,
            elapsed: 0.016, pace: .balanced, hasRateSample: true, isFinalizing: false
        )
        let fast = ChatRevealPacer.stepCursor(
            current: 0, controllerTarget: 500, totalPoints: 500,
            elapsed: 0.016, pace: .fast, hasRateSample: true, isFinalizing: false
        )
        XCTAssertGreaterThan(gentle, 0)
        XCTAssertLessThan(gentle, balanced)
        XCTAssertLessThan(balanced, fast)

        // Small backlog enforces the reading ceiling cleanly without a high-speed floor jump.
        let smallStep = ChatRevealPacer.stepCursor(
            current: 0, controllerTarget: 40, totalPoints: 40,
            elapsed: 0.016, pace: .gentle, hasRateSample: true, isFinalizing: false
        )
        XCTAssertLessThan(smallStep, 12.0, "Gentle pace must not jump with a high-speed floor")

        // Large backlog engages S-curve catch-up smoothly faster than tiny backlog.
        let largeStep = ChatRevealPacer.stepCursor(
            current: 0, controllerTarget: 900, totalPoints: 900,
            elapsed: 0.016, pace: .gentle, hasRateSample: true, isFinalizing: false
        )
        XCTAssertGreaterThan(largeStep, smallStep * 1.8)

        // Subpixel drain completes crisply when finalizing.
        let drained = ChatRevealPacer.stepCursor(
            current: 99.6, controllerTarget: 99.7, totalPoints: 100,
            elapsed: 0.016, pace: .balanced, hasRateSample: true, isFinalizing: true
        )
        XCTAssertEqual(drained, 100.0)
    }

    func testBlurFilterIsCompileIsolatedOutOfDefaultBuildAndDegradesOnConstraints() {
        // Default / App Store builds MUST exclude any private CAFilter symbol path.
        XCTAssertFalse(ChatRevealPolicy.isBlurFilterCompiledIn)

        XCTAssertTrue(ChatRevealPolicy.allowsMotionEffects(reduceMotion: false, isLowPowerMode: false, thermalState: .nominal))
        XCTAssertFalse(ChatRevealPolicy.allowsMotionEffects(reduceMotion: true, isLowPowerMode: false, thermalState: .nominal))
        XCTAssertFalse(ChatRevealPolicy.allowsMotionEffects(reduceMotion: false, isLowPowerMode: true, thermalState: .nominal))
        XCTAssertFalse(ChatRevealPolicy.allowsMotionEffects(reduceMotion: false, isLowPowerMode: false, thermalState: .serious))
        XCTAssertFalse(ChatRevealPolicy.allowsMotionEffects(reduceMotion: false, isLowPowerMode: false, thermalState: .critical))

        let degraded = ChatRevealSnippetPlanner.evaluateAnimation(progress: 0.25, motionEnabled: false)
        XCTAssertEqual(degraded.scale, 1.0)
        XCTAssertEqual(degraded.translateY, 0.0)
        XCTAssertEqual(degraded.blurRadius, 0.0)

        let baselineStart = ChatRevealSnippetPlanner.evaluateAnimation(progress: 0.0, motionEnabled: true)
        XCTAssertEqual(baselineStart.scale, 0.5, accuracy: 0.001)
        XCTAssertEqual(baselineStart.translateY, 6.0, accuracy: 0.001)
        XCTAssertEqual(baselineStart.opacity, 0.0, accuracy: 0.001)

        let baselineEnd = ChatRevealSnippetPlanner.evaluateAnimation(progress: 1.0, motionEnabled: true)
        XCTAssertEqual(baselineEnd.scale, 1.0, accuracy: 0.001)
        XCTAssertEqual(baselineEnd.translateY, 0.0, accuracy: 0.001)
        XCTAssertEqual(baselineEnd.opacity, 1.0, accuracy: 0.001)
    }

    func testSnippetPlannerTileSeamFallbackPoolCapAndAntiGhostingClamp() {
        let tiles: [ChatRevealSnippetPlanner.TileMetrics] = [
            .init(y: 0, height: 512, pixelWidth: 1170, pixelHeight: 1536),
            .init(y: 512, height: 256, pixelWidth: 1170, pixelHeight: 768),
        ]
        // Single-tile interior glyph locks exact normalized contentsRect at 3x scale (tileW=390, tileH=512).
        let interior = CGRect(x: 39, y: 128, width: 19.5, height: 25.6)
        let mapped = ChatRevealSnippetPlanner.tileSlice(for: interior, tiles: tiles, scale: 3.0)
        XCTAssertNotNil(mapped)
        XCTAssertEqual(mapped?.tileIndex, 0)
        XCTAssertEqual(mapped!.contentsRect.minX, 0.10, accuracy: 0.001)
        XCTAssertEqual(mapped!.contentsRect.minY, 0.25, accuracy: 0.001)
        XCTAssertEqual(mapped!.contentsRect.width, 0.05, accuracy: 0.001)
        XCTAssertEqual(mapped!.contentsRect.height, 0.05, accuracy: 0.001)

        // Glyph straddling tile seam (y: 505...520) MUST return nil (pure fade fallback, zero tearing).
        let seamCrossing = CGRect(x: 20, y: 505, width: 18, height: 15)
        XCTAssertNil(ChatRevealSnippetPlanner.tileSlice(for: seamCrossing, tiles: tiles, scale: 3.0))

        // Burst of 80 glyph units MUST batch & respect hard concurrent pool cap <= 36.
        var burstUnits: [ChatRevealAtomicUnit] = []
        for i in 0..<80 {
            let rect = CGRect(x: CGFloat((i % 20) * 16), y: CGFloat((i / 20) * 24 + 8), width: 15, height: 20)
            burstUnits.append(ChatRevealAtomicUnit(
                utf16Location: i, utf16Length: 1,
                minX: rect.minX, maxX: rect.maxX,
                inkRect: rect, bleedRect: rect,
                hasInlineAttachment: false, isWhitespace: false,
                startPoints: i * 16, endPoints: (i + 1) * 16
            ))
        }
        let batches = ChatRevealSnippetPlanner.planBatches(
            for: burstUnits, lineHasRTL: false, tiles: tiles, scale: 3.0, activeCount: 10, maxPoolSize: 36
        )
        XCTAssertLessThanOrEqual(batches.count + 10, 36)
        XCTAssertGreaterThan(batches.count, 0)

        // Inline attachment / formula units and RTL lines skip snippet layers cleanly.
        let attachmentUnit = ChatRevealAtomicUnit(
            utf16Location: 0, utf16Length: 1, minX: 0, maxX: 24,
            inkRect: CGRect(x: 0, y: 10, width: 24, height: 20),
            bleedRect: CGRect(x: 0, y: 8.5, width: 25.5, height: 23),
            hasInlineAttachment: true, isWhitespace: false,
            startPoints: 0, endPoints: 24
        )
        XCTAssertTrue(ChatRevealSnippetPlanner.planBatches(
            for: [attachmentUnit], lineHasRTL: false, tiles: tiles, scale: 3.0, activeCount: 0
        ).isEmpty)
        XCTAssertTrue(ChatRevealSnippetPlanner.planBatches(
            for: Array(burstUnits.prefix(3)), lineHasRTL: true, tiles: tiles, scale: 3.0, activeCount: 0
        ).isEmpty)

        // Anti-ghosting static mask clamp strictly stays before lowestAnimatingStartPoints.
        XCTAssertEqual(
            ChatRevealSnippetPlanner.clampedStaticMaskPoints(cursorPoints: 180, lowestAnimatingStartPoints: 120),
            120
        )
        XCTAssertEqual(
            ChatRevealSnippetPlanner.clampedStaticMaskPoints(cursorPoints: 180, lowestAnimatingStartPoints: nil),
            180
        )
    }

    func testItalicOverhangExtendsTheRevealMaskWithoutChangingPointCost() throws {
        let font = try XCTUnwrap(UIFont(name: "TimesNewRomanPS-ItalicMT", size: 36))
        let text = NSAttributedString(string: "  fx\nnext", attributes: [.font: font])
        let snapshot = ChatRevealLayoutSnapshot.build(
            attributed: text, width: 260, height: 160,
            topInset: 4, bottomInset: 4, sourceRenderToken: 1
        )
        let line = try XCTUnwrap(snapshot.lines.first)
        let glyph = try XCTUnwrap(line.units.first { $0.utf16Location == 2 })
        XCTAssertGreaterThan(glyph.inkRect.maxX, glyph.maxX)
        XCTAssertGreaterThan(glyph.inkRect.minY, line.rawTop)
        XCTAssertEqual(glyph.costPoints, ChatRevealPacer.pointCost(forAdvance: glyph.maxX - glyph.minX, isWhitespace: false))

        guard case let .partial(_, bandTop, bandHeight, _, frontier, _) = snapshot.maskState(forPoints: Double(glyph.endPoints)) else {
            return XCTFail("The first line should still be revealing")
        }
        XCTAssertGreaterThanOrEqual(frontier, glyph.inkRect.maxX)
        XCTAssertLessThanOrEqual(bandTop, glyph.inkRect.minY)
        XCTAssertGreaterThanOrEqual(bandTop + bandHeight, glyph.inkRect.maxY)
        let nextFrontier = line.frontierX(forPoints: Double(glyph.endPoints) + 0.1, fallbackWidth: 260)
        XCTAssertGreaterThanOrEqual(nextFrontier, frontier)
    }

    func testObjectReplacementCharacterKeepsItsRevealPointsAndSeparatesSnippetBatches() throws {
        let text = NSAttributedString(string: "a\u{FFFC}bcdefgh", attributes: [.font: UIFont.systemFont(ofSize: 20)])
        let snapshot = ChatRevealLayoutSnapshot.build(
            attributed: text, width: 240, height: 60,
            topInset: 0, bottomInset: 0, sourceRenderToken: 1
        )
        let line = try XCTUnwrap(snapshot.lines.first)
        let placeholder = try XCTUnwrap(line.units.first { $0.hasInlineAttachment })
        XCTAssertEqual(placeholder.utf16Location, 1)
        XCTAssertEqual(placeholder.utf16Length, 1)
        XCTAssertGreaterThan(placeholder.costPoints, 0)
        XCTAssertEqual(snapshot.pointsBefore(utf16Offset: 1), placeholder.startPoints)
        XCTAssertEqual(snapshot.pointsBefore(utf16Offset: 2), placeholder.endPoints)
        let batches = ChatRevealSnippetPlanner.planBatches(
            for: line.units, lineHasRTL: line.hasRTL,
            tiles: [.init(y: 0, height: 60, pixelWidth: 480, pixelHeight: 120)],
            scale: 2, activeCount: 0
        )
        XCTAssertTrue(batches.contains { $0.endPoints == placeholder.startPoints })
        XCTAssertTrue(batches.contains { $0.startPoints == placeholder.endPoints })
        XCTAssertTrue(batches.allSatisfy {
            $0.endPoints <= placeholder.startPoints || $0.startPoints >= placeholder.endPoints
        })
    }

    func testRunDelegateMetricsFitTheRevealBandForATallAttachment() throws {
        var callbacks = CTRunDelegateCallbacks(
            version: kCTRunDelegateVersion1,
            dealloc: { _ in },
            getAscent: { _ in 34 },
            getDescent: { _ in 15 },
            getWidth: { _ in 38 }
        )
        let delegate = try XCTUnwrap(CTRunDelegateCreate(&callbacks, nil))
        let text = NSMutableAttributedString(
            string: "above\na\u{FFFC}b\nbelow", attributes: [.font: UIFont.systemFont(ofSize: 18)]
        )
        text.addAttribute(
            NSAttributedString.Key(rawValue: kCTRunDelegateAttributeName as String),
            value: delegate, range: NSRange(location: 7, length: 1)
        )
        let snapshot = ChatRevealLayoutSnapshot.build(
            attributed: text, width: 240, height: 160,
            topInset: 4, bottomInset: 4, sourceRenderToken: 1
        )
        let line = try XCTUnwrap(snapshot.lines.first { $0.units.contains { $0.hasInlineAttachment } })
        let attachment = try XCTUnwrap(line.units.first { $0.hasInlineAttachment })
        XCTAssertEqual(attachment.inkRect.height, 49, accuracy: 0.5)
        XCTAssertEqual(attachment.inkRect.width, 38, accuracy: 0.5)
        XCTAssertLessThanOrEqual(line.bandTop, attachment.inkRect.minY + 0.5)
        XCTAssertGreaterThanOrEqual(line.bandBottom, attachment.inkRect.maxY - 0.5)
    }

    func testMessageRevealCoordinatorUnifiedCrossBlockTimelineAndRevealAll() {
        // Paragraph 1 starts streaming (weight 200).
        let coordinator = MessageRevealCoordinator(
            slices: [.init(id: "rt0", kind: .richText, weightPoints: 200)],
            initialCursorPoints: 0,
            finalizeImmediately: false,
            pace: .balanced,
            now: 1.0
        )
        _ = coordinator.step(now: 1.10)
        let cursorAfterFirstTick = coordinator.cursorPoints
        XCTAssertGreaterThan(cursorAfterFirstTick, 0)
        XCTAssertLessThan(cursorAfterFirstTick, 200)

        // `\n\n` seals paragraph 1 (`rt0`) and appends code block + paragraph 2 (`rt1`) + table.
        // Paragraph 1 MUST stay partially masked at the same global cursor (zero early pop-out!),
        // and code / rt1 / table MUST stay hidden until the global cursor reaches them.
        coordinator.update(
            slices: [
                .init(id: "rt0", kind: .richText, weightPoints: 200),
                .init(id: "code0", kind: .code, weightPoints: 80),
                .init(id: "rt1", kind: .richText, weightPoints: 160),
                .init(id: "table0", kind: .table, weightPoints: 60),
            ],
            isLive: true,
            pace: .balanced,
            now: 1.12
        )
        XCTAssertEqual(coordinator.cursorPoints, cursorAfterFirstTick, accuracy: 0.001)
        if case .revealing = coordinator.sliceState(at: 0) {
            // Expected: sealed paragraph 0 still reveals smoothly!
        } else {
            XCTFail("Sealed paragraph popped early instead of staying on unified timeline")
        }
        XCTAssertEqual(coordinator.sliceState(at: 1), .hidden)
        XCTAssertEqual(coordinator.sliceState(at: 2), .hidden)
        XCTAssertEqual(coordinator.sliceState(at: 3), .hidden)

        // Long-press selection triggers revealAll() -> all blocks immediately complete.
        coordinator.revealAll()
        XCTAssertTrue(coordinator.isComplete)
        XCTAssertEqual(coordinator.sliceState(at: 0), .complete)
        XCTAssertEqual(coordinator.sliceState(at: 1), .complete)
        XCTAssertEqual(coordinator.sliceState(at: 2), .complete)
        XCTAssertEqual(coordinator.sliceState(at: 3), .complete)
    }

    func testRevealPacePreferenceRoundTripUsesBackupIncludedLookPrefix() {
        XCTAssertTrue(Pref.revealPaceKey.hasPrefix("look."))
        let defaults = UserDefaults.standard
        let original = defaults.object(forKey: Pref.revealPaceKey)
        defer {
            if let original { defaults.set(original, forKey: Pref.revealPaceKey) }
            else { defaults.removeObject(forKey: Pref.revealPaceKey) }
        }
        for pace in Pref.RevealPace.allCases {
            defaults.set(pace.rawValue, forKey: Pref.revealPaceKey)
            XCTAssertEqual(Pref.RevealPace(rawValue: defaults.string(forKey: Pref.revealPaceKey) ?? ""), pace)
        }
    }

    // MARK: - 2. Unified Keyboard Occlusion Geometry (Docked / Floating / Partial Overlap / Hardware)

    func testDockedKeyboardAndInteractivePresentationGeometryMatchSingleOcclusion() {
        let host = CGRect(x: 0, y: 0, width: 390, height: 844)
        let dockedKB = CGRect(x: 0, y: 508, width: 390, height: 336)

        let res = ChatKeyboardGeometrySolver.resolve(ChatKeyboardGeometryInput(
            hostBounds: host,
            safeAreaBottom: 34,
            restingComposerHeight: 56,
            keyboardFrameInHost: dockedKB,
            keyboardBelongsToHostScreen: true,
            extraBottomPadding: 12
        ))
        // restingComposerBottomY = 810, avoided = 508 -> occlusion = 302
        XCTAssertEqual(res.mode, .docked)
        XCTAssertEqual(res.restingComposerBottomY, 810)
        XCTAssertEqual(res.resolvedAvoidedComposerBottomY, 508)
        XCTAssertEqual(res.effectiveBottomOcclusion, 302)
        XCTAssertEqual(res.composerFrameInHost.maxY, 508)
        XCTAssertEqual(res.collectionBottomInset, 34 + 56 + 302 + 12)
        XCTAssertEqual(res.scrollIndicatorBottomInset, res.collectionBottomInset)
        XCTAssertEqual(res.minimapBottomClearance, 56 + 302)
        XCTAssertEqual(res.additionalSafeAreaBottom, 0)

        // Interactive drag-dismiss probe halfway down at y = 660.
        let dragRes = ChatKeyboardGeometrySolver.resolve(ChatKeyboardGeometryInput(
            hostBounds: host,
            safeAreaBottom: 34,
            restingComposerHeight: 56,
            keyboardFrameInHost: dockedKB,
            keyboardBelongsToHostScreen: true,
            interactivePresentationTopY: 660,
            extraBottomPadding: 12
        ))
        XCTAssertEqual(dragRes.effectiveBottomOcclusion, 810 - 660)
        XCTAssertEqual(dragRes.composerFrameInHost.maxY, 660)
    }

    func testFloatingKeyboardHoveringMidScreenZeroOverlapLeavesComposerAtBottom() {
        let host = CGRect(x: 0, y: 0, width: 390, height: 844)
        // Floating keyboard hovering in mid-screen (y: 220...460), zero overlap with composer (750...810).
        let floatingMid = CGRect(x: 40, y: 220, width: 300, height: 240)

        let res = ChatKeyboardGeometrySolver.resolve(ChatKeyboardGeometryInput(
            hostBounds: host,
            safeAreaBottom: 34,
            restingComposerHeight: 60,
            keyboardFrameInHost: floatingMid,
            keyboardBelongsToHostScreen: true,
            extraBottomPadding: 12
        ))
        XCTAssertEqual(res.mode, .floatingOrSplit)
        XCTAssertEqual(res.effectiveBottomOcclusion, 0)
        XCTAssertEqual(res.resolvedAvoidedComposerBottomY, 810)
        XCTAssertEqual(res.composerFrameInHost, CGRect(x: 0, y: 750, width: 390, height: 60))
        XCTAssertFalse(res.isKeyboardVisiblyOccluding)
    }

    func testFloatingKeyboardPartiallyOverlappingComposerUsesFullAvoidanceDisplacement() {
        // Exact spec verification:
        // Resting composer occupies y: 750...800 (restingBottomY = 800, composerHeight = 50).
        // Floating keyboard sits at y: 720...770 (does NOT touch window bottom 844!), partially overlapping
        // the right/send-button side of the composer by 20pt.
        // Composer MUST lift to y: 670...720 (80pt shift), and effectiveBottomOcclusion == 80pt everywhere.
        let host = CGRect(x: 0, y: 0, width: 390, height: 844)
        let partialFloatingKB = CGRect(x: 150, y: 720, width: 220, height: 50)

        let resting = ChatKeyboardGeometrySolver.resolve(ChatKeyboardGeometryInput(
            hostBounds: host,
            safeAreaBottom: 44,
            restingComposerHeight: 50,
            keyboardFrameInHost: nil,
            extraBottomPadding: 12
        ))
        let avoided = ChatKeyboardGeometrySolver.resolve(ChatKeyboardGeometryInput(
            hostBounds: host,
            safeAreaBottom: 44,
            restingComposerHeight: 50,
            keyboardFrameInHost: partialFloatingKB,
            keyboardBelongsToHostScreen: true,
            extraBottomPadding: 12
        ))

        XCTAssertEqual(avoided.mode, .floatingOrSplit)
        XCTAssertEqual(avoided.restingComposerBottomY, 800)
        XCTAssertEqual(avoided.resolvedAvoidedComposerBottomY, 720)
        XCTAssertEqual(avoided.effectiveBottomOcclusion, 80)
        XCTAssertEqual(avoided.composerFrameInHost, CGRect(x: 0, y: 670, width: 390, height: 50))
        // Send button hit frame (trailing 44x44 inside composer) is 100% clear of the floating keyboard!
        let sendButtonHitFrame = CGRect(
            x: avoided.composerFrameInHost.maxX - 52,
            y: avoided.composerFrameInHost.minY + 3,
            width: 44,
            height: 44
        )
        XCTAssertFalse(sendButtonHitFrame.intersects(partialFloatingKB))
        // Composer lift, collection contentInset.bottom delta, scrollIndicator delta, and minimap delta all equal 80pt!
        XCTAssertEqual(avoided.collectionBottomInset - resting.collectionBottomInset, 80)
        XCTAssertEqual(avoided.scrollIndicatorBottomInset - resting.scrollIndicatorBottomInset, 80)
        XCTAssertEqual(avoided.minimapBottomClearance - resting.minimapBottomClearance, 80)
    }

    func testDifferentScreenAndHardwareKeyboardYieldZeroOcclusion() {
        let host = CGRect(x: 0, y: 0, width: 390, height: 844)
        let otherScreenKB = ChatKeyboardGeometrySolver.resolve(ChatKeyboardGeometryInput(
            hostBounds: host,
            safeAreaBottom: 34,
            restingComposerHeight: 56,
            keyboardFrameInHost: CGRect(x: 0, y: 500, width: 390, height: 344),
            keyboardBelongsToHostScreen: false
        ))
        XCTAssertEqual(otherScreenKB.mode, .hardwareOrNone)
        XCTAssertEqual(otherScreenKB.effectiveBottomOcclusion, 0)

        let offscreenHardwareKB = ChatKeyboardGeometrySolver.resolve(ChatKeyboardGeometryInput(
            hostBounds: host,
            safeAreaBottom: 34,
            restingComposerHeight: 56,
            keyboardFrameInHost: CGRect(x: 0, y: 844, width: 390, height: 44),
            keyboardBelongsToHostScreen: true
        ))
        XCTAssertEqual(offscreenHardwareKB.mode, .hardwareOrNone)
        XCTAssertEqual(offscreenHardwareKB.effectiveBottomOcclusion, 0)
    }

    // MARK: - 3. Single `contentOffset` Write-Point & 3-Tier Competition Arbiter

    func testCombinedRaceUserScrollStreamingFinalizeAndApprovalSettleProduceZeroWritesAfterHandoff() {
        var arbiter = ChatScrollArbiterCore(isPinnedToBottom: true)
        let baseMetrics = ChatScrollArbiterCore.FrameMetrics(
            currentOffsetY: 1200,
            contentHeight: 1800,
            boundsHeight: 844,
            topInset: 96,
            bottomInset: 400,
            revealedBottomOffsetY: 1320,
            anchorTargetOffsetY: 1180
        )

        // Capture epochs while pinned & keyboard opening (in-flight reveal tick, finalize settle, old approval settle).
        let staleEpoch = arbiter.interactionEpoch
        XCTAssertTrue(arbiter.resolveWrite(source: .revealTick(epoch: staleEpoch), metrics: baseMetrics).wroteOffset)

        // Same frame: user touches screen and scrolls up away from bottom (Tier 1 takes immediate control).
        arbiter.beginUserTouchScroll(interactiveKeyboardDismiss: true)
        arbiter.userScrolledAwayFromBottom()

        // Colliding in-flight reveal tick, streaming finalize settle, and old approval card settle MUST write 0 offsets!
        let revealDecision = arbiter.resolveWrite(source: .revealTick(epoch: staleEpoch), metrics: baseMetrics)
        let finalizeDecision = arbiter.resolveWrite(source: .finalizedSettle(epoch: staleEpoch), metrics: baseMetrics)
        let approvalDecision = arbiter.resolveWrite(source: .approvalCardSettle(epoch: staleEpoch), metrics: baseMetrics)
        let insetDecision = arbiter.resolveWrite(source: .insetOrKeyboardSynthesis(epoch: staleEpoch), metrics: baseMetrics)

        XCTAssertFalse(revealDecision.wroteOffset)
        XCTAssertFalse(finalizeDecision.wroteOffset)
        XCTAssertFalse(approvalDecision.wroteOffset)
        XCTAssertFalse(insetDecision.wroteOffset)

        // Even after finger lifts away from bottom, old captured epochs MUST still produce zero offset writes.
        arbiter.endUserTouchScroll(shouldPinToBottom: false)
        XCTAssertFalse(arbiter.isPinnedToBottom)
        XCTAssertFalse(arbiter.resolveWrite(source: .revealTick(epoch: staleEpoch), metrics: baseMetrics).wroteOffset)
        XCTAssertFalse(arbiter.resolveWrite(source: .finalizedSettle(epoch: staleEpoch), metrics: baseMetrics).wroteOffset)
        XCTAssertFalse(arbiter.resolveWrite(source: .approvalCardSettle(epoch: staleEpoch), metrics: baseMetrics).wroteOffset)
    }

    func testMildOffBottomOneShotLiftPreservesUnpinnedStateAndHandlesShortListThreshold() {
        // Case A: Reader 80pt (<= 120pt) above bottom -> one-shot lift without mutating `isPinnedToBottom`.
        var arbiter = ChatScrollArbiterCore(isPinnedToBottom: false)
        let beforeKB = ChatScrollArbiterCore.FrameMetrics(
            currentOffsetY: 976, // maxBottomOffsetY = 1800 - 844 + 100 = 1056 -> distance = 80pt
            contentHeight: 1800,
            boundsHeight: 844,
            topInset: 96,
            bottomInset: 100,
            revealedBottomOffsetY: nil,
            anchorTargetOffsetY: 976
        )
        arbiter.beginKeyboardTransition(metrics: beforeKB, targetBottomInset: 400)
        XCTAssertFalse(arbiter.isPinnedToBottom)
        XCTAssertNotNil(arbiter.mildLift)

        let afterKB = ChatScrollArbiterCore.FrameMetrics(
            currentOffsetY: 976,
            contentHeight: 1800,
            boundsHeight: 844,
            topInset: 96,
            bottomInset: 400, // maxBottomOffsetY = 1356 -> lifted target = 1356 - 80 = 1276
            revealedBottomOffsetY: nil,
            anchorTargetOffsetY: 976
        )
        let liftDecision = arbiter.resolveWrite(
            source: .insetOrKeyboardSynthesis(epoch: arbiter.interactionEpoch),
            metrics: afterKB
        )
        XCTAssertTrue(liftDecision.wroteOffset)
        XCTAssertEqual(liftDecision.targetOffsetY ?? 0, 1276, accuracy: 0.5)
        XCTAssertFalse(arbiter.isPinnedToBottom, "One-shot mild lift MUST NOT mutate isPinnedToBottom")

        // Case B: Short list crossing unscrollable -> scrollable never shoots behind top bar (>= -topInset).
        var shortArbiter = ChatScrollArbiterCore(isPinnedToBottom: false)
        let shortBefore = ChatScrollArbiterCore.FrameMetrics(
            currentOffsetY: -96,
            contentHeight: 420,
            boundsHeight: 844,
            topInset: 96,
            bottomInset: 100, // 420 + 96 + 100 = 616 <= 844 (unscrollable)
            revealedBottomOffsetY: nil,
            anchorTargetOffsetY: -96
        )
        shortArbiter.beginKeyboardTransition(metrics: shortBefore, targetBottomInset: 400)
        XCTAssertNotNil(shortArbiter.mildLift)
        let shortAfter = ChatScrollArbiterCore.FrameMetrics(
            currentOffsetY: -96,
            contentHeight: 420,
            boundsHeight: 844,
            topInset: 96,
            bottomInset: 400, // 420 + 96 + 400 = 916 > 844 (now scrollable; maxBottom = -24)
            revealedBottomOffsetY: nil,
            anchorTargetOffsetY: -96
        )
        let shortDecision = shortArbiter.resolveWrite(
            source: .insetOrKeyboardSynthesis(epoch: shortArbiter.interactionEpoch),
            metrics: shortAfter
        )
        XCTAssertTrue(shortDecision.wroteOffset)
        XCTAssertFalse(shortArbiter.isPinnedToBottom)
        if let y = shortDecision.targetOffsetY {
            XCTAssertGreaterThanOrEqual(y, -96.0)
            XCTAssertLessThanOrEqual(y, shortAfter.maxBottomOffsetY)
        } else {
            XCTFail("Expected clamped mild lift offset for short list crossing scrollable threshold")
        }
    }

    func testDeepHistorySelectionAndExplicitJumpPriorities() {
        var arbiter = ChatScrollArbiterCore(isPinnedToBottom: false)
        // Reader 300pt (> 120pt) above bottom -> NO mild lift; preserves exact reading anchor.
        let deepMetrics = ChatScrollArbiterCore.FrameMetrics(
            currentOffsetY: 756,
            contentHeight: 1800,
            boundsHeight: 844,
            topInset: 96,
            bottomInset: 100,
            revealedBottomOffsetY: nil,
            anchorTargetOffsetY: 756
        )
        arbiter.beginKeyboardTransition(metrics: deepMetrics, targetBottomInset: 400)
        XCTAssertNil(arbiter.mildLift)

        // Active text selection cancels any lift and vetoes reveal/settle pulls.
        arbiter.setPinnedFromHost(true)
        let preSelectEpoch = arbiter.interactionEpoch
        arbiter.setTextSelectionActive(true)
        XCTAssertFalse(arbiter.resolveWrite(source: .revealTick(epoch: preSelectEpoch), metrics: deepMetrics).wroteOffset)

        // Tier 2 explicit jump takes ownership cleanly.
        arbiter.setTextSelectionActive(false)
        _ = arbiter.beginExplicitJump()
        let jumpDecision = arbiter.resolveWrite(source: .explicitJump, metrics: deepMetrics, explicitTargetY: 320)
        XCTAssertTrue(jumpDecision.wroteOffset)
        XCTAssertEqual(jumpDecision.targetOffsetY, 320)
        XCTAssertFalse(arbiter.isPinnedToBottom)
    }

    // MARK: - 4. 3-Card Shared Height Budget, Chrome Lock, & Scene-Scoped Toast Isolation

    func testThreeCardSharedHeightBudgetEnforcesStrictPriorityOrder() {
        // Generous space (keyboard closed): all 3 cards fit cleanly.
        let roomy = ChatDockCardBudget.allocate(ChatDockCardBudget.Input(
            viewportHeight: 844,
            effectiveBottomOcclusion: 0,
            topBarHeight: 52,
            composerHeight: 68,
            minProseReadableHeight: 120,
            hasPendingApproval: true,
            canInlineApproval: true,
            hasInlineAsk: true,
            hasPlanCard: true
        ))
        if case .inline = roomy.approval {} else { XCTFail("Expected inline approval when roomy") }
        if case .inline = roomy.inlineAsk {} else { XCTFail("Expected inline ask when roomy") }
        if case .expandable = roomy.planCard {} else { XCTFail("Expected expandable plan when roomy") }

        // Mid squeeze (keyboard open): Approval gets inline priority, PlanCard collapses first!
        let midSqueeze = ChatDockCardBudget.allocate(ChatDockCardBudget.Input(
            viewportHeight: 844,
            effectiveBottomOcclusion: 260, // aboveKeyboard = 584, budget = 584 - 52 - 68 - 120 = 344
            topBarHeight: 52,
            composerHeight: 68,
            minProseReadableHeight: 120,
            hasPendingApproval: true,
            canInlineApproval: true,
            hasInlineAsk: true,
            hasPlanCard: true
        ))
        if case .inline = midSqueeze.approval {} else { XCTFail("Priority 1 approval should stay inline") }
        XCTAssertEqual(midSqueeze.planCard, .forcedCollapsedCapsule, "Priority 3 PlanCard must collapse first")

        // Severe squeeze (tall composer + keyboard): Approval -> sheetFallbackOnly (NEVER downgraded),
        // InlineAsk -> compactSummaryWithSheetFallback (keeps form.id + draft), PlanCard -> forcedCollapsedCapsule!
        let severeSqueeze = ChatDockCardBudget.allocate(ChatDockCardBudget.Input(
            viewportHeight: 740,
            effectiveBottomOcclusion: 336, // aboveKeyboard = 404, budget = 404 - 52 - 140 - 120 = 92
            topBarHeight: 52,
            composerHeight: 140,
            minProseReadableHeight: 120,
            hasPendingApproval: true,
            canInlineApproval: true,
            hasInlineAsk: true,
            hasPlanCard: true
        ))
        XCTAssertEqual(severeSqueeze.approval, .sheetFallbackOnly)
        XCTAssertEqual(severeSqueeze.inlineAsk, .compactSummaryWithSheetFallback)
        XCTAssertEqual(severeSqueeze.planCard, .forcedCollapsedCapsule)

        // InlineAskDraftStore preserves draft strictly keyed by form.id across compact -> sheet -> inline.
        let formID = UUID()
        let draft = InlineAskDraftStore.Draft(
            selectedByKey: ["mode": ["fast"]],
            customByKey: ["note": "保留草稿"],
            customOpenKeys: ["note"],
            textValues: ["note": "保留草稿"]
        )
        InlineAskDraftStore.shared.save(draft, for: formID)
        XCTAssertEqual(InlineAskDraftStore.shared.draft(for: formID), draft)
        InlineAskDraftStore.shared.clear(for: formID)
        XCTAssertNil(InlineAskDraftStore.shared.draft(for: formID))
    }

    func testChromeCoordinatorLocksCollapseDuringKeyboardTransition() {
        let coord = ChatChromeCoordinator()
        coord.setEnabled(true)
        XCTAssertFalse(coord.isLockedToFull)

        coord.syncLocks(keyboardTransitioning: true)
        XCTAssertTrue(coord.isLockedToFull)

        // Upward drag during keyboard transition MUST NOT enter immersive collapse.
        coord.handleUserScroll(
            rawDeltaY: -120,
            clampedDeltaY: -120,
            distanceFromBottom: 400,
            distanceFromTop: 200,
            isDragging: true,
            isScrollable: true
        )
        XCTAssertEqual(coord.mode, .full)
        XCTAssertEqual(coord.collapseProgress, 0)

        coord.syncLocks(keyboardTransitioning: false)
        XCTAssertFalse(coord.isLockedToFull)
    }

    func testToastCenterSceneScopedGeometryIsolation() {
        let center = ToastCenter.shared
        let ownerA = UUID()
        let ownerB = UUID()
        let sceneA = "test-scene-\(UUID().uuidString)"
        let sceneB = "test-scene-\(UUID().uuidString)"
        defer {
            center.unregisterChatGeometry(ownerID: ownerA)
            center.unregisterChatGeometry(ownerID: ownerB)
        }

        center.updateChatGeometry(ownerID: ownerA, sceneID: sceneA, clearance: 124)
        XCTAssertTrue(center.hasChatGeometryOwner(forSceneID: sceneA))
        XCTAssertFalse(center.hasChatGeometryOwner(forSceneID: sceneB))
        // Chat scene consumes chat host clearance directly, ignoring non-chat fallback keyboard clearance.
        XCTAssertEqual(center.resolvedBottomClearance(forSceneID: sceneA, fallbackKeyboardClearance: 320), 124)
        // Non-chat scene still uses fallback keyboard clearance cleanly.
        XCTAssertEqual(center.resolvedBottomClearance(forSceneID: sceneB, fallbackKeyboardClearance: 320), 320)

        // Second chat owner on same scene registers before first owner disappears:
        // departing ownerA MUST NOT zero out ownerB's clearance!
        center.updateChatGeometry(ownerID: ownerB, sceneID: sceneA, clearance: 148)
        center.unregisterChatGeometry(ownerID: ownerA)
        XCTAssertTrue(center.hasChatGeometryOwner(forSceneID: sceneA))
        XCTAssertEqual(center.resolvedBottomClearance(forSceneID: sceneA, fallbackKeyboardClearance: 320), 148)

        center.unregisterChatGeometry(ownerID: ownerB)
        XCTAssertFalse(center.hasChatGeometryOwner(forSceneID: sceneA))
        XCTAssertEqual(center.resolvedBottomClearance(forSceneID: sceneA, fallbackKeyboardClearance: 320), 320)
    }
}
