// SPDX-License-Identifier: GPL-3.0-or-later
// Adapts Telegram-iOS CoreList at 24638bc6 (GPL-2.0-or-later).
// See Reading/ThirdParty/TelegramReveal/UPSTREAM.md for source mapping.

import Foundation
#if canImport(UIKit)
import UIKit
import QuartzCore
#endif

/// Pure value-type adaptation of Telegram CoreList's `ReleaseDecision` + `Deceleration` momentum projection.
/// Plugs into `UICollectionViewDelegate`'s `scrollViewWillBeginDragging`, pan updates,
/// `scrollViewWillEndDragging(_:withVelocity:targetContentOffset:)`, and `scrollViewDidEndDecelerating`.
///
/// Velocity internally uses points/millisecond (content-signed: `-panVelocity * 0.001`),
/// while public UIKit bridge parameters accept points/second (finger-signed) directly from `UIPanGestureRecognizer`.
public struct ClioFlickAccelerator: Equatable, Sendable {
    public enum ReleaseOutcome: Equatable, Sendable {
        /// `velocityPtPerMs` is content-signed; `multiplier` is in `1.0...16.0`.
        case decelerate(velocityPtPerMs: CGPoint, multiplier: CGFloat, streakCount: Int)
        case stop
    }

    // Calibrated constants from Telegram CoreList `ReleaseDecision.swift`:
    /// `|v|^2 >= 0.0625` (`|v| >= 0.25 pt/ms` == `250 pt/s`) triggers deceleration.
    public static let decelerateThresholdSquared: CGFloat = 0.0625
    /// Low-pass blend weights (`0.75 * previous + 0.25 * latest`, skipped when `previous == .zero`).
    public static let previousWeight: CGFloat = 0.75
    public static let latestWeight: CGFloat = 0.25
    /// pts/s -> pts/ms.
    public static let recognizerVelocityScale: CGFloat = 0.001
    /// `|v|^2 >= 0.36` (`|v| >= 0.60 pt/ms` == `600 pt/s`) counts as a fast flick.
    public static let fastFlickThresholdSquared: CGFloat = 0.36
    /// Slowing below `|v| = 0.13 pt/ms` (`130 pt/s`) mid-drag breaks the streak.
    public static let streakBreakThresholdSquared: CGFloat = 0.0169
    /// Seconds after the previous release during which a new touch carries the streak.
    public static let streakTimeout: TimeInterval = 1.0
    /// Drag distance (pt) saturating per-flick growth.
    public static let streakDistanceScale: CGFloat = 240.0
    /// Per-step growth clamp.
    public static let streakDistanceCap: CGFloat = 0.9
    /// Hard upper bound on deceleration distance multiplier.
    public static let multiplierCap: CGFloat = 16.0
    /// Consecutive fast flicks required before multiplier starts scaling above 1x.
    public static let streakGrowthFloor: Int = 3
    /// Normal `UIScrollView` per-millisecond deceleration rate (`0.998`).
    public static let normalDecelerationRate: CGFloat = 0.998
    /// 3x-Retina boundary settle tolerance (Telegram `Deceleration.swift` real-device `-0.33pt` fix).
    public static let boundarySnapTolerance: CGFloat = 0.5

    public private(set) var latestVelocityPtPerMs: CGPoint = .zero
    public private(set) var previousVelocityPtPerMs: CGPoint = .zero
    public private(set) var streakCount: Int = 0
    public private(set) var multiplier: CGFloat = 1.0
    public private(set) var startMultiplier: CGFloat = 1.0
    public private(set) var lastResetReason: String = "-"

    private var streakEndTime: TimeInterval?
    private var lastSignY: FloatingPointSign?
    private var streakDirection: FloatingPointSign?

    public init() {}

    /// Call on touch-down / `scrollViewWillBeginDragging` with monotonic `CACurrentMediaTime()`.
    public mutating func beginTouchTracking(at timestamp: TimeInterval) {
        previousVelocityPtPerMs = .zero
        if let end = streakEndTime, timestamp > end + Self.streakTimeout {
            streakCount = 0
            multiplier = 1.0
            streakDirection = nil
            lastResetReason = "timeout"
        }
        startMultiplier = multiplier
    }

