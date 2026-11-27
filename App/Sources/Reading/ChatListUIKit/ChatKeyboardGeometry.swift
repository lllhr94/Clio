import CoreGraphics
import Foundation
import UIKit

/// Classified keyboard presentation posture relative to the chat host window.
enum ChatKeyboardMode: Equatable, Sendable {
    case docked
    case floatingOrSplit
    case hardwareOrNone
}

/// Pure geometric inputs for computing unified composer avoidance and bottom occlusion
/// across docked, floating/split/partially-overlapping, and external hardware keyboards.
struct ChatKeyboardGeometryInput: Equatable, Sendable {
    let hostBounds: CGRect
    let safeAreaBottom: CGFloat
    let restingComposerHeight: CGFloat
    let keyboardFrameInHost: CGRect?
    let keyboardBelongsToHostScreen: Bool
    let interactivePresentationTopY: CGFloat?
    let extraBottomPadding: CGFloat

    init(
        hostBounds: CGRect,
        safeAreaBottom: CGFloat,
        restingComposerHeight: CGFloat,
        keyboardFrameInHost: CGRect?,
        keyboardBelongsToHostScreen: Bool = true,
        interactivePresentationTopY: CGFloat? = nil,
        extraBottomPadding: CGFloat = 12
    ) {
        self.hostBounds = hostBounds
        self.safeAreaBottom = max(0, safeAreaBottom)
        self.restingComposerHeight = max(0, restingComposerHeight)
        self.keyboardFrameInHost = keyboardFrameInHost
        self.keyboardBelongsToHostScreen = keyboardBelongsToHostScreen
        self.interactivePresentationTopY = interactivePresentationTopY
        self.extraBottomPadding = max(0, extraBottomPadding)
    }
}

/// Single source of truth consumed identically by the hosted composer, `UICollectionView.contentInset.bottom`,
/// `verticalScrollIndicatorInsets.bottom`, `minimap`, `FloatingToastOverlay`, and the scroll arbiter's reading anchor.
struct ChatEffectiveOcclusionResult: Equatable, Sendable {
    let mode: ChatKeyboardMode
    let restingComposerBottomY: CGFloat
    let resolvedAvoidedComposerBottomY: CGFloat
    /// Unified occlusion: `max(0, restingComposerBottomY - resolvedAvoidedComposerBottomY)`.
    let effectiveBottomOcclusion: CGFloat
    /// Resolved composer frame in host coordinates after applying `effectiveBottomOcclusion`.
    let composerFrameInHost: CGRect
    /// Unified bottom inset for `collectionView.contentInset.bottom` and `verticalScrollIndicatorInsets.bottom`.
    let collectionBottomInset: CGFloat
    let scrollIndicatorBottomInset: CGFloat
    /// Bottom clearance for `minimap` controls & hit targets (above safe area).
    let minimapBottomClearance: CGFloat
    /// Separately derived additional safe area for native soft edge (never double-counted into `collectionBottomInset`).
    let additionalSafeAreaBottom: CGFloat
    let isKeyboardVisiblyOccluding: Bool
}

