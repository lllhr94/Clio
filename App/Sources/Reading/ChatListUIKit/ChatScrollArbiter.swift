import CoreGraphics
import Foundation

/// Single per-frame `contentOffset` write-point arbiter implementing strict 3-tier competition priority:
/// 1. Tier 1 (Highest): Active user touch/scroll or text selection immediately cancels all pinned/lift/reveal/settle transactions.
/// 2. Tier 2: Explicit jump (minimap/search/outline) or history pagination takes anchor ownership.
/// 3. Tier 3 (Base): Single unified synthesis per frame from effective occlusion + frozen reading intent
///    (`isPinnedToBottom` follow vs one-shot mild off-bottom lift `<= 120pt` without mutating `isPinnedToBottom`).
struct ChatScrollArbiterCore: Equatable, Sendable {
    static let mildOffBottomMaxDistance: CGFloat = 120.0

    enum WriteSource: Equatable, Sendable {
        case revealTick(epoch: UInt64)
        case finalizedSettle(epoch: UInt64)
        case approvalCardSettle(epoch: UInt64)
        case insetOrKeyboardSynthesis(epoch: UInt64)
        case streamingResize(epoch: UInt64)
        case explicitJump
        case historyPagination
        case userAnchorPreserve
    }

    struct MildOffBottomLift: Equatable, Sendable {
        let preFocusDistanceFromBottom: CGFloat
        let preFocusOffsetY: CGFloat
        let startBottomInset: CGFloat
        let targetBottomInset: CGFloat
        let wasUnscrollable: Bool
        let epoch: UInt64
    }

    struct FrameMetrics: Equatable, Sendable {
        let currentOffsetY: CGFloat
        let contentHeight: CGFloat
        let boundsHeight: CGFloat
        let topInset: CGFloat
        let bottomInset: CGFloat
        /// Optional reveal-line bottom target offset when streaming reveal is actively unfolding.
        let revealedBottomOffsetY: CGFloat?
        /// Preserved reading-anchor target offset (`anchorFrameMinY - anchorVisualY`) for deep history.
        let anchorTargetOffsetY: CGFloat?

        var minOffsetY: CGFloat { -topInset }
        var maxBottomOffsetY: CGFloat {
            max(minOffsetY, contentHeight - boundsHeight + bottomInset)
        }
        var effectiveBottomOffsetY: CGFloat {
            guard let revealed = revealedBottomOffsetY else { return maxBottomOffsetY }
            return max(minOffsetY, min(maxBottomOffsetY, revealed))
        }
        var isScrollable: Bool {
            (contentHeight + topInset + bottomInset) > boundsHeight + 0.5
        }
    }

    struct SynthesisDecision: Equatable, Sendable {
        let targetOffsetY: CGFloat?
        let wroteOffset: Bool
        let reason: String
    }

    private(set) var isPinnedToBottom: Bool = true
    private(set) var isUserTouchScrolling: Bool = false
    private(set) var hasActiveTextSelection: Bool = false
    private(set) var isInteractiveKeyboardDismissing: Bool = false
    private(set) var interactionEpoch: UInt64 = 1
    private(set) var mildLift: MildOffBottomLift?
    private(set) var explicitJumpEpoch: UInt64?

    init(isPinnedToBottom: Bool = true) {
        self.isPinnedToBottom = isPinnedToBottom
    }

    var canAutoPinToBottom: Bool {
        isPinnedToBottom && !isUserTouchScrolling && !hasActiveTextSelection
    }

    // MARK: - Tier 1: User Touch / Scroll / Selection

    /// Immediately aborts any frozen pinned/lift/reveal/settle transaction.
    mutating func beginUserTouchScroll(interactiveKeyboardDismiss: Bool = false) {
        isUserTouchScrolling = true
        isInteractiveKeyboardDismissing = interactiveKeyboardDismiss
        interactionEpoch &+= 1
        mildLift = nil
        explicitJumpEpoch = nil
    }

    mutating func updateInteractiveKeyboardDismissing(_ active: Bool) {
        isInteractiveKeyboardDismissing = active
    }

    mutating func endUserTouchScroll(shouldPinToBottom: Bool) {
        isUserTouchScrolling = false
        isInteractiveKeyboardDismissing = false
        if hasActiveTextSelection {
            isPinnedToBottom = false
        } else {
            isPinnedToBottom = shouldPinToBottom
        }
        mildLift = nil
    }

    /// Long-press / text selection immediately freezes reading anchor and cancels pending lift/pinned follow.
    mutating func setTextSelectionActive(_ active: Bool) {
        guard hasActiveTextSelection != active else { return }
        hasActiveTextSelection = active
        if active {
            interactionEpoch &+= 1
            mildLift = nil
            explicitJumpEpoch = nil
        }
    }

