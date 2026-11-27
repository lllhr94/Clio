import CoreText
import SwiftUI
import UIKit

/// High-performance rich-text view backed by off-main-thread CoreText tiled bitmaps by default,
/// lazily mounting a TextKit 2 `UITextView` only during active selection, live streaming, or
/// selection transfer — with CoreText link hit-testing and `CALayer` block decorations.
@MainActor
final class ChatRichTextView: UIView, UITextViewDelegate, UIGestureRecognizerDelegate, ChatRevealDisplayClient {
    let selectionOwnerID = UUID()

    var allowLongPressSelection = true {
        didSet {
            if oldValue != allowLongPressSelection {
                updateGestureStates()
            }
        }
    }

    var onQuoteSelection: ((String) -> Void)?
    var onSubConversationSelection: ((String, String) -> Void)?
    var onSaveNoteSelection: ((String) -> Void)?
    var onSpeakSelection: ((String) -> Void)?
    var onSelectionActiveChanged: ((UUID, Bool) -> Void)?
    var onLinkTapped: ((URL) -> Void)?
    var onRevealFrame: ((Bool) -> Void)?
    var onRequestRevealAll: (() -> Void)?

    var hasPaintedLiveTail: Bool { currentIsLiveTail && appliedRenderToken != 0 }

    var revealSnapshotTotalPoints: Int? {
        appliedRevealSnapshot?.totalPoints
    }

    var hasActiveFlyingSnippets: Bool {
        revealMaskCoordinator.snippetHost.activeCount > 0
    }

    /// Local bottom of the line currently being revealed, or the first line while tiles are being prepared.
    var revealedLineBottom: CGFloat? {
        guard let style = currentStyle, selectionTextView == nil,
              ChatRevealPolicy.isEligible(
                fade: style.fade, reduceMotion: style.reduceMotion, attributedLength: currentRendered.attributed.length
              ) else { return nil }

        let bottom: CGFloat
        if isExternallyRevealControlled {
            switch externalRevealState {
            case .hidden:
                bottom = appliedRevealSnapshot?.lines.first?.bandBottom ?? (currentRendered.topInset + style.fonts.reading.regular.lineHeight)
            case .revealing(let localPoints, let progress):
                if let snap = appliedRevealSnapshot {
                    switch snap.maskState(forPoints: localPoints) {
                    case .hidden:
                        bottom = snap.lines.first?.bandBottom ?? bounds.height
                    case .partial(_, let top, let height, _, _, _):
                        bottom = top + height
                    case .complete:
                        bottom = snap.layoutSize.height
                    }
                } else {
                    bottom = max(currentRendered.topInset + style.fonts.reading.regular.lineHeight, bounds.height * CGFloat(progress))
                }
            case .complete:
                bottom = appliedRevealSnapshot?.layoutSize.height ?? bounds.height
            }
        } else if let session = revealSession {
            switch session.currentMaskState() {
            case .hidden:
                bottom = session.snapshot.lines.first?.bandBottom ?? bounds.height
            case .partial(_, let top, let height, _, _, _):
                bottom = top + height
            case .complete:
                bottom = session.snapshot.layoutSize.height
            }
        } else if pendingRevealHandoff != nil || (currentIsLiveTail && !hasPaintedLiveTail) {
            bottom = currentRendered.topInset + style.fonts.reading.regular.lineHeight
        } else {
            return nil
        }
        return min(bounds.height, max(0, bottom))
    }