/// Deterministic same-host keyboard occlusion solver.
///
/// Key invariant:
/// - Full-screen `collectionView` bounds NEVER shrink with the keyboard.
/// - `followsUndockedKeyboard = false` on `UIKeyboardLayoutGuide` for docked iPhone keyboards.
/// - Floating / split keyboards are screen-filtered and intersected with the resting composer rectangle:
///   - Upper/mid hovering keyboard with zero composer overlap -> `effectiveBottomOcclusion = 0`.
///   - Any partial or bottom overlap against composer / send button -> lift entire composer above
///     `overlapRect.minY`, setting `resolvedAvoidedComposerBottomY = min(restingComposerBottomY, overlapRect.minY)`
///     and `effectiveBottomOcclusion = max(0, restingComposerBottomY - resolvedAvoidedComposerBottomY)` so
///     composer, `contentInset.bottom`, `verticalScrollIndicatorInsets.bottom`, `minimap`, and reading anchor
///     100% agree on one single number.
enum ChatKeyboardGeometrySolver {
    nonisolated static func resolve(_ input: ChatKeyboardGeometryInput) -> ChatEffectiveOcclusionResult {
        let host = input.hostBounds
        let restingBottomY = max(host.minY, host.maxY - input.safeAreaBottom)
        let composerH = input.restingComposerHeight

        func makeResult(mode: ChatKeyboardMode, avoidedBottomY: CGFloat) -> ChatEffectiveOcclusionResult {
            let clampedAvoided = max(host.minY + min(composerH, host.height), min(restingBottomY, avoidedBottomY))
            let occlusion = max(0, restingBottomY - clampedAvoided)
            let composerFrame = CGRect(
                x: host.minX,
                y: clampedAvoided - composerH,
                width: host.width,
                height: composerH
            )
            let totalBottomInset = input.safeAreaBottom + composerH + occlusion + input.extraBottomPadding
            let minimapClearance = composerH + occlusion
            // Additional safe area is derived exclusively for native soft edge, never added into `collectionBottomInset`.
            let additionalSafe = occlusion > 1 ? 0 : input.safeAreaBottom
            return ChatEffectiveOcclusionResult(
                mode: mode,
                restingComposerBottomY: restingBottomY,
                resolvedAvoidedComposerBottomY: clampedAvoided,
                effectiveBottomOcclusion: occlusion,
                composerFrameInHost: composerFrame,
                collectionBottomInset: totalBottomInset,
                scrollIndicatorBottomInset: totalBottomInset,
                minimapBottomClearance: minimapClearance,
                additionalSafeAreaBottom: additionalSafe,
                isKeyboardVisiblyOccluding: occlusion > 1
            )
        }

        // Interactive drag-dismiss presentation geometry probe takes direct precedence while active.
        if let probeTopY = input.interactivePresentationTopY, probeTopY.isFinite {
            let avoided = min(restingBottomY, probeTopY)
            return makeResult(mode: .docked, avoidedBottomY: avoided)
        }

        guard input.keyboardBelongsToHostScreen,
              let rawKeyboard = input.keyboardFrameInHost,
              !rawKeyboard.isNull,
              !rawKeyboard.isEmpty,
              rawKeyboard.minY.isFinite,
              rawKeyboard.maxY.isFinite else {
            return makeResult(mode: .hardwareOrNone, avoidedBottomY: restingBottomY)
        }

        let hostOverlap = rawKeyboard.intersection(host)
        guard !hostOverlap.isNull, hostOverlap.height >= 4, hostOverlap.width >= 4 else {
            return makeResult(mode: .hardwareOrNone, avoidedBottomY: restingBottomY)
        }

        // Docked soft keyboard touches host bottom and spans near-full host width.
        let touchesBottom = hostOverlap.maxY >= host.maxY - 2.0
        let spansHostWidth = hostOverlap.width >= host.width - 24.0
        if touchesBottom && spansHostWidth {
            let avoided = min(restingBottomY, hostOverlap.minY)
            return makeResult(mode: .docked, avoidedBottomY: avoided)
        }

        // Floating / split / narrow-window / partially overlapping keyboard:
        // only lift when the keyboard intersects the resting composer band (input field or send button).
        let restingComposerRect = CGRect(
            x: host.minX,
            y: restingBottomY - composerH,
            width: host.width,
            height: composerH
        )
        let composerOverlap = hostOverlap.intersection(restingComposerRect)
        guard !composerOverlap.isNull, composerOverlap.width > 0.5, composerOverlap.height > 0.5 else {
            return makeResult(mode: .floatingOrSplit, avoidedBottomY: restingBottomY)
        }

        // Lift entire composer above the overlapping keyboard rect's upper edge.
        let avoided = min(restingBottomY, hostOverlap.minY)
        return makeResult(mode: .floatingOrSplit, avoidedBottomY: avoided)
    }

    /// Filters keyboard screen notification frames to the target host window's `UIScreen` and converts into host view coordinates.
    @MainActor
    static func convertKeyboardScreenRect(
        _ screenRect: CGRect?,
        in hostView: UIView
    ) -> (frameInHost: CGRect?, belongsToScreen: Bool) {
        guard let screenRect,
              !screenRect.isNull,
              !screenRect.isEmpty,
              let window = hostView.window,
              let screen = window.windowScene?.screen else {
            return (nil, false)
        }
        // Reject frames originating outside this window's screen bounds (e.g. external display).
        let expandedScreenBounds = screen.bounds.insetBy(dx: -screen.bounds.width, dy: -screen.bounds.height)
        guard expandedScreenBounds.intersects(screenRect) else {
            return (nil, false)
        }
        let local = hostView.convert(screenRect, from: screen.coordinateSpace)
        return (local, true)
    }
}

/// Shared 3-card vertical height budget above the composer with strict priority ordering:
/// 1. Forced / pending Approval (`InlineApproval`) — highest priority; insufficient room falls back strictly to full sheet (never downgrades approval or unlocks Plan).
/// 2. Active `InlineAsk` form — second priority; preserves `form.id` & draft, collapses to compact summary bar with single 「展开详情」 sheet fallback.
/// 3. `PlanCard` — third priority; collapses to single-line summary capsule when squeezed.
enum ChatDockCardBudget {
    enum ApprovalLayout: Equatable, Sendable {
        case none
        case inline(maxHeight: CGFloat)
        case sheetFallbackOnly
    }

