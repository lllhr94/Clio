// ChatScrollCoordinator.swift
// Clio Smart Scroll State Machine (`keepingEdge` Over-One-Screen Top-Edge Lock & Drag Quiet Lock)
// License: GPL-3.0-or-later

import Foundation

public struct ViewportMetrics: Equatable, Sendable {
    public let visibleHeight: Double
    public let contentHeight: Double
    public let contentOffsetY: Double
    public let topSafeInset: Double
    public let bottomSafeInset: Double

    public init(
        visibleHeight: Double,
        contentHeight: Double,
        contentOffsetY: Double,
        topSafeInset: Double,
        bottomSafeInset: Double
    ) {
        self.visibleHeight = visibleHeight
        self.contentHeight = contentHeight
        self.contentOffsetY = contentOffsetY
        self.topSafeInset = topSafeInset
        self.bottomSafeInset = bottomSafeInset
    }
}

public struct VisibleItemMetric<ItemID: Hashable & Sendable>: Equatable, Sendable {
    public let id: ItemID
    public let minY: Double
    public let maxY: Double

    public init(id: ItemID, minY: Double, maxY: Double) {
        self.id = id
        self.minY = minY
        self.maxY = maxY
    }
}

public struct SettleAnchor<ItemID: Hashable & Sendable>: Equatable, Sendable {
    public let id: ItemID
    public let screenOffsetY: Double

    public init(id: ItemID, screenOffsetY: Double) {
        self.id = id
        self.screenOffsetY = screenOffsetY
    }
}

public enum ChatFollowMode<ItemID: Hashable & Sendable>: Equatable, Sendable {
    case followingBottom
    case pinningReplyTop(ItemID)
    case detachedBrowsing
}

public struct ScrollDecision<ItemID: Hashable & Sendable>: Equatable, Sendable {
    public let mode: ChatFollowMode<ItemID>
    public let targetContentOffsetY: Double?
    public let deferStreamingRelayout: Bool
    public let showJumpToBottomControl: Bool

    public init(
        mode: ChatFollowMode<ItemID>,
        targetContentOffsetY: Double?,
        deferStreamingRelayout: Bool,
        showJumpToBottomControl: Bool
    ) {
        self.mode = mode
        self.targetContentOffsetY = targetContentOffsetY
        self.deferStreamingRelayout = deferStreamingRelayout
        self.showJumpToBottomControl = showJumpToBottomControl
    }
}

/// Pure Foundation scroll state machine coordinating:
/// 1. Over-one-screen streaming top-edge lock (`pinningReplyTop`, guarded by `overflows` so short replies stay bottom-pinned).
/// 2. User drag/deceleration quiet lock capturing the live top visible item right before deferred layout flush.
/// 3. Synchronous collapsible-block offset compensation (resetting cleanly to `.followingBottom` if content no longer overflows).
public struct ChatScrollStateMachine<ItemID: Hashable & Sendable>: Sendable {
    public private(set) var mode: ChatFollowMode<ItemID> = .followingBottom
    public private(set) var isUserInteracting: Bool = false
    public private(set) var settleAnchor: SettleAnchor<ItemID>?

    public let pinnedTolerance: Double
    public let safeReadingMargin: Double

    public init(pinnedTolerance: Double = 24.0, safeReadingMargin: Double = 16.0) {
        self.pinnedTolerance = pinnedTolerance
        self.safeReadingMargin = safeReadingMargin
    }

    public static func scrollBounds(for vp: ViewportMetrics) -> (minY: Double, maxY: Double, overflows: Bool) {
        let minY = -vp.topSafeInset
        let maxY = max(minY, vp.contentHeight + vp.bottomSafeInset - vp.visibleHeight)
        return (minY, maxY, maxY > minY + 1.0)
    }