    /// Call when the pan gesture enters `.began` (resets per-gesture velocity history before first sample).
    public mutating func beginGesture() {
        latestVelocityPtPerMs = .zero
        previousVelocityPtPerMs = .zero
        lastSignY = nil
    }

    /// Call on pan `.changed` (or `scrollViewDidScroll` while dragging) with finger-signed `pan.velocity(in:)`
    /// and cumulative `pan.translation(in:)`.
    public mutating func notePanSample(
        recognizerVelocityPtPerSec: CGPoint,
        cumulativeTranslation: CGPoint
    ) {
        previousVelocityPtPerMs = latestVelocityPtPerMs
        latestVelocityPtPerMs = CGPoint(
            x: -recognizerVelocityPtPerSec.x * Self.recognizerVelocityScale,
            y: -recognizerVelocityPtPerSec.y * Self.recognizerVelocityScale
        )

        if latestVelocityPtPerMs.y != 0 {
            let sign = latestVelocityPtPerMs.y.sign
            let priorSign = lastSignY ?? streakDirection
            let reversed = priorSign.map { $0 != sign } ?? false
            let magSq = latestVelocityPtPerMs.x * latestVelocityPtPerMs.x
                + latestVelocityPtPerMs.y * latestVelocityPtPerMs.y
            if reversed || magSq < Self.streakBreakThresholdSquared {
                if streakCount > 0 {
                    lastResetReason = reversed ? "reversal" : "slow-drag-sample"
                }
                streakCount = 0
                multiplier = 1.0
                streakDirection = nil
            }
            lastSignY = sign
        }

        let nextStreak = streakCount + 1
        if nextStreak >= Self.streakGrowthFloor {
            let distance = hypot(cumulativeTranslation.x, cumulativeTranslation.y)
            let steps = 1.0 + CGFloat(nextStreak - Self.streakGrowthFloor) / 2.0
            let term = steps * min(distance / Self.streakDistanceScale, Self.streakDistanceCap)
            multiplier = min(startMultiplier + term, Self.multiplierCap)
        }
    }

    /// Call inside `scrollViewWillEndDragging(_:withVelocity:targetContentOffset:)`.
    /// Pass `scrollView.panGestureRecognizer.velocity(in: scrollView)` (pt/s, finger-signed) and `CACurrentMediaTime()`.
    public mutating func release(
        recognizerVelocityPtPerSec: CGPoint,
        at timestamp: TimeInterval
    ) -> ReleaseOutcome {
        if recognizerVelocityPtPerSec == .zero {
            latestVelocityPtPerMs = .zero
        } else if latestVelocityPtPerMs == .zero {
            // Single-callback flick fallback if no `.changed` sample arrived before release.
            latestVelocityPtPerMs = CGPoint(
                x: -recognizerVelocityPtPerSec.x * Self.recognizerVelocityScale,
                y: -recognizerVelocityPtPerSec.y * Self.recognizerVelocityScale
            )
        }

        if let direction = streakDirection, latestVelocityPtPerMs.y != 0,
           direction != latestVelocityPtPerMs.y.sign {
            lastResetReason = "reversal"
            streakCount = 0
            multiplier = 1.0
            streakDirection = nil
        }
        let magSq = latestVelocityPtPerMs.x * latestVelocityPtPerMs.x
            + latestVelocityPtPerMs.y * latestVelocityPtPerMs.y
        guard magSq >= Self.decelerateThresholdSquared else {
            latestVelocityPtPerMs = .zero
            previousVelocityPtPerMs = .zero
            if streakCount > 0 { lastResetReason = "below-decel-threshold" }
            streakCount = 0
            multiplier = 1.0
            streakDirection = nil
            return .stop
        }

        if magSq < Self.fastFlickThresholdSquared || abs(latestVelocityPtPerMs.y) < abs(latestVelocityPtPerMs.x) {
            if streakCount > 0 { lastResetReason = "slow-release" }
            streakCount = 0
            multiplier = 1.0
            streakDirection = nil
        } else {
            streakCount += 1
            streakEndTime = timestamp
            streakDirection = latestVelocityPtPerMs.y.sign
        }

        // Guarded low-pass filter: skipped on single-frame flicks (`previous == .zero`).
        if previousVelocityPtPerMs != .zero {
            latestVelocityPtPerMs = CGPoint(
                x: Self.previousWeight * previousVelocityPtPerMs.x + Self.latestWeight * latestVelocityPtPerMs.x,
                y: Self.previousWeight * previousVelocityPtPerMs.y + Self.latestWeight * latestVelocityPtPerMs.y
            )
        }

        return .decelerate(
            velocityPtPerMs: latestVelocityPtPerMs,
            multiplier: multiplier,
            streakCount: streakCount
        )
    }