    enum InlineAskLayout: Equatable, Sendable {
        case none
        case inline(maxHeight: CGFloat)
        case compactSummaryWithSheetFallback
    }

    enum PlanCardLayout: Equatable, Sendable {
        case none
        case expandable(maxHeight: CGFloat)
        case forcedCollapsedCapsule
    }

    struct Input: Equatable, Sendable {
        let viewportHeight: CGFloat
        let effectiveBottomOcclusion: CGFloat
        let topBarHeight: CGFloat
        let composerHeight: CGFloat
        let minProseReadableHeight: CGFloat
        let hasPendingApproval: Bool
        let canInlineApproval: Bool
        let hasInlineAsk: Bool
        let hasPlanCard: Bool

        init(
            viewportHeight: CGFloat,
            effectiveBottomOcclusion: CGFloat,
            topBarHeight: CGFloat,
            composerHeight: CGFloat,
            minProseReadableHeight: CGFloat = 120,
            hasPendingApproval: Bool,
            canInlineApproval: Bool,
            hasInlineAsk: Bool,
            hasPlanCard: Bool
        ) {
            self.viewportHeight = max(0, viewportHeight)
            self.effectiveBottomOcclusion = max(0, effectiveBottomOcclusion)
            self.topBarHeight = max(0, topBarHeight)
            self.composerHeight = max(0, composerHeight)
            self.minProseReadableHeight = max(0, minProseReadableHeight)
            self.hasPendingApproval = hasPendingApproval
            self.canInlineApproval = canInlineApproval
            self.hasInlineAsk = hasInlineAsk
            self.hasPlanCard = hasPlanCard
        }
    }

    struct Allocation: Equatable, Sendable {
        let availableAboveKeyboard: CGFloat
        let totalCardBudget: CGFloat
        let approval: ApprovalLayout
        let inlineAsk: InlineAskLayout
        let planCard: PlanCardLayout
    }

    static let minInlineApprovalHeight: CGFloat = 140
    static let maxInlineApprovalHeight: CGFloat = 240
    static let compactApprovalBannerHeight: CGFloat = 56
    static let minInlineAskHeight: CGFloat = 120
    static let compactAskSummaryHeight: CGFloat = 48
    static let minExpandedPlanHeight: CGFloat = 120

    nonisolated static func allocate(_ input: Input) -> Allocation {
        let aboveKeyboard = max(0, input.viewportHeight - input.effectiveBottomOcclusion)
        let totalBudget = max(
            0,
            aboveKeyboard - input.topBarHeight - input.composerHeight - input.minProseReadableHeight
        )
        var remaining = totalBudget

        // Priority 1: Forced / pending approval card (NEVER downgraded; falls back only to full approval sheet).
        let approvalLayout: ApprovalLayout
        if input.hasPendingApproval {
            if input.canInlineApproval && remaining >= minInlineApprovalHeight {
                let cap = min(remaining, maxInlineApprovalHeight)
                approvalLayout = .inline(maxHeight: cap)
                remaining = max(0, remaining - cap - 8)
            } else {
                approvalLayout = .sheetFallbackOnly
                remaining = max(0, remaining - compactApprovalBannerHeight - 8)
            }
        } else {
            approvalLayout = .none
        }

        // Priority 2: Active InlineAsk form (preserves form.id & draft; falls back to compact summary + detail sheet).
        let askLayout: InlineAskLayout
        if input.hasInlineAsk {
            if remaining >= minInlineAskHeight {
                let shareCap = max(minInlineAskHeight, aboveKeyboard * 0.34)
                let cap = min(remaining, shareCap)
                askLayout = .inline(maxHeight: cap)
                remaining = max(0, remaining - cap - 8)
            } else {
                askLayout = .compactSummaryWithSheetFallback
                remaining = max(0, remaining - compactAskSummaryHeight - 8)
            }
        } else {
            askLayout = .none
        }

        // Priority 3: PlanCard (squeezes down to single-line collapsed summary capsule first).
        let planLayout: PlanCardLayout
        if input.hasPlanCard {
            if remaining >= minExpandedPlanHeight {
                let shareCap = max(140, aboveKeyboard * 0.38)
                let cap = min(remaining, shareCap)
                planLayout = .expandable(maxHeight: cap)
            } else {
                planLayout = .forcedCollapsedCapsule
            }
        } else {
            planLayout = .none
        }

        return Allocation(
            availableAboveKeyboard: aboveKeyboard,
            totalCardBudget: totalBudget,
            approval: approvalLayout,
            inlineAsk: askLayout,
            planCard: planLayout
        )
    }
}