    var hasSelectableText: Bool {
        !currentRendered.isEmpty
            && !currentRendered.attributed.string
                .replacingOccurrences(of: "\u{200B}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
    }

    var selectedRange: NSRange {
        selectionTextView?.selectedRange ?? NSRange(location: 0, length: 0)
    }

    private let tileRoot = CALayer()
    private var tileLayers: [CALayer] = []

    private var selectionTextView: UITextView?
    private var isActivatingSelection = false
    private var keepsFallbackTextView = false
    private var isAwaitingFinalizedTiles = false
    private var drawGeneration: UInt64 = 0

    private struct DecorationCacheKey: Hashable, Sendable {
        let renderToken: UInt64
        let widthKey: Int
    }

    private struct DecorationGeometry: @unchecked Sendable {
        let codePath: CGPath?
        let rulePath: CGPath?
        let quoteSpans: [(minY: CGFloat, maxY: CGFloat)?]
    }

    private static let decorationGeometryCache: BoundedLRUCache<DecorationCacheKey, DecorationGeometry> = {
        let cache = BoundedLRUCache<DecorationCacheKey, DecorationGeometry>(countLimit: 256)
        _ = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { _ in
            cache.removeAll()
        }
        return cache
    }()

    private var decorationRoot: CALayer?
    private var inlineCodeLayer: CAShapeLayer?
    private var ruleLayer: CAShapeLayer?
    private var quoteLayers: [QuoteCardLayer] = []

    private var linkTapGesture: UITapGestureRecognizer!
    private var doubleTapGesture: UITapGestureRecognizer!
    private var longPressGesture: UILongPressGestureRecognizer!

    private var currentOwnerID: String?
    private var currentRendered: ChatRenderedProse = .empty
    private var currentStyle: ChatListStyle?
    private var currentIsLive = false
    private var currentIsLiveTail = false

    private var lastRenderToken: UInt64 = 0
    private var lastStyleKey = ""
    private var lastIsLive = false
    private var lastIsLiveTail = false

    private var activeRenderKey = ""
    private var appliedRenderKey = ""
    private var inFlightRenderKey = ""
    private var activeTileCount = 0

    private var revealSession: ChatRevealSession?
    private let revealMaskCoordinator = ChatRevealMaskCoordinator()
    private var pendingRevealHandoff: ChatRevealHandoff?
    private var appliedRevealSnapshot: ChatRevealLayoutSnapshot?
    private var appliedRenderToken: UInt64 = 0
    private var isRevealVisible = true
    private var isExternallyRevealControlled = false
    private var externalRevealState: MessageRevealTimeline.SliceRevealState = .complete
    private var lastExternalLocalPoints: Double = 0
    private var hasAppliedExternalRevealBaseline = false
    private var lastAppliedBoundsWidth: CGFloat = 0

    private var paintedWidth: CGFloat = -1
    private var paintedToken: UInt64 = 0
    private var paintedTraitStyle: UIUserInterfaceStyle = .unspecified
    private var needsDecorationLayout = false
    private var wasSelecting = false

    private final class QuoteCardLayer: CALayer {
        let stripe = CALayer()

        override init() {
            super.init()
            cornerCurve = .continuous
            borderWidth = 0
            masksToBounds = true
            stripe.cornerRadius = 1.0
            addSublayer(stripe)
        }

        override init(layer: Any) {
            super.init(layer: layer)
        }

        required init?(coder: NSCoder) {
            nil
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    static func resolveDisplayScale(for traitCollection: UITraitCollection, window: UIWindow?) -> CGFloat {
        if traitCollection.displayScale > 0 { return traitCollection.displayScale }
        if let scale = window?.windowScene?.screen.scale, scale > 0 { return scale }
        for scene in UIApplication.shared.connectedScenes {
            if let windowScene = scene as? UIWindowScene, windowScene.activationState == .foregroundActive {
                return windowScene.screen.scale
            }
        }
        if let anyScene = UIApplication.shared.connectedScenes.first as? UIWindowScene {
            return anyScene.screen.scale
        }
        return 3
    }

    private func configure() {
        backgroundColor = .clear
        clipsToBounds = true
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        tileRoot.masksToBounds = false
        layer.addSublayer(tileRoot)

        linkTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleLinkTap(_:)))
        linkTapGesture.delegate = self
        linkTapGesture.cancelsTouchesInView = false
        addGestureRecognizer(linkTapGesture)

        doubleTapGesture = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTapGesture.numberOfTapsRequired = 2
        doubleTapGesture.delegate = self
        addGestureRecognizer(doubleTapGesture)

        longPressGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
        longPressGesture.minimumPressDuration = 0.32
        longPressGesture.delegate = self
        addGestureRecognizer(longPressGesture)

        updateGestureStates()
        updateAccessibility()

        registerForTraitChanges([
            UITraitUserInterfaceStyle.self,
            UITraitPreferredContentSizeCategory.self,
            UITraitDisplayScale.self,
        ]) { (view: ChatRichTextView, _) in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            view.revealMaskCoordinator.clearFlyingSnippets()
            CATransaction.commit()
            view.drawGeneration &+= 1
            view.activeRenderKey = ""
            view.appliedRenderKey = ""
            view.inFlightRenderKey = ""
            view.appliedRevealSnapshot = nil
            view.appliedRenderToken = 0
            view.paintedTraitStyle = .unspecified
            view.needsDecorationLayout = true
            view.clearTileLayers()
            view.setNeedsLayout()
        }
    }

    func currentSelectionSnapshot() -> (range: NSRange, substring: String)? {
        guard let tv = selectionTextView else { return nil }
        let range = tv.selectedRange
        guard range.length > 0, let text = tv.attributedText?.string as NSString?,
              range.location >= 0, range.location + range.length <= text.length else {
            return nil
        }
        return (range, text.substring(with: range))
    }

    func apply(
        ownerID: String,
        rendered: ChatRenderedProse,
        style: ChatListStyle,
        isLive: Bool = false,
        isLiveTail: Bool = false,
        externalRevealControlled: Bool = false,
        transferredSelection: (range: NSRange, substring: String)? = nil,
        transferredReveal: ChatRevealHandoff? = nil
    ) {
        let sameOwner = currentOwnerID == ownerID
        let sameToken = sameOwner
            && rendered.renderToken == lastRenderToken
            && style.styleKey == lastStyleKey
            && style.revealPace == currentStyle?.revealPace
            && isLive == lastIsLive
            && isLiveTail == lastIsLiveTail
            && externalRevealControlled == isExternallyRevealControlled
        if sameToken && transferredSelection == nil && transferredReveal == nil { return }

        let wasLive = lastIsLive
        let wasAwaitingTiles = isAwaitingFinalizedTiles

        let oldRange = selectedRange
        let oldNS = (selectionTextView?.attributedText?.string ?? currentRendered.attributed.string) as NSString
        let newNS = rendered.attributed.string as NSString
        var restoredRange: NSRange?

        if let transferredSelection,
           transferredSelection.range.length > 0 {
            let exact = transferredSelection.range
            if exact.location >= 0,
               exact.location + exact.length <= newNS.length,
               newNS.substring(with: exact) == transferredSelection.substring {
                restoredRange = exact
            } else {
                let fallback = newNS.range(of: transferredSelection.substring, options: .backwards)
                if fallback.location != NSNotFound, fallback.length > 0 {
                    restoredRange = fallback
                }
            }
        } else if sameOwner,
                  oldRange.length > 0,
                  oldRange.location >= 0,
                  oldRange.location + oldRange.length <= oldNS.length,
                  oldRange.location + oldRange.length <= newNS.length {
            let oldSelected = oldNS.substring(with: oldRange)
            let newSelected = newNS.substring(with: oldRange)
            if oldSelected == newSelected {
                restoredRange = oldRange
            }
        }

        let eligibleReveal = ChatRevealPolicy.isEligible(
            fade: style.fade,
            reduceMotion: style.reduceMotion,
            attributedLength: rendered.attributed.length
        )

        let keepLiveTailGeneration = sameOwner
            && style.styleKey == lastStyleKey
            && (isLiveTail || externalRevealControlled)
            && (lastIsLiveTail || isExternallyRevealControlled)
            && eligibleReveal
            && restoredRange == nil
            && selectionTextView == nil
        if !keepLiveTailGeneration {
            drawGeneration &+= 1
        }
        if style.styleKey != lastStyleKey {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            revealMaskCoordinator.clearFlyingSnippets()
            CATransaction.commit()
        }

        currentOwnerID = ownerID
        currentRendered = rendered
        currentStyle = style
        currentIsLive = isLive
        currentIsLiveTail = isLiveTail
        isExternallyRevealControlled = externalRevealControlled && eligibleReveal && restoredRange == nil && !(selectionTextView != nil && oldRange.length > 0)
        if !sameOwner {
            lastExternalLocalPoints = 0
            hasAppliedExternalRevealBaseline = false
            externalRevealState = isExternallyRevealControlled ? .hidden : .complete
        }
        lastRenderToken = rendered.renderToken
        lastStyleKey = style.styleKey
        lastIsLive = isLive
        lastIsLiveTail = isLiveTail
        keepsFallbackTextView = false

        if !eligibleReveal || restoredRange != nil || (selectionTextView != nil && oldRange.length > 0) {
            teardownReveal()
            let transitionFromLiveToSettled = !isLive
                && restoredRange == nil
                && (wasLive || wasAwaitingTiles)
                && selectionTextView != nil
                && !rendered.isEmpty

            if isLive || restoredRange != nil {
                isAwaitingFinalizedTiles = false
                activeRenderKey = ""
                inFlightRenderKey = ""
                clearTileLayers()
                isActivatingSelection = true
                let tv = ensureSelectionTextView()
                applyToSelectionTextView(tv, rendered: rendered, restoredRange: restoredRange)
                isActivatingSelection = false
                if let restoredRange, restoredRange.length > 0 {
                    publishSelection(true)
                } else if oldRange.length > 0 {
                    publishSelection(false)
                }
            } else if transitionFromLiveToSettled, let tv = selectionTextView {
                isAwaitingFinalizedTiles = true
                activeRenderKey = ""
                appliedRenderKey = ""
                inFlightRenderKey = ""
                clearTileLayers()
                isActivatingSelection = true
                applyToSelectionTextView(tv, rendered: rendered, restoredRange: nil)
                isActivatingSelection = false
                if oldRange.length > 0 {
                    publishSelection(false)
                }
            } else {
                isAwaitingFinalizedTiles = false
                if selectionTextView != nil {
                    teardownSelectionTextView(notifyIfNeeded: oldRange.length > 0)
                }
                activeRenderKey = ""
                appliedRenderKey = ""
                inFlightRenderKey = ""
            }
        } else if isExternallyRevealControlled {
            // Driven by MessageRevealCoordinator across sealed paragraphs + live tail + blocks.
            isAwaitingFinalizedTiles = false
            pendingRevealHandoff = nil
            revealSession = nil
            ChatRevealDisplayDriver.shared.unregister(self)
            if selectionTextView != nil {
                teardownSelectionTextView(notifyIfNeeded: oldRange.length > 0, triggerLayout: false)
            }
        } else if isLiveTail {
            // CoreText tile reveal owns the active tail instead of mounting TextKit 2 selection text view.
            isAwaitingFinalizedTiles = false
            if selectionTextView != nil {
                teardownSelectionTextView(notifyIfNeeded: oldRange.length > 0, triggerLayout: false)
            }
            if !sameOwner {
                revealSession = nil
                if let transferredReveal,
                   ChatRevealSession.resolveInitialUTF16(handoff: transferredReveal, in: rendered.attributed.string) != nil {
                    pendingRevealHandoff = transferredReveal
                } else {
                    pendingRevealHandoff = nil
                }
            } else {
                pendingRevealHandoff = nil
            }
        } else if !isLive && sameOwner && revealSession != nil && !(revealSession?.isComplete ?? true) {
            isAwaitingFinalizedTiles = false
            pendingRevealHandoff = nil
            if selectionTextView != nil {
                teardownSelectionTextView(notifyIfNeeded: oldRange.length > 0, triggerLayout: false)
            }
            revealSession?.markFinalizing()
        } else if !isLive,
                  let handoff = transferredReveal,
                  ChatRevealSession.resolveInitialUTF16(handoff: handoff, in: rendered.attributed.string) != nil {
            isAwaitingFinalizedTiles = false
            if selectionTextView != nil {
                teardownSelectionTextView(notifyIfNeeded: oldRange.length > 0, triggerLayout: false)
            }
            revealSession = nil
            pendingRevealHandoff = handoff
            activeRenderKey = ""
            appliedRenderKey = ""
            inFlightRenderKey = ""
        } else if isLive {
            // Non-tail live view (e.g., live-pulse): retain TextKit 2 path without reveal mask.
            teardownReveal()
            isAwaitingFinalizedTiles = false
            activeRenderKey = ""
            inFlightRenderKey = ""
            clearTileLayers()
            isActivatingSelection = true
            let tv = ensureSelectionTextView()
            applyToSelectionTextView(tv, rendered: rendered, restoredRange: nil)
            isActivatingSelection = false
            if oldRange.length > 0 {
                publishSelection(false)
            }
        } else {
            teardownReveal()
            let transitionFromLiveToSettled = (wasLive || wasAwaitingTiles)
                && selectionTextView != nil
                && !rendered.isEmpty
            if transitionFromLiveToSettled, let tv = selectionTextView {
                isAwaitingFinalizedTiles = true
                activeRenderKey = ""
                appliedRenderKey = ""
                inFlightRenderKey = ""
                clearTileLayers()
                isActivatingSelection = true
                applyToSelectionTextView(tv, rendered: rendered, restoredRange: nil)
                isActivatingSelection = false
                if oldRange.length > 0 {
                    publishSelection(false)
                }
            } else {
                isAwaitingFinalizedTiles = false
                if selectionTextView != nil {
                    teardownSelectionTextView(notifyIfNeeded: oldRange.length > 0)
                }
                activeRenderKey = ""
                appliedRenderKey = ""
                inFlightRenderKey = ""
            }
        }

        needsDecorationLayout = true
        updateGestureStates()
        updateAccessibility()
        setNeedsLayout()
    }

    func setRevealVisible(_ visible: Bool) {
        guard isRevealVisible != visible else { return }
        isRevealVisible = visible
        if !visible {
            if let session = revealSession, session.isFinalizing {
                teardownReveal()
            } else {
                ChatRevealDisplayDriver.shared.unregister(self)
            }
        } else {
            syncRevealDisplayDriver()
        }
    }

    func captureRevealHandoff(sealedPrefixUTF16: Int = 0) -> ChatRevealHandoff? {
        revealSession?.makeHandoff(sealedPrefixUTF16: sealedPrefixUTF16)
    }

    /// Immediately clears all reveal masks and flying glyph snippets (e.g. on long-press selection or tap-to-finish).
    func revealAll() {
        isExternallyRevealControlled = false
        externalRevealState = .complete
        lastExternalLocalPoints = 0
        hasAppliedExternalRevealBaseline = false
        teardownReveal()
    }

    /// Applies unified cross-block message reveal progress from `MessageRevealCoordinator`.
    func applyExternalRevealState(_ state: MessageRevealTimeline.SliceRevealState, now: CFTimeInterval) {
        guard isExternallyRevealControlled, selectionTextView == nil else { return }
        externalRevealState = state
        guard bounds.width > 0, bounds.height > 0, let style = currentStyle else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        applyExternalRevealMaskInsideTransaction(style: style, now: now)
        CATransaction.commit()
    }

    private func applyExternalRevealMaskInsideTransaction(style: ChatListStyle, now: CFTimeInterval) {
        switch externalRevealState {
        case .hidden:
            lastExternalLocalPoints = 0
            hasAppliedExternalRevealBaseline = true
            revealMaskCoordinator.clearFlyingSnippets()
            revealMaskCoordinator.lockMaskBeforeTileContents(
                maskState: .hidden,
                bounds: bounds,
                tileRoot: tileRoot,
                overlayHost: layer
            )

        case .revealing(let localPoints, _):
            guard let snap = appliedRevealSnapshot else {
                revealMaskCoordinator.lockMaskBeforeTileContents(
                    maskState: .hidden,
                    bounds: bounds,
                    tileRoot: tileRoot,
                    overlayHost: layer
                )
                return
            }
            let clampedLocal = min(Double(snap.totalPoints), max(0, localPoints))
            let newlyRevealed: [(lineHasRTL: Bool, units: [ChatRevealAtomicUnit])]
            if !hasAppliedExternalRevealBaseline {
                // First sample after a live->settled handoff seeds the baseline without re-spawning
                // flying snippets for glyphs that were already visible prior to handoff.
                hasAppliedExternalRevealBaseline = true
                lastExternalLocalPoints = clampedLocal
                newlyRevealed = []
            } else {
                let prev = min(lastExternalLocalPoints, clampedLocal)
                newlyRevealed = snap.unitsNewlyRevealed(from: prev, to: clampedLocal)
                lastExternalLocalPoints = max(lastExternalLocalPoints, clampedLocal)
            }
            let motionEnabled = ChatRevealPolicy.currentAllowsMotionEffects(reduceMotion: style.reduceMotion)
            let allowsSnippets = ChatRevealPolicy.allowsSnippets(
                fade: style.fade,
                reduceMotion: style.reduceMotion,
                attributedLength: currentRendered.attributed.length,
                tileCount: max(1, activeTileCount)
            )
            revealMaskCoordinator.apply(
                snapshot: snap,
                cursorPoints: clampedLocal,
                newlyRevealed: newlyRevealed,
                bounds: bounds,
                allowsSnippets: allowsSnippets,
                motionEnabled: motionEnabled,
                now: now,
                tileRoot: tileRoot,
                overlayHost: layer
            )

        case .complete:
            if let snap = appliedRevealSnapshot, revealMaskCoordinator.snippetHost.activeCount > 0 {
                let total = Double(snap.totalPoints)
                let newlyRevealed = snap.unitsNewlyRevealed(from: lastExternalLocalPoints, to: total)
                lastExternalLocalPoints = total
                let motionEnabled = ChatRevealPolicy.currentAllowsMotionEffects(reduceMotion: style.reduceMotion)
                revealMaskCoordinator.apply(
                    snapshot: snap,
                    cursorPoints: total,
                    newlyRevealed: newlyRevealed,
                    bounds: bounds,
                    allowsSnippets: false,
                    motionEnabled: motionEnabled,
                    now: now,
                    tileRoot: tileRoot,
                    overlayHost: layer
                )
                if revealMaskCoordinator.snippetHost.activeCount == 0 {
                    revealMaskCoordinator.detach(from: tileRoot)
                }
            } else {
                revealMaskCoordinator.detach(from: tileRoot)
            }
        }
    }

    func resetForReuse() {
        drawGeneration &+= 1
        isAwaitingFinalizedTiles = false
        currentOwnerID = nil
        currentRendered = .empty
        currentStyle = nil
        currentIsLive = false
        currentIsLiveTail = false
        isExternallyRevealControlled = false
        externalRevealState = .complete
        lastExternalLocalPoints = 0
        hasAppliedExternalRevealBaseline = false
        lastAppliedBoundsWidth = 0
        lastRenderToken = 0
        lastStyleKey = ""
        lastIsLive = false
        lastIsLiveTail = false
        activeRenderKey = ""
        appliedRenderKey = ""
        inFlightRenderKey = ""
        activeTileCount = 0
        keepsFallbackTextView = false
        isRevealVisible = true
        teardownReveal()
        clearSelectionIfNeeded()
        clearTileLayers()
        onQuoteSelection = nil
        onSubConversationSelection = nil
        onSaveNoteSelection = nil
        onSpeakSelection = nil
        onSelectionActiveChanged = nil
        onLinkTapped = nil
        onRevealFrame = nil
        onRequestRevealAll = nil
        updateGestureStates()
        updateAccessibility()
    }

    func clearSelectionIfNeeded() {
        if let tv = selectionTextView {
            if tv.selectedRange.length > 0 {
                tv.selectedRange = NSRange(location: 0, length: 0)
            }
            publishSelection(false)
            if !currentIsLive && !keepsFallbackTextView && !isAwaitingFinalizedTiles {
                teardownSelectionTextView(notifyIfNeeded: false)
            }
        } else {
            publishSelection(false)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if let tv = selectionTextView {
            tileRoot.isHidden = true
            tv.frame = bounds
            updateDecorationsIfNeeded(for: tv)
            if !isAwaitingFinalizedTiles {
                return
            }
        } else {
            decorationRoot?.isHidden = true
        }

        guard bounds.width > 0, bounds.height > 0, let style = currentStyle else {
            clearTileLayers()
            return
        }
        guard !currentRendered.isEmpty else {
            activeRenderKey = ""
            appliedRenderKey = ""
            inFlightRenderKey = ""
            isAwaitingFinalizedTiles = false
            clearTileLayers()
            if selectionTextView != nil && !currentIsLive && !keepsFallbackTextView && selectedRange.length == 0 {
                teardownSelectionTextView(notifyIfNeeded: false, triggerLayout: false)
            }
            return
        }

        if lastAppliedBoundsWidth > 0 && abs(bounds.width - lastAppliedBoundsWidth) > 0.5 {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            revealMaskCoordinator.clearFlyingSnippets()
            CATransaction.commit()
        }
        lastAppliedBoundsWidth = bounds.width

        let scale = Self.resolveDisplayScale(for: traitCollection, window: window)
        let renderKey = ChatTextTileRenderer.cacheKey(
            token: currentRendered.renderToken,
            width: bounds.width,
            height: bounds.height,
            styleKey: style.styleKey,
            scale: scale
        )

        let wantsRevealTiles = isExternallyRevealControlled
            || (currentIsLiveTail && ChatRevealPolicy.isEligible(
                fade: style.fade,
                reduceMotion: style.reduceMotion,
                attributedLength: currentRendered.attributed.length
            ))
            || revealSession != nil
            || pendingRevealHandoff != nil

        if appliedRenderKey == renderKey && !isAwaitingFinalizedTiles {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            tileRoot.isHidden = false
            tileRoot.frame = bounds
            if isExternallyRevealControlled {
                applyExternalRevealMaskInsideTransaction(style: style, now: CACurrentMediaTime())
            } else if wantsRevealTiles {
                syncRevealSessionAndMaskAfterTiles(style: style, tileCount: max(1, activeTileCount))
            }
            CATransaction.commit()
            if wantsRevealTiles && !isExternallyRevealControlled {
                syncRevealDisplayDriver()
            }
            return
        }

        activeRenderKey = renderKey
        if let cached = ChatTextTileRenderer.shared.cached(for: renderKey),
           (!wantsRevealTiles || cached.revealSnapshot != nil) {
            applyTiles(cached, forKey: renderKey, scale: scale, token: currentRendered.renderToken)
            return
        }

        if inFlightRenderKey == renderKey {
            return
        }

        if !wantsRevealTiles {
            clearTileLayers()
        }
        let requestedToken = currentRendered.renderToken
        let requestWidth = bounds.width
        let requestStyleKey = style.styleKey
        let request = ChatTextRenderRequest(
            cacheKey: renderKey,
            attributed: currentRendered.attributed,
            decorations: currentRendered.decorations,
            topInset: currentRendered.topInset,
            bottomInset: currentRendered.bottomInset,
            width: bounds.width,
            height: bounds.height,
            scale: scale,
            palette: ChatTextRenderPalette.make(style: style),
            includeRevealSnapshot: wantsRevealTiles,
            sourceRenderToken: requestedToken
        )

        let canRenderSync = currentRendered.attributed.length <= 80 && !currentRendered.decorations.hasAny

        if canRenderSync {
            if let tiles = ChatTextTileRenderer.shared.renderSync(request) {
                applyTiles(tiles, forKey: renderKey, scale: scale, token: requestedToken)
            } else {
                teardownReveal()
                isAwaitingFinalizedTiles = false
                mountFallbackTextView()
            }
        } else {
            let expectedDrawGen = drawGeneration
            inFlightRenderKey = renderKey
            ChatTextTileRenderer.shared.renderAsync(request) { [weak self] key, result in
                guard let self else { return }
                if self.drawGeneration == expectedDrawGen && self.inFlightRenderKey == key {
                    self.inFlightRenderKey = ""
                }
                guard self.drawGeneration == expectedDrawGen,
                      self.selectionTextView == nil || self.isAwaitingFinalizedTiles else {
                    return
                }
                let matchesLatest = self.activeRenderKey == key
                let canAdvanceLiveTail = self.currentIsLiveTail
                    && requestedToken >= self.appliedRenderToken
                    && abs(self.bounds.width - requestWidth) <= 0.5
                    && self.currentStyle?.styleKey == requestStyleKey
                guard matchesLatest || canAdvanceLiveTail else {
                    return
                }
                switch result {
                case .rendered(let tiles):
                    self.applyTiles(tiles, forKey: key, scale: scale, token: requestedToken)
                    if self.activeRenderKey != key {
                        self.setNeedsLayout()
                    }
                case .staleOrCancelled:
                    self.setNeedsLayout()
                case .failed:
                    if matchesLatest {
                        self.teardownReveal()
                        self.isAwaitingFinalizedTiles = false
                        self.mountFallbackTextView()
                    }
                }
            }
        }
    }

    // MARK: - Tile Rendering Layer Pool

    private func applyTiles(_ rendered: ChatRenderedTiles, forKey key: String, scale: CGFloat, token: UInt64) {
        if let tv = selectionTextView {
            guard !keepsFallbackTextView, tv.selectedRange.length == 0, isAwaitingFinalizedTiles else {
                isAwaitingFinalizedTiles = false
                return
            }
        }
        isAwaitingFinalizedTiles = false
        activeTileCount = rendered.tiles.count
        appliedRevealSnapshot = rendered.revealSnapshot
        appliedRenderToken = token

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tileRoot.isHidden = false
        tileRoot.frame = bounds

        // Anti-flash redline: lock revealMask BEFORE assigning any tileLayer.contents.
        if let style = currentStyle {
            let eligible = ChatRevealPolicy.isEligible(
                fade: style.fade,
                reduceMotion: style.reduceMotion,
                attributedLength: currentRendered.attributed.length
            )
            let preLockNeeded = eligible && (isExternallyRevealControlled || currentIsLiveTail || revealSession != nil || pendingRevealHandoff != nil)
            if preLockNeeded {
                let preLockState: ChatRevealLayoutSnapshot.MaskState
                if isExternallyRevealControlled {
                    switch externalRevealState {
                    case .hidden:
                        preLockState = .hidden
                    case .revealing(let localPoints, _):
                        if let snap = rendered.revealSnapshot {
                            let clamped = ChatRevealSnippetPlanner.clampedStaticMaskPoints(
                                cursorPoints: localPoints,
                                lowestAnimatingStartPoints: revealMaskCoordinator.snippetHost.lowestAnimatingStartPoints
                            )
                            preLockState = snap.maskState(forPoints: clamped)
                        } else {
                            preLockState = .hidden
                        }
                    case .complete:
                        preLockState = .complete
                    }
                } else if let session = revealSession {
                    let clamped = ChatRevealSnippetPlanner.clampedStaticMaskPoints(
                        cursorPoints: session.currentPoints,
                        lowestAnimatingStartPoints: revealMaskCoordinator.snippetHost.lowestAnimatingStartPoints
                    )
                    preLockState = (rendered.revealSnapshot ?? session.snapshot).maskState(forPoints: clamped)
                } else {
                    preLockState = .hidden
                }
                revealMaskCoordinator.lockMaskBeforeTileContents(
                    maskState: preLockState,
                    bounds: bounds,
                    tileRoot: tileRoot,
                    overlayHost: layer
                )
            }
        }

        while tileLayers.count < rendered.tiles.count {
            let tileLayer = CALayer()
            tileLayer.contentsGravity = .topLeft
            tileLayer.masksToBounds = true
            tileRoot.addSublayer(tileLayer)
            tileLayers.append(tileLayer)
        }

        for (idx, tileLayer) in tileLayers.enumerated() {
            if idx < rendered.tiles.count {
                let tile = rendered.tiles[idx]
                let tileW = CGFloat(tile.image.width) / scale
                tileLayer.isHidden = false
                tileLayer.contentsScale = scale
                tileLayer.frame = CGRect(x: 0, y: tile.y, width: tileW, height: tile.height)
                tileLayer.contents = tile.image
            } else {
                tileLayer.isHidden = true
                tileLayer.contents = nil
            }
        }

        revealMaskCoordinator.updateTiles(rendered, scale: scale)

        if let style = currentStyle {
            if isExternallyRevealControlled {
                applyExternalRevealMaskInsideTransaction(style: style, now: CACurrentMediaTime())
            } else {
                syncRevealSessionAndMaskAfterTiles(style: style, tileCount: rendered.tiles.count)
            }
        }

        if selectionTextView != nil {
            teardownSelectionTextView(notifyIfNeeded: false, triggerLayout: false)
        }
        CATransaction.commit()
        appliedRenderKey = key
        inFlightRenderKey = ""
        if !isExternallyRevealControlled {
            syncRevealDisplayDriver()
        }
        updateAccessibility()
    }

    private func clearTileLayers() {
        appliedRenderKey = ""
        appliedRevealSnapshot = nil
        appliedRenderToken = 0
        activeTileCount = 0
        guard !tileLayers.isEmpty else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for tileLayer in tileLayers {
            tileLayer.isHidden = true
            tileLayer.contents = nil
        }
        CATransaction.commit()
    }

    private func syncRevealSessionAndMaskAfterTiles(style: ChatListStyle, tileCount: Int) {
        guard ChatRevealPolicy.isEligible(
            fade: style.fade,
            reduceMotion: style.reduceMotion,
            attributedLength: currentRendered.attributed.length
        ) else {
            detachRevealStateAndMask()
            return
        }

        let snap: ChatRevealLayoutSnapshot
        if let prebuilt = appliedRevealSnapshot,
           abs(prebuilt.layoutSize.width - bounds.width) <= 0.5,
           ((prebuilt.sourceRenderToken == currentRendered.renderToken && abs(prebuilt.layoutSize.height - bounds.height) <= 0.5)
            || (currentIsLiveTail && prebuilt.sourceRenderToken == appliedRenderToken && appliedRenderToken > 0)) {
            snap = prebuilt
        } else if currentRendered.attributed.length <= 80 && !currentRendered.decorations.hasAny {
            snap = ChatRevealLayoutSnapshot.build(
                attributed: currentRendered.attributed,
                width: bounds.width,
                height: bounds.height,
                topInset: currentRendered.topInset,
                bottomInset: currentRendered.bottomInset,
                sourceRenderToken: currentRendered.renderToken
            )
        } else {
            return
        }
        let now = CACurrentMediaTime()

        if let handoff = pendingRevealHandoff {
            pendingRevealHandoff = nil
            if let initialUTF16 = ChatRevealSession.resolveInitialUTF16(handoff: handoff, in: currentRendered.attributed.string) {
                revealSession = ChatRevealSession(
                    snapshot: snap,
                    initialRevealedUTF16: initialUTF16,
                    finalizeImmediately: !currentIsLiveTail,
                    pace: style.revealPace,
                    now: now
                )
            } else {
                detachRevealStateAndMask()
                return
            }
        } else if let session = revealSession {
            if session.snapshot.sourceRenderToken != snap.sourceRenderToken
                || abs(session.snapshot.layoutSize.width - snap.layoutSize.width) > 0.5
                || abs(session.snapshot.layoutSize.height - snap.layoutSize.height) > 0.5 {
                session.update(snapshot: snap, isLive: currentIsLiveTail, pace: style.revealPace, now: now)
            } else if !currentIsLiveTail && !session.isFinalizing {
                session.markFinalizing(now: now)
            }
        } else if currentIsLiveTail {
            revealSession = ChatRevealSession(
                snapshot: snap,
                initialRevealedUTF16: 0,
                finalizeImmediately: false,
                pace: style.revealPace,
                now: now
            )
        } else {
            detachRevealStateAndMask()
            return
        }

        guard let session = revealSession, !session.isComplete || revealMaskCoordinator.snippetHost.activeCount > 0 else {
            detachRevealStateAndMask()
            return
        }

        let motionEnabled = ChatRevealPolicy.currentAllowsMotionEffects(reduceMotion: style.reduceMotion)
        let allowsSnippets = ChatRevealPolicy.allowsSnippets(
            fade: style.fade,
            reduceMotion: style.reduceMotion,
            attributedLength: currentRendered.attributed.length,
            tileCount: tileCount
        )
        revealMaskCoordinator.apply(
            snapshot: session.snapshot,
            cursorPoints: session.currentPoints,
            newlyRevealed: [],
            bounds: bounds,
            allowsSnippets: allowsSnippets,
            motionEnabled: motionEnabled,
            now: now,
            tileRoot: tileRoot,
            overlayHost: layer
        )
    }

    private func syncRevealDisplayDriver() {
        guard !isExternallyRevealControlled,
              isRevealVisible,
              let session = revealSession,
              (!session.isComplete || revealMaskCoordinator.snippetHost.activeCount > 0) else {
            ChatRevealDisplayDriver.shared.unregister(self)
            return
        }
        let needsActiveTick = session.isFinalizing
            || session.backlogPoints > 0
            || session.currentMaskState() != .complete
            || revealMaskCoordinator.snippetHost.activeCount > 0
        if needsActiveTick {
            ChatRevealDisplayDriver.shared.register(self)
        } else {
            ChatRevealDisplayDriver.shared.unregister(self)
        }
    }

    private func detachRevealStateAndMask() {
        pendingRevealHandoff = nil
        revealSession = nil
        revealMaskCoordinator.detach(from: tileRoot)
    }

    private func teardownReveal() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        detachRevealStateAndMask()
        CATransaction.commit()
        ChatRevealDisplayDriver.shared.unregister(self)
    }

    func revealDisplayTick(now: CFTimeInterval) {
        guard !isExternallyRevealControlled, isRevealVisible, let session = revealSession else {
            ChatRevealDisplayDriver.shared.unregister(self)
            return
        }
        guard let style = currentStyle else {
            teardownReveal()
            return
        }
        let stepResult = session.step(now: now)
        let newlyRevealed = session.snapshot.unitsNewlyRevealed(
            from: stepResult.prevPoints,
            to: stepResult.nextPoints
        )
        let motionEnabled = ChatRevealPolicy.currentAllowsMotionEffects(reduceMotion: style.reduceMotion)
        let allowsSnippets = ChatRevealPolicy.allowsSnippets(
            fade: style.fade,
            reduceMotion: style.reduceMotion,
            attributedLength: currentRendered.attributed.length,
            tileCount: max(1, activeTileCount)
        )
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        revealMaskCoordinator.apply(
            snapshot: session.snapshot,
            cursorPoints: stepResult.nextPoints,
            newlyRevealed: newlyRevealed,
            bounds: bounds,
            allowsSnippets: allowsSnippets,
            motionEnabled: motionEnabled,
            now: now,
            tileRoot: tileRoot,
            overlayHost: layer
        )
        CATransaction.commit()

        let finished = stepResult.isComplete && revealMaskCoordinator.snippetHost.activeCount == 0
        if finished {
            teardownReveal()
            onRevealFrame?(true)
            return
        }
        onRevealFrame?(false)

        if !session.isFinalizing
            && stepResult.backlogPoints == 0
            && stepResult.maskState == .complete
            && revealMaskCoordinator.snippetHost.activeCount == 0 {
            ChatRevealDisplayDriver.shared.unregister(self)
        }
    }

    // MARK: - Lazy TextKit 2 Selection TextView

    private func ensureSelectionTextView() -> UITextView {
        if let existing = selectionTextView {
            return existing
        }
        let tv = UITextView(usingTextLayoutManager: true)
        tv.isEditable = false
        tv.isSelectable = true
        tv.isScrollEnabled = false
        tv.backgroundColor = .clear
        tv.textContainer.lineFragmentPadding = 0
        tv.textContainerInset = .zero
        tv.linkTextAttributes = [:]
        tv.dataDetectorTypes = []
        tv.adjustsFontForContentSizeCategory = false
        tv.delegate = self
        tv.frame = bounds
        addSubview(tv)
        selectionTextView = tv
        updateGestureStates()
        updateAccessibility()
        return tv
    }

    private func applyToSelectionTextView(
        _ tv: UITextView,
        rendered: ChatRenderedProse,
        restoredRange: NSRange?
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tileRoot.isHidden = true
        let desiredInset = UIEdgeInsets(top: rendered.topInset, left: 0, bottom: rendered.bottomInset, right: 0)
        if tv.textContainerInset != desiredInset {
            tv.textContainerInset = desiredInset
        }
        tv.attributedText = rendered.attributed
        if let restoredRange {
            tv.selectedRange = restoredRange
        } else {
            tv.selectedRange = NSRange(location: 0, length: 0)
        }
        CATransaction.commit()
    }

    private func mountFallbackTextView() {
        guard !currentRendered.isEmpty else { return }
        keepsFallbackTextView = true
        isActivatingSelection = true
        let tv = ensureSelectionTextView()
        applyToSelectionTextView(tv, rendered: currentRendered, restoredRange: nil)
        isActivatingSelection = false
        needsDecorationLayout = true
        updateGestureStates()
        updateAccessibility()
        setNeedsLayout()
    }

    private func teardownSelectionTextView(notifyIfNeeded: Bool, triggerLayout: Bool = true) {
        drawGeneration &+= 1
        isAwaitingFinalizedTiles = false
        if notifyIfNeeded {
            publishSelection(false)
        }
        guard let tv = selectionTextView else { return }
        tv.delegate = nil
        if tv.isFirstResponder {
            tv.resignFirstResponder()
        }
        tv.removeFromSuperview()
        selectionTextView = nil
        keepsFallbackTextView = false
        resetDecorationLayers()
        updateGestureStates()
        updateAccessibility()
        if triggerLayout {
            setNeedsLayout()
        }
    }

    private func scheduleTeardownSelectionTextViewIfIdle() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard !self.currentIsLive,
                  !self.isActivatingSelection,
                  !self.keepsFallbackTextView,
                  !self.isAwaitingFinalizedTiles else {
                return
            }
            guard let tv = self.selectionTextView, tv.selectedRange.length == 0 else { return }
            self.teardownSelectionTextView(notifyIfNeeded: false)
        }
    }

    private func prepareSelectionTextView() -> UITextView? {
        guard !currentRendered.isEmpty else { return nil }
        drawGeneration &+= 1
        isAwaitingFinalizedTiles = false

        let tv = ensureSelectionTextView()
        tv.frame = bounds
        applyToSelectionTextView(tv, rendered: currentRendered, restoredRange: nil)
        tv.layoutIfNeeded()
        needsDecorationLayout = true
        updateDecorationsIfNeeded(for: tv)
        return tv
    }

    private func activateSelection(at point: CGPoint) {
        onRequestRevealAll?()
        revealAll()
        isActivatingSelection = true
        defer { isActivatingSelection = false }
        guard let tv = prepareSelectionTextView() else { return }

        let localPoint = convert(point, to: tv)
        let len = tv.attributedText?.length ?? 0
        if len > 0, let pos = tv.closestPosition(to: localPoint) {
            let wordRange = tv.tokenizer.rangeEnclosingPosition(pos, with: .word, inDirection: .layout(.left))
                ?? tv.tokenizer.rangeEnclosingPosition(pos, with: .word, inDirection: .layout(.right))
            if let wordRange, !wordRange.isEmpty {
                let startOffset = tv.offset(from: tv.beginningOfDocument, to: wordRange.start)
                let endOffset = tv.offset(from: tv.beginningOfDocument, to: wordRange.end)
                if endOffset > startOffset, endOffset <= len {
                    tv.selectedRange = NSRange(location: startOffset, length: endOffset - startOffset)
                }
            }
            if tv.selectedRange.length == 0 {
                let offset = tv.offset(from: tv.beginningOfDocument, to: pos)
                let clamped = min(max(0, offset), len - 1)
                tv.selectedRange = NSRange(location: clamped, length: 1)
            }
        }
        if tv.selectedRange.length == 0 && len > 0 {
            tv.selectedRange = NSRange(location: 0, length: 1)
        }

        tv.becomeFirstResponder()
        publishSelection(tv.selectedRange.length > 0)
        updateGestureStates()
        updateAccessibility()
    }

    @discardableResult
    func activateSelectionAll() -> Bool {
        guard hasSelectableText else { return false }
        onRequestRevealAll?()
        revealAll()
        isActivatingSelection = true
        defer { isActivatingSelection = false }
        guard let tv = prepareSelectionTextView() else { return false }

        let nsText = (tv.attributedText?.string ?? "") as NSString
        let len = nsText.length
        guard len > 0 else {
            if !currentIsLive && !keepsFallbackTextView {
                teardownSelectionTextView(notifyIfNeeded: false)
            }
            return false
        }
        var start = 0
        while start < len {
            let ch = nsText.character(at: start)
            if ch == 0x200B || ch == 0x000A || ch == 0x000D {
                start += 1
            } else {
                break
            }
        }
        var end = len
        while end > start {
            let ch = nsText.character(at: end - 1)
            if ch == 0x200B || ch == 0x000A || ch == 0x000D {
                end -= 1
            } else {
                break
            }
        }
        tv.selectedRange = end > start ? NSRange(location: start, length: end - start) : NSRange(location: 0, length: len)
        tv.becomeFirstResponder()
        publishSelection(true)
        updateGestureStates()
        updateAccessibility()
        return true
    }

    private struct AccessibilityLinkKey: Hashable {
        let title: String
        let url: URL
    }

    private func makeLinkAccessibilityActions() -> [UIAccessibilityCustomAction]? {
        let attributed = currentRendered.attributed
        guard attributed.length > 0 else { return nil }
        let fullText = attributed.string as NSString
        var actions: [UIAccessibilityCustomAction] = []
        var seen = Set<AccessibilityLinkKey>()

        attributed.enumerateAttribute(
            .link,
            in: NSRange(location: 0, length: attributed.length),
            options: []
        ) { value, range, _ in
            let url: URL?
            if let direct = value as? URL {
                url = direct
            } else if let str = value as? String {
                url = URL(string: str)
            } else {
                url = nil
            }
            guard let url else { return }
            let rawTitle = fullText.substring(with: range)
                .replacingOccurrences(of: "\u{200B}", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let title = rawTitle.isEmpty ? url.absoluteString : rawTitle
            let key = AccessibilityLinkKey(title: title, url: url)
            guard seen.insert(key).inserted else { return }
            actions.append(UIAccessibilityCustomAction(name: title) { [weak self] _ in
                self?.onLinkTapped?(url)
                return true
            })
        }
        return actions.isEmpty ? nil : actions
    }

    private func updateAccessibility() {
        let label = currentRendered.attributed.string
            .replacingOccurrences(of: "\u{200B}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if selectionTextView == nil && !currentRendered.isEmpty && !label.isEmpty {
            isAccessibilityElement = true
            accessibilityLabel = label
            accessibilityTraits = [.staticText]
            accessibilityCustomActions = currentRendered.hasLinks ? makeLinkAccessibilityActions() : nil
        } else {
            isAccessibilityElement = false
            accessibilityLabel = nil
            accessibilityTraits = []
            accessibilityCustomActions = nil
        }
    }

    var hasActiveSelection: Bool {
        selectionTextView != nil
    }

    // MARK: - Gestures & CoreText Link Hit-Testing

    private func updateGestureStates() {
        let tilesActive = (selectionTextView == nil)
        let hasText = hasSelectableText
        linkTapGesture?.isEnabled = tilesActive && currentRendered.hasLinks
        doubleTapGesture?.isEnabled = tilesActive && hasText
        longPressGesture?.isEnabled = tilesActive && hasText && allowLongPressSelection
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === linkTapGesture {
            return hitTestLink(at: gestureRecognizer.location(in: self)) != nil
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    @objc private func handleLinkTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended else { return }
        if let url = hitTestLink(at: recognizer.location(in: self)) {
            onLinkTapped?(url)
        }
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, selectionTextView == nil else { return }
        activateSelection(at: recognizer.location(in: self))
    }

    @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
        guard recognizer.state == .began, allowLongPressSelection, selectionTextView == nil else { return }
        Haptics.tick(0.45)
        activateSelection(at: recognizer.location(in: self))
    }

    func hitTestLink(at point: CGPoint) -> URL? {
        guard currentRendered.hasLinks,
              !currentRendered.isEmpty,
              bounds.width > 0,
              bounds.height > 0 else {
            return nil
        }

        let textHeight = max(1, bounds.height - currentRendered.topInset - currentRendered.bottomInset)
        guard point.x >= -4, point.x <= bounds.width + 4,
              point.y >= currentRendered.topInset - 4,
              point.y <= currentRendered.topInset + textHeight + 4 else {
            return nil
        }

        let source = ChatLayoutCache.prepareCoreTextSource(currentRendered.attributed)
        let framesetter = CTFramesetterCreateWithAttributedString(source as CFAttributedString)
        let path = CGPath(rect: CGRect(x: 0, y: 0, width: max(1, bounds.width), height: textHeight), transform: nil)
        let ctFrame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: source.length), path, nil)

        let cfLines = CTFrameGetLines(ctFrame)
        let lineCount = CFArrayGetCount(cfLines)
        guard lineCount > 0 else { return nil }
        var origins = [CGPoint](repeating: .zero, count: lineCount)
        CTFrameGetLineOrigins(ctFrame, CFRange(location: 0, length: 0), &origins)

        let attrLength = currentRendered.attributed.length
        for i in 0..<lineCount {
            let line = unsafeBitCast(CFArrayGetValueAtIndex(cfLines, i), to: CTLine.self)
            let cfRange = CTLineGetStringRange(line)
            guard cfRange.location != kCFNotFound, cfRange.length > 0 else { continue }
            let lineRange = cfRange.location..<(cfRange.location + cfRange.length)
            let origin = origins[i]
            var ascent: CGFloat = 0
            var descent: CGFloat = 0
            var leading: CGFloat = 0
            let lineWidth = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
            let baselineY = currentRendered.topInset + (textHeight - origin.y)
            let lineTop = baselineY - ascent
            let lineBottom = baselineY + descent

            guard point.y >= lineTop - 4 && point.y <= lineBottom + 4 else { continue }
            guard point.x >= origin.x - 4 && point.x <= origin.x + lineWidth + 4 else { continue }

            let localPoint = CGPoint(x: point.x - origin.x, y: baselineY - point.y)
            let rawIndex = CTLineGetStringIndexForPosition(line, localPoint)
            guard rawIndex != kCFNotFound else { continue }

            let candidates = [rawIndex, rawIndex - 1]
            for idx in candidates where lineRange.contains(idx) && idx >= 0 && idx < attrLength {
                let value = currentRendered.attributed.attribute(.link, at: idx, effectiveRange: nil)
                if let url = value as? URL {
                    return url
                }
                if let str = value as? String, let url = URL(string: str) {
                    return url
                }
            }
        }
        return nil
    }

    // MARK: - Selection-Mode Decorations Behind UITextView

    private func ensureDecorationLayers() -> (root: CALayer, code: CAShapeLayer, rule: CAShapeLayer) {
        if let decorationRoot, let inlineCodeLayer, let ruleLayer {
            return (decorationRoot, inlineCodeLayer, ruleLayer)
        }
        let root = CALayer()
        root.zPosition = -1
        let code = CAShapeLayer()
        let rule = CAShapeLayer()
        root.addSublayer(code)
        root.addSublayer(rule)
        layer.insertSublayer(root, at: 0)
        decorationRoot = root
        inlineCodeLayer = code
        ruleLayer = rule
        return (root, code, rule)
    }

    private func resetDecorationLayers() {
        guard let decorationRoot else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        decorationRoot.isHidden = true
        inlineCodeLayer?.path = nil
        ruleLayer?.path = nil
        for qLayer in quoteLayers {
            qLayer.isHidden = true
        }
        CATransaction.commit()
        paintedWidth = -1
        paintedToken = 0
        needsDecorationLayout = false
    }

    private func updateDecorationsIfNeeded(for tv: UITextView) {
        guard bounds.width > 0 else { return }
        let decorations = currentRendered.decorations
        let currentInterface = traitCollection.userInterfaceStyle
        if !needsDecorationLayout
            && abs(paintedWidth - bounds.width) < 0.25
            && paintedToken == lastRenderToken
            && paintedTraitStyle == currentInterface {
            return
        }

        guard decorations.hasAny else {
            resetDecorationLayers()
            paintedWidth = bounds.width
            paintedToken = lastRenderToken
            paintedTraitStyle = currentInterface
            needsDecorationLayout = false
            return
        }

        let layers = ensureDecorationLayers()
        layers.root.isHidden = false

        let widthKey = Int((bounds.width * 2).rounded())
        let cacheKey = DecorationCacheKey(renderToken: lastRenderToken, widthKey: widthKey)
        if lastRenderToken > 0, let cached = Self.decorationGeometryCache.get(cacheKey) {
            applyDecorationGeometry(cached, to: layers)
            paintedWidth = bounds.width
            paintedToken = lastRenderToken
            paintedTraitStyle = currentInterface
            needsDecorationLayout = false
            return
        }

        if let tlm = tv.textLayoutManager {
            let geometry = layoutDecorationsSinglePass(using: tlm, textView: tv, layers: layers)
            if lastRenderToken > 0 {
                Self.decorationGeometryCache.set(geometry, for: cacheKey)
            }
        } else {
            tv.layoutManager.ensureLayout(for: tv.textContainer)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layers.root.frame = bounds
            layoutInlineCodeFallback(decorations.inlineCodeRanges, textView: tv, codeLayer: layers.code)
            layoutRulesFallback(decorations.ruleRanges, textView: tv, ruleLayer: layers.rule)
            let fallbackSpans = decorations.quoteBlocks.map { verticalSpanFallback(for: $0, textView: tv) }
            applyQuoteLayers(spans: fallbackSpans, root: layers.root)
            CATransaction.commit()
        }

        paintedWidth = bounds.width
        paintedToken = lastRenderToken
        paintedTraitStyle = currentInterface
        needsDecorationLayout = false
    }

    private func applyDecorationGeometry(
        _ geometry: DecorationGeometry,
        to layers: (root: CALayer, code: CAShapeLayer, rule: CAShapeLayer)
    ) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layers.root.frame = bounds
        if let codePath = geometry.codePath {
            layers.code.path = codePath
            layers.code.fillColor = resolvedColorCG(Ink.surfaceSubtle, alpha: 1.0)
        } else {
            layers.code.path = nil
        }
        if let rulePath = geometry.rulePath {
            layers.rule.path = rulePath
            layers.rule.fillColor = resolvedColorCG(Ink.rule, alpha: 0.85)
        } else {
            layers.rule.path = nil
        }
        applyQuoteLayers(spans: geometry.quoteSpans, root: layers.root)
        CATransaction.commit()
    }

    private func layoutDecorationsSinglePass(
        using tlm: NSTextLayoutManager,
        textView tv: UITextView,
        layers: (root: CALayer, code: CAShapeLayer, rule: CAShapeLayer)
    ) -> DecorationGeometry {
        let decorations = currentRendered.decorations
        let totalLength = tv.attributedText?.length ?? 0
        let codeRanges = decorations.inlineCodeRanges
            .filter { $0.length > 0 && $0.location >= 0 && $0.location + $0.length <= totalLength }
            .sorted { $0.location < $1.location }
        let ruleRanges = decorations.ruleRanges
            .filter { $0.length > 0 && $0.location >= 0 && $0.location + $0.length <= totalLength }
            .sorted { $0.location < $1.location }
        let quoteRanges = decorations.quoteBlocks
            .filter { $0.length > 0 && $0.location >= 0 && $0.location + $0.length <= totalLength }
            .sorted { $0.location < $1.location }

        let codePath = CGMutablePath()
        let rulePath = CGMutablePath()
        var quoteSpans: [(minY: CGFloat, maxY: CGFloat)?] = Array(repeating: nil, count: quoteRanges.count)

        var ruleIdx = 0
        var quoteIdx = 0

        let inset = tv.textContainerInset
        let corner = currentStyle?.inlineCodeCorner ?? (5 * UIScale.factor)
        let ruleInset = Ink.Space.l
        let ruleWidth = max(24, bounds.width - ruleInset * 2)
        let docStart = tlm.documentRange.location

        if !ruleRanges.isEmpty || !quoteRanges.isEmpty {
            _ = tlm.enumerateTextLayoutFragments(from: docStart, options: [.ensuresLayout]) { fragment in
                let fragRange = fragment.rangeInElement
                let fragStart = tlm.offset(from: docStart, to: fragRange.location)
                let fragEnd = tlm.offset(from: docStart, to: fragRange.endLocation)
                guard fragEnd > fragStart else {
                    return ruleIdx < ruleRanges.count || quoteIdx < quoteRanges.count
                }

                let fragFrame = fragment.layoutFragmentFrame
                let originY = inset.top + fragFrame.minY
                let lineFragments = fragment.textLineFragments

                while ruleIdx < ruleRanges.count && NSMaxRange(ruleRanges[ruleIdx]) <= fragStart {
                    ruleIdx += 1
                }
                var rScan = ruleIdx
                while rScan < ruleRanges.count && ruleRanges[rScan].location < fragEnd {
                    let target = ruleRanges[rScan]
                    let tStart = target.location
                    let tEnd = NSMaxRange(target)
                    var minY = CGFloat.greatestFiniteMagnitude
                    var maxY = -CGFloat.greatestFiniteMagnitude
                    for lineFrag in lineFragments {
                        let lineStart = fragStart + lineFrag.characterRange.location
                        let lineEnd = lineStart + lineFrag.characterRange.length
                        if tEnd > lineStart && tStart < lineEnd {
                            let tBounds = lineFrag.typographicBounds
                            minY = min(minY, originY + tBounds.minY)
                            maxY = max(maxY, originY + tBounds.maxY)
                        }
                    }
                    if !minY.isFinite || !maxY.isFinite {
                        minY = originY
                        maxY = originY + fragFrame.height
                    }
                    if minY <= maxY {
                        let midY = (minY + maxY) * 0.5
                        rulePath.addRect(CGRect(x: ruleInset, y: midY - 0.375, width: ruleWidth, height: 0.75))
                    }
                    if tEnd <= fragEnd {
                        ruleIdx = rScan + 1
                    }
                    rScan += 1
                }

                while quoteIdx < quoteRanges.count && NSMaxRange(quoteRanges[quoteIdx]) <= fragStart {
                    quoteIdx += 1
                }
                var qScan = quoteIdx
                while qScan < quoteRanges.count && quoteRanges[qScan].location < fragEnd {
                    let target = quoteRanges[qScan]
                    let tStart = target.location
                    let tEnd = NSMaxRange(target)
                    var spanMinY = quoteSpans[qScan]?.minY ?? CGFloat.greatestFiniteMagnitude
                    var spanMaxY = quoteSpans[qScan]?.maxY ?? -CGFloat.greatestFiniteMagnitude
                    for lineFrag in lineFragments {
                        let lineStart = fragStart + lineFrag.characterRange.location
                        let lineEnd = lineStart + lineFrag.characterRange.length
                        if tEnd > lineStart && tStart < lineEnd {
                            let tBounds = lineFrag.typographicBounds
                            spanMinY = min(spanMinY, originY + tBounds.minY)
                            spanMaxY = max(spanMaxY, originY + tBounds.maxY)
                        }
                    }
                    if lineFragments.isEmpty && tEnd > fragStart && tStart < fragEnd {
                        spanMinY = min(spanMinY, originY)
                        spanMaxY = max(spanMaxY, originY + fragFrame.height)
                    }
                    if spanMinY <= spanMaxY, spanMinY.isFinite, spanMaxY.isFinite {
                        quoteSpans[qScan] = (minY: spanMinY, maxY: spanMaxY)
                    }
                    if tEnd <= fragEnd {
                        quoteIdx = qScan + 1
                    }
                    qScan += 1
                }

                return ruleIdx < ruleRanges.count || quoteIdx < quoteRanges.count
            }
        }

        if !codeRanges.isEmpty {
            for r in codeRanges {
                guard let startLoc = tlm.location(docStart, offsetBy: r.location),
                      let endLoc = tlm.location(docStart, offsetBy: NSMaxRange(r)),
                      let segRange = NSTextRange(location: startLoc, end: endLoc) else { continue }
                tlm.ensureLayout(for: segRange)
                tlm.enumerateTextSegments(in: segRange, type: .selection, options: []) { _, segmentFrame, _, _ in
                    let offsetFrame = segmentFrame.offsetBy(dx: inset.left, dy: inset.top)
                    guard offsetFrame.width > 0, offsetFrame.height > 0 else { return true }
                    let rect = offsetFrame.insetBy(dx: -2.5, dy: offsetFrame.height * 0.06)
                    let radius = min(corner, rect.height * 0.3)
                    codePath.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
                    return true
                }
            }
        }

        let geometry = DecorationGeometry(
            codePath: codeRanges.isEmpty ? nil : codePath,
            rulePath: ruleRanges.isEmpty ? nil : rulePath,
            quoteSpans: quoteSpans
        )
        applyDecorationGeometry(geometry, to: layers)
        return geometry
    }

    private func layoutInlineCodeFallback(_ ranges: [NSRange], textView tv: UITextView, codeLayer: CAShapeLayer) {
        guard !ranges.isEmpty else {
            codeLayer.path = nil
            return
        }
        let path = CGMutablePath()
        let corner = currentStyle?.inlineCodeCorner ?? (5 * UIScale.factor)
        let length = tv.attributedText?.length ?? 0

        for range in ranges {
            guard range.location >= 0, range.location + range.length <= length, range.length > 0,
                  let start = tv.position(from: tv.beginningOfDocument, offset: range.location),
                  let end = tv.position(from: start, offset: range.length),
                  let tr = tv.textRange(from: start, to: end) else { continue }
            for fragment in tv.selectionRects(for: tr) {
                guard fragment.rect.width > 0, fragment.rect.height > 0 else { continue }
                let rect = fragment.rect.insetBy(dx: -2.5, dy: fragment.rect.height * 0.06)
                let radius = min(corner, rect.height * 0.3)
                path.addRoundedRect(in: rect, cornerWidth: radius, cornerHeight: radius)
            }
        }
        codeLayer.path = path
        codeLayer.fillColor = resolvedColorCG(Ink.surfaceSubtle, alpha: 1.0)
    }

    private func layoutRulesFallback(_ ranges: [NSRange], textView tv: UITextView, ruleLayer: CAShapeLayer) {
        guard !ranges.isEmpty else {
            ruleLayer.path = nil
            return
        }
        let path = CGMutablePath()
        let inset = Ink.Space.l
        let lineW = max(24, bounds.width - inset * 2)
        for range in ranges {
            guard let span = verticalSpanFallback(for: range, textView: tv) else { continue }
            let midY = (span.minY + span.maxY) * 0.5
            path.addRect(CGRect(x: inset, y: midY - 0.375, width: lineW, height: 0.75))
        }
        ruleLayer.path = path
        ruleLayer.fillColor = resolvedColorCG(Ink.rule, alpha: 0.85)
    }

    private func applyQuoteLayers(spans: [(minY: CGFloat, maxY: CGFloat)?], root: CALayer) {
        while quoteLayers.count < spans.count {
            let qLayer = QuoteCardLayer()
            root.insertSublayer(qLayer, at: 0)
            quoteLayers.append(qLayer)
        }
        let padV = Ink.Space.m
        let cardBg = resolvedColorCG(Ink.surfaceSubtle, alpha: 0.35)
        let stripeColor = resolvedColorCG(Ink.accent, alpha: 0.55)
        let radius = Ink.Radius.small

        for (idx, qLayer) in quoteLayers.enumerated() {
            guard idx < spans.count, let span = spans[idx] else {
                qLayer.isHidden = true
                continue
            }
            let topY = max(0, span.minY - padV)
            let bottomY = min(bounds.height, span.maxY + padV)
            let frame = CGRect(x: 0, y: topY, width: bounds.width, height: max(padV * 2, bottomY - topY))
            qLayer.isHidden = false
            qLayer.frame = frame
            qLayer.cornerRadius = radius
            qLayer.backgroundColor = cardBg
            qLayer.borderColor = nil
            qLayer.stripe.backgroundColor = stripeColor
            qLayer.stripe.frame = CGRect(
                x: Ink.Space.m,
                y: padV,
                width: 2.0,
                height: max(6, frame.height - padV * 2)
            )
        }
    }

    private func verticalSpanFallback(for range: NSRange, textView tv: UITextView) -> (minY: CGFloat, maxY: CGFloat)? {
        let total = tv.attributedText?.length ?? 0
        guard range.location >= 0, range.location + range.length <= total, range.length > 0,
              let start = tv.position(from: tv.beginningOfDocument, offset: range.location),
              let end = tv.position(from: start, offset: range.length),
              let tr = tv.textRange(from: start, to: end) else {
            return nil
        }

        var minY = CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        for fragment in tv.selectionRects(for: tr) where fragment.rect.height > 0 {
            minY = min(minY, fragment.rect.minY)
            maxY = max(maxY, fragment.rect.maxY)
        }

        let startCaret = tv.caretRect(for: start)
        if !startCaret.isNull && !startCaret.isInfinite && startCaret.height > 0 {
            minY = min(minY, startCaret.minY)
            maxY = max(maxY, startCaret.maxY)
        }
        let endCaret = tv.caretRect(for: end)
        if !endCaret.isNull && !endCaret.isInfinite && endCaret.height > 0 {
            minY = min(minY, endCaret.minY)
            maxY = max(maxY, endCaret.maxY)
        }

        guard minY <= maxY, minY.isFinite, maxY.isFinite else { return nil }
        return (minY, maxY)
    }

    private func resolvedColorCG(_ color: Color, alpha: CGFloat) -> CGColor {
        if let style = currentStyle {
            return style.resolveColor(color, alpha: alpha).cgColor
        }
        return UIColor(color).resolvedColor(with: traitCollection).withAlphaComponent(alpha).cgColor
    }

    // MARK: - UITextViewDelegate

    func textViewDidChangeSelection(_ textView: UITextView) {
        let hasSel = textView.selectedRange.length > 0
        if hasSel {
            isAwaitingFinalizedTiles = false
        }
        publishSelection(hasSel)
        if !hasSel && !currentIsLive && !isActivatingSelection && !keepsFallbackTextView && !isAwaitingFinalizedTiles {
            scheduleTeardownSelectionTextViewIfIdle()
        }
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        publishSelection(false)
        if !currentIsLive && !isActivatingSelection && !keepsFallbackTextView && !isAwaitingFinalizedTiles {
            scheduleTeardownSelectionTextViewIfIdle()
        }
    }

    func publishSelection(_ active: Bool) {
        guard active != wasSelecting else { return }
        wasSelecting = active
        onSelectionActiveChanged?(selectionOwnerID, active)
    }

    func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard range.length > 0,
              let nsText = textView.text as NSString?,
              range.location >= 0,
              range.location + range.length <= nsText.length else {
            return UIMenu(children: suggestedActions)
        }

        let cleaned = Self.cleanExcerpt(nsText.substring(with: range))
        guard !cleaned.isEmpty else {
            return UIMenu(children: suggestedActions)
        }

        var custom: [UIMenuElement] = []
        if let onQuoteSelection {
            custom.append(UIAction(
                title: L.t("chat.quoteFollowup"),
                image: UIImage(systemName: "text.quote")
            ) { [weak self, weak textView] _ in
                textView?.selectedRange = NSRange(location: 0, length: 0)
                self?.publishSelection(false)
                DispatchQueue.main.async { onQuoteSelection(cleaned) }
            })
        }
        if !currentIsLive, !currentIsLiveTail, let owner = currentOwnerID,
           let entryID = owner.split(separator: "#", maxSplits: 1).first.map(String.init),
           onSubConversationSelection != nil || (onQuoteSelection != nil && UUID(uuidString: entryID) != nil) {
            custom.append(UIAction(
                title: L.t("subConversation.title"),
                image: UIImage(systemName: "arrow.branch")
            ) { [weak self, weak textView] _ in
                guard let self, self.currentOwnerID == owner else { return }
                textView?.selectedRange = NSRange(location: 0, length: 0)
                self.publishSelection(false)
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.currentOwnerID == owner else { return }
                    if let callback = self.onSubConversationSelection {
                        callback(cleaned, entryID)
                    } else {
                        var responder: UIResponder? = self
                        while let current = responder {
                            if let presenter = current as? UIViewController {
                                SubConversationSheet.present(quote: cleaned, entryID: entryID, from: presenter)
                                break
                            }
                            responder = current.next
                        }
                    }
                }
            })
        }
        if let onSaveNoteSelection {
            custom.append(UIAction(
                title: L.t("saveNote.title"),
                image: UIImage(systemName: "square.and.arrow.down.on.square")
            ) { [weak self, weak textView] _ in
                textView?.selectedRange = NSRange(location: 0, length: 0)
                self?.publishSelection(false)
                DispatchQueue.main.async { onSaveNoteSelection(cleaned) }
            })
        }
        if let onSpeakSelection {
            custom.append(UIAction(
                title: "朗读",
                image: UIImage(systemName: "speaker.wave.2")
            ) { [weak self, weak textView] _ in
                textView?.selectedRange = NSRange(location: 0, length: 0)
                self?.publishSelection(false)
                DispatchQueue.main.async { onSpeakSelection(cleaned) }
            })
        }
        guard !custom.isEmpty else {
            return UIMenu(children: suggestedActions)
        }
        return UIMenu(children: custom + suggestedActions)
    }

    func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
        if case .link(let url) = textItem.content, let onLinkTapped {
            return UIAction { _ in onLinkTapped(url) }
        }
        return defaultAction
    }

    static func cleanExcerpt(_ raw: String) -> String {
        let stripped = raw
            .replacingOccurrences(of: "\u{200B}", with: "")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.count > 1200 {
            return String(stripped.prefix(1200))
        }
        return stripped
    }
}
