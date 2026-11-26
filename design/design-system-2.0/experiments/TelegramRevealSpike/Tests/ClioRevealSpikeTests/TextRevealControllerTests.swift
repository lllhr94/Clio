import CoreGraphics
import CoreText
import Foundation
import XCTest
@testable import ClioRevealSpike
@testable import TelegramRevealUpstream

final class TextRevealControllerTests: XCTestCase {
    func testVerbatimControllerInitialAndFinalizeCatchUp() {
        let controller = TextRevealController(initialRevealedCount: 0, initialLength: 20, durationMultiplier: 1.0)
        XCTAssertEqual(controller.currentGlyphCount, 0)
        XCTAssertEqual(controller.latestLength, 20)
        XCTAssertFalse(controller.isFinalizing)

        controller.observeUpdate(latestLength: 50, at: 0.05)
        // First tick initializes TextRevealController.lastFrameTime (dt == 0), subsequent frame advances reveal.
        let initFrame = controller.tick(now: 0.066)
        XCTAssertEqual(initFrame.revealedGlyphCount, 0)
        XCTAssertFalse(initFrame.isComplete)
        let secondFrame = controller.tick(now: 0.082)
        XCTAssertGreaterThan(secondFrame.revealedGlyphCount, 0)
        XCTAssertFalse(secondFrame.isComplete)

        // Burst while finalizing must still drain cleanly without overshooting latestLength.
        controller.observeUpdate(latestLength: 120, at: 0.12)
        controller.finalize(finalLength: 120)
        XCTAssertTrue(controller.isFinalizing)

        var t = 0.066
        var completed = false
        for _ in 0..<240 {
            t += 1.0 / 60.0
            let step = controller.tick(now: t)
            XCTAssertLessThanOrEqual(step.revealedGlyphCount, 120)
            if step.isComplete {
                completed = true
                XCTAssertEqual(step.revealedGlyphCount, 120)
                break
            }
        }
        XCTAssertTrue(completed, "Controller should finalize completely within bounded ticks")
    }

    func testStallFloorAndBacklogSmoothingAcrossJitterAndBurst() {
        let controller = TextRevealController(initialRevealedCount: 0, initialLength: 0, durationMultiplier: 10.0)
        var t = 0.0

        // Simulate realistic network jitter (30ms -> 420ms -> 15ms burst -> 900ms stall)
        let schedule: [(deltaT: Double, addPoints: Int)] = [
            (0.03, 180),
            (0.03, 160),
            (0.42, 60),
            (0.015, 700),
            (0.02, 520),
            (0.90, 200),
            (0.05, 220),
        ]

        var totalPoints = 0
        var arrivalIdx = 0
        var nextEventTime = 0.01
        var maxBacklog = 0
        var prevCount = 0

        for _ in 0..<400 {
            t += 1.0 / 120.0
            if arrivalIdx < schedule.count && t >= nextEventTime {
                totalPoints += schedule[arrivalIdx].addPoints
                controller.observeUpdate(latestLength: totalPoints, at: t)
                nextEventTime = t + schedule[arrivalIdx].deltaT
                arrivalIdx += 1
            }
            if arrivalIdx == schedule.count && !controller.isFinalizing {
                controller.finalize(finalLength: totalPoints)
            }
            let tickRes = controller.tick(now: t)
            XCTAssertGreaterThanOrEqual(tickRes.revealedGlyphCount, prevCount, "Reveal must remain monotonic under jitter")
            prevCount = tickRes.revealedGlyphCount
            maxBacklog = max(maxBacklog, totalPoints - tickRes.revealedGlyphCount)
            if tickRes.isComplete {
                break
            }
        }

        XCTAssertTrue(controller.isFinalizing)
        XCTAssertEqual(controller.currentGlyphCount, totalPoints)
        XCTAssertGreaterThan(maxBacklog, 0)
    }