    public mutating func onStreamingGeometryUpdate(
        viewport vp: ViewportMetrics,
        activeReplyID: ItemID?,
        activeReplyMinY: Double
    ) -> ScrollDecision<ItemID> {
        let (minY, maxY, overflows) = Self.scrollBounds(for: vp)
        let safeTopLine = vp.topSafeInset + safeReadingMargin

        if isUserInteracting {
            return ScrollDecision(
                mode: mode,
                targetContentOffsetY: nil,
                deferStreamingRelayout: true,
                showJumpToBottomControl: overflows && ((maxY - vp.contentOffsetY) > pinnedTolerance)
            )
        }

        switch mode {
        case .followingBottom:
            let replyScreenTopIfPinnedBottom = activeReplyMinY - maxY
            if overflows, let replyID = activeReplyID, replyScreenTopIfPinnedBottom <= safeTopLine {
                mode = .pinningReplyTop(replyID)
                let targetY = min(maxY, max(minY, activeReplyMinY - safeTopLine))
                return ScrollDecision(
                    mode: mode,
                    targetContentOffsetY: targetY,
                    deferStreamingRelayout: false,
                    showJumpToBottomControl: (maxY - targetY) > pinnedTolerance
                )
            }
            return ScrollDecision(
                mode: .followingBottom,
                targetContentOffsetY: maxY,
                deferStreamingRelayout: false,
                showJumpToBottomControl: false
            )

        case .pinningReplyTop(let pinnedID) where pinnedID == activeReplyID && overflows:
            let targetY = min(maxY, max(minY, activeReplyMinY - safeTopLine))
            return ScrollDecision(
                mode: mode,
                targetContentOffsetY: targetY,
                deferStreamingRelayout: false,
                showJumpToBottomControl: (maxY - targetY) > pinnedTolerance
            )

        default:
            return ScrollDecision(
                mode: mode,
                targetContentOffsetY: nil,
                deferStreamingRelayout: false,
                showJumpToBottomControl: overflows && ((maxY - vp.contentOffsetY) > pinnedTolerance)
            )
        }
    }

    public mutating func onUserDragBegan() {
        isUserInteracting = true
        settleAnchor = nil
    }

    @discardableResult
    public mutating func prepareSettleFlush(
        viewport vp: ViewportMetrics,
        visibleItems: [VisibleItemMetric<ItemID>]
    ) -> SettleAnchor<ItemID>? {
        isUserInteracting = false
        let (_, maxY, overflows) = Self.scrollBounds(for: vp)
        if !overflows || (maxY - vp.contentOffsetY) <= pinnedTolerance {
            mode = .followingBottom
            settleAnchor = nil
            return nil
        }

        mode = .detachedBrowsing
        let readingTopY = vp.contentOffsetY + vp.topSafeInset
        let sorted = visibleItems.sorted { $0.minY < $1.minY }
        if let chosen = sorted.first(where: { $0.maxY > readingTopY }) ?? sorted.first {
            let anchor = SettleAnchor(id: chosen.id, screenOffsetY: chosen.minY - vp.contentOffsetY)
            settleAnchor = anchor
            return anchor
        }
        return nil
    }

    public mutating func didFlushDeferredLayout(
        viewportAfter vpAfter: ViewportMetrics,
        updatedAnchorMinY: Double?
    ) -> Double? {
        let (minY, maxY, overflows) = Self.scrollBounds(for: vpAfter)
        if !overflows {
            mode = .followingBottom
            settleAnchor = nil
            return maxY
        }
        if case .followingBottom = mode { return maxY }
        if let anchor = settleAnchor, let newMinY = updatedAnchorMinY {
            settleAnchor = nil
            return min(maxY, max(minY, newMinY - anchor.screenOffsetY))
        }
        return nil
    }

    public mutating func compensateCollapse(
        viewportAfter vpAfter: ViewportMetrics,
        collapsedItemMinY: Double,
        oldHeight: Double,
        newHeight: Double
    ) -> Double? {
        let (minY, maxY, overflows) = Self.scrollBounds(for: vpAfter)
        if !overflows {
            mode = .followingBottom
            settleAnchor = nil
            return maxY
        }
        if case .followingBottom = mode { return maxY }
        let delta = newHeight - oldHeight
        let readingLineContentY = vpAfter.contentOffsetY + vpAfter.topSafeInset + safeReadingMargin
        if delta < 0 && collapsedItemMinY < readingLineContentY {
            return min(maxY, max(minY, vpAfter.contentOffsetY + delta))
        }
        return nil
    }

    public mutating func resetToFollowingBottom(viewport vp: ViewportMetrics) -> Double {
        mode = .followingBottom
        isUserInteracting = false
        settleAnchor = nil
        return Self.scrollBounds(for: vp).maxY
    }

    /// Transitions to `.detachedBrowsing` when host jumps to an older row, starts pagination,
    /// activates text selection, or explicitly turns off bottom following.
    public mutating func detachForUserNavigation() {
        mode = .detachedBrowsing
        isUserInteracting = false
        settleAnchor = nil
    }

    public mutating func resetForChatSwitch() {
        mode = .followingBottom
        isUserInteracting = false
        settleAnchor = nil
    }
}
