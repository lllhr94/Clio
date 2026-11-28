// ClioMotion.swift
// Clio Native Motion Policy Core & Interruptible Core Animation Primitives (iOS 26.0+)
// License: GPL-3.0-or-later

import CoreGraphics
import Foundation
import QuartzCore
import SwiftUI
import UIKit

// MARK: - 1. Pure Motion Policy Core

public enum ThermalBand: String, Codable, Sendable {
    case nominal, fair, serious, critical

    public static var current: ThermalBand {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .nominal
        }
    }
}

public struct FrameRatePolicy: Equatable, Sendable {
    public let minHz: Float
    public let maxHz: Float
    public let preferredHz: Float
    public let disableContinuousEffects: Bool

    public init(minHz: Float, maxHz: Float, preferredHz: Float, disableContinuousEffects: Bool) {
        self.minHz = minHz
        self.maxHz = maxHz
        self.preferredHz = preferredHz
        self.disableContinuousEffects = disableContinuousEffects
    }

    public var caFrameRateRange: CAFrameRateRange {
        CAFrameRateRange(minimum: minHz, maximum: maxHz, preferred: preferredHz)
    }
}

public enum MotionPolicyCore {
    /// Exact iOS 26 system keyboard spring parameters (`0.3832s`, mass=1, k=555.027, c=47.118).
    public static let keyboardSpring = (mass: 1.0, stiffness: 555.027, damping: 47.118, duration: 0.3832)

    /// Preserves 80–120Hz ProMotion in both `.nominal` and `.fair` thermal states; degrades gracefully under
    /// Low Power Mode or `.serious`/`.critical` thermal pressure.
    public static func preferredFrameRate(thermal: ThermalBand, isLowPowerMode: Bool) -> FrameRatePolicy {
        if thermal == .critical {
            return FrameRatePolicy(minHz: 30, maxHz: 60, preferredHz: 30, disableContinuousEffects: true)
        }
        if isLowPowerMode || thermal == .serious {
            return FrameRatePolicy(minHz: 60, maxHz: 60, preferredHz: 60, disableContinuousEffects: true)
        }
        return FrameRatePolicy(minHz: 80, maxHz: 120, preferredHz: 120, disableContinuousEffects: false)
    }

    /// Computes anonymous additive inverse position delta `(old - new -> 0)`.
    /// Never apply additive `bounds` animations to bordered or frosted/glass subview containers.
    public static func additivePositionDelta(
        oldCenter: (x: Double, y: Double),
        newCenter: (x: Double, y: Double)
    ) -> (dx: Double, dy: Double) {
        (dx: oldCenter.x - newCenter.x, dy: oldCenter.y - newCenter.y)
    }
}

// MARK: - 2. Semantic Spring Presets

public struct ClioSpringParameters: Sendable, Equatable {
    public let mass: CGFloat
    public let stiffness: CGFloat
    public let damping: CGFloat
    public let settlingDuration: TimeInterval
    public let prefersHighFrameRate: Bool

    public init(
        mass: CGFloat = 1.0,
        stiffness: CGFloat,
        damping: CGFloat,
        settlingDuration: TimeInterval,
        prefersHighFrameRate: Bool = true
    ) {
        self.mass = max(0.001, mass)
        self.stiffness = max(0.001, stiffness)
        self.damping = max(0.0, damping)
        self.settlingDuration = max(0.0, settlingDuration)
        self.prefersHighFrameRate = prefersHighFrameRate
    }

    public static func perceptual(
        duration: TimeInterval,
        bounce: CGFloat = 0.0,
        prefersHighFrameRate: Bool = true
    ) -> ClioSpringParameters {
        let clampedDuration = max(0.01, CGFloat(duration))
        let clampedBounce = min(max(bounce, -0.95), 0.95)
        let omega = (2.0 * .pi) / clampedDuration
        let stiffness = omega * omega
        let zeta: CGFloat = clampedBounce >= 0.0
            ? (1.0 - clampedBounce)
            : (1.0 / (1.0 + clampedBounce))
        let damping = 2.0 * zeta * omega
        let settled = estimateSettlingDuration(mass: 1.0, stiffness: stiffness, damping: damping, fallback: duration)
        return ClioSpringParameters(
            mass: 1.0,
            stiffness: stiffness,
            damping: damping,
            settlingDuration: settled,
            prefersHighFrameRate: prefersHighFrameRate
        )
    }

    private static func estimateSettlingDuration(
        mass: CGFloat,
        stiffness: CGFloat,
        damping: CGFloat,
        fallback: TimeInterval
    ) -> TimeInterval {
        let omega0 = sqrt(stiffness / mass)
        let zeta = damping / (2.0 * sqrt(stiffness * mass))
        guard omega0 > 0 else { return fallback }
        if zeta < 1.0 {
            let decayRate = max(0.5, zeta * omega0)
            return min(1.2, max(fallback, Double(6.9078 / decayRate)))
        } else if abs(zeta - 1.0) < 1e-4 {
            return min(1.2, max(fallback, Double(9.2334 / omega0)))
        } else {
            let sSlow = omega0 * (zeta - sqrt(zeta * zeta - 1.0))
            return min(1.2, max(fallback, Double(6.9078 / max(0.5, sSlow))))
        }
    }
}