    func testDurationMultiplierEmpiricalComparisonWithPointsCost() {
        // Measure TTFT, backlog, peak/avg Points/s, and settle duration under real Points costs.
        let sample = String(repeating: "在 iPhone 真机 CoreText 上测试中英混排 SwiftUI 与 UIKit 揭示速率，确保不从半个字符切断。", count: 6)
        let font = ClioFontLoader.loadBundledFont(named: "ClioKai-Medium.ttf", size: 17.0)
            ?? ClioFontLoader.systemReadingFont(size: 17.0)
        let attributed = NSMutableAttributedString(
            string: sample,
            attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]
        )
        let layout = CoreTextRevealMeasurer.layoutText(attributed, maxWidth: 330.0)
        let costMap = SpikeRevealCostMap.buildSingleTextDocument(
            lines: layout.lines,
            atomicUnits: layout.atomicUnits,
            contentSize: layout.contentSize,
            utf16Length: attributed.length
        )

        let totalPts = costMap.totalPoints
        XCTAssertGreaterThan(totalPts, 500)

        let multipliers: [Double] = [1.0, 2.5, 5.0, 10.0]
        var metricsSummary: [String] = []

        for mult in multipliers {
            let ctrl = TextRevealController(initialRevealedCount: 0, initialLength: 0, durationMultiplier: mult)
            let chunkSize = max(1, totalPts / 18)
            var streamedPts = 0
            var t = 0.0
            var ttftMs: Double?
            var peakBacklog = 0
            var peakPtsPerSec = 0.0
            var prevRevealed = 0
            var finalizeStart: Double?
            var completedAt: Double?

            for frame in 0..<1500 {
                t = Double(frame) / 60.0
                if frame % 3 == 0 && streamedPts < totalPts {
                    streamedPts = min(totalPts, streamedPts + chunkSize)
                    ctrl.observeUpdate(latestLength: streamedPts, at: t)
                    if streamedPts == totalPts && !ctrl.isFinalizing {
                        ctrl.finalize(finalLength: totalPts)
                        finalizeStart = t
                    }
                }
                let step = ctrl.tick(now: t)
                if ttftMs == nil && step.revealedGlyphCount > 0 {
                    ttftMs = t * 1000.0
                }
                let backlog = streamedPts - step.revealedGlyphCount
                peakBacklog = max(peakBacklog, backlog)
                let deltaPts = Double(max(0, step.revealedGlyphCount - prevRevealed))
                peakPtsPerSec = max(peakPtsPerSec, deltaPts * 60.0)
                prevRevealed = step.revealedGlyphCount

                if step.isComplete {
                    completedAt = t
                    break
                }
            }

            XCTAssertNotNil(completedAt, "Multiplier \(mult) failed to finish")
            let totalSec = max(0.01, completedAt ?? 1.0)
            let avgPtsPerSec = Double(totalPts) / totalSec
            let drainMs = ((completedAt ?? 0.0) - (finalizeStart ?? 0.0)) * 1000.0
            let line = String(
                format: "[METRIC] durationMultiplier=%.1f totalPoints=%d ttftMs=%.1f avgPtsPerSec=%.1f peakPtsPerSec=%.1f peakBacklogPts=%d finalizeDrainMs=%.1f",
                mult, totalPts, ttftMs ?? -1.0, avgPtsPerSec, peakPtsPerSec, peakBacklog, drainMs
            )
            metricsSummary.append(line)
            print(line)
        }

        XCTAssertEqual(metricsSummary.count, 4)
    }

    func testShrinkLengthClampsRevealedCountWithoutTrap() {
        let controller = TextRevealController(initialRevealedCount: 40, initialLength: 50, durationMultiplier: 1.0)
        controller.observeUpdate(latestLength: 25, at: 0.1)
        XCTAssertEqual(controller.revealedCount, 25.0, accuracy: 0.0001)
        controller.finalize(finalLength: 20)
        XCTAssertEqual(controller.revealedCount, 20.0, accuracy: 0.0001)
    }
}