    /// Call inside `scrollViewDidEndDecelerating` and when drag ends with `willDecelerate == false`.
    /// Ensures a streak only carries across gestures that interrupt an active flight.
    public mutating func resetAfterDecelerationEnded() {
        if streakCount > 0 { lastResetReason = "decel-ended" }
        streakCount = 0
        multiplier = 1.0
        streakDirection = nil
        streakEndTime = nil
    }

    /// Computes the boosted `targetContentOffset.pointee.y` for `UICollectionView`'s native Render-Server deceleration.
    ///
    /// - Returns: `nil` when `multiplier <= 1.0` (keep UIKit's default target untouched) or Reduce Motion is enabled;
    ///   otherwise returns the clamped target Y honoring both scroll bounds and Clio's `CX-08` streaming reveal ceiling.
    public static func boostedTargetOffsetY(
        outcome: ReleaseOutcome,
        currentOffsetY: CGFloat,
        defaultTargetOffsetY: CGFloat,
        minOffsetY: CGFloat,
        maxOffsetY: CGFloat,
        revealLimitOffsetY: CGFloat? = nil,
        decelerationRate: CGFloat = normalDecelerationRate,
        reduceMotion: Bool = false
    ) -> CGFloat? {
        guard !reduceMotion,
              case let .decelerate(velocityPtPerMs, mult, _) = outcome,
              mult > 1.001,
              abs(velocityPtPerMs.y) >= 0.01 else {
            return nil
        }

        let hi = max(minOffsetY, maxOffsetY)
        let clampedRate = min(max(decelerationRate, 0.90), 0.9995)
        // Analytical total travel from Telegram Deceleration.swift: dx = v * rate / (1 - rate) * vScale
        let boostedTravel = velocityPtPerMs.y * clampedRate / (1.0 - clampedRate) * mult
        var candidate = currentOffsetY + boostedTravel

        // Never shorten UIKit's own default travel in the same direction.
        if velocityPtPerMs.y > 0 {
            candidate = max(candidate, defaultTargetOffsetY)
        } else {
            candidate = min(candidate, defaultTargetOffsetY)
        }

        // Clamp to content bounds.
        candidate = min(hi, max(minOffsetY, candidate))

        // Clio CX-08 guard: never overshoot past the active streaming reveal frontier into blank tail space.
        if let revealLimitOffsetY, revealLimitOffsetY < hi - 2.0, candidate > revealLimitOffsetY {
            candidate = max(minOffsetY, revealLimitOffsetY)
        }
        return candidate
    }

    /// Replicates Telegram `Deceleration.swift`'s 3x-Retina settle snap:
    /// clamps tiny `<= 0.5pt` boundary residue (e.g. `-0.33pt` on 3x screens) cleanly onto `[minOffsetY, maxOffsetY]`.
    public static func snappedSettledOffsetY(
        _ offsetY: CGFloat,
        minOffsetY: CGFloat,
        maxOffsetY: CGFloat,
        tolerance: CGFloat = boundarySnapTolerance
    ) -> CGFloat? {
        let hi = max(minOffsetY, maxOffsetY)
        if offsetY < minOffsetY && (minOffsetY - offsetY) <= tolerance {
            return minOffsetY
        }
        if offsetY > hi && (offsetY - hi) <= tolerance {
            return hi
        }
        return nil
    }
}