public enum ClioMotionPreset: Sendable {
    /// 140ms critically damped spring for button/pill taps.
    case microPress
    /// 220ms critically damped spring for send-bubble overlay flight & snappy layout moves.
    case sendFlight
    /// 260ms critically damped spring for layout reflows (zero bounce).
    case snappyLayout
    /// Exact iOS 26 system keyboard spring (`0.3832s`).
    case keyboardSync
    /// 360ms light-bounce (`0.10`) interactive spring for sidebar drawer & panels.
    case interactivePanel
    /// 180ms gentle deceleration for subtle reveals.
    case gentleReveal
    /// Custom perceptual spring.
    case custom(duration: TimeInterval, bounce: CGFloat)

    public var parameters: ClioSpringParameters {
        switch self {
        case .microPress:
            return .perceptual(duration: 0.14, bounce: 0.0, prefersHighFrameRate: false)
        case .sendFlight:
            return .perceptual(duration: 0.22, bounce: 0.0, prefersHighFrameRate: true)
        case .snappyLayout:
            return .perceptual(duration: 0.26, bounce: 0.0, prefersHighFrameRate: true)
        case .keyboardSync:
            let kb = MotionPolicyCore.keyboardSpring
            return ClioSpringParameters(
                mass: CGFloat(kb.mass),
                stiffness: CGFloat(kb.stiffness),
                damping: CGFloat(kb.damping),
                settlingDuration: kb.duration,
                prefersHighFrameRate: true
            )
        case .interactivePanel:
            return .perceptual(duration: 0.36, bounce: 0.10, prefersHighFrameRate: true)
        case .gentleReveal:
            return .perceptual(duration: 0.18, bounce: 0.0, prefersHighFrameRate: false)
        case let .custom(duration, bounce):
            return .perceptual(duration: duration, bounce: bounce, prefersHighFrameRate: true)
        }
    }

    public var swiftUIAnimation: Animation {
        let p = parameters
        return .interpolatingSpring(
            mass: Double(p.mass),
            stiffness: Double(p.stiffness),
            damping: Double(p.damping),
            initialVelocity: 0.0
        )
    }
}

/// Animation metadata shared by UIKit's manual dock layout and the SwiftUI toast overlay.
struct ClioKeyboardMotion {
    let duration: TimeInterval
    let curve: UIView.AnimationCurve?
    let spring: ClioMotionPreset

    init(_ notification: Notification) {
        let info = notification.userInfo
        let reportedDuration = info?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double
        let standardDuration = MotionPolicyCore.keyboardSpring.duration
        let requested = reportedDuration.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } ?? standardDuration

        if abs(requested - standardDuration) < 0.02 {
            duration = standardDuration
            curve = nil
            spring = .keyboardSync
        } else {
            duration = requested
            let curveValue = info?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int
            curve = curveValue.flatMap(UIView.AnimationCurve.init(rawValue:))
            spring = .custom(duration: requested, bounce: 0)
        }
    }

    var swiftUIAnimation: Animation? {
        guard duration > 0.001 else { return nil }
        switch curve {
        case .easeInOut: return .easeInOut(duration: duration)
        case .easeIn: return .easeIn(duration: duration)
        case .easeOut: return .easeOut(duration: duration)
        case .linear: return .linear(duration: duration)
        case nil: return spring.swiftUIAnimation
        @unknown default: return spring.swiftUIAnimation
        }
    }
}

// MARK: - 3. Interruptible Core Animation Executor

