@testable import Clio
import Foundation
import XCTest

final class ClioScrollPhysicsTests: XCTestCase {
    func testSameDirectionStreakBuildsFromThirdReleaseAndCapsAtSixteen() {
        var accelerator = ClioFlickAccelerator()
        var multipliers: [CGFloat] = []
        for index in 0..<9 {
            let time = Double(index) * 0.5
            let outcome = flick(&accelerator, time: time, y: -1_600)
            guard case let .decelerate(_, multiplier, streak) = outcome else {
                return XCTFail("Fast vertical release should decelerate")
            }
            XCTAssertEqual(streak, index + 1)
            multipliers.append(multiplier)
        }
        XCTAssertEqual(Array(multipliers.prefix(2)), [1, 1])
        XCTAssertGreaterThan(multipliers[2], 1)
        XCTAssertGreaterThan(multipliers[7], multipliers[2])
        XCTAssertEqual(multipliers.last, 16)
    }

    func testReversalTimeoutAndSettlingResetStreak() {
        var accelerator = ClioFlickAccelerator()
        _ = flick(&accelerator, time: 0, y: -1_600)
        _ = flick(&accelerator, time: 0.25, y: -1_600)
        XCTAssertEqual(flick(&accelerator, time: 0.50, y: 1_600),
                       .decelerate(velocityPtPerMs: CGPoint(x: 0, y: -1.6), multiplier: 1, streakCount: 1))
        _ = flick(&accelerator, time: 0.75, y: 1_600)
        _ = flick(&accelerator, time: 2, y: 1_600)
        XCTAssertEqual(accelerator.streakCount, 1)
        accelerator.resetAfterDecelerationEnded()
        XCTAssertEqual(accelerator.streakCount, 0)
    }

    func testSingleSampleUsesReleaseVelocityAndSlowPanBreaksStreak() {
        var accelerator = ClioFlickAccelerator()
        accelerator.beginTouchTracking(at: 0)
        accelerator.beginGesture()
        XCTAssertEqual(accelerator.release(recognizerVelocityPtPerSec: CGPoint(x: 0, y: -800), at: 0.1),
                       .decelerate(velocityPtPerMs: CGPoint(x: 0, y: 0.8), multiplier: 1, streakCount: 1))
        accelerator.beginTouchTracking(at: 0.25)
        accelerator.beginGesture()
        accelerator.notePanSample(recognizerVelocityPtPerSec: CGPoint(x: 0, y: -90), cumulativeTranslation: .zero)
        XCTAssertEqual(accelerator.release(recognizerVelocityPtPerSec: CGPoint(x: 0, y: -90), at: 0.4), .stop)
        XCTAssertEqual(accelerator.streakCount, 0)
    }

    func testBoostHonorsRevealCeilingAndMotionPreference() {
        let release = ClioFlickAccelerator.ReleaseOutcome.decelerate(
            velocityPtPerMs: CGPoint(x: 0, y: 1), multiplier: 16, streakCount: 8
        )
        XCTAssertEqual(ClioFlickAccelerator.boostedTargetOffsetY(
            outcome: release, currentOffsetY: 100, defaultTargetOffsetY: 500,
            minOffsetY: -30, maxOffsetY: 5_000, revealLimitOffsetY: 650
        ), 650)
        XCTAssertNil(ClioFlickAccelerator.boostedTargetOffsetY(
            outcome: release, currentOffsetY: 100, defaultTargetOffsetY: 500,
            minOffsetY: -30, maxOffsetY: 5_000, reduceMotion: true
        ))
    }

    func testSettledOffsetSnapsOnlySubpixelOvershoot() {
        XCTAssertEqual(ClioFlickAccelerator.snappedSettledOffsetY(-30 - 1.0 / 3, minOffsetY: -30, maxOffsetY: 200), -30)
        XCTAssertEqual(ClioFlickAccelerator.snappedSettledOffsetY(200 + 1.0 / 3, minOffsetY: -30, maxOffsetY: 200), 200)
        XCTAssertNil(ClioFlickAccelerator.snappedSettledOffsetY(-31, minOffsetY: -30, maxOffsetY: 200))
        XCTAssertNil(ClioFlickAccelerator.snappedSettledOffsetY(-29.75, minOffsetY: -30, maxOffsetY: 200))
    }

    func testJumpSpringIsMonotoneAndRetargetUsesOnlyRemainingDistance() {
        let spring = ClioSmoothScrollSpring.self
        XCTAssertEqual(spring.progress(atElapsed: 0.115), 0.5, accuracy: 0.01)
        XCTAssertEqual(spring.progress(atElapsed: 0.35), 0.96, accuracy: 0.01)
        var last = 0.0
        for step in 0...240 {
            let progress = spring.progress(atElapsed: Double(step) / 120)
            XCTAssertTrue((last...1).contains(progress))
            last = progress
        }
        XCTAssertEqual(last, 1)
        XCTAssertEqual(spring.remainingFraction(previous: 0.5, current: 0.5), 0)
        XCTAssertEqual(spring.remainingFraction(previous: 0.5, current: 0.75), 0.5)
        XCTAssertEqual(spring.remainingFraction(previous: 0.75, current: 1), 1)
    }

    private func flick(_ accelerator: inout ClioFlickAccelerator, time: Double, y: CGFloat)
        -> ClioFlickAccelerator.ReleaseOutcome {
        let velocity = CGPoint(x: 0, y: y)
        accelerator.beginTouchTracking(at: time)
        accelerator.beginGesture()
        accelerator.notePanSample(recognizerVelocityPtPerSec: velocity,
                                  cumulativeTranslation: CGPoint(x: 0, y: y.sign == .minus ? -250 : 250))
        return accelerator.release(recognizerVelocityPtPerSec: velocity, at: time + 0.1)
    }
}