// MARK: - 2. Telegram UIKit Smooth-Deceleration Scroll Spring (Zero Private API)

/// Pure closed-form reproduction of UIKit's `__smoothDecelerationAnimation` documented in Telegram
/// `CoreListSpringAnimation.swift` (`response = 0.6`, critically damped `zeta = 1.0`,
/// `naturalDuration = 1.6s`, played at `1.15s` logical duration => `~1.39x` speed).
///
/// Half the distance completes by ~0.115s and ~96% by ~0.35s with zero overshoot — ideal for
/// Clio's jump-to-bottom (`⌄`), right-side minimap jump, search hit jump, and citation jump.
public enum ClioSmoothScrollSpring {
    public static let response: Double = 0.6
    public static let naturalDuration: Double = 1.6
    public static let defaultDuration: Double = 1.15
    public static let omega: Double = 2.0 * Double.pi / response
    /// Closed-form critically damped progress in `[0, 1]` at elapsed wall-clock seconds `elapsed`
    /// for a jump of logical `duration` (default `1.15s`). Zero `_solveForInput:` private API.
    public static func progress(atElapsed elapsed: Double, duration: Double = defaultDuration) -> Double {
        guard duration > 0.0001 else { return 1.0 }
        let clamped = min(max(elapsed, 0.0), duration)
        if clamped >= duration { return 1.0 }
        // Map logical duration onto natural 1.6s spring timeline via playback speed `natural / logical`.
        let springTime = clamped * (naturalDuration / duration)
        let displacement = exp(-omega * springTime) * (-1.0 - omega * springTime)
        let value = 1.0 + displacement
        if value >= 0.9998 { return 1.0 }
        return min(1.0, max(0.0, value))
    }

    /// Convert the spring's absolute progress into the fraction of distance remaining
    /// to travel on this frame. A moving destination never changes earlier frames.
    static func remainingFraction(previous: Double, current: Double) -> CGFloat {
        guard previous < 1 else { return 1 }
        return CGFloat(min(1, max(0, (current - previous) / (1 - previous))))
    }
}

#if canImport(UIKit)
@MainActor
final class ClioSmoothScrollJumpDriver {
    var isActive: Bool { onComplete != nil }

    private weak var scrollView: UIScrollView?
    private var startTime: CFTimeInterval = 0
    private var previousProgress: Double = 0
    private var onComplete: ((Bool) -> Void)?

    func start(on scrollView: UIScrollView, onComplete: @escaping (Bool) -> Void) {
        self.scrollView = scrollView
        startTime = CACurrentMediaTime()
        previousProgress = 0
        self.onComplete = onComplete
    }

    func step(now: CFTimeInterval, targetY: CGFloat, within bounds: ClosedRange<CGFloat>) {
        guard isActive else { return }
        guard let scrollView, !scrollView.isTracking, !scrollView.isDragging else {
            finish(reachedDestination: false)
            return
        }
        let targetOffsetY = min(bounds.upperBound, max(bounds.lowerBound, targetY))
        let progress = ClioSmoothScrollSpring.progress(atElapsed: now - startTime)
        let fraction = ClioSmoothScrollSpring.remainingFraction(previous: previousProgress, current: progress)
        previousProgress = progress

        let currentY = scrollView.contentOffset.y
        let nextY = currentY + (targetOffsetY - currentY) * fraction
        let finished = progress >= 1 || abs(targetOffsetY - nextY) < 0.25
        let finalY = finished ? targetOffsetY : min(bounds.upperBound, max(bounds.lowerBound, nextY))
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: finalY), animated: false)
        if finished { finish(reachedDestination: true) }
    }

    func cancel() {
        scrollView = nil
        onComplete = nil
    }

    private func finish(reachedDestination: Bool) {
        let completion = onComplete
        cancel()
        completion?(reachedDestination)
    }
}
#endif