@MainActor
public enum ClioTransition {
    public static var currentFrameRatePolicy: FrameRatePolicy {
        MotionPolicyCore.preferredFrameRate(
            thermal: ThermalBand.current,
            isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }

    public static var shouldSimplifyMotion: Bool {
        if UIAccessibility.isReduceMotionEnabled || Theme.shared.reduceVisualEffects {
            return true
        }
        return currentFrameRatePolicy.disableContinuousEffects
    }

    /// Adds a pure 2D anonymous additive translation spring (`forKey: nil`) on `layer.position`
    /// without mutating `bounds`, guaranteeing 0.0pt jumps under arbitrary mid-flight interruption.
    public static func animatePositionAdditive(
        layer: CALayer,
        fromOffset delta: CGPoint,
        preset: ClioMotionPreset = .snappyLayout,
        initialVelocity: CGFloat = 0.0,
        completion: ((Bool) -> Void)? = nil
    ) {
        guard !shouldSimplifyMotion, (abs(delta.x) > 0.01 || abs(delta.y) > 0.01) else {
            completion?(true)
            return
        }
        let anim = makeSpringAnimation(
            keyPath: "position",
            fromValue: NSValue(cgPoint: delta),
            toValue: NSValue(cgPoint: .zero),
            isAdditive: true,
            parameters: preset.parameters,
            initialVelocity: initialVelocity,
            completion: completion
        )
        layer.add(anim, forKey: nil)
    }

    /// Retargets non-additive scalar properties (`opacity`, `cornerRadius`, `transform.scale`)
    /// seamlessly from `layer.presentation()`.
    public static func animateScalarFromPresentation(
        layer: CALayer,
        keyPath: String,
        to targetValue: CGFloat,
        preset: ClioMotionPreset = .snappyLayout,
        completion: ((Bool) -> Void)? = nil
    ) {
        let currentPresented = (layer.presentation()?.value(forKeyPath: keyPath) as? CGFloat)
            ?? (layer.value(forKeyPath: keyPath) as? CGFloat)
            ?? targetValue

        layer.setValue(targetValue, forKeyPath: keyPath)

        guard !shouldSimplifyMotion, abs(currentPresented - targetValue) > 0.001 else {
            layer.removeAnimation(forKey: keyPath)
            completion?(true)
            return
        }

        let anim = makeSpringAnimation(
            keyPath: keyPath,
            fromValue: currentPresented,
            toValue: targetValue,
            isAdditive: false,
            parameters: preset.parameters,
            initialVelocity: 0.0,
            completion: completion
        )
        layer.add(anim, forKey: keyPath)
    }

    /// SwiftUI owns both the layout and the presentation values in a hosted view. Its spring
    /// retargets the existing presentation without applying a second animation to the host layer.
    public static var layoutAnimation: Animation? {
        shouldSimplifyMotion ? nil : ClioMotionPreset.snappyLayout.swiftUIAnimation
    }

    /// Matches the iOS 26 keyboard spring while respecting explicit zero-duration updates.
    public static func syncWithKeyboardNotification(
        _ notification: Notification,
        animations: @escaping () -> Void,
        completion: (() -> Void)? = nil
    ) {
        let motion = ClioKeyboardMotion(notification)
        if motion.duration <= 0.001 || shouldSimplifyMotion {
            UIView.performWithoutAnimation(animations)
            completion?()
            return
        }

        let animator: UIViewPropertyAnimator
        if let curve = motion.curve {
            animator = UIViewPropertyAnimator(duration: motion.duration, curve: curve)
        } else {
            let p = motion.spring.parameters
            let timing = UISpringTimingParameters(
                mass: p.mass,
                stiffness: p.stiffness,
                damping: p.damping,
                initialVelocity: .zero
            )
            animator = UIViewPropertyAnimator(duration: motion.duration, timingParameters: timing)
        }
        animator.isInterruptible = true
        animator.addAnimations(animations)
        if let completion {
            animator.addCompletion { _ in completion() }
        }
        animator.startAnimation()
    }

    public static func syncWithKeyboardNotification(
        _ notification: Notification,
        swiftUIUpdates: () -> Void
    ) {
        let motion = ClioKeyboardMotion(notification)
        let animation = shouldSimplifyMotion ? nil : motion.swiftUIAnimation
        withAnimation(animation, swiftUIUpdates)
    }

    /// Projects resting offset from gesture release velocity using UIScrollView exponential decay.
    public static func projectLandingOffset(
        currentOffset: CGFloat,
        velocityPtPerSec: CGFloat,
        decelerationRate: CGFloat = UIScrollView.DecelerationRate.normal.rawValue
    ) -> CGFloat {
        let velocityPerMs = velocityPtPerSec / 1000.0
        let clampedRate = min(max(decelerationRate, 0.90), 0.9995)
        return currentOffset + velocityPerMs * clampedRate / (1.0 - clampedRate)
    }

    // MARK: - Internal Factory

    private static func makeSpringAnimation(
        keyPath: String,
        fromValue: Any,
        toValue: Any,
        isAdditive: Bool,
        parameters: ClioSpringParameters,
        initialVelocity: CGFloat,
        completion: ((Bool) -> Void)?
    ) -> CASpringAnimation {
        let anim = CASpringAnimation(keyPath: keyPath)
        anim.mass = parameters.mass
        anim.stiffness = parameters.stiffness
        anim.damping = parameters.damping
        anim.initialVelocity = initialVelocity
        anim.fromValue = fromValue
        anim.toValue = toValue
        anim.isAdditive = isAdditive
        anim.duration = max(anim.settlingDuration, parameters.settlingDuration)
        anim.isRemovedOnCompletion = true
        anim.fillMode = .forwards

        let ratePolicy = currentFrameRatePolicy
        if parameters.prefersHighFrameRate && !ratePolicy.disableContinuousEffects {
            anim.preferredFrameRateRange = ratePolicy.caFrameRateRange
        }

        if let completion {
            anim.delegate = ClioAnimationCompletionDelegate(onComplete: completion)
        }
        return anim
    }
}

private final class ClioAnimationCompletionDelegate: NSObject, CAAnimationDelegate {
    private var onComplete: ((Bool) -> Void)?

    init(onComplete: @escaping (Bool) -> Void) {
        self.onComplete = onComplete
        super.init()
    }

    func animationDidStop(_ anim: CAAnimation, finished flag: Bool) {
        let callback = onComplete
        onComplete = nil
        callback?(flag)
    }
}
