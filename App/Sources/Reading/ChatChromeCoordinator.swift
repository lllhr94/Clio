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
    var isImmersive: Bool { mode == .immersive }

    @ObservationIgnored var isKeyboardOpen = false
    @ObservationIgnored var isComposerFocused = false
    @ObservationIgnored var hasActiveSelection = false
    @ObservationIgnored var isDictating = false
    @ObservationIgnored var hasQuoteOrEdit = false
    @ObservationIgnored var hasPendingApproval = false
    @ObservationIgnored var hasInlineAsk = false
    @ObservationIgnored var hasBrowserTakeover = false
    @ObservationIgnored var isFinding = false

    @ObservationIgnored private var upwardAccumulated: CGFloat = 0
    @ObservationIgnored private var downwardAccumulated: CGFloat = 0
    @ObservationIgnored private var programmaticUntil: CFTimeInterval = 0

    let enterUpwardDistance: CGFloat = 44
    let exitDownwardDistance: CGFloat = 56
    let minDistanceFromBottomToEnter: CGFloat = 80
    let restoreBottomDistance: CGFloat = 48
    let programmaticImmunityWindow: CFTimeInterval = 0.14

    var isLockedToFull: Bool {
        isKeyboardOpen
            || isComposerFocused
            || hasActiveSelection
            || isDictating
            || UIAccessibility.isVoiceOverRunning
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
        downwardAccumulated = 0
    }

    func restore() {
        upwardAccumulated = 0
        downwardAccumulated = 0
        if mode != .full {
            mode = .full
        }
        markProgrammaticScroll(duration: 0.16)
    }

    func syncLocks(
        keyboardOpen: Bool? = nil,
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
        if let composerFocused { isComposerFocused = composerFocused }
        if let activeSelection { hasActiveSelection = activeSelection }
        if let dictating { isDictating = dictating }
        if let quoteOrEdit { hasQuoteOrEdit = quoteOrEdit }
        if let pendingApproval { hasPendingApproval = pendingApproval }
        if let inlineAsk { hasInlineAsk = inlineAsk }
        if let browserTakeover { hasBrowserTakeover = browserTakeover }
        if let finding { isFinding = finding }

        if isLockedToFull && mode == .immersive {
            restore()
        }
    }

    func handleUserScroll(deltaY: CGFloat, distanceFromBottom: CGFloat, isScrollable: Bool) {
        guard !isLockedToFull, isScrollable else {
            if mode == .immersive {
                restore()
            } else {
                upwardAccumulated = 0
                downwardAccumulated = 0
            }
            return
        }
        guard CACurrentMediaTime() >= programmaticUntil else { return }

        if distanceFromBottom <= restoreBottomDistance {
            if mode == .immersive {
                restore()
            } else {
                upwardAccumulated = 0
                downwardAccumulated = 0
            }
            return
        }

        if deltaY < -0.25 {
            upwardAccumulated += -deltaY
            downwardAccumulated = 0
            if mode == .full,
               distanceFromBottom > minDistanceFromBottomToEnter,
               upwardAccumulated >= enterUpwardDistance {
                mode = .immersive
                upwardAccumulated = 0
                markProgrammaticScroll(duration: 0.16)
            }
        } else if deltaY > 0.25 {
            downwardAccumulated += deltaY
            upwardAccumulated = 0
            if mode == .immersive,
               downwardAccumulated >= exitDownwardDistance {
                restore()
            }
        }
    }

    func resetForChatSwitch() {
        isKeyboardOpen = false
        isComposerFocused = false
        hasActiveSelection = false
        isDictating = false
        hasQuoteOrEdit = false
        hasPendingApproval = false
        hasInlineAsk = false
        hasBrowserTakeover = false
        isFinding = false
        upwardAccumulated = 0
        downwardAccumulated = 0
        programmaticUntil = 0
        if mode != .full {
            mode = .full
        }
    }

    static func jumpKeepOutWidth(jumpVisible: Bool, latestVisible: Bool) -> CGFloat {
        if jumpVisible && latestVisible {
            return 104 * UIScale.factor + Ink.Space.xs + Ink.Space.s
        }
        if jumpVisible {
            return 70 * UIScale.factor + Ink.Space.s
        }
        if latestVisible {
            return 32 * UIScale.factor + Ink.Space.s
        }
        return 0
    }
}