    /// Cancels `isPinnedToBottom` when user scrolls upward away from the foot.
    mutating func userScrolledAwayFromBottom() {
        interactionEpoch &+= 1
        isPinnedToBottom = false
        mildLift = nil
    }

    // MARK: - Tier 2: Explicit Jump & History Pagination

    mutating func beginExplicitJump() -> UInt64 {
        interactionEpoch &+= 1
        isPinnedToBottom = false
        mildLift = nil
        explicitJumpEpoch = interactionEpoch
        return interactionEpoch
    }

    mutating func beginHistoryPagination() -> UInt64 {
        interactionEpoch &+= 1
        isPinnedToBottom = false
        mildLift = nil
        explicitJumpEpoch = interactionEpoch
        return interactionEpoch
    }

    mutating func setPinnedFromHost(_ pinned: Bool) {
        isPinnedToBottom = pinned
        if pinned {
            mildLift = nil
            explicitJumpEpoch = nil
        }
    }

    // MARK: - Keyboard Transition Mild Off-Bottom Lift Transaction

    /// Freezes a one-shot lift transaction when the keyboard opens while the reader sits mildly off-bottom (`<= 120pt`).
    /// Strictly NEVER mutates `isPinnedToBottom`.
    mutating func beginKeyboardTransition(
        metrics: FrameMetrics,
        targetBottomInset: CGFloat
    ) {
        guard !isUserTouchScrolling, !hasActiveTextSelection else {
            mildLift = nil
            return
        }
        // Only start a mild lift when NOT pinned and keyboard is expanding bottom occlusion.
        guard !isPinnedToBottom else {
            mildLift = nil
            return
        }
        let insetDelta = targetBottomInset - metrics.bottomInset
        guard insetDelta > 1.0 else {
            // Closing keyboard clears any completed lift without altering `isPinnedToBottom`.
            if targetBottomInset < metrics.bottomInset - 1.0 {
                mildLift = nil
            }
            return
        }
        let distanceFromBottom = max(0, metrics.maxBottomOffsetY - metrics.currentOffsetY)
        if distanceFromBottom <= Self.mildOffBottomMaxDistance {
            mildLift = MildOffBottomLift(
                preFocusDistanceFromBottom: distanceFromBottom,
                preFocusOffsetY: metrics.currentOffsetY,
                startBottomInset: metrics.bottomInset,
                targetBottomInset: targetBottomInset,
                wasUnscrollable: !metrics.isScrollable,
                epoch: interactionEpoch
            )
        } else {
            mildLift = nil
        }
    }

    mutating func finishKeyboardTransition() {
        mildLift = nil
        isInteractiveKeyboardDismissing = false
    }

    // MARK: - Tier 3: Single Per-Frame Unified Offset Synthesis

