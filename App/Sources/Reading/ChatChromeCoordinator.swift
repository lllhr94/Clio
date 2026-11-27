import Observation
import QuartzCore
import SwiftUI
import UIKit

/// Coordinates Scroll-Aware immersive chrome transitions, 9-condition full locks,
/// and floating overlay clearance without triggering chat-row body redraws.
@MainActor @Observable
final class ChatChromeCoordinator {
    enum Mode: Equatable {
        case full
        case immersive
    }

    private(set) var mode: Mode = .full
    private(set) var collapseProgress: CGFloat = 0
    @ObservationIgnored private(set) var isEnabled: Bool = Pref.immersiveChrome
    var isImmersive: Bool { mode == .immersive }
    var visualProgress: CGFloat { isEnabled ? collapseProgress : 0 }

    @ObservationIgnored var isKeyboardOpen = false
    @ObservationIgnored var isKeyboardTransitioning = false
    @ObservationIgnored var isComposerFocused = false
    @ObservationIgnored var hasActiveSelection = false
    @ObservationIgnored var isDictating = false
    @ObservationIgnored var hasQuoteOrEdit = false
    @ObservationIgnored var hasPendingApproval = false
    @ObservationIgnored var hasInlineAsk = false
    @ObservationIgnored var hasBrowserTakeover = false
    @ObservationIgnored var isFinding = false

    @ObservationIgnored private var upwardAccumulated: CGFloat = 0
    @ObservationIgnored private var lastDragDirection: Int = 0
    @ObservationIgnored private var programmaticUntil: CFTimeInterval = 0
    @ObservationIgnored private nonisolated(unsafe) var voiceOverObserver: NSObjectProtocol?
    @ObservationIgnored private nonisolated(unsafe) var switchControlObserver: NSObjectProtocol?