    /// Evaluates a candidate `contentOffset.y` write through the strict 3-tier priority rules.
    /// Returns `nil` (`wroteOffset == false`) whenever a higher-priority owner or stale epoch vetoes the write.
    mutating func resolveWrite(
        source: WriteSource,
        metrics: FrameMetrics,
        explicitTargetY: CGFloat? = nil
    ) -> SynthesisDecision {
        let minY = metrics.minOffsetY
        let maxY = metrics.maxBottomOffsetY

        // Tier 2 explicit jump / history pagination directly owns anchor when no active user finger drag is running.
        switch source {
        case .explicitJump, .historyPagination:
            guard !isUserTouchScrolling else {
                return SynthesisDecision(targetOffsetY: nil, wroteOffset: false, reason: "tier1-user-drag-veto")
            }
            if let explicitTargetY {
                let clamped = min(maxY, max(minY, explicitTargetY))
                return SynthesisDecision(targetOffsetY: clamped, wroteOffset: true, reason: "tier2-explicit-target")
            }
            if let anchorY = metrics.anchorTargetOffsetY {
                let clamped = min(maxY, max(minY, anchorY))
                return SynthesisDecision(targetOffsetY: clamped, wroteOffset: true, reason: "tier2-pagination-anchor")
            }
            return SynthesisDecision(targetOffsetY: nil, wroteOffset: false, reason: "tier2-no-target")

        case .userAnchorPreserve:
            guard !isUserTouchScrolling else {
                return SynthesisDecision(targetOffsetY: nil, wroteOffset: false, reason: "tier1-user-drag-veto")
            }
            if let anchorY = metrics.anchorTargetOffsetY {
                let clamped = min(maxY, max(minY, anchorY))
                return SynthesisDecision(targetOffsetY: clamped, wroteOffset: true, reason: "anchor-preserve")
            }
            return SynthesisDecision(targetOffsetY: nil, wroteOffset: false, reason: "anchor-missing")

        case .revealTick(let epoch),
             .finalizedSettle(let epoch),
             .approvalCardSettle(let epoch),
             .insetOrKeyboardSynthesis(let epoch),
             .streamingResize(let epoch):
            // Tier 1 veto: active user touch/scroll, interactive drag-dismiss, or text selection blocks all Tier 3 writes.
            if isUserTouchScrolling || isInteractiveKeyboardDismissing {
                return SynthesisDecision(targetOffsetY: nil, wroteOffset: false, reason: "tier1-touch-veto")
            }
            if hasActiveTextSelection {
                // Preserve selected text anchor on layout changes, never pull to bottom or lift.
                if case .insetOrKeyboardSynthesis = source, let anchorY = metrics.anchorTargetOffsetY {
                    let clamped = min(maxY, max(minY, anchorY))
                    return SynthesisDecision(targetOffsetY: clamped, wroteOffset: true, reason: "tier1-selection-anchor")
                }
                return SynthesisDecision(targetOffsetY: nil, wroteOffset: false, reason: "tier1-selection-veto")
            }

            // Stale-epoch veto: any reveal tick, finalized commit settle, or old approval card settle
            // captured before user scrolled/jumped MUST perform zero offset writes.
            if epoch != interactionEpoch {
                return SynthesisDecision(targetOffsetY: nil, wroteOffset: false, reason: "stale-epoch-veto")
            }

            // Base synthesis: pinned to bottom.
            if isPinnedToBottom {
                let target = metrics.effectiveBottomOffsetY
                if case .revealTick = source {
                    let distance = target - metrics.currentOffsetY
                    guard distance > 0.5 else {
                        return SynthesisDecision(targetOffsetY: nil, wroteOffset: false, reason: "reveal-already-aligned")
                    }
                    let smoothed = metrics.currentOffsetY + min(distance, max(0.5, distance * 0.24))
                    return SynthesisDecision(targetOffsetY: min(maxY, max(minY, smoothed)), wroteOffset: true, reason: "tier3-pinned-reveal")
                }
                return SynthesisDecision(targetOffsetY: target, wroteOffset: true, reason: "tier3-pinned-bottom")
            }

            // Base synthesis: one-shot mild off-bottom lift (`<= 120pt`) during keyboard/inset transition.
            if case .insetOrKeyboardSynthesis = source,
               let lift = mildLift,
               lift.epoch == interactionEpoch {
                let insetSpan = max(1, lift.targetBottomInset - lift.startBottomInset)
                let progress = min(1, max(0, (metrics.bottomInset - lift.startBottomInset) / insetSpan))
                let targetForCurrentInset = max(minY, min(maxY, maxY - lift.preFocusDistanceFromBottom))
                let synthesized: CGFloat
                if lift.wasUnscrollable {
                    // Short list crossing unscrollable -> scrollable transitions smoothly from frozen baseline,
                    // strictly clamped >= minY so content never shoots behind the top bar.
                    synthesized = max(minY, min(maxY, lift.preFocusOffsetY + (targetForCurrentInset - lift.preFocusOffsetY) * progress))
                } else {
                    synthesized = targetForCurrentInset
                }
                if progress >= 0.999 {
                    mildLift = nil
                }
                return SynthesisDecision(targetOffsetY: synthesized, wroteOffset: true, reason: "tier3-mild-lift")
            }

            // Base synthesis: deep history (> 120pt) or unpinned streaming/approval settle -> preserve anchor only.
            switch source {
            case .revealTick, .finalizedSettle, .approvalCardSettle:
                return SynthesisDecision(targetOffsetY: nil, wroteOffset: false, reason: "unpinned-no-follow")
            case .insetOrKeyboardSynthesis, .streamingResize:
                if let anchorY = metrics.anchorTargetOffsetY {
                    let clamped = min(maxY, max(minY, anchorY))
                    return SynthesisDecision(targetOffsetY: clamped, wroteOffset: true, reason: "tier3-history-anchor")
                }
                let clamped = min(maxY, max(minY, metrics.currentOffsetY))
                if abs(clamped - metrics.currentOffsetY) > 0.25 {
                    return SynthesisDecision(targetOffsetY: clamped, wroteOffset: true, reason: "tier3-bounds-clamp")
                }
                return SynthesisDecision(targetOffsetY: nil, wroteOffset: false, reason: "tier3-steady")
            default:
                return SynthesisDecision(targetOffsetY: nil, wroteOffset: false, reason: "noop")
            }
        }
    }
}