    init() {
        voiceOverObserver = NotificationCenter.default.addObserver(
            forName: UIAccessibility.voiceOverStatusDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if UIAccessibility.isVoiceOverRunning && (self.mode == .immersive || self.collapseProgress > 0) {
                    self.restore()
                }
            }
        }
        switchControlObserver = NotificationCenter.default.addObserver(
            forName: UIAccessibility.switchControlStatusDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if UIAccessibility.isSwitchControlRunning && (self.mode == .immersive || self.collapseProgress > 0) {
                    self.restore()
                }
            }
        }
    }

    deinit {
        if let voiceOverObserver {
            NotificationCenter.default.removeObserver(voiceOverObserver)
        }
        if let switchControlObserver {
            NotificationCenter.default.removeObserver(switchControlObserver)
        }
    }

    let enterDeadzone: CGFloat = 12
    let collapseSpan: CGFloat = 84
    let reverseExpandSpan: CGFloat = 72
    let minDistanceFromBottomToEnter: CGFloat = 64
    let restoreBottomDistance: CGFloat = 60
    let topPullRestoreBand: CGFloat = 8
    let programmaticImmunityWindow: CFTimeInterval = 0.14

    private var settleAnimation: Animation {
        UIAccessibility.isReduceMotionEnabled
            ? .easeOut(duration: 0.18)
            : .spring(response: 0.34, dampingFraction: 0.90)
    }

    var isLockedToFull: Bool {
        isKeyboardOpen
            || isKeyboardTransitioning
            || isComposerFocused
            || hasActiveSelection
            || isDictating
            || UIAccessibility.isVoiceOverRunning
            || UIAccessibility.isSwitchControlRunning
            || hasQuoteOrEdit
            || hasPendingApproval
            || hasInlineAsk
            || hasBrowserTakeover
            || isFinding
    }

    func markProgrammaticScroll(duration: CFTimeInterval? = nil) {
        let window = duration ?? programmaticImmunityWindow
        programmaticUntil = max(programmaticUntil, CACurrentMediaTime() + max(0, window))
        upwardAccumulated = 0
        lastDragDirection = 0
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        if !enabled {
            restore(animated: true)
        }
    }

    func restore(animated: Bool = true) {
        upwardAccumulated = 0
        lastDragDirection = 0
        if mode != .full || collapseProgress > 0 {
            if animated {
                withAnimation(settleAnimation) {
                    mode = .full
                    collapseProgress = 0
                }
            } else {
                mode = .full
                collapseProgress = 0
            }
        }
        markProgrammaticScroll(duration: 0.16)
    }

    func syncLocks(
        keyboardOpen: Bool? = nil,
        keyboardTransitioning: Bool? = nil,
        composerFocused: Bool? = nil,
        activeSelection: Bool? = nil,
        dictating: Bool? = nil,
        quoteOrEdit: Bool? = nil,
        pendingApproval: Bool? = nil,
        inlineAsk: Bool? = nil,
        browserTakeover: Bool? = nil,
        finding: Bool? = nil
    ) {
        if let keyboardOpen { isKeyboardOpen = keyboardOpen }
        if let keyboardTransitioning { isKeyboardTransitioning = keyboardTransitioning }
        if let composerFocused { isComposerFocused = composerFocused }
        if let activeSelection { hasActiveSelection = activeSelection }
        if let dictating { isDictating = dictating }
        if let quoteOrEdit { hasQuoteOrEdit = quoteOrEdit }
        if let pendingApproval { hasPendingApproval = pendingApproval }
        if let inlineAsk { hasInlineAsk = inlineAsk }
        if let browserTakeover { hasBrowserTakeover = browserTakeover }
        if let finding { isFinding = finding }

        if isLockedToFull && (mode == .immersive || collapseProgress > 0) {
            restore(animated: true)
        }
    }

    func handleUserScroll(
        rawDeltaY: CGFloat,
        clampedDeltaY: CGFloat,
        distanceFromBottom: CGFloat,
        distanceFromTop: CGFloat,
        isDragging: Bool,
        isScrollable: Bool
    ) {
        guard isEnabled, !isLockedToFull, isScrollable else {
            if mode != .full || collapseProgress > 0 {
                restore(animated: true)
            } else {
                upwardAccumulated = 0
                lastDragDirection = 0
            }
            return
        }
        guard CACurrentMediaTime() >= programmaticUntil else { return }

        if distanceFromBottom <= restoreBottomDistance {
            if mode != .full || collapseProgress > 0 {
                restore(animated: true)
            } else {
                upwardAccumulated = 0
                lastDragDirection = 0
            }
            return
        }

        if isDragging && distanceFromTop <= topPullRestoreBand && rawDeltaY < -1.0 {
            if mode != .full || collapseProgress > 0 {
                restore(animated: true)
            }
            return
        }

        guard isDragging else { return }

        if clampedDeltaY < 0, distanceFromBottom > minDistanceFromBottomToEnter {
            let upwardStep = -clampedDeltaY
            if UIAccessibility.isReduceMotionEnabled {
                upwardAccumulated += upwardStep
                if mode == .full && upwardAccumulated >= 56 {
                    upwardAccumulated = 0
                    lastDragDirection = -1
                    withAnimation(settleAnimation) {
                        collapseProgress = 1
                        mode = .immersive
                    }
                }
            } else {
                let effectiveDelta: CGFloat
                if upwardAccumulated < enterDeadzone {
                    let remaining = enterDeadzone - upwardAccumulated
                    if upwardStep <= remaining {
                        upwardAccumulated += upwardStep
                        return
                    }
                    upwardAccumulated = enterDeadzone
                    effectiveDelta = upwardStep - remaining
                } else {
                    effectiveDelta = upwardStep
                }
                lastDragDirection = -1
                let next = min(1, collapseProgress + effectiveDelta / collapseSpan)
                if next >= 0.995 {
                    collapseProgress = 1
                    mode = .immersive
                } else if next != collapseProgress {
                    collapseProgress = next
                }
            }
        } else if clampedDeltaY > 0 {
            upwardAccumulated = 0
            // Once collapsed, downward reading of a multi-screen reply stays quiet until near the bottom.
            if collapseProgress > 0 && collapseProgress < 0.99 && !UIAccessibility.isReduceMotionEnabled {
                lastDragDirection = 1
                let next = max(0, collapseProgress - clampedDeltaY / reverseExpandSpan)
                collapseProgress = next
                if next <= 0.005 {
                    collapseProgress = 0
                    mode = .full
                }
            }
        }
    }

    func handleUserDragEnded() {
        upwardAccumulated = 0
        guard isEnabled, !isLockedToFull else {
            if mode != .full || collapseProgress > 0 {
                restore(animated: true)
            }
            return
        }
        if collapseProgress > 0 && collapseProgress < 1 {
            let shouldCollapse = (lastDragDirection < 0 && collapseProgress >= 0.32) || collapseProgress >= 0.5
            lastDragDirection = 0
            withAnimation(settleAnimation) {
                collapseProgress = shouldCollapse ? 1 : 0
                mode = shouldCollapse ? .immersive : .full
            }
        } else {
            lastDragDirection = 0
        }
    }

    func resetForChatSwitch() {
        isKeyboardOpen = false
        isKeyboardTransitioning = false
        isComposerFocused = false
        hasActiveSelection = false
        isDictating = false
        hasQuoteOrEdit = false
        hasPendingApproval = false
        hasInlineAsk = false
        hasBrowserTakeover = false
        isFinding = false
        upwardAccumulated = 0
        lastDragDirection = 0
        programmaticUntil = 0
        if mode != .full || collapseProgress > 0 {
            collapseProgress = 0
            mode = .full
        }
    }

    @MainActor
    static func jumpKeepOutWidth(latestVisible: Bool) -> CGFloat {
        latestVisible ? (ChatBarMetrics.jumpSize + 8 * ChatBarMetrics.scale) : 0
    }
}
