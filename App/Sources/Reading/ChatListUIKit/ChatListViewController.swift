import AgentKit
import Craft
import Observation
import QuartzCore
import SwiftUI
import UIKit

/// Pass-through container registered with `UIScrollEdgeElementContainerInteraction` so status bar taps and
/// transparent gaps between floating top-bar controls fall through to `UICollectionView` and sidebar swipe.
private final class PassThroughTopEdgeContainerView: UIView {
    weak var hostView: UIView?
    var interactiveRects: [Int: CGRect] = [:]
    var isCollapsed = false

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isCollapsed else { return nil }
        let hit = super.hitTest(point, with: event)
        guard let hit, hit !== self else { return nil }
        if let hostView, !interactiveRects.isEmpty {
            let pointInHost = hostView.convert(point, from: self)
            let hitsControl = interactiveRects.values.contains { rect in
                !rect.isEmpty && rect.insetBy(dx: -2, dy: -2).contains(pointInHost)
            }
            if !hitsControl { return nil }
        }
        return hit
    }
}

/// Pass-through container hosting the same-host SwiftUI bottom composer above `UICollectionView`.
/// Transparent areas fall through straight to the full-screen `UICollectionView` below.
private final class PassThroughBottomDockContainerView: UIView {
    var onMeasuredHeightChanged: ((CGFloat) -> Void)?
    private var lastReportedHeight: CGFloat = 0

    override func layoutSubviews() {
        super.layoutSubviews()
        let h = bounds.height.rounded(.up)
        if abs(h - lastReportedHeight) > 0.5 {
            lastReportedHeight = h
            onMeasuredHeightChanged?(h)
        }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        guard let hit, hit !== self else { return nil }
        return hit
    }
}

/// Concrete SwiftUI root view installed once inside `ChatListViewController`'s bottom-dock `UIHostingController`.
/// Owns native `@FocusState` synced bidirectionally with `ChatComposerFocusBridge` so `TextField` identity
/// and Chinese IME composition stay rock-solid across updates.
private struct ChatHostedBottomDockRoot: View {
    let model: ChatBottomDockHostModel
    let focusBridge: ChatComposerFocusBridge
    @FocusState private var localTyping: Bool

    var body: some View {
        let _ = model.revision
        Group {
            if let build = model.buildDock {
                build($localTyping, model.effectiveBottomOcclusion, model.hostViewportHeight, model.topBarHeight)
            } else {
                EmptyView()
            }
        }
        .onChange(of: localTyping) { old, now in
            if focusBridge.isFocused != now {
                focusBridge.isFocused = now
            }
            if !old && now && focusBridge.shouldPlayUserFocusHaptic() {
                Haptics.tick(0.35)
            }
        }
        .onChange(of: focusBridge.requestNonce) { _, _ in
            if let req = focusBridge.requestedFocus, localTyping != req {
                localTyping = req
            }
        }
        .onAppear {
            if let req = focusBridge.requestedFocus, localTyping != req {
                localTyping = req
            } else if focusBridge.isFocused != localTyping {
                focusBridge.isFocused = localTyping
            }
        }
    }
}

/// Production `UICollectionView` chat stream controller implementing:
/// - Deterministic pre-measured heights + hosted SwiftUI cells for `Trace` / empty / tool-tail
/// - Zero-flicker in-place streaming updates & live-to-settled selection transfer
/// - Upward pagination anchor lock (0.0 pt viewport shift)
/// - Clean `following` / `touchScrolling` / `PetPerch` clearance bridging
@MainActor
final class ChatListViewController: UIViewController, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let actions: ChatListActions
    private let layoutCache = ChatLayoutCache()
    private var currentStyle: ChatListStyle!
    private var currentState: ChatListState?

    var makeEmptyView: (() -> AnyView)?
    var onTopBarGeometryChanged: ((CGFloat, CGFloat) -> Void)?

    private var collectionView: UICollectionView!
    private var topEdgeContainerView: PassThroughTopEdgeContainerView?
    private var topEdgeInteraction: UIScrollEdgeElementContainerInteraction?
    private var topBarHostingController: UIHostingController<AnyView>?
    private var pendingTopBarRootView: AnyView?
    private var topEdgeHeightConstraint: NSLayoutConstraint?
    private var topBarTopConstraint: NSLayoutConstraint?
    private var topBarHeightConstraint: NSLayoutConstraint?
    private var bottomDockContainerView: PassThroughBottomDockContainerView?
    private var bottomDockHostingController: UIHostingController<ChatHostedBottomDockRoot>?
    private var bottomDockDockedConstraint: NSLayoutConstraint?
    private var bottomDockManualBottomConstraint: NSLayoutConstraint?
    private var bottomDockHostModel: ChatBottomDockHostModel?
    private var bottomDockFocusBridge: ChatComposerFocusBridge?
    private var measuredBottomDockHeight: CGFloat = 0
    private var measuredTopBarHeight: CGFloat = 0
    private var lastMeasuredTopBarWidth: CGFloat = -1
    private var topBarNeedsRemeasure = true
    private var lastReportedTopBarHeight: CGFloat = 0
    private var lastReportedTopBarBottomY: CGFloat = 0
    private var isTopBarCollapsed = false
    private var immersiveRestoreTapGesture: UITapGestureRecognizer?
    private var dataSource: UICollectionViewDiffableDataSource<ChatListItemID, ChatListItemID>!

    private var items: [ChatListItemID] = []
    private var itemIndexByID: [ChatListItemID: Int] = [:]
    private var rowByID: [String: ChatListRowItem] = [:]

    private var expandedThinkingIDs: Set<String> = []
    private var expandedPulseIDs: Set<String> = []
    private var expandedLookbackIDs: Set<String> = []
    private var unfoldedCodeSlices: [String: Set<Int>] = [:]
    private var prefetchTasksBySection: [Int: Task<Void, Never>] = [:]
    private var prefetchTokensBySection: [Int: ChatPrefetchToken] = [:]
    private var prefetchedSectionIDs: [Int: ChatListItemID] = [:]
    private var prewarmGeneration: UInt64 = 0
    private let prewarmGate = ChatPrewarmGate()
    private var prewarmTask: Task<Void, Never>?
    private var prewarmToken: ChatPrefetchToken?
    private struct JumpPrewarmKey: Equatable {
        let section: Int
        let itemID: ChatListItemID
        let itemCount: Int
        let widthKey: Int
        let styleKey: String
        let chatKey: String
    }
    private var jumpPrewarmGeneration: UInt64 = 0
    private let jumpPrewarmGate = ChatPrewarmGate()
    private var jumpPrewarmTask: Task<Void, Never>?
    private var jumpPrewarmToken: ChatPrefetchToken?
    private var lastJumpPrewarmKey: JumpPrewarmKey?
    private var scrollDirection: Int = -1
    private var pendingDynamicOwnerIDs: Set<String> = []

    private var selectingOwnerIDs: Set<UUID> = []
    private var hasPerformedInitialScroll = false
    private var scrollArbiter = ChatScrollArbiterCore(isPinnedToBottom: true)
    var isPinnedToBottom: Bool {
        get { scrollArbiter.isPinnedToBottom }
        set { scrollArbiter.setPinnedFromHost(newValue) }
    }
    var currentInteractionEpoch: UInt64 { scrollArbiter.interactionEpoch }
    private var isProgrammaticScroll = false
    private var isLoadingEarlierRequest = false
    private var loadEarlierGeneration: UInt64 = 0
    private var loadEarlierSawHostBusy = false
    private var loadEarlierResetTask: Task<Void, Never>?
    private var isInHostUpdate = false
    private var isDismantled = false
    private var pendingHostMetricFlush = false
    private var animatedScrollID: UInt64 = 0
    private var lastScrollOffsetY: CGFloat = 0
    private var dragStartOffsetY: CGFloat = 0
    private var lastAutoPrependTime: CFTimeInterval = 0
    private var lastKnownContentWidth: CGFloat = 0
    private var lastReportedFarFromEnd: Bool?
    private var lastReportedNeedsEndCorrection: Bool?
    private var lastReportedVisibleIDs: [String] = []
    private var turnUserIDBySection: [String?] = []
    private var firstUserRowID: String?
    private var lastUserRowID: String?
    private var lastReportedActiveTurnID: String?
    private var lastReportedReplyOwner: String?
    private var lastReportedReplyRect: CGRect = .null
    private var lastKnownRevealLimit: (ownerID: String, lineBottom: CGFloat)?

    private var pendingScrollRequest: (id: String, anchor: UnitPoint, animated: Bool)?
    private var pendingDynamicRefresh = false
    private var needsDeferredDynamicRefresh = false
    private var needsDeferredStreamingResize = false
    private var lastMeasuredItemHeights: [ChatListItemID: CGFloat] = [:]
    private var userDefaultsObserver: NSObjectProtocol?
    private var mountedFoldersObserver: NSObjectProtocol?
    private var lastObservedUserAvatarSignature = ""
    private var lastObservedTraceOpen = Pref.traceOpen
    private var activeTraceSheetModel: ChatTraceDetailSheetModel?
    private var activeTraceSheetLineID: String?
    private weak var activeTraceSheetVC: UIViewController?
    private var tracePrewarmTasks: [UUID: Task<Void, Never>] = [:]
    private var inFlightTracePrewarmIDs: Set<String> = []
    private var keyboardObserverTokens: [NSObjectProtocol] = []
    private var isViewVisible = false
    private var pendingAvatarRefresh = false
    private var pendingMountRefresh = false
    private var deferredState: ChatListState?
    private var pendingKeyboardSync = false
    private var lastReportedKeyboardOpen: Bool?
    private var styleObservationGeneration: UInt64 = 0

    private let keyboardSpacerView = UIView()
    private var insetDisplayLink: CADisplayLink?
    private var insetCatchUpStartTime: CFTimeInterval = 0
    private var insetCatchUpDuration: CFTimeInterval = 0
    private var insetCatchUpFromBottom: CGFloat = 0
    private var insetCatchUpToBottom: CGFloat = 0
    private var targetTopInset: CGFloat = 0
    private var targetBottomInset: CGFloat = 0

    private var activeKeyboardStartOverlap: CGFloat = 0
    private var activeKeyboardEndOverlap: CGFloat = 0
    private var activeKeyboardDuration: TimeInterval = 0
    private var activeKeyboardDeadline: CFTimeInterval = 0
    private var lastKeyboardFrameInHost: CGRect?
    private var lastKeyboardBelongsToHostScreen = true
    private var lastEffectiveOcclusion = ChatKeyboardGeometrySolver.resolve(
        ChatKeyboardGeometryInput(hostBounds: .zero, safeAreaBottom: 0, restingComposerHeight: 0, keyboardFrameInHost: nil)
    )
    private var lastReportedKeyboardTransitioning = false
    private var lastReportedBottomOcclusion: CGFloat = -1
    private var lastReportedComposerMinY: CGFloat = -1

    private var isTrackingUserScroll = false
    private var isSettlingUserScrollEnd = false
    private var wasPinnedAtDragStart = false
    private var userMovedAwayFromBottomDuringDrag = false
    private var lastScrollMetricsPublishTime: CFTimeInterval = 0
    private var lastReportedHeroTarget: ChatPhotoHeroTarget?

    private var isUserTouchScrolling: Bool {
        guard collectionView != nil, !isSettlingUserScrollEnd else { return false }
        return collectionView.isDragging || collectionView.isDecelerating || isTrackingUserScroll
    }

    private var canAutoPinToBottom: Bool {
        isPinnedToBottom
            && !isUserTouchScrolling
            && !(currentState?.historyInView ?? false)
            && selectingOwnerIDs.isEmpty
    }

    private var reduceMotionEnabled: Bool {
        currentState?.reduceMotion ?? UIAccessibility.isReduceMotionEnabled
    }

    func performHostUpdate(_ work: () -> Void) {
        let wasInHost = isInHostUpdate
        isInHostUpdate = true
        work()
        isInHostUpdate = wasInHost
    }

    func prepareForDismantle() -> String? {
        isDismantled = true
        isViewVisible = false
        pendingAvatarRefresh = false
        pendingMountRefresh = false
        deferredState = nil
        pendingKeyboardSync = false
        lastReportedKeyboardOpen = nil
        styleObservationGeneration &+= 1
        pendingHostMetricFlush = false
        pendingDynamicRefresh = false
        needsDeferredDynamicRefresh = false
        needsDeferredStreamingResize = false
        pendingDynamicOwnerIDs.removeAll()
        lastMeasuredItemHeights.removeAll()
        activeTraceSheetVC = nil
        activeTraceSheetModel = nil
        activeTraceSheetLineID = nil
        stopInsetDisplayLink()
        loadEarlierResetTask?.cancel()
        loadEarlierResetTask = nil
        if let observer = userDefaultsObserver {
            NotificationCenter.default.removeObserver(observer)
            userDefaultsObserver = nil
        }
        if let observer = mountedFoldersObserver {
            NotificationCenter.default.removeObserver(observer)
            mountedFoldersObserver = nil
        }
        for token in keyboardObserverTokens {
            NotificationCenter.default.removeObserver(token)
        }
        keyboardObserverTokens.removeAll()
        if let collectionView {
            for cell in collectionView.visibleCells {
                (cell as? ChatAssistantCell)?.setRevealVisible(false)
                (cell as? ChatAssistantCell)?.prepareForReuse()
                (cell as? ChatLiveToolTailCell)?.stopObserving()
            }
        }
        pendingRevealTransfers.removeAll()
        settlingRevealID = nil
        lastKnownRevealLimit = nil
        cancelAllPrefetches()
        cancelPrewarm()
        if let topEdgeInteraction {
            topEdgeContainerView?.removeInteraction(topEdgeInteraction)
            self.topEdgeInteraction = nil
        }
        if let topHost = topBarHostingController {
            if let presented = topHost.presentedViewController, presented.presentingViewController === topHost {
                presented.dismiss(animated: false)
            }
            topHost.willMove(toParent: nil)
            topHost.view.removeFromSuperview()
            topHost.removeFromParent()
            topBarHostingController = nil
        }
        if let bottomHost = bottomDockHostingController {
            if let presented = bottomHost.presentedViewController, presented.presentingViewController === bottomHost {
                presented.dismiss(animated: false)
            }
            bottomHost.willMove(toParent: nil)
            bottomHost.view.removeFromSuperview()
            bottomHost.removeFromParent()
            bottomDockHostingController = nil
        }
        bottomDockContainerView?.onMeasuredHeightChanged = nil
        bottomDockContainerView?.removeFromSuperview()
        bottomDockContainerView = nil
        bottomDockDockedConstraint = nil
        bottomDockManualBottomConstraint = nil
        bottomDockHostModel = nil
        bottomDockFocusBridge = nil
        actions.petPerch.directHostTracking = false
        topEdgeContainerView?.hostView = nil
        topEdgeContainerView?.interactiveRects.removeAll()
        topEdgeContainerView?.removeFromSuperview()
        topEdgeContainerView = nil
        pendingTopBarRootView = nil
        topEdgeHeightConstraint = nil
        topBarTopConstraint = nil
        topBarHeightConstraint = nil
        onTopBarGeometryChanged = nil
        let owner = lastReportedReplyOwner
        lastReportedReplyOwner = nil
        lastReportedReplyRect = .null
        lastReportedHeroTarget = nil
        lastReportedActiveTurnID = nil
        return owner
    }

    init(actions: ChatListActions) {
        self.actions = actions
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        insetDisplayLink?.invalidate()
        loadEarlierResetTask?.cancel()
        prewarmTask?.cancel()
        if let prewarmToken {
            ChatTextTileRenderer.shared.cancelPrefetch(token: prewarmToken)
        }
        jumpPrewarmTask?.cancel()
        if let jumpPrewarmToken {
            ChatTextTileRenderer.shared.cancelPrefetch(token: jumpPrewarmToken)
        }
        for task in tracePrewarmTasks.values {
            task.cancel()
        }
        for task in prefetchTasksBySection.values {
            task.cancel()
        }
        for token in prefetchTokensBySection.values {
            ChatTextTileRenderer.shared.cancelPrefetch(token: token)
        }
        if let observer = userDefaultsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = mountedFoldersObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        for token in keyboardObserverTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        currentStyle = ChatListStyle.current(traits: traitCollection, reduceMotion: currentState?.reduceMotion ?? false)
        view.backgroundColor = UIColor(Ink.paper)

        setupKeyboardTracking()
        setupCollectionView()
        if let pendingTopBarRootView {
            self.pendingTopBarRootView = nil
            installOrUpdateTopBarHost(rootView: pendingTopBarRootView)
        }
        if let model = bottomDockHostModel, let bridge = bottomDockFocusBridge {
            installBottomDockHostIfNeeded(model: model, focusBridge: bridge)
        }

        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitPreferredContentSizeCategory.self]) { (controller: ChatListViewController, _) in
            controller.refreshTypographyAndTheme()
        }

        lastObservedUserAvatarSignature = currentUserAvatarSignature()
        lastObservedTraceOpen = Pref.traceOpen
        userDefaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleUserDefaultsChanged()
            }
        }
        mountedFoldersObserver = NotificationCenter.default.addObserver(
            forName: MountedFolders.changed,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleMountedFoldersChanged()
            }
        }

        if let initialState = currentState {
            applyInitialState(initialState)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isViewVisible = true
        if let pending = deferredState {
            deferredState = nil
            applyState(pending)
        }
        refreshTypographyAndTheme()
        if pendingAvatarRefresh {
            pendingAvatarRefresh = false
            handleUserDefaultsChanged()
        }
        if pendingMountRefresh {
            pendingMountRefresh = false
            handleMountedFoldersChanged()
        }
        if pendingKeyboardSync {
            pendingKeyboardSync = false
            activeKeyboardDeadline = 0
            updateCollectionInsetsIfNeeded()
        }
        collectionView?.visibleCells.forEach { ($0 as? ChatAssistantCell)?.setRevealVisible(true) }
        updateTopEdgeContainerLayout(animated: false)
        startStyleObservationIfVisible()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isViewVisible = false
        if let topHost = topBarHostingController,
           let presented = topHost.presentedViewController,
           presented.presentingViewController === topHost {
            presented.dismiss(animated: false)
        }
        collectionView?.visibleCells.forEach { ($0 as? ChatAssistantCell)?.setRevealVisible(false) }
        styleObservationGeneration &+= 1
        activeKeyboardDeadline = 0
        stopInsetDisplayLink()
        clearReplyPerchClearance()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        updateTopEdgeContainerLayout(animated: false)
        updateCollectionInsetsIfNeeded()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        bottomDockFocusBridge?.suppressFocusHaptic = true
        if let collectionView {
            for cell in collectionView.visibleCells {
                (cell as? ChatAssistantCell)?.revealAll()
            }
        }
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            guard let self else { return }
            self.bottomDockFocusBridge?.suppressFocusHaptic = false
            self.updateCollectionInsetsIfNeeded()
        }
    }

    /// Installs the same-host SwiftUI bottom dock inside `ChatListViewController.view` anchored to
    /// `view.keyboardLayoutGuide.topAnchor` (docked) or unified `effectiveBottomOcclusion` (floating/split).
    func configureBottomDockHost(model: ChatBottomDockHostModel, focusBridge: ChatComposerFocusBridge) {
        guard !isDismantled else { return }
        bottomDockHostModel = model
        bottomDockFocusBridge = focusBridge
        actions.petPerch.directHostTracking = true
        guard isViewLoaded, collectionView != nil else { return }
        installBottomDockHostIfNeeded(model: model, focusBridge: focusBridge)
    }

    private func installBottomDockHostIfNeeded(model: ChatBottomDockHostModel, focusBridge: ChatComposerFocusBridge) {
        guard bottomDockHostingController == nil else { return }

        let container = PassThroughBottomDockContainerView()
        container.backgroundColor = .clear
        container.clipsToBounds = false
        container.translatesAutoresizingMaskIntoConstraints = false
        container.onMeasuredHeightChanged = { [weak self] height in
            guard let self, !self.isDismantled else { return }
            if abs(self.measuredBottomDockHeight - height) > 0.5 {
                self.measuredBottomDockHeight = height
                self.updateCollectionInsetsIfNeeded()
            }
        }
        view.addSubview(container)

        let docked = container.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        let manual = container.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: 0)
        manual.isActive = false
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            docked,
        ])

        let host = UIHostingController(rootView: ChatHostedBottomDockRoot(model: model, focusBridge: focusBridge))
        host.view.backgroundColor = .clear
        host.view.clipsToBounds = false
        host.safeAreaRegions = []
        host.sizingOptions = [.intrinsicContentSize]
        host.view.translatesAutoresizingMaskIntoConstraints = false

        addChild(host)
        container.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: container.topAnchor),
            host.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            host.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        host.didMove(toParent: self)

        if let topEdge = topEdgeContainerView {
            view.bringSubviewToFront(topEdge)
        }

        bottomDockContainerView = container
        bottomDockHostingController = host
        bottomDockDockedConstraint = docked
        bottomDockManualBottomConstraint = manual
    }

    func updateTopBarHitRect(_ slot: Int, rect: CGRect) {
        topEdgeContainerView?.interactiveRects[slot] = rect
    }

    func updateHostedTopBarHeight(_ height: CGFloat) {
        guard !isDismantled, isViewLoaded else { return }
        let clamped = max(ChatBarMetrics.height + 2, height.rounded(.up))
        guard abs(measuredTopBarHeight - clamped) > 0.5 else { return }
        measuredTopBarHeight = clamped
        updateTopEdgeContainerLayout(animated: false)
        updateCollectionInsetsIfNeeded()
    }

    func configureTopBarHost(rootView: AnyView) {
        guard !isDismantled else { return }
        guard isViewLoaded, collectionView != nil else {
            pendingTopBarRootView = rootView
            return
        }
        installOrUpdateTopBarHost(rootView: rootView)
    }

    func syncTopBarCollapseState(collapsed: Bool, animated: Bool) {
        guard !isDismantled else { return }
        if isTopBarCollapsed != collapsed {
            isTopBarCollapsed = collapsed
            if let container = topEdgeContainerView {
                container.isCollapsed = collapsed
            }
            topBarHostingController?.view.accessibilityElementsHidden = collapsed
            if collapsed,
               let topHost = topBarHostingController,
               let presented = topHost.presentedViewController,
               presented.presentingViewController === topHost {
                presented.dismiss(animated: false)
            }
            updateTopEdgeContainerLayout(animated: animated)
        }
    }

    private func installOrUpdateTopBarHost(rootView: AnyView) {
        if let host = topBarHostingController {
            host.rootView = rootView
            topBarNeedsRemeasure = true
            updateTopEdgeContainerLayout(animated: false)
            return
        }
        let container = PassThroughTopEdgeContainerView()
        container.backgroundColor = .clear
        container.clipsToBounds = false
        container.translatesAutoresizingMaskIntoConstraints = false
        container.isCollapsed = isTopBarCollapsed
        view.addSubview(container)

        let windowTop = view.window?.safeAreaInsets.top ?? view.safeAreaInsets.top
        let initialBarHeight = max(measuredTopBarHeight, ChatBarMetrics.height + 2)
        let initialHeight = isTopBarCollapsed ? max(0, windowTop + 2) : (windowTop + initialBarHeight)
        let containerHeight = container.heightAnchor.constraint(equalToConstant: initialHeight)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: view.topAnchor),
            container.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            containerHeight,
        ])

        let host = UIHostingController(rootView: rootView)
        host.view.backgroundColor = .clear
        host.view.clipsToBounds = false
        host.safeAreaRegions = []
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.accessibilityElementsHidden = isTopBarCollapsed

        addChild(host)
        container.addSubview(host.view)
        let barTop = host.view.topAnchor.constraint(equalTo: container.topAnchor, constant: windowTop)
        let barHeightConstraint = host.view.heightAnchor.constraint(equalToConstant: initialBarHeight)
        NSLayoutConstraint.activate([
            barTop,
            host.view.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            barHeightConstraint,
        ])
        host.didMove(toParent: self)
        container.hostView = host.view

        let interaction = UIScrollEdgeElementContainerInteraction()
        interaction.scrollView = collectionView
        interaction.edge = .top
        container.addInteraction(interaction)

        self.topEdgeContainerView = container
        self.topEdgeInteraction = interaction
        self.topBarHostingController = host
        self.topEdgeHeightConstraint = containerHeight
        self.topBarTopConstraint = barTop
        self.topBarHeightConstraint = barHeightConstraint
        self.topBarNeedsRemeasure = true

        updateTopEdgeContainerLayout(animated: false)
    }

    private func updateTopEdgeContainerLayout(animated: Bool) {
        guard !isDismantled, isViewLoaded else { return }
        collectionView?.topEdgeEffect.isHidden = Theme.shared.reduceVisualEffects

        guard let host = topBarHostingController else { return }
        let safeInsets = view.safeAreaInsets
        let windowTop = view.window?.safeAreaInsets.top ?? safeInsets.top
        let fullWidth = view.bounds.width > 0 ? view.bounds.width : (view.window?.bounds.width ?? 0)
        let availableWidth = max(0, fullWidth - safeInsets.left - safeInsets.right)
        if availableWidth > 0 && (topBarNeedsRemeasure || abs(availableWidth - lastMeasuredTopBarWidth) > 0.5) {
            let fitted = host.sizeThatFits(in: CGSize(width: availableWidth, height: .greatestFiniteMagnitude)).height
            let measured = fitted > 1 ? fitted.rounded(.up) : max(measuredTopBarHeight, ChatBarMetrics.height + 2)
            measuredTopBarHeight = measured
            lastMeasuredTopBarWidth = availableWidth
            topBarNeedsRemeasure = false
        }
        let barHeight = max(measuredTopBarHeight, ChatBarMetrics.height + 2)

        if abs((topBarTopConstraint?.constant ?? -1) - windowTop) > 0.5 {
            topBarTopConstraint?.constant = windowTop
        }
        if abs((topBarHeightConstraint?.constant ?? -1) - barHeight) > 0.5 {
            topBarHeightConstraint?.constant = barHeight
        }

        let desiredHeight = isTopBarCollapsed ? max(0, windowTop + 2) : (windowTop + barHeight)
        let heightDelta = abs((topEdgeHeightConstraint?.constant ?? -1) - desiredHeight)
        if heightDelta > 0.5 {
            if animated && !reduceMotionEnabled && view.window != nil {
                topEdgeHeightConstraint?.constant = desiredHeight
                UIView.animate(withDuration: 0.24, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                    self.view.layoutIfNeeded()
                }
            } else {
                topEdgeHeightConstraint?.constant = desiredHeight
            }
        }

        if availableWidth > 0 && view.window != nil {
            let globalTop = view.convert(CGPoint.zero, to: nil).y
            let bottomY = (globalTop + windowTop + barHeight).rounded(.up)
            if abs(barHeight - lastReportedTopBarHeight) > 0.5 || abs(bottomY - lastReportedTopBarBottomY) > 0.5 {
                lastReportedTopBarHeight = barHeight
                lastReportedTopBarBottomY = bottomY
                DispatchQueue.main.async { [weak self] in
                    guard let self, !self.isDismantled else { return }
                    self.onTopBarGeometryChanged?(barHeight, bottomY)
                }
            }
        }
    }

    private func setupCollectionView() {
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.showsVerticalScrollIndicator = false
        collectionView.topEdgeEffect.style = .soft
        collectionView.topEdgeEffect.isHidden = Theme.shared.reduceVisualEffects
        collectionView.bottomEdgeEffect.isHidden = true
        collectionView.keyboardDismissMode = .interactive
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.delegate = self
        collectionView.prefetchDataSource = self
        collectionView.translatesAutoresizingMaskIntoConstraints = false

        collectionView.register(ChatAssistantCell.self, forCellWithReuseIdentifier: ChatAssistantCell.reuseID)
        collectionView.register(ChatUserCell.self, forCellWithReuseIdentifier: ChatUserCell.reuseID)
        collectionView.register(ChatNoteCell.self, forCellWithReuseIdentifier: ChatNoteCell.reuseID)
        collectionView.register(ChatEarlierButtonCell.self, forCellWithReuseIdentifier: ChatEarlierButtonCell.reuseID)
        collectionView.register(ChatLivePulseCell.self, forCellWithReuseIdentifier: ChatLivePulseCell.reuseID)
        collectionView.register(ChatLiveThinkingCell.self, forCellWithReuseIdentifier: ChatLiveThinkingCell.reuseID)
        collectionView.register(ChatLiveFailureCell.self, forCellWithReuseIdentifier: ChatLiveFailureCell.reuseID)
        collectionView.register(ChatQueuedCell.self, forCellWithReuseIdentifier: ChatQueuedCell.reuseID)
        collectionView.register(ChatLiveFoldingCell.self, forCellWithReuseIdentifier: ChatLiveFoldingCell.reuseID)
        collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "ChatEmptyHostCell")
        collectionView.register(ChatTraceSummaryCell.self, forCellWithReuseIdentifier: ChatTraceSummaryCell.reuseID)
        collectionView.register(ChatTraceHostingCell.self, forCellWithReuseIdentifier: ChatTraceHostingCell.reuseID)
        collectionView.register(ChatLiveToolTailCell.self, forCellWithReuseIdentifier: ChatLiveToolTailCell.reuseID)
        collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "ChatSpacerCell")

        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(handleImmersiveBackgroundTap(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        collectionView.addGestureRecognizer(tap)
        immersiveRestoreTapGesture = tap

        dataSource = UICollectionViewDiffableDataSource<ChatListItemID, ChatListItemID>(
            collectionView: collectionView
        ) { [weak self] collectionView, indexPath, itemID in
            guard let self else { return UICollectionViewCell() }
            return self.dequeueAndConfigureCell(collectionView: collectionView, indexPath: indexPath, itemID: itemID)
        }
    }

    private func makeLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, layoutEnvironment in
            let width = max(240, layoutEnvironment.container.effectiveContentSize.width)
            guard let self,
                  let itemID = self.dataSource?.sectionIdentifier(for: sectionIndex) else {
                let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: .absolute(44))
                let item = NSCollectionLayoutItem(layoutSize: size)
                return NSCollectionLayoutSection(group: NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [item]))
            }
            let dim = self.heightDimension(for: itemID, width: width)
            let size = NSCollectionLayoutSize(widthDimension: .fractionalWidth(1.0), heightDimension: dim)
            let item = NSCollectionLayoutItem(layoutSize: size)
            let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [item])
            return NSCollectionLayoutSection(group: group)
        }
    }

    private func heightDimension(for itemID: ChatListItemID, width: CGFloat) -> NSCollectionLayoutDimension {
        switch itemID {
        case .emptyStatus:
            let cached = layoutCache.hostingHeight(for: "empty") ?? max(320, view.bounds.height * 0.55)
            return .estimated(cached)

        case .earlierButton:
            let h = 36 + ChatCellMetrics.rowSpacing
            lastMeasuredItemHeights[itemID] = h
            return .absolute(h)

        case .line(let id):
            guard let row = rowByID[id] else { return .absolute(44) }
            switch row.line.kind {
            case .user:
                let h = layoutCache.measureUser(row: row, collectionWidth: width, style: currentStyle).cellHeight
                lastMeasuredItemHeights[itemID] = h
                return .absolute(h)
            case .bot:
                let h = measureAssistant(row: row, width: width).cellHeight
                lastMeasuredItemHeights[itemID] = h
                return .absolute(h)
            case .steps:
                if Trace.shouldUseSummaryCell(for: row.line) {
                    let h = layoutCache.measureTraceSummary(row: row, collectionWidth: width, style: currentStyle).cellHeight
                    lastMeasuredItemHeights[itemID] = h
                    return .absolute(h)
                } else {
                    let key = traceHeightKey(row)
                    let est = layoutCache.hostingHeight(for: key) ?? 50
                    return .estimated(est)
                }
            case .note:
                let h = measureNoteEntry(row, width: width).cellHeight
                lastMeasuredItemHeights[itemID] = h
                return .absolute(h)
            }

        case .liveFolding:
            let h = 24 + ChatCellMetrics.rowSpacing
            lastMeasuredItemHeights[itemID] = h
            return .absolute(h)

        case .livePulse:
            let text = currentState?.streamPulse ?? ""
            let tail = text.split(separator: "\n", omittingEmptySubsequences: true).suffix(4).joined(separator: "\n")
            let h = layoutCache.measureLiveText(tail, collectionWidth: width, style: currentStyle, cardInsetH: Ink.Space.m, cardInsetV: Ink.Space.s).cellHeight
            lastMeasuredItemHeights[itemID] = h
            return .absolute(h)

        case .liveThinking:
            let h = ChatLiveThinkingCell.fixedHeight()
            lastMeasuredItemHeights[itemID] = h
            return .absolute(h)

        case .liveProse(let gen):
            let text = currentState?.streamText ?? ""
            let h = layoutCache.measureLiveStreamingProse(text: text, generation: gen, collectionWidth: width, style: currentStyle).cellHeight
            lastMeasuredItemHeights[itemID] = h
            return .absolute(h)

        case .liveToolTail:
            let chatKey = currentState?.chatKey ?? actions.chat.key
            let tail = actions.team.toolTail(for: chatKey)
            let h = ChatLiveToolTailCell.measureHeight(lines: tail.lines, style: currentStyle)
            lastMeasuredItemHeights[itemID] = h
            return .absolute(h)

        case .liveFailure:
            let err = currentState?.failureCardError ?? ""
            let working = currentState?.working ?? false
            let h = layoutCache.measureFailure(error: err, working: working, collectionWidth: width, style: currentStyle)
            lastMeasuredItemHeights[itemID] = h
            return .absolute(h)

        case .queued(let id):
            if let item = currentState?.queuedItems.first(where: { $0.id == id }) {
                let h = layoutCache.measureQueued(item, collectionWidth: width, style: currentStyle).cellHeight
                lastMeasuredItemHeights[itemID] = h
                return .absolute(h)
            }
            return .absolute(56)

        case .bottomSpacer:
            let h = ChatCellMetrics.bottomSpacerHeight
            lastMeasuredItemHeights[itemID] = h
            return .absolute(h)
        }
    }

    private func measureAssistant(row: ChatListRowItem, width: CGFloat) -> ChatLayoutCache.AssistantLayoutEntry {
        layoutCache.measureAssistant(
            row: row,
            collectionWidth: width,
            style: currentStyle,
            expandedThinking: expandedThinkingIDs.contains(row.line.id),
            expandedPulse: expandedPulseIDs.contains(row.line.id),
            expandedLookback: expandedLookbackIDs.contains(row.line.id),
            unfoldedSlices: unfoldedCodeSlices[row.line.id] ?? []
        )
    }

    private func measureNoteEntry(_ row: ChatListRowItem, width: CGFloat) -> ChatLayoutCache.NoteLayoutEntry {
        var adviceTitle: String?
        if !row.line.fold, let next = row.line.next {
            let parts = row.line.text.split(separator: "\n", maxSplits: 1).map(String.init)
            let advice = Explain.Advice(title: parts.first ?? row.line.text, detail: parts.count > 1 ? parts[1] : "", next: next)
            adviceTitle = advice.displayTitle
        }
        return layoutCache.measureNote(
            line: row.line,
            isLatestNote: row.isLatestNote,
            collectionWidth: width,
            style: currentStyle,
            adviceTitle: adviceTitle
        )
    }

    private func dequeueAndConfigureCell(
        collectionView: UICollectionView,
        indexPath: IndexPath,
        itemID: ChatListItemID
    ) -> UICollectionViewCell {
        let width = max(240, collectionView.bounds.width)
        switch itemID {
        case .emptyStatus:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "ChatEmptyHostCell", for: indexPath)
            configureEmptyCell(cell)
            return cell

        case .earlierButton:
            guard let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: ChatEarlierButtonCell.reuseID,
                for: indexPath
            ) as? ChatEarlierButtonCell else { return UICollectionViewCell() }
            cell.configure { [weak self] in
                self?.requestLoadEarlier()
            }
            return cell

        case .line(let id):
            guard let row = rowByID[id] else { return UICollectionViewCell() }
            return configureRowCell(collectionView: collectionView, indexPath: indexPath, row: row, width: width)

        case .liveFolding:
            return collectionView.dequeueReusableCell(withReuseIdentifier: ChatLiveFoldingCell.reuseID, for: indexPath)

        case .livePulse:
            guard let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: ChatLivePulseCell.reuseID,
                for: indexPath
            ) as? ChatLivePulseCell else { return UICollectionViewCell() }
            let raw = currentState?.streamPulse ?? ""
            let tail = raw.split(separator: "\n", omittingEmptySubsequences: true).suffix(4).joined(separator: "\n")
            let entry = layoutCache.measureLiveText(tail, collectionWidth: width, style: currentStyle, cardInsetH: Ink.Space.m, cardInsetV: Ink.Space.s)
            let speaker = currentState?.streamPulseSpeaker ?? (currentState?.isRoom == true ? nil : currentState?.defaultBot)
            cell.configure(
                text: tail,
                temper: Temper.of(speaker),
                entry: entry,
                style: currentStyle,
                onSelectionChanged: { [weak self] uuid, active in self?.handleSelectionChanged(uuid, active) },
                onQuoteExcerpt: { [weak self] excerpt in self?.actions.onQuoteExcerpt(excerpt) },
                onSaveNoteExcerpt: { [weak self] excerpt in self?.actions.onSaveNoteExcerpt("live-pulse", excerpt) },
                onSpeakExcerpt: { [weak self] excerpt in self?.actions.onSpeakExcerpt(excerpt) }
            )
            return cell

        case .liveThinking:
            guard let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: ChatLiveThinkingCell.reuseID,
                for: indexPath
            ) as? ChatLiveThinkingCell else { return UICollectionViewCell() }
            cell.configure(text: currentState?.streamReasoning ?? "")
            return cell

        case .liveProse(let gen):
            guard let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: ChatAssistantCell.reuseID,
                for: indexPath
            ) as? ChatAssistantCell else { return UICollectionViewCell() }
            let text = currentState?.streamText ?? ""
            let entry = layoutCache.measureLiveStreamingProse(text: text, generation: gen, collectionWidth: width, style: currentStyle)
            cell.configureLiveStreaming(
                generation: gen,
                entry: entry,
                style: currentStyle,
                hostViewController: self,
                actions: actions,
                callbacks: makeAssistantCallbacks(lineID: "streaming-\(gen)")
            )
            return cell

        case .liveToolTail:
            guard let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: ChatLiveToolTailCell.reuseID,
                for: indexPath
            ) as? ChatLiveToolTailCell else { return UICollectionViewCell() }
            let chatKey = currentState?.chatKey ?? actions.chat.key
            let tail = actions.team.toolTail(for: chatKey)
            let expected = lastMeasuredItemHeights[.liveToolTail] ?? -1
            cell.configure(tail: tail, style: currentStyle, expectedHeight: expected) { [weak self] h in
                self?.handleLiveToolTailHeightChanged(h)
            }
            return cell

        case .liveFailure:
            guard let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: ChatLiveFailureCell.reuseID,
                for: indexPath
            ) as? ChatLiveFailureCell else { return UICollectionViewCell() }
            cell.configure(error: currentState?.failureCardError ?? "", working: currentState?.working ?? false) { [weak self] in
                self?.actions.bridge.onRetry()
            }
            return cell

        case .queued(let id):
            guard let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: ChatQueuedCell.reuseID,
                for: indexPath
            ) as? ChatQueuedCell,
                  let item = currentState?.queuedItems.first(where: { $0.id == id }) else {
                return UICollectionViewCell()
            }
            let entry = layoutCache.measureQueued(item, collectionWidth: width, style: currentStyle)
            cell.configure(
                item: item,
                entry: entry,
                working: currentState?.working ?? false,
                sendingBlocked: currentState?.sendingBlocked ?? false,
                onWithdraw: { [weak self] in self?.actions.bridge.onWithdrawQueued(item) },
                onSendNow: { [weak self] in self?.actions.bridge.onSendQueuedNow() }
            )
            return cell

        case .bottomSpacer:
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "ChatSpacerCell", for: indexPath)
            cell.backgroundColor = .clear
            cell.contentView.backgroundColor = .clear
            return cell
        }
    }

    private func configureRowCell(
        collectionView: UICollectionView,
        indexPath: IndexPath,
        row: ChatListRowItem,
        width: CGFloat
    ) -> UICollectionViewCell {
        switch row.line.kind {
        case .user:
            guard let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: ChatUserCell.reuseID,
                for: indexPath
            ) as? ChatUserCell else { return UICollectionViewCell() }
            let entry = layoutCache.measureUser(row: row, collectionWidth: width, style: currentStyle)
            cell.onQuoteExcerpt = { [weak self] excerpt in self?.actions.onQuoteExcerpt(excerpt) }
            cell.onSaveNoteExcerpt = { [weak self] lineID, excerpt in self?.actions.onSaveNoteExcerpt(lineID, excerpt) }
            cell.onSpeakExcerpt = { [weak self] excerpt in self?.actions.onSpeakExcerpt(excerpt) }
            cell.onSelectionChanged = { [weak self] uuid, active in self?.handleSelectionChanged(uuid, active) }
            cell.configure(row: row, entry: entry, style: currentStyle, hostViewController: self, actions: actions)
            return cell

        case .bot:
            guard let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: ChatAssistantCell.reuseID,
                for: indexPath
            ) as? ChatAssistantCell else { return UICollectionViewCell() }
            let entry = measureAssistant(row: row, width: width)
            let transfer = pendingSelectionTransfers.removeValue(forKey: row.line.id)
            let revealTransfer = pendingRevealTransfers.removeValue(forKey: row.line.id)
            cell.configure(
                row: row,
                entry: entry,
                style: currentStyle,
                expandedThinking: expandedThinkingIDs.contains(row.line.id),
                expandedPulse: expandedPulseIDs.contains(row.line.id),
                expandedLookback: expandedLookbackIDs.contains(row.line.id),
                unfoldedSlices: unfoldedCodeSlices[row.line.id] ?? [],
                hostViewController: self,
                actions: actions,
                callbacks: makeAssistantCallbacks(lineID: row.line.id),
                transferredSelection: transfer,
                transferredReveal: revealTransfer
            )
            return cell

        case .steps:
            if Trace.shouldUseSummaryCell(for: row.line) {
                guard let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: ChatTraceSummaryCell.reuseID,
                    for: indexPath
                ) as? ChatTraceSummaryCell else { return UICollectionViewCell() }
                let entry = layoutCache.measureTraceSummary(row: row, collectionWidth: width, style: currentStyle)
                let lineID = row.line.id
                cell.configure(row: row, entry: entry, style: currentStyle) { [weak self] in
                    guard let self else { return }
                    let targetLine = self.rowByID[lineID]?.line ?? row.line
                    self.presentTraceDetailSheet(for: targetLine)
                }
                return cell
            }
            guard let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: ChatTraceHostingCell.reuseID,
                for: indexPath
            ) as? ChatTraceHostingCell else { return UICollectionViewCell() }
            cell.configure(
                row: row,
                actions: actions,
                onHeightChanged: { [weak self] updatedRow, h in
                    guard let self else { return }
                    self.handleDynamicHostHeight(key: self.traceHeightKey(updatedRow), height: h)
                }
            )
            return cell

        case .note:
            guard let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: ChatNoteCell.reuseID,
                for: indexPath
            ) as? ChatNoteCell else { return UICollectionViewCell() }
            let entry = measureNoteEntry(row, width: width)
            cell.configure(row: row, entry: entry, actions: actions)
            return cell
        }
    }

    private func configureEmptyCell(_ cell: UICollectionViewCell) {
        cell.backgroundColor = .clear
        cell.contentView.backgroundColor = .clear
        let makeEmpty = makeEmptyView
        cell.contentConfiguration = UIHostingConfiguration {
            if let makeEmpty {
                makeEmpty()
                    .padding(.horizontal, Ink.Space.page)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [weak self] h in
                        self?.handleDynamicHostHeight(key: "empty", height: h)
                    }
            }
        }
        .margins(.all, 0)
        .background(.clear)
    }

    private var pendingSelectionTransfers: [String: ChatProseSelectionSnapshot] = [:]
    private var pendingRevealTransfers: [String: ChatRevealHandoff] = [:]
    private var settlingRevealID: String?

    private func makeAssistantCallbacks(lineID: String) -> ChatAssistantCell.Callbacks {
        ChatAssistantCell.Callbacks(
            onToggleThinking: { [weak self] in
                self?.toggleThinking(for: lineID)
            },
            onTogglePulse: { [weak self] in
                self?.togglePulse(for: lineID)
            },
            onToggleLookback: { [weak self] in
                self?.toggleLookback(for: lineID)
            },
            onToggleCodeFold: { [weak self] sliceIndex in
                self?.toggleCodeFold(for: lineID, sliceIndex: sliceIndex)
            },
            onBlockHeightChanged: { [weak self] ownerID, blockKey, h in
                self?.handleDynamicBlockHeight(ownerID: ownerID, key: blockKey, height: h)
            },
            onFormulaHeightResolved: { [weak self] ownerID, blockKey, h in
                self?.handleDynamicBlockHeight(ownerID: ownerID, key: blockKey, height: h)
            },
            onSelectionChanged: { [weak self] uuid, active in
                self?.handleSelectionChanged(uuid, active)
            },
            onQuoteExcerpt: { [weak self] excerpt in
                self?.actions.onQuoteExcerpt(excerpt)
            },
            onSpeakExcerpt: { [weak self] excerpt in
                self?.actions.onSpeakExcerpt(excerpt)
            },
            onSaveNoteExcerpt: { [weak self] ownerLineID, excerpt in
                self?.actions.onSaveNoteExcerpt(ownerLineID, excerpt)
            },
            onShareText: { [weak self] text in
                self?.presentShareSheet(for: text)
            },
            onRevealFrame: { [weak self] completed in
                self?.followRevealFrame(ownerID: lineID, completed: completed)
            }
        )
    }

    private func presentTraceDetailSheet(for line: ChatLine) {
        guard !isDismantled, presentedViewController == nil else { return }
        let latestLine = rowByID[line.id]?.line ?? line
        let model = ChatTraceDetailSheetModel(line: latestLine)
        activeTraceSheetModel = model
        activeTraceSheetLineID = latestLine.id
        let sheet = ChatTraceDetailSheetView(model: model, actions: actions) { [weak self] in
            if self?.activeTraceSheetModel === model {
                self?.activeTraceSheetVC = nil
                self?.activeTraceSheetModel = nil
                self?.activeTraceSheetLineID = nil
            }
        }
        let vc = UIHostingController(rootView: sheet)
        activeTraceSheetVC = vc
        present(vc, animated: true)
    }

    private func presentShareSheet(for text: String) {
        let activity = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        if let pop = activity.popoverPresentationController {
            pop.sourceView = view
            pop.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.maxY - 80, width: 1, height: 1)
        }
        present(activity, animated: true)
    }

    // MARK: - Expand / Collapse Toggles

    private func toggleThinking(for id: String) {
        if expandedThinkingIDs.contains(id) {
            expandedThinkingIDs.remove(id)
        } else {
            expandedThinkingIDs.insert(id)
        }
        reconfigureRowInPlace(id: id)
    }

    private func togglePulse(for id: String) {
        if expandedPulseIDs.contains(id) {
            expandedPulseIDs.remove(id)
        } else {
            expandedPulseIDs.insert(id)
        }
        reconfigureRowInPlace(id: id)
    }

    private func toggleLookback(for id: String) {
        if expandedLookbackIDs.contains(id) {
            expandedLookbackIDs.remove(id)
        } else {
            expandedLookbackIDs.insert(id)
        }
        reconfigureRowInPlace(id: id)
    }

    private func toggleCodeFold(for id: String, sliceIndex: Int) {
        var set = unfoldedCodeSlices[id] ?? []
        if set.contains(sliceIndex) {
            set.remove(sliceIndex)
        } else {
            set.insert(sliceIndex)
        }
        unfoldedCodeSlices[id] = set
        reconfigureRowInPlace(id: id)
    }

    private func reconfigureRowInPlace(id: String) {
        guard collectionView != nil,
              let row = rowByID[id],
              let sectionIdx = itemIndexByID[.line(id)] else { return }
        let width = max(240, collectionView.bounds.width)
        let entry = measureAssistant(row: row, width: width)
        let indexPath = IndexPath(item: 0, section: sectionIdx)

        preserveReadingAnchorDuring {
            if let cell = collectionView.cellForItem(at: indexPath) as? ChatAssistantCell {
                cell.updateSettledInPlace(
                    row: row,
                    entry: entry,
                    style: currentStyle,
                    expandedThinking: expandedThinkingIDs.contains(id),
                    expandedPulse: expandedPulseIDs.contains(id),
                    expandedLookback: expandedLookbackIDs.contains(id),
                    unfoldedSlices: unfoldedCodeSlices[id] ?? []
                )
            }
            collectionView.collectionViewLayout.invalidateLayout()
            collectionView.layoutIfNeeded()
        }
    }

    private func handleDynamicBlockHeight(ownerID: String, key: String, height: CGFloat) {
        guard layoutCache.setBlockHeightOverride(height, key: key, ownerID: ownerID) else { return }
        pendingDynamicOwnerIDs.insert(ownerID)
        scheduleDynamicLayoutRefresh()
    }

    private func handleDynamicHostHeight(key: String, height: CGFloat) {
        guard layoutCache.setHostingHeight(height, for: key) else { return }
        scheduleDynamicLayoutRefresh()
    }

    private func handleLiveToolTailHeightChanged(_ height: CGFloat) {
        let rounded = ceil(height)
        if let prev = lastMeasuredItemHeights[.liveToolTail], abs(prev - rounded) <= 0.5 {
            return
        }
        lastMeasuredItemHeights[.liveToolTail] = rounded
        scheduleDynamicLayoutRefresh()
    }

    private func applyPendingDynamicCellReconfigurations() {
        guard !pendingDynamicOwnerIDs.isEmpty, collectionView != nil else { return }
        let ownerIDs = pendingDynamicOwnerIDs
        pendingDynamicOwnerIDs.removeAll()
        let width = max(240, collectionView.bounds.width)
        for indexPath in collectionView.indexPathsForVisibleItems where indexPath.section < items.count {
            switch items[indexPath.section] {
            case .line(let lineID) where ownerIDs.contains(lineID):
                if let row = rowByID[lineID], row.line.kind == .bot {
                    let entry = measureAssistant(row: row, width: width)
                    if let cell = collectionView.cellForItem(at: indexPath) as? ChatAssistantCell {
                        cell.updateSettledInPlace(
                            row: row,
                            entry: entry,
                            style: currentStyle,
                            expandedThinking: expandedThinkingIDs.contains(lineID),
                            expandedPulse: expandedPulseIDs.contains(lineID),
                            expandedLookback: expandedLookbackIDs.contains(lineID),
                            unfoldedSlices: unfoldedCodeSlices[lineID] ?? []
                        )
                    }
                }
            case .liveProse(let gen):
                let liveOwner = "streaming-\(gen)"
                if ownerIDs.contains(liveOwner),
                   let cell = collectionView.cellForItem(at: indexPath) as? ChatAssistantCell {
                    let entry = layoutCache.measureLiveStreamingProse(
                        text: currentState?.streamText ?? "",
                        generation: gen,
                        collectionWidth: width,
                        style: currentStyle
                    )
                    cell.updateLiveStreamingInPlace(entry: entry, style: currentStyle)
                }
            default:
                break
            }
        }
    }

    private func scheduleDynamicLayoutRefresh() {
        if isUserTouchScrolling {
            needsDeferredDynamicRefresh = true
            return
        }
        guard !pendingDynamicRefresh else { return }
        pendingDynamicRefresh = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingDynamicRefresh = false
            guard !self.isDismantled, self.collectionView != nil, self.collectionView.bounds.width > 0 else { return }
            if self.isUserTouchScrolling {
                self.needsDeferredDynamicRefresh = true
                return
            }
            self.preserveReadingAnchorDuring {
                self.applyPendingDynamicCellReconfigurations()
                self.collectionView.collectionViewLayout.invalidateLayout()
                self.collectionView.layoutIfNeeded()
            }
            self.publishVisibleAndFooterMetrics()
        }
    }

    private func requestLoadEarlier() {
        guard !isDismantled,
              !isLoadingEarlierRequest,
              selectingOwnerIDs.isEmpty,
              (currentState?.canLoadEarlier ?? false) else { return }

        isLoadingEarlierRequest = true
        loadEarlierSawHostBusy = false
        loadEarlierGeneration &+= 1
        let generation = loadEarlierGeneration

        _ = scrollArbiter.beginHistoryPagination()
        actions.onFollowingChanged(false)

        loadEarlierResetTask?.cancel()
        loadEarlierResetTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard let self, !self.isDismantled, self.loadEarlierGeneration == generation else { return }
            if self.isLoadingEarlierRequest && !self.loadEarlierSawHostBusy && !(self.currentState?.isLoadingEarlier ?? false) {
                self.isLoadingEarlierRequest = false
            }
        }
        actions.onLoadEarlier()
    }

    // MARK: - State Synchronization

    func applyState(_ next: ChatListState) {
        guard !isDismantled else { return }
        if !isViewVisible, isViewLoaded, currentState != nil {
            deferredState = next
            return
        }
        let prev = currentState
        currentState = next

        if isLoadingEarlierRequest {
            if next.isLoadingEarlier {
                loadEarlierSawHostBusy = true
            }
            let prepended = prev != nil && (next.rows.first?.line.id != prev?.rows.first?.line.id || next.rows.count > (prev?.rows.count ?? 0))
            let hostFinished = loadEarlierSawHostBusy && !next.isLoadingEarlier
            if prepended || !next.canLoadEarlier || hostFinished {
                isLoadingEarlierRequest = false
                loadEarlierSawHostBusy = false
                loadEarlierResetTask?.cancel()
                loadEarlierResetTask = nil
            }
        }

        guard isViewLoaded else { return }

        if prev == nil {
            applyInitialState(next)
            return
        }
        guard let prev else { return }

        if prev.isEquivalent(to: next) {
            return
        }

        if prev.chatKey != next.chatKey {
            resetForChatSwitch(next)
            return
        }

        if (prev.hasStreaming && !next.hasStreaming)
            || (next.hasStreaming && prev.streamGeneration != next.streamGeneration)
        {
            layoutCache.pruneStaleStreamingState(
                activeStreamingOwnerID: next.hasStreaming ? "streaming-\(next.streamGeneration)" : nil,
                retainedRowIDs: Set(next.rows.map(\.line.id))
            )
            if !next.hasStreaming {
                lastKnownRevealLimit = nil
            }
        }

        let nextItems = buildItemIDs(for: next)
        let nextRowMap = Dictionary(uniqueKeysWithValues: next.rows.map { ($0.line.id, $0) })
        let structuralChanged = nextItems != items || prev.historyInView != next.historyInView

        if !structuralChanged {
            applyInPlaceUpdates(prev: prev, next: next, nextRowMap: nextRowMap)
            return
        }

        applyStructuralUpdate(prev: prev, next: next, nextItems: nextItems, nextRowMap: nextRowMap)
    }

    private func applyInitialState(_ state: ChatListState) {
        let nextItems = buildItemIDs(for: state)
        items = nextItems
        rebuildIndexMaps(rows: state.rows)

        var snapshot = NSDiffableDataSourceSnapshot<ChatListItemID, ChatListItemID>()
        snapshot.appendSections(nextItems)
        for id in nextItems {
            snapshot.appendItems([id], toSection: id)
        }
        dataSource.apply(snapshot, animatingDifferences: false)

        if collectionView.bounds.width > 0 {
            updateCollectionInsetsIfNeeded()
            collectionView.layoutIfNeeded()
            if !hasPerformedInitialScroll {
                if isPinnedToBottom && !state.historyInView && selectingOwnerIDs.isEmpty {
                    scrollToBottom(animated: false)
                }
                hasPerformedInitialScroll = true
                lastKnownContentWidth = collectionView.bounds.width
            }
            prewarmInitialWindow()
            publishVisibleAndFooterMetrics()
        }
    }

    private func resetForChatSwitch(_ next: ChatListState) {
        cancelAllPrefetches()
        cancelPrewarm()
        pendingDynamicOwnerIDs.removeAll()
        expandedThinkingIDs.removeAll()
        expandedPulseIDs.removeAll()
        expandedLookbackIDs.removeAll()
        unfoldedCodeSlices.removeAll()
        pendingSelectionTransfers.removeAll()
        pendingRevealTransfers.removeAll()
        settlingRevealID = nil
        lastKnownRevealLimit = nil
        if activeTraceSheetLineID != nil,
           activeTraceSheetModel != nil,
           let presented = presentedViewController,
           presented === activeTraceSheetVC {
            presented.dismiss(animated: false)
        }
        activeTraceSheetVC = nil
        activeTraceSheetModel = nil
        activeTraceSheetLineID = nil
        isLoadingEarlierRequest = false
        loadEarlierSawHostBusy = false
        loadEarlierResetTask?.cancel()
        loadEarlierResetTask = nil
        clearAllSelections()
        layoutCache.invalidateAll(clearOverrides: true)
        stopInsetDisplayLink()
        animatedScrollID &+= 1
        isPinnedToBottom = true
        isTrackingUserScroll = false
        needsDeferredDynamicRefresh = false
        needsDeferredStreamingResize = false
        lastMeasuredItemHeights.removeAll()
        lastScrollMetricsPublishTime = 0
        wasPinnedAtDragStart = false
        userMovedAwayFromBottomDuringDrag = false
        hasPerformedInitialScroll = false
        lastReportedReplyOwner = nil
        lastReportedReplyRect = .null
        lastReportedHeroTarget = nil
        if lastReportedActiveTurnID != nil {
            lastReportedActiveTurnID = nil
            if isInHostUpdate {
                Task { @MainActor [weak self] in
                    guard let self, !self.isDismantled else { return }
                    if self.lastReportedActiveTurnID == nil {
                        self.actions.onActiveTurnChanged(nil)
                    }
                }
            } else {
                actions.onActiveTurnChanged(nil)
            }
        }
        if let heroID = actions.currentPreparedHeroID() {
            if isInHostUpdate {
                Task { @MainActor [weak self] in
                    guard let self, !self.isDismantled else { return }
                    self.actions.onClearPhotoHero(heroID)
                }
            } else {
                actions.onClearPhotoHero(heroID)
            }
        }
        scheduleHostMetricsFlush()

        items = buildItemIDs(for: next)
        rebuildIndexMaps(rows: next.rows)

        UIView.performWithoutAnimation {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            isProgrammaticScroll = true

            var snapshot = NSDiffableDataSourceSnapshot<ChatListItemID, ChatListItemID>()
            snapshot.appendSections(items)
            for id in items { snapshot.appendItems([id], toSection: id) }
            dataSource.apply(snapshot, animatingDifferences: false)

            if collectionView.bounds.width > 0 {
                updateCollectionInsetsIfNeeded()
                collectionView.layoutIfNeeded()
                scrollToBottom(animated: false)
                hasPerformedInitialScroll = true
                lastKnownContentWidth = collectionView.bounds.width
                prewarmInitialWindow()
            }

            isProgrammaticScroll = false
            CATransaction.commit()
        }
        publishVisibleAndFooterMetrics()
    }

    private func applyInPlaceUpdates(
        prev: ChatListState,
        next: ChatListState,
        nextRowMap: [String: ChatListRowItem]
    ) {
        let oldRowMap = rowByID
        rowByID = nextRowMap
        if prev.rows != next.rows {
            rebuildTurnUserIndex()
            lastJumpPrewarmKey = nil
        }
        let width = max(240, collectionView.bounds.width)
        var layoutMayHaveChanged = false
        var checkedItemIDs: Set<ChatListItemID> = []
        var cellTypeReloadIDs: [ChatListItemID] = []

        if let sheetLineID = activeTraceSheetLineID,
           let updated = nextRowMap[sheetLineID],
           activeTraceSheetModel?.line != updated.line {
            activeTraceSheetModel?.line = updated.line
        }

        for indexPath in collectionView.indexPathsForVisibleItems {
            guard indexPath.section < items.count else { continue }
            let itemID = items[indexPath.section]
            switch itemID {
            case .emptyStatus:
                if Self.emptyContentChanged(prev: prev, next: next),
                   let cell = collectionView.cellForItem(at: indexPath) {
                    configureEmptyCell(cell)
                    layoutMayHaveChanged = true
                }

            case .liveProse(let gen):
                if prev.streamText != next.streamText {
                    checkedItemIDs.insert(itemID)
                    let entry = layoutCache.measureLiveStreamingProse(text: next.streamText, generation: gen, collectionWidth: width, style: currentStyle)
                    if let cell = collectionView.cellForItem(at: indexPath) as? ChatAssistantCell {
                        cell.updateLiveStreamingInPlace(entry: entry, style: currentStyle)
                    }
                    let prevH = lastMeasuredItemHeights[itemID]
                    if prevH == nil || abs((prevH ?? 0) - entry.cellHeight) > 0.5 {
                        lastMeasuredItemHeights[itemID] = entry.cellHeight
                        layoutMayHaveChanged = true
                    }
                }

            case .livePulse:
                if prev.streamPulse != next.streamPulse {
                    checkedItemIDs.insert(itemID)
                    let tail = next.streamPulse.split(separator: "\n", omittingEmptySubsequences: true).suffix(4).joined(separator: "\n")
                    let entry = layoutCache.measureLiveText(tail, collectionWidth: width, style: currentStyle, cardInsetH: Ink.Space.m, cardInsetV: Ink.Space.s)
                    if let cell = collectionView.cellForItem(at: indexPath) as? ChatLivePulseCell {
                        let speaker = next.streamPulseSpeaker ?? (next.isRoom ? nil : next.defaultBot)
                        cell.configure(
                            text: tail,
                            temper: Temper.of(speaker),
                            entry: entry,
                            style: currentStyle,
                            onSelectionChanged: { [weak self] uuid, active in self?.handleSelectionChanged(uuid, active) },
                            onQuoteExcerpt: { [weak self] excerpt in self?.actions.onQuoteExcerpt(excerpt) },
                            onSaveNoteExcerpt: { [weak self] excerpt in self?.actions.onSaveNoteExcerpt("live-pulse", excerpt) },
                            onSpeakExcerpt: { [weak self] excerpt in self?.actions.onSpeakExcerpt(excerpt) }
                        )
                    }
                    let prevH = lastMeasuredItemHeights[itemID]
                    if prevH == nil || abs((prevH ?? 0) - entry.cellHeight) > 0.5 {
                        lastMeasuredItemHeights[itemID] = entry.cellHeight
                        layoutMayHaveChanged = true
                    }
                }

            case .liveThinking:
                if prev.streamReasoning != next.streamReasoning,
                   let cell = collectionView.cellForItem(at: indexPath) as? ChatLiveThinkingCell {
                    cell.configure(text: next.streamReasoning)
                }

            case .liveFailure:
                if (prev.failureCardError != next.failureCardError || prev.working != next.working),
                   let cell = collectionView.cellForItem(at: indexPath) as? ChatLiveFailureCell {
                    cell.configure(error: next.failureCardError ?? "", working: next.working) { [weak self] in
                        self?.actions.bridge.onRetry()
                    }
                    layoutMayHaveChanged = true
                }

            case .queued(let qid):
                if let qItem = next.queuedItems.first(where: { $0.id == qid }),
                   let cell = collectionView.cellForItem(at: indexPath) as? ChatQueuedCell {
                    let entry = layoutCache.measureQueued(qItem, collectionWidth: width, style: currentStyle)
                    cell.configure(
                        item: qItem,
                        entry: entry,
                        working: next.working,
                        sendingBlocked: next.sendingBlocked,
                        onWithdraw: { [weak self] in self?.actions.bridge.onWithdrawQueued(qItem) },
                        onSendNow: { [weak self] in self?.actions.bridge.onSendQueuedNow() }
                    )
                    let prevH = lastMeasuredItemHeights[itemID]
                    if prevH == nil || abs((prevH ?? 0) - entry.cellHeight) > 0.5 {
                        lastMeasuredItemHeights[itemID] = entry.cellHeight
                        layoutMayHaveChanged = true
                    }
                }

            case .line(let lineID):
                guard let newRow = nextRowMap[lineID], oldRowMap[lineID] != newRow else { continue }
                checkedItemIDs.insert(itemID)
                let newHeight = updateVisibleRowCell(at: indexPath, newRow: newRow, width: width, reloadIDs: &cellTypeReloadIDs)
                if let newHeight {
                    let prevH = lastMeasuredItemHeights[itemID]
                    if prevH == nil || abs((prevH ?? 0) - newHeight) > 0.5 {
                        lastMeasuredItemHeights[itemID] = newHeight
                        layoutMayHaveChanged = true
                    }
                } else {
                    layoutMayHaveChanged = true
                }

            default:
                break
            }
        }

        if !cellTypeReloadIDs.isEmpty {
            UIView.performWithoutAnimation {
                var snapshot = dataSource.snapshot()
                snapshot.reloadItems(cellTypeReloadIDs)
                dataSource.apply(snapshot, animatingDifferences: false)
            }
            layoutMayHaveChanged = true
        }

        // Also check offscreen height changes for fresh handoff / streaming / row text edits.
        if !layoutMayHaveChanged && prev.streamText != next.streamText {
            let liveID = ChatListItemID.liveProse(next.streamGeneration)
            if !checkedItemIDs.contains(liveID) {
                let entry = layoutCache.measureLiveStreamingProse(
                    text: next.streamText,
                    generation: next.streamGeneration,
                    collectionWidth: width,
                    style: currentStyle
                )
                let prevH = lastMeasuredItemHeights[liveID]
                if prevH == nil || abs((prevH ?? 0) - entry.cellHeight) > 0.5 {
                    lastMeasuredItemHeights[liveID] = entry.cellHeight
                    layoutMayHaveChanged = true
                }
            }
        }
        if !layoutMayHaveChanged && prev.streamPulse != next.streamPulse {
            if !checkedItemIDs.contains(.livePulse) {
                let tail = next.streamPulse.split(separator: "\n", omittingEmptySubsequences: true).suffix(4).joined(separator: "\n")
                let entry = layoutCache.measureLiveText(tail, collectionWidth: width, style: currentStyle, cardInsetH: Ink.Space.m, cardInsetV: Ink.Space.s)
                let prevH = lastMeasuredItemHeights[.livePulse]
                if prevH == nil || abs((prevH ?? 0) - entry.cellHeight) > 0.5 {
                    lastMeasuredItemHeights[.livePulse] = entry.cellHeight
                    layoutMayHaveChanged = true
                }
            }
        }
        if !layoutMayHaveChanged && prev.rows != next.rows {
            for newRow in next.rows {
                let id = ChatListItemID.line(newRow.line.id)
                guard !checkedItemIDs.contains(id), oldRowMap[newRow.line.id] != newRow else { continue }
                let newHeight = measuredHeightForRow(newRow, width: width)
                if let newHeight {
                    let prevH = lastMeasuredItemHeights[id]
                    if prevH == nil || abs((prevH ?? 0) - newHeight) > 0.5 {
                        lastMeasuredItemHeights[id] = newHeight
                        layoutMayHaveChanged = true
                        break
                    }
                } else {
                    layoutMayHaveChanged = true
                    break
                }
            }
        }

        if layoutMayHaveChanged && collectionView.bounds.width > 0 {
            if isUserTouchScrolling && !isPinnedToBottom {
                needsDeferredStreamingResize = true
            } else {
                applyStreamingResizePreservingScroll()
            }
        }
        if prev.headerHeight != next.headerHeight {
            updateCollectionInsetsIfNeeded()
        }
        publishVisibleAndFooterMetrics()
    }

    private func measuredHeightForRow(_ row: ChatListRowItem, width: CGFloat) -> CGFloat? {
        switch row.line.kind {
        case .user:
            return layoutCache.measureUser(row: row, collectionWidth: width, style: currentStyle).cellHeight
        case .bot:
            return measureAssistant(row: row, width: width).cellHeight
        case .steps:
            if Trace.shouldUseSummaryCell(for: row.line) {
                return layoutCache.measureTraceSummary(row: row, collectionWidth: width, style: currentStyle).cellHeight
            }
            return nil
        case .note:
            return measureNoteEntry(row, width: width).cellHeight
        }
    }

    @discardableResult
    private func updateVisibleRowCell(
        at indexPath: IndexPath,
        newRow: ChatListRowItem,
        width: CGFloat,
        reloadIDs: inout [ChatListItemID]
    ) -> CGFloat? {
        switch newRow.line.kind {
        case .bot:
            let entry = measureAssistant(row: newRow, width: width)
            let revealTransfer = pendingRevealTransfers.removeValue(forKey: newRow.line.id)
            if let cell = collectionView.cellForItem(at: indexPath) as? ChatAssistantCell {
                cell.updateSettledInPlace(
                    row: newRow,
                    entry: entry,
                    style: currentStyle,
                    expandedThinking: expandedThinkingIDs.contains(newRow.line.id),
                    expandedPulse: expandedPulseIDs.contains(newRow.line.id),
                    expandedLookback: expandedLookbackIDs.contains(newRow.line.id),
                    unfoldedSlices: unfoldedCodeSlices[newRow.line.id] ?? [],
                    transferredReveal: revealTransfer
                )
            }
            return entry.cellHeight
        case .user:
            let entry = layoutCache.measureUser(row: newRow, collectionWidth: width, style: currentStyle)
            if let cell = collectionView.cellForItem(at: indexPath) as? ChatUserCell {
                cell.configure(row: newRow, entry: entry, style: currentStyle, hostViewController: self, actions: actions)
            }
            return entry.cellHeight
        case .steps:
            if Trace.shouldUseSummaryCell(for: newRow.line) {
                let entry = layoutCache.measureTraceSummary(row: newRow, collectionWidth: width, style: currentStyle)
                if let cell = collectionView.cellForItem(at: indexPath) as? ChatTraceSummaryCell {
                    cell.updateLineInPlace(row: newRow, entry: entry, style: currentStyle)
                    return entry.cellHeight
                }
                reloadIDs.append(.line(newRow.line.id))
                return entry.cellHeight
            } else {
                if let cell = collectionView.cellForItem(at: indexPath) as? ChatTraceHostingCell {
                    cell.updateLineInPlace(newRow)
                    return nil
                }
                reloadIDs.append(.line(newRow.line.id))
                return nil
            }
        case .note:
            let entry = measureNoteEntry(newRow, width: width)
            if let cell = collectionView.cellForItem(at: indexPath) as? ChatNoteCell {
                cell.configure(row: newRow, entry: entry, actions: actions)
            }
            return entry.cellHeight
        }
    }

    private func applyStructuralUpdate(
        prev: ChatListState,
        next: ChatListState,
        nextItems: [ChatListItemID],
        nextRowMap: [String: ChatListRowItem]
    ) {
        let oldRowMap = rowByID
        let prependedCount: Int
        if let oldFirstID = prev.rows.first?.line.id,
           let oldFirstInNext = next.rows.firstIndex(where: { $0.line.id == oldFirstID }),
           oldFirstInNext > 0 {
            prependedCount = oldFirstInNext
        } else {
            prependedCount = 0
        }
        let loadedInitialRows = (prev.rows.isEmpty && !next.rows.isEmpty)
            || (!prev.loaded && next.loaded && !next.rows.isEmpty)

        // The model can commit before the first tile returns, or before a live row is mounted at all.
        if !next.hasStreaming, let targetBotID = next.fresh?.id,
           prev.hasStreaming || prev.fresh?.id != targetBotID {
            let liveCell = itemIndexByID[.liveProse(prev.streamGeneration)].flatMap {
                collectionView.cellForItem(at: IndexPath(item: 0, section: $0)) as? ChatAssistantCell
            }
            if let snap = liveCell?.currentProseSelectionSnapshot() {
                pendingSelectionTransfers[targetBotID] = snap
            } else if currentStyle.fade && !currentStyle.reduceMotion {
                let handoff = liveCell?.captureRevealHandoff()
                if let handoff {
                    pendingRevealTransfers[targetBotID] = handoff
                    settlingRevealID = targetBotID
                } else if canAutoPinToBottom, liveCell?.hasPaintedLiveTail != true {
                    pendingRevealTransfers[targetBotID] = .unseenReply
                    settlingRevealID = targetBotID
                }
            }
        }

        let shouldPinToBottom = canAutoPinToBottom
        let switchedHistoryView = prev.historyInView != next.historyInView
        let anchor: (id: ChatListItemID, visualY: CGFloat)? = (!shouldPinToBottom && !switchedHistoryView && pendingScrollRequest == nil)
            ? topVisibleAnchor()
            : nil

        items = nextItems
        cancelAllPrefetches()
        lastMeasuredItemHeights.removeAll()
        rebuildIndexMaps(rows: next.rows)

        UIView.performWithoutAnimation {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let wasProgrammatic = isProgrammaticScroll
            isProgrammaticScroll = true

            var snapshot = NSDiffableDataSourceSnapshot<ChatListItemID, ChatListItemID>()
            snapshot.appendSections(nextItems)
            for id in nextItems {
                snapshot.appendItems([id], toSection: id)
            }
            dataSource.apply(snapshot, animatingDifferences: false)

            // Update existing visible cells whose payload changed even though their ID stayed in the snapshot.
            let width = max(240, collectionView.bounds.width)
            if let sheetLineID = activeTraceSheetLineID,
               let updated = nextRowMap[sheetLineID],
               activeTraceSheetModel?.line != updated.line {
                activeTraceSheetModel?.line = updated.line
            }
            var cellTypeReloadIDs: [ChatListItemID] = []
            for indexPath in collectionView.indexPathsForVisibleItems where indexPath.section < items.count {
                if case .line(let lineID) = items[indexPath.section],
                   let newRow = nextRowMap[lineID],
                   oldRowMap[lineID] != nil,
                   oldRowMap[lineID] != newRow {
                    updateVisibleRowCell(at: indexPath, newRow: newRow, width: width, reloadIDs: &cellTypeReloadIDs)
                }
            }
            if !cellTypeReloadIDs.isEmpty {
                var reloadSnap = dataSource.snapshot()
                reloadSnap.reloadItems(cellTypeReloadIDs)
                dataSource.apply(reloadSnap, animatingDifferences: false)
            }

            collectionView.layoutIfNeeded()

            var snapped = false
            if let req = pendingScrollRequest,
               let targetIdx = itemIndexByID[.line(req.id)] {
                pendingScrollRequest = nil
                performScrollToRow(section: targetIdx, anchor: req.anchor, animated: false)
                snapped = true
            } else if shouldPinToBottom {
                scrollToBottom(animated: false, layoutIfNeeded: false, publishMetrics: false)
                snapped = true
            } else if let anchor {
                _ = commitContentOffset(
                    source: prependedCount > 0 ? .historyPagination : .userAnchorPreserve,
                    anchor: anchor,
                    animated: false,
                    layoutIfNeeded: true,
                    publishMetrics: false
                )
                snapped = true
            }

            if snapped {
                animatedScrollID &+= 1
                isProgrammaticScroll = false
            } else {
                isProgrammaticScroll = wasProgrammatic
            }
            CATransaction.commit()
        }

        lastScrollOffsetY = collectionView.contentOffset.y
        updateCollectionInsetsIfNeeded()
        if collectionView.bounds.width > 0 {
            if loadedInitialRows || switchedHistoryView {
                prewarmInitialWindow()
            } else if prependedCount > 0 {
                prewarmPrependedRows(prependedRowCount: prependedCount)
            }
        }
        publishVisibleAndFooterMetrics()
    }

    private static func emptyContentChanged(prev: ChatListState, next: ChatListState) -> Bool {
        guard prev.loaded == next.loaded,
              prev.reach == next.reach,
              prev.emptyPetState == next.emptyPetState,
              prev.starters.count == next.starters.count else {
            return true
        }
        return zip(prev.starters, next.starters).contains { lhs, rhs in
            lhs.0 != rhs.0 || lhs.1 != rhs.1 || lhs.2 != rhs.2
        }
    }

    private func buildItemIDs(for state: ChatListState) -> [ChatListItemID] {
        var out: [ChatListItemID] = []
        if !state.loaded || (state.rows.isEmpty && !state.hasStreaming && state.streamPulse.isEmpty && state.streamReasoning.isEmpty) {
            out.append(.emptyStatus)
        }
        if state.canLoadEarlier {
            out.append(.earlierButton)
        }
        for row in state.rows {
            out.append(.line(row.line.id))
        }
        if !state.historyInView {
            if state.isCompressing { out.append(.liveFolding) }
            if !state.streamPulse.isEmpty { out.append(.livePulse) }
            if !state.streamReasoning.isEmpty && !state.hasStreaming { out.append(.liveThinking) }
            if state.hasStreaming { out.append(.liveProse(state.streamGeneration)) }
            if state.showToolTail { out.append(.liveToolTail) }
            if state.failureCardError != nil { out.append(.liveFailure) }
            for q in state.queuedItems { out.append(.queued(q.id)) }
        }
        out.append(.bottomSpacer)
        return out
    }

    private func rebuildIndexMaps(rows: [ChatListRowItem]) {
        itemIndexByID.removeAll(keepingCapacity: true)
        for (idx, item) in items.enumerated() {
            itemIndexByID[item] = idx
        }
        rowByID.removeAll(keepingCapacity: true)
        for row in rows {
            rowByID[row.line.id] = row
        }
        rebuildTurnUserIndex()
    }

    private func rebuildTurnUserIndex() {
        var firstUser: String?
        var lastUser: String?
        for item in items {
            if case .line(let id) = item, rowByID[id]?.line.kind == .user {
                if firstUser == nil { firstUser = id }
                lastUser = id
            }
        }
        firstUserRowID = firstUser
        lastUserRowID = lastUser

        turnUserIDBySection = []
        turnUserIDBySection.reserveCapacity(items.count)
        var currentUserID = firstUser
        for item in items {
            if case .line(let id) = item, rowByID[id]?.line.kind == .user {
                currentUserID = id
            }
            turnUserIDBySection.append(currentUserID)
        }
    }

    // MARK: - Typography, Theme, Layout & Insets

    private func startStyleObservationIfVisible() {
        guard isViewVisible, !isDismantled else { return }
        styleObservationGeneration &+= 1
        let generation = styleObservationGeneration
        withObservationTracking {
            _ = ChatListStyle.current(traits: traitCollection, reduceMotion: currentState?.reduceMotion ?? false)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, !self.isDismantled, self.styleObservationGeneration == generation else { return }
                guard self.isViewVisible else { return }
                self.refreshTypographyAndTheme()
                self.startStyleObservationIfVisible()
            }
        }
    }

    func refreshTypographyAndTheme() {
        let hideEdge = Theme.shared.reduceVisualEffects
        if collectionView?.topEdgeEffect.isHidden != hideEdge {
            collectionView?.topEdgeEffect.isHidden = hideEdge
        }
        guard isViewVisible else { return }
        let nextStyle = ChatListStyle.current(traits: traitCollection, reduceMotion: currentState?.reduceMotion ?? false)
        view.backgroundColor = UIColor(Ink.paper)
        guard nextStyle != currentStyle else { return }
        topBarNeedsRemeasure = true
        updateTopEdgeContainerLayout(animated: false)
        currentStyle = nextStyle
        cancelAllPrefetches()
        cancelPrewarm()
        pendingDynamicOwnerIDs.removeAll()
        lastMeasuredItemHeights.removeAll()
        layoutCache.invalidateAll()
        ChatTextTileRenderer.shared.invalidateAll()
        guard collectionView != nil, collectionView.bounds.width > 0 else { return }
        preserveReadingAnchorDuring {
            reconfigureAllVisibleCells()
            collectionView.collectionViewLayout.invalidateLayout()
            collectionView.layoutIfNeeded()
        }
        prewarmInitialWindow()
        publishVisibleAndFooterMetrics()
    }

    private func currentUserAvatarSignature() -> String {
        let face = UserDefaults.standard.string(forKey: "me.avatar") ?? ""
        let legacyPet = CompanionAvatar.legacyPack(for: face)?.dir.path ?? ""
        let photoID: Int
        if face == "photo", let img = Avatars.image("me") {
            photoID = ObjectIdentifier(img).hashValue
        } else {
            photoID = 0
        }
        return "\(face)|\(legacyPet)|\(photoID)"
    }

    private func handleUserDefaultsChanged() {
        let hideEdge = Theme.shared.reduceVisualEffects
        if collectionView?.topEdgeEffect.isHidden != hideEdge {
            collectionView?.topEdgeEffect.isHidden = hideEdge
        }
        guard isViewVisible else {
            pendingAvatarRefresh = true
            return
        }
        let nextTraceOpen = Pref.traceOpen
        if nextTraceOpen != lastObservedTraceOpen {
            lastObservedTraceOpen = nextTraceOpen
            reloadTraceRowsForPreferenceChange()
        }
        let nextSignature = currentUserAvatarSignature()
        guard nextSignature != lastObservedUserAvatarSignature else { return }
        lastObservedUserAvatarSignature = nextSignature
        refreshVisibleUserAvatars()
    }

    private func handleMountedFoldersChanged() {
        guard !isDismantled else { return }
        Trace.clearSummaryCache()
        inFlightTracePrewarmIDs.removeAll()
        for task in tracePrewarmTasks.values {
            task.cancel()
        }
        tracePrewarmTasks.removeAll()
        guard isViewVisible else {
            pendingMountRefresh = true
            return
        }
        reloadTraceRowsForPreferenceChange()
        prewarmTraceRows(in: Array(items.indices))
    }

    private func reloadTraceRowsForPreferenceChange() {
        guard collectionView != nil, dataSource != nil else { return }
        let stepIDs = items.filter { itemID in
            if case .line(let id) = itemID {
                return rowByID[id]?.line.kind == .steps
            }
            return false
        }
        guard !stepIDs.isEmpty else { return }
        preserveReadingAnchorDuring {
            var snapshot = dataSource.snapshot()
            snapshot.reloadItems(stepIDs)
            dataSource.apply(snapshot, animatingDifferences: false)
            collectionView.collectionViewLayout.invalidateLayout()
            collectionView.layoutIfNeeded()
        }
        publishVisibleAndFooterMetrics()
    }

    private func refreshVisibleUserAvatars() {
        guard isViewVisible else {
            pendingAvatarRefresh = true
            return
        }
        guard collectionView != nil else { return }
        for cell in collectionView.visibleCells {
            if let userCell = cell as? ChatUserCell,
               let indexPath = collectionView.indexPath(for: userCell),
               indexPath.section < items.count,
               case .line(let id) = items[indexPath.section],
               let row = rowByID[id] {
                let entry = layoutCache.measureUser(row: row, collectionWidth: max(240, collectionView.bounds.width), style: currentStyle)
                userCell.configure(row: row, entry: entry, style: currentStyle, hostViewController: self, actions: actions)
            }
        }
    }

    private func reconfigureAllVisibleCells() {
        let width = max(240, collectionView.bounds.width)
        var cellTypeReloadIDs: [ChatListItemID] = []
        for indexPath in collectionView.indexPathsForVisibleItems where indexPath.section < items.count {
            let itemID = items[indexPath.section]
            switch itemID {
            case .emptyStatus:
                if let cell = collectionView.cellForItem(at: indexPath) {
                    configureEmptyCell(cell)
                }
            case .earlierButton:
                (collectionView.cellForItem(at: indexPath) as? ChatEarlierButtonCell)?.refreshTypography()
            case .line(let id):
                if let row = rowByID[id] {
                    updateVisibleRowCell(at: indexPath, newRow: row, width: width, reloadIDs: &cellTypeReloadIDs)
                }
            case .liveFolding:
                (collectionView.cellForItem(at: indexPath) as? ChatLiveFoldingCell)?.refreshTypography()
            case .liveThinking:
                if let cell = collectionView.cellForItem(at: indexPath) as? ChatLiveThinkingCell {
                    cell.configure(text: currentState?.streamReasoning ?? "")
                }
            case .liveToolTail:
                (collectionView.cellForItem(at: indexPath) as? ChatLiveToolTailCell)?.refreshTypography(style: currentStyle)
            case .liveFailure:
                if let cell = collectionView.cellForItem(at: indexPath) as? ChatLiveFailureCell {
                    cell.configure(error: currentState?.failureCardError ?? "", working: currentState?.working ?? false) { [weak self] in
                        self?.actions.bridge.onRetry()
                    }
                }
            case .queued(let qid):
                if let qItem = currentState?.queuedItems.first(where: { $0.id == qid }),
                   let cell = collectionView.cellForItem(at: indexPath) as? ChatQueuedCell {
                    let entry = layoutCache.measureQueued(qItem, collectionWidth: width, style: currentStyle)
                    cell.configure(
                        item: qItem,
                        entry: entry,
                        working: currentState?.working ?? false,
                        sendingBlocked: currentState?.sendingBlocked ?? false,
                        onWithdraw: { [weak self] in self?.actions.bridge.onWithdrawQueued(qItem) },
                        onSendNow: { [weak self] in self?.actions.bridge.onSendQueuedNow() }
                    )
                }
            case .liveProse(let gen):
                if let cell = collectionView.cellForItem(at: indexPath) as? ChatAssistantCell {
                    let entry = layoutCache.measureLiveStreamingProse(text: currentState?.streamText ?? "", generation: gen, collectionWidth: width, style: currentStyle)
                    cell.updateLiveStreamingInPlace(entry: entry, style: currentStyle)
                }
            case .livePulse:
                if let cell = collectionView.cellForItem(at: indexPath) as? ChatLivePulseCell {
                    let raw = currentState?.streamPulse ?? ""
                    let tail = raw.split(separator: "\n", omittingEmptySubsequences: true).suffix(4).joined(separator: "\n")
                    let entry = layoutCache.measureLiveText(tail, collectionWidth: width, style: currentStyle, cardInsetH: Ink.Space.m, cardInsetV: Ink.Space.s)
                    let speaker = currentState?.streamPulseSpeaker ?? (currentState?.isRoom == true ? nil : currentState?.defaultBot)
                    cell.configure(
                        text: tail,
                        temper: Temper.of(speaker),
                        entry: entry,
                        style: currentStyle,
                        onSelectionChanged: { [weak self] uuid, active in self?.handleSelectionChanged(uuid, active) },
                        onQuoteExcerpt: { [weak self] excerpt in self?.actions.onQuoteExcerpt(excerpt) },
                        onSaveNoteExcerpt: { [weak self] excerpt in self?.actions.onSaveNoteExcerpt("live-pulse", excerpt) },
                        onSpeakExcerpt: { [weak self] excerpt in self?.actions.onSpeakExcerpt(excerpt) }
                    )
                }
            default:
                break
            }
        }
        if !cellTypeReloadIDs.isEmpty {
            var reloadSnap = dataSource.snapshot()
            reloadSnap.reloadItems(cellTypeReloadIDs)
            dataSource.apply(reloadSnap, animatingDifferences: false)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard collectionView.bounds.width > 0 else { return }

        performHostUpdate {
            updateTopEdgeContainerLayout(animated: false)
            updateCollectionInsetsIfNeeded()

            if !hasPerformedInitialScroll {
                collectionView.layoutIfNeeded()
                if let req = pendingScrollRequest, let section = itemIndexByID[.line(req.id)] {
                    pendingScrollRequest = nil
                    performScrollToRow(section: section, anchor: req.anchor, animated: false)
                } else if isPinnedToBottom && !(currentState?.historyInView ?? false) && selectingOwnerIDs.isEmpty {
                    scrollToBottom(animated: false)
                }
                hasPerformedInitialScroll = true
                lastKnownContentWidth = collectionView.bounds.width
                lastScrollOffsetY = collectionView.contentOffset.y
                prewarmInitialWindow()
                scheduleHostMetricsFlush()
            } else if abs(collectionView.bounds.width - lastKnownContentWidth) > 0.5 {
                lastKnownContentWidth = collectionView.bounds.width
                cancelAllPrefetches()
                cancelPrewarm()
                pendingDynamicOwnerIDs.removeAll()
                lastMeasuredItemHeights.removeAll()
                layoutCache.invalidateHeightsOnly()
                preserveReadingAnchorDuring {
                    reconfigureAllVisibleCells()
                    collectionView.collectionViewLayout.invalidateLayout()
                    collectionView.layoutIfNeeded()
                }
                prewarmInitialWindow()
                scheduleHostMetricsFlush()
            }
        }
    }

    @MainActor
    private final class InsetClock: NSObject {
        weak var owner: ChatListViewController?
        init(_ owner: ChatListViewController) { self.owner = owner }
        @objc func beat(_ link: CADisplayLink) {
            guard let owner else { link.invalidate(); return }
            owner.stepInsetTick(link)
        }
    }

    private func setupKeyboardTracking() {
        keyboardSpacerView.backgroundColor = .clear
        keyboardSpacerView.isUserInteractionEnabled = false
        keyboardSpacerView.isAccessibilityElement = false
        keyboardSpacerView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(keyboardSpacerView)
        // Explicit iPhone docked posture: undocked/floating keyboards are handled via screen-filtered
        // intersection in `ChatKeyboardGeometrySolver` instead of letting UIKit drag the dock mid-screen.
        view.keyboardLayoutGuide.followsUndockedKeyboard = false
        NSLayoutConstraint.activate([
            keyboardSpacerView.topAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            keyboardSpacerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            keyboardSpacerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            keyboardSpacerView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        let willChange = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let beginRect = (note.userInfo?[UIResponder.keyboardFrameBeginUserInfoKey] as? NSValue)?.cgRectValue
            let endRect = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
            let duration = (note.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? TimeInterval) ?? 0.25
            MainActor.assumeIsolated {
                self?.handleKeyboardWillChangeFrame(beginScreen: beginRect, endScreen: endRect, duration: duration)
            }
        }
        let didChange = NotificationCenter.default.addObserver(
            forName: UIResponder.keyboardDidChangeFrameNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let endRect = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
            MainActor.assumeIsolated {
                self?.handleKeyboardDidChangeFrame(endScreen: endRect)
            }
        }
        keyboardObserverTokens = [willChange, didChange]
    }

    private func keyboardOverlap(forScreenRect screenRect: CGRect) -> CGFloat {
        let converted = ChatKeyboardGeometrySolver.convertKeyboardScreenRect(screenRect, in: view)
        guard converted.belongsToScreen, let local = converted.frameInHost else { return 0 }
        return max(0, view.bounds.maxY - local.minY)
    }

    private func currentKeyboardLayoutOverlap() -> CGFloat {
        max(0, view.bounds.maxY - view.keyboardLayoutGuide.layoutFrame.minY)
    }

    private func resolvedEffectiveOcclusion(interactiveProbeTopY: CGFloat? = nil) -> ChatEffectiveOcclusionResult {
        let hostBounds = view.bounds
        let safeBottom = view.safeAreaInsets.bottom
        let restingComposerH: CGFloat
        if bottomDockContainerView != nil {
            restingComposerH = measuredBottomDockHeight > 0 ? measuredBottomDockHeight : max(0, hostBottomInset - safeBottom)
        } else {
            restingComposerH = max(0, hostBottomInset - safeBottom)
        }
        return ChatKeyboardGeometrySolver.resolve(ChatKeyboardGeometryInput(
            hostBounds: hostBounds,
            safeAreaBottom: safeBottom,
            restingComposerHeight: restingComposerH,
            keyboardFrameInHost: lastKeyboardFrameInHost,
            keyboardBelongsToHostScreen: lastKeyboardBelongsToHostScreen,
            interactivePresentationTopY: interactiveProbeTopY,
            extraBottomPadding: Ink.Space.m
        ))
    }

    private func syncBottomDockConstraints(for result: ChatEffectiveOcclusionResult) {
        guard let docked = bottomDockDockedConstraint, let manual = bottomDockManualBottomConstraint else { return }
        switch result.mode {
        case .docked, .hardwareOrNone:
            // Keep `view.keyboardLayoutGuide.topAnchor` active for docked open, docked dismiss, and closed rest
            // so UIKit drives the dock smoothly in CoreAnimation with zero snap on dismiss.
            if manual.isActive { manual.isActive = false }
            if !docked.isActive { docked.isActive = true }
        case .floatingOrSplit:
            if docked.isActive { docked.isActive = false }
            let targetConstant = -result.effectiveBottomOcclusion
            if abs(manual.constant - targetConstant) > 0.25 {
                manual.constant = targetConstant
            }
            if !manual.isActive { manual.isActive = true }
        }
    }

    private func publishEffectiveBottomGeometryIfNeeded(_ result: ChatEffectiveOcclusionResult) {
        lastEffectiveOcclusion = result
        if let model = bottomDockHostModel {
            if abs(model.effectiveBottomOcclusion - result.effectiveBottomOcclusion) > 0.5 {
                model.effectiveBottomOcclusion = result.effectiveBottomOcclusion
            }
            if abs(model.hostViewportHeight - view.bounds.height) > 0.5 {
                model.hostViewportHeight = view.bounds.height
            }
            let topH = max(measuredTopBarHeight, currentState?.headerHeight ?? 0)
            if abs(model.topBarHeight - topH) > 0.5 {
                model.topBarHeight = topH
            }
        }
        if abs(lastReportedBottomOcclusion - result.effectiveBottomOcclusion) > 0.5
            || abs(lastReportedComposerMinY - result.composerFrameInHost.minY) > 0.5 {
            lastReportedBottomOcclusion = result.effectiveBottomOcclusion
            lastReportedComposerMinY = result.composerFrameInHost.minY
            actions.onEffectiveBottomGeometryChanged(result)
        }
    }

    private func setKeyboardTransitioning(_ active: Bool) {
        guard lastReportedKeyboardTransitioning != active else { return }
        lastReportedKeyboardTransitioning = active
        actions.onKeyboardTransitionChanged(active)
    }

    private func handleKeyboardWillChangeFrame(beginScreen: CGRect?, endScreen: CGRect?, duration: TimeInterval) {
        guard !isDismantled, isViewLoaded, view.window != nil else { return }
        guard isViewVisible else {
            pendingKeyboardSync = true
            return
        }
        let converted = ChatKeyboardGeometrySolver.convertKeyboardScreenRect(endScreen, in: view)
        lastKeyboardFrameInHost = converted.frameInHost
        lastKeyboardBelongsToHostScreen = converted.belongsToScreen

        let beginOverlap = beginScreen.map { keyboardOverlap(forScreenRect: $0) } ?? currentKeyboardLayoutOverlap()
        let endOverlap = endScreen.map { keyboardOverlap(forScreenRect: $0) } ?? currentKeyboardLayoutOverlap()

        activeKeyboardStartOverlap = beginOverlap
        activeKeyboardEndOverlap = endOverlap
        activeKeyboardDuration = duration
        if duration > 0.01 {
            activeKeyboardDeadline = CACurrentMediaTime() + duration + 0.12
            setKeyboardTransitioning(true)
        } else {
            activeKeyboardDeadline = 0
            setKeyboardTransitioning(false)
        }

        if insetDisplayLink != nil && abs(insetCatchUpToBottom - insetCatchUpFromBottom) > 0.5 && duration > 0.01 {
            insetCatchUpDuration = max(0.08, duration)
        }

        let resolved = resolvedEffectiveOcclusion()
        syncBottomDockConstraints(for: resolved)
        publishEffectiveBottomGeometryIfNeeded(resolved)

        if hasPerformedInitialScroll, collectionView != nil, collectionView.bounds.width > 0 {
            let insets = collectionView.adjustedContentInset
            let currentMetrics = makeScrollFrameMetrics(
                topInset: insets.top,
                bottomInset: insets.bottom,
                anchor: nil
            )
            scrollArbiter.beginKeyboardTransition(
                metrics: currentMetrics,
                targetBottomInset: resolved.collectionBottomInset
            )
        }

        let kbOpen = resolved.isKeyboardVisiblyOccluding || endOverlap > 10
        if lastReportedKeyboardOpen != kbOpen {
            lastReportedKeyboardOpen = kbOpen
            actions.onKeyboardVisibilityChanged(kbOpen)
        }
        updateCollectionInsetsIfNeeded()
    }

    private func handleKeyboardDidChangeFrame(endScreen: CGRect?) {
        guard !isDismantled, isViewLoaded, view.window != nil else { return }
        guard isViewVisible else {
            pendingKeyboardSync = true
            activeKeyboardDeadline = 0
            setKeyboardTransitioning(false)
            stopInsetDisplayLink()
            return
        }
        if let endScreen {
            let converted = ChatKeyboardGeometrySolver.convertKeyboardScreenRect(endScreen, in: view)
            lastKeyboardFrameInHost = converted.frameInHost
            lastKeyboardBelongsToHostScreen = converted.belongsToScreen
            activeKeyboardEndOverlap = keyboardOverlap(forScreenRect: endScreen)
            activeKeyboardStartOverlap = activeKeyboardEndOverlap
        }
        let resolved = resolvedEffectiveOcclusion()
        syncBottomDockConstraints(for: resolved)
        publishEffectiveBottomGeometryIfNeeded(resolved)
        setKeyboardTransitioning(false)
        bottomDockFocusBridge?.suppressFocusHaptic = false
        scrollArbiter.finishKeyboardTransition()

        let kbOpen = resolved.isKeyboardVisiblyOccluding || activeKeyboardEndOverlap > 10
        if lastReportedKeyboardOpen != kbOpen {
            lastReportedKeyboardOpen = kbOpen
            actions.onKeyboardVisibilityChanged(kbOpen)
        }
        activeKeyboardDeadline = 0
        if insetDisplayLink != nil {
            stopInsetDisplayLink()
            applyInsetsNow(top: targetTopInset, bottom: resolved.collectionBottomInset)
        } else {
            updateCollectionInsetsIfNeeded()
        }
    }

    private func currentKeyboardPresentationTopY() -> CGFloat? {
        guard let presentation = keyboardSpacerView.layer.presentation(),
              view.bounds.height > 0 else {
            return nil
        }
        let topY = presentation.frame.minY
        guard topY.isFinite else { return nil }
        return topY
    }

    private func currentKeyboardAnimationProgress() -> CGFloat? {
        let kbDelta = activeKeyboardEndOverlap - activeKeyboardStartOverlap
        guard abs(kbDelta) > 1,
              keyboardSpacerView.layer.animationKeys()?.isEmpty == false,
              let presentationTopY = currentKeyboardPresentationTopY(),
              view.bounds.height > 0 else {
            return nil
        }
        let currentOverlap = max(0, view.bounds.maxY - presentationTopY)
        let raw = (currentOverlap - activeKeyboardStartOverlap) / kbDelta
        return min(1, max(0, raw))
    }

    private func startInsetCatchUp(toBottom desiredBottom: CGFloat, duration: TimeInterval) {
        guard collectionView != nil else { return }
        insetCatchUpFromBottom = collectionView.contentInset.bottom
        insetCatchUpToBottom = desiredBottom
        insetCatchUpStartTime = CACurrentMediaTime()
        insetCatchUpDuration = max(0.08, duration)

        if insetDisplayLink == nil {
            let link = CADisplayLink(target: InsetClock(self), selector: #selector(InsetClock.beat(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            insetDisplayLink = link
        }
    }

    private func stopInsetDisplayLink() {
        insetDisplayLink?.invalidate()
        insetDisplayLink = nil
    }

    private func stepInsetTick(_ link: CADisplayLink) {
        guard !isDismantled, isViewLoaded, isViewVisible, collectionView != nil, collectionView.bounds.width > 0 else {
            if !isViewVisible { pendingKeyboardSync = true }
            stopInsetDisplayLink()
            return
        }
        let now = link.timestamp
        if collectionView.isDragging, let probeTopY = currentKeyboardPresentationTopY() {
            // Interactive keyboard drag-dismiss: sample presentation geometry directly.
            let liveResult = resolvedEffectiveOcclusion(interactiveProbeTopY: probeTopY)
            publishEffectiveBottomGeometryIfNeeded(liveResult)
            applyInsetsNow(top: targetTopInset, bottom: liveResult.collectionBottomInset, publishMetrics: false)
            return
        }

        let progress: CGFloat
        if now <= activeKeyboardDeadline,
           let kbProgress = currentKeyboardAnimationProgress() {
            progress = kbProgress
        } else {
            let elapsed = max(0, now - insetCatchUpStartTime)
            let dur = max(0.01, insetCatchUpDuration)
            let t = min(1, elapsed / dur)
            progress = CGFloat(t * t * (3 - 2 * t))
        }

        let nextBottom = insetCatchUpFromBottom + (insetCatchUpToBottom - insetCatchUpFromBottom) * progress
        let finished = progress >= 1 || abs(nextBottom - insetCatchUpToBottom) < 0.5
        let resolvedBottom = finished ? insetCatchUpToBottom : nextBottom

        applyInsetsNow(top: targetTopInset, bottom: resolvedBottom, publishMetrics: finished)

        if finished {
            stopInsetDisplayLink()
        }
    }

    private var hostTopInset: CGFloat = 0
    private var hostBottomInset: CGFloat = 0

    func setHostSafeInsets(top: CGFloat, bottom: CGFloat) {
        let clampedTop = max(0, top)
        let clampedBottom = max(0, bottom)
        guard abs(hostTopInset - clampedTop) > 0.5 || abs(hostBottomInset - clampedBottom) > 0.5 else { return }
        hostTopInset = clampedTop
        hostBottomInset = clampedBottom
        updateCollectionInsetsIfNeeded()
    }

    private func updateCollectionInsetsIfNeeded() {
        guard isViewVisible || !hasPerformedInitialScroll else {
            pendingKeyboardSync = true
            return
        }
        guard collectionView != nil, collectionView.bounds.width > 0 else { return }
        let windowTop = view.window?.safeAreaInsets.top ?? view.safeAreaInsets.top
        let embeddedTop = (windowTop > 0 || measuredTopBarHeight > 0) ? (windowTop + measuredTopBarHeight) : 0
        let resolvedTop = max(
            hostTopInset,
            embeddedTop > 0 ? embeddedTop : max(view.safeAreaInsets.top, windowTop + (currentState?.headerHeight ?? 0))
        )
        let desiredTop = resolvedTop + Ink.Space.s
        let desiredBottom: CGFloat
        if bottomDockContainerView != nil {
            let occlusion = resolvedEffectiveOcclusion()
            syncBottomDockConstraints(for: occlusion)
            publishEffectiveBottomGeometryIfNeeded(occlusion)
            desiredBottom = occlusion.collectionBottomInset
        } else {
            let resolvedBottom = hostBottomInset > 0 ? hostBottomInset : view.safeAreaInsets.bottom
            desiredBottom = resolvedBottom + Ink.Space.m
        }

        let comparedTop = insetDisplayLink != nil ? targetTopInset : collectionView.contentInset.top
        let comparedBottom = insetDisplayLink != nil ? targetBottomInset : collectionView.contentInset.bottom
        guard abs(comparedTop - desiredTop) > 0.5 || abs(comparedBottom - desiredBottom) > 0.5 else { return }

        targetTopInset = desiredTop
        targetBottomInset = desiredBottom

        guard hasPerformedInitialScroll else {
            stopInsetDisplayLink()
            applyInsetsNow(top: desiredTop, bottom: desiredBottom)
            return
        }

        let bottomDelta = desiredBottom - collectionView.contentInset.bottom
        if abs(bottomDelta) <= 0.5 {
            stopInsetDisplayLink()
            applyInsetsNow(top: desiredTop, bottom: desiredBottom)
            return
        }

        let now = CACurrentMediaTime()
        let inKeyboardWindow = now <= activeKeyboardDeadline
            && activeKeyboardDuration > 0.01
            && abs(activeKeyboardEndOverlap - activeKeyboardStartOverlap) > 1
        let isInteractiveFingerFollow = collectionView.isDragging && !inKeyboardWindow
        let shouldSnapImmediately = isInteractiveFingerFollow || (reduceMotionEnabled && (!inKeyboardWindow || activeKeyboardDuration <= 0.01))

        if shouldSnapImmediately {
            stopInsetDisplayLink()
            applyInsetsNow(top: desiredTop, bottom: desiredBottom)
        } else {
            let duration = inKeyboardWindow ? max(0.08, activeKeyboardDuration) : 0.22
            startInsetCatchUp(toBottom: desiredBottom, duration: duration)
        }
    }

    private func makeScrollFrameMetrics(
        topInset: CGFloat,
        bottomInset: CGFloat,
        anchor: (id: ChatListItemID, visualY: CGFloat)?
    ) -> ChatScrollArbiterCore.FrameMetrics {
        let anchorTargetY: CGFloat?
        if let anchor,
           let newIdx = itemIndexByID[anchor.id],
           let afterAttrs = collectionView.layoutAttributesForItem(at: IndexPath(item: 0, section: newIdx)) {
            anchorTargetY = afterAttrs.frame.minY - anchor.visualY
        } else {
            anchorTargetY = nil
        }
        let revealedTargetY: CGFloat? = (revealFollowItem != nil) ? bottomOffsetFollowingReveal() : nil
        return ChatScrollArbiterCore.FrameMetrics(
            currentOffsetY: collectionView.contentOffset.y,
            contentHeight: collectionView.contentSize.height,
            boundsHeight: collectionView.bounds.height,
            topInset: topInset,
            bottomInset: bottomInset,
            revealedBottomOffsetY: revealedTargetY,
            anchorTargetOffsetY: anchorTargetY
        )
    }

    /// Single per-frame `contentOffset` write-point enforcing strict 3-tier competition arbitration.
    @discardableResult
    private func commitContentOffset(
        source: ChatScrollArbiterCore.WriteSource,
        anchor: (id: ChatListItemID, visualY: CGFloat)? = nil,
        explicitTargetY: CGFloat? = nil,
        animated: Bool = false,
        layoutIfNeeded: Bool = false,
        publishMetrics: Bool = false
    ) -> Bool {
        guard collectionView != nil, collectionView.bounds.width > 0 else { return false }
        let insets = collectionView.adjustedContentInset
        let metrics = makeScrollFrameMetrics(
            topInset: insets.top,
            bottomInset: insets.bottom,
            anchor: anchor
        )
        let decision = scrollArbiter.resolveWrite(source: source, metrics: metrics, explicitTargetY: explicitTargetY)
        guard decision.wroteOffset, let targetY = decision.targetOffsetY else { return false }

        if animated {
            if abs(collectionView.contentOffset.y - targetY) < 0.5 {
                isProgrammaticScroll = false
                lastScrollOffsetY = collectionView.contentOffset.y
                if publishMetrics { publishVisibleAndFooterMetrics() }
                return false
            }
            isProgrammaticScroll = true
            animatedScrollID &+= 1
            let currentID = animatedScrollID
            collectionView.setContentOffset(CGPoint(x: 0, y: targetY), animated: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.65) { [weak self] in
                guard let self, self.animatedScrollID == currentID, self.isProgrammaticScroll else { return }
                self.isProgrammaticScroll = false
                self.lastScrollOffsetY = self.collectionView.contentOffset.y
                self.publishVisibleAndFooterMetrics()
            }
            return true
        }

        let wasProgrammatic = isProgrammaticScroll
        isProgrammaticScroll = true
        if abs(collectionView.contentOffset.y - targetY) > 0.25 {
            collectionView.contentOffset = CGPoint(x: collectionView.contentOffset.x, y: targetY)
        }
        if layoutIfNeeded {
            collectionView.layoutIfNeeded()
        }
        lastScrollOffsetY = collectionView.contentOffset.y
        isProgrammaticScroll = wasProgrammatic
        if publishMetrics {
            publishVisibleAndFooterMetrics()
        }
        return true
    }

    func handleApprovalCardSettle(capturedEpoch: UInt64) {
        guard !isDismantled, isViewLoaded, hasPerformedInitialScroll,
              !(currentState?.historyInView ?? false) else { return }
        _ = commitContentOffset(
            source: .approvalCardSettle(epoch: capturedEpoch),
            animated: false,
            layoutIfNeeded: false,
            publishMetrics: true
        )
    }

    private func applyInsetsNow(top: CGFloat, bottom: CGFloat, publishMetrics: Bool = true) {
        guard collectionView != nil, collectionView.bounds.width > 0 else { return }
        let current = collectionView.contentInset
        guard abs(current.top - top) > 0.25 || abs(current.bottom - bottom) > 0.25 else { return }

        let anchor: (id: ChatListItemID, visualY: CGFloat)? = (!canAutoPinToBottom && hasPerformedInitialScroll && !isUserTouchScrolling)
            ? topVisibleAnchor()
            : nil

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let wasProgrammatic = isProgrammaticScroll
        isProgrammaticScroll = true

        let nextInset = UIEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        collectionView.contentInset = nextInset
        collectionView.verticalScrollIndicatorInsets = nextInset

        if hasPerformedInitialScroll {
            _ = commitContentOffset(
                source: .insetOrKeyboardSynthesis(epoch: scrollArbiter.interactionEpoch),
                anchor: anchor,
                animated: false,
                layoutIfNeeded: canAutoPinToBottom,
                publishMetrics: false
            )
        }

        lastScrollOffsetY = collectionView.contentOffset.y
        isProgrammaticScroll = wasProgrammatic
        CATransaction.commit()

        if publishMetrics && hasPerformedInitialScroll {
            publishVisibleAndFooterMetrics()
        }
    }

    // MARK: - Anchor Lock & Scroll Helpers

    private func topVisibleAnchor() -> (id: ChatListItemID, visualY: CGFloat)? {
        let topEdge = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        let visiblePaths = collectionView.indexPathsForVisibleItems.sorted { $0.section < $1.section }

        if !selectingOwnerIDs.isEmpty {
            for path in visiblePaths where path.section < items.count {
                let cell = collectionView.cellForItem(at: path)
                let ownsSelection: Bool
                if let assistant = cell as? ChatAssistantCell {
                    ownsSelection = !assistant.activeSelectionOwnerIDs().isEmpty
                } else if let user = cell as? ChatUserCell {
                    ownsSelection = !user.activeSelectionOwnerIDs().isEmpty
                } else {
                    ownsSelection = false
                }
                if ownsSelection, let attrs = collectionView.layoutAttributesForItem(at: path) {
                    return (items[path.section], attrs.frame.minY - collectionView.contentOffset.y)
                }
            }
        }

        let linePaths = visiblePaths.filter { path in
            guard path.section < items.count else { return false }
            if case .line = items[path.section] { return true }
            return false
        }
        let searchPool = linePaths.isEmpty ? visiblePaths : linePaths
        let candidate = searchPool.first(where: { path in
            guard let attrs = collectionView.layoutAttributesForItem(at: path) else { return false }
            return attrs.frame.maxY > topEdge + 2
        }) ?? searchPool.first

        if let path = candidate,
           path.section < items.count,
           let attrs = collectionView.layoutAttributesForItem(at: path) {
            return (items[path.section], attrs.frame.minY - collectionView.contentOffset.y)
        }
        return nil
    }

    private func resolvedLayoutAttributes(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        if let attrs = collectionView.layoutAttributesForItem(at: indexPath) {
            return attrs
        }
        collectionView.collectionViewLayout.invalidateLayout()
        collectionView.layoutIfNeeded()
        return collectionView.layoutAttributesForItem(at: indexPath)
            ?? collectionView.collectionViewLayout.layoutAttributesForItem(at: indexPath)
    }

    private func preserveReadingAnchorDuring(_ work: () -> Void) {
        let anchor = topVisibleAnchor()
        let wasPinned = canAutoPinToBottom
        UIView.performWithoutAnimation {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let wasProgrammatic = isProgrammaticScroll
            isProgrammaticScroll = true
            work()
            if wasPinned {
                scrollToBottom(animated: false)
            } else if let anchor {
                _ = commitContentOffset(
                    source: .userAnchorPreserve,
                    anchor: anchor,
                    animated: false,
                    layoutIfNeeded: true,
                    publishMetrics: false
                )
            }
            isProgrammaticScroll = wasProgrammatic
            CATransaction.commit()
        }
    }

    private func applyStreamingResizePreservingScroll() {
        needsDeferredStreamingResize = false
        let epoch = scrollArbiter.interactionEpoch
        let wasProgrammatic = isProgrammaticScroll

        UIView.performWithoutAnimation {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            isProgrammaticScroll = true

            collectionView.collectionViewLayout.invalidateLayout()
            collectionView.layoutIfNeeded()

            if !wasProgrammatic {
                _ = commitContentOffset(
                    source: .streamingResize(epoch: epoch),
                    animated: false,
                    layoutIfNeeded: false,
                    publishMetrics: false
                )
            }

            isProgrammaticScroll = wasProgrammatic
            CATransaction.commit()
        }
    }

    // MARK: - Host Navigation API

    var isCurrentlyNearBottom: Bool {
        guard isViewLoaded, collectionView != nil else { return true }
        return (bottomOffsetY(for: collectionView) - collectionView.contentOffset.y) < 40
    }

    func setFollowingFromHost(_ following: Bool) {
        isPinnedToBottom = following
        if following,
           !isUserTouchScrolling,
           selectingOwnerIDs.isEmpty,
           isViewLoaded,
           collectionView.bounds.width > 0,
           !(currentState?.historyInView ?? false),
           !isProgrammaticScroll {
            let dist = bottomOffsetY(for: collectionView) - collectionView.contentOffset.y
            if dist > 2 {
                scrollToBottom(animated: false)
            }
        }
    }

    func scrollToBottomFromHost(animated: Bool) {
        pendingScrollRequest = nil
        isPinnedToBottom = true
        guard isViewLoaded, collectionView.bounds.width > 0 else { return }
        collectionView.layoutIfNeeded()
        scrollToBottom(animated: animated)
        publishVisibleAndFooterMetrics()
    }

    func scrollToRow(id: String, anchor: UnitPoint, animated: Bool) {
        _ = scrollArbiter.beginExplicitJump()
        guard isViewLoaded,
              collectionView.bounds.width > 0,
              let section = itemIndexByID[.line(id)] else {
            pendingScrollRequest = (id, anchor, animated)
            return
        }
        pendingScrollRequest = nil
        performScrollToRow(section: section, anchor: anchor, animated: animated)
        publishActiveTurnIfNeeded(for: collectionView)
    }

    private func performScrollToRow(section: Int, anchor: UnitPoint, animated: Bool) {
        actions.onProgrammaticScroll()
        prewarmAroundSection(section)
        let indexPath = IndexPath(item: 0, section: section)
        collectionView.layoutIfNeeded()
        guard let attrs = resolvedLayoutAttributes(at: indexPath) else { return }

        let insets = collectionView.adjustedContentInset
        let visibleH = max(40, collectionView.bounds.height - insets.top - insets.bottom)

        let rawTargetY: CGFloat
        switch anchor {
        case .top:
            rawTargetY = attrs.frame.minY - insets.top
        case .center:
            rawTargetY = attrs.frame.midY - (insets.top + visibleH * 0.5)
        case .bottom:
            rawTargetY = attrs.frame.maxY - (collectionView.bounds.height - insets.bottom)
        default:
            rawTargetY = attrs.frame.minY - insets.top
        }

        _ = commitContentOffset(
            source: .explicitJump,
            explicitTargetY: rawTargetY,
            animated: animated,
            layoutIfNeeded: !animated,
            publishMetrics: true
        )
    }

    private func bottomOffsetY(for scrollView: UIScrollView) -> CGFloat {
        let insets = scrollView.adjustedContentInset
        let minY = -insets.top
        let maxY = scrollView.contentSize.height - scrollView.bounds.height + insets.bottom
        return max(minY, maxY)
    }

    private var revealFollowItem: (id: ChatListItemID, ownerID: String)? {
        guard currentStyle.fade, !currentStyle.reduceMotion, let state = currentState else { return nil }
        if state.hasStreaming {
            return (.liveProse(state.streamGeneration), "streaming-\(state.streamGeneration)")
        }
        if let id = settlingRevealID,
           state.rows.last(where: { $0.line.kind == .user || $0.line.kind == .bot })?.line.id == id {
            return (.line(id), id)
        }
        return nil
    }

    private func bottomOffsetFollowingReveal() -> CGFloat {
        let bottom = bottomOffsetY(for: collectionView)
        guard let item = revealFollowItem, let section = itemIndexByID[item.id] else { return bottom }
        let path = IndexPath(item: 0, section: section)
        let lineBottom: CGFloat
        if let cell = collectionView.cellForItem(at: path) as? ChatAssistantCell {
            guard let visible = cell.revealedLineBottom(in: collectionView) else { return bottom }
            lastKnownRevealLimit = (ownerID: item.ownerID, lineBottom: visible)
            lineBottom = visible
        } else {
            // CX-08: Never run synchronous CoreText layout measurement for offscreen cells during scroll ticks.
            if let cached = lastKnownRevealLimit, cached.ownerID == item.ownerID {
                lineBottom = cached.lineBottom
            } else if let attrs = collectionView.layoutAttributesForItem(at: path) {
                lineBottom = attrs.frame.minY + min(attrs.frame.height, 2 * Ink.Size.body)
            } else {
                return bottom
            }
        }
        let insets = collectionView.adjustedContentInset
        let visibleHeight = collectionView.bounds.height - insets.bottom
        let headroom = max(Ink.Space.s, currentStyle.fonts.reading.regular.lineHeight)
        return max(-insets.top, min(bottom, lineBottom + headroom - visibleHeight))
    }

    private func followRevealFrame(ownerID: String, completed: Bool) {
        guard revealFollowItem?.ownerID == ownerID else { return }
        if completed && settlingRevealID == ownerID {
            settlingRevealID = nil
            lastKnownRevealLimit = nil
        }
        guard hasPerformedInitialScroll, canAutoPinToBottom, !isProgrammaticScroll,
              !isInHostUpdate, !isDismantled, isViewVisible else { return }
        let epoch = scrollArbiter.interactionEpoch
        if completed {
            _ = commitContentOffset(
                source: .finalizedSettle(epoch: epoch),
                animated: true,
                layoutIfNeeded: false,
                publishMetrics: true
            )
        } else {
            _ = commitContentOffset(
                source: .revealTick(epoch: epoch),
                animated: false,
                layoutIfNeeded: false,
                publishMetrics: false
            )
        }
    }

    private func scrollToBottom(animated: Bool, layoutIfNeeded: Bool = true, publishMetrics: Bool = true) {
        actions.onProgrammaticScroll()
        isPinnedToBottom = true
        _ = commitContentOffset(
            source: .insetOrKeyboardSynthesis(epoch: scrollArbiter.interactionEpoch),
            animated: animated,
            layoutIfNeeded: layoutIfNeeded,
            publishMetrics: publishMetrics
        )
    }

    private func clearAllSelections() {
        for cell in collectionView.visibleCells {
            if let assistant = cell as? ChatAssistantCell {
                assistant.clearAllSelections()
            } else if let user = cell as? ChatUserCell {
                user.clearSelection()
            }
        }
        let active = Array(selectingOwnerIDs)
        selectingOwnerIDs.removeAll()
        guard !active.isEmpty else { return }
        if isInHostUpdate {
            Task { @MainActor [weak self] in
                guard let self, !self.isDismantled else { return }
                for uuid in active {
                    self.actions.onSelectionChanged(uuid, false)
                }
            }
        } else {
            for uuid in active {
                actions.onSelectionChanged(uuid, false)
            }
        }
    }

    private func handleSelectionChanged(_ uuid: UUID, _ active: Bool) {
        guard !isDismantled else { return }
        if active {
            selectingOwnerIDs.insert(uuid)
        } else {
            selectingOwnerIDs.remove(uuid)
        }
        scrollArbiter.setTextSelectionActive(!selectingOwnerIDs.isEmpty)
        if isInHostUpdate {
            Task { @MainActor [weak self] in
                guard let self, !self.isDismantled else { return }
                self.actions.onSelectionChanged(uuid, active)
            }
        } else {
            actions.onSelectionChanged(uuid, active)
        }
    }

    // MARK: - UIScrollViewDelegate & UICollectionViewDelegate

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        dragStartOffsetY = scrollView.contentOffset.y
        isTrackingUserScroll = true
        wasPinnedAtDragStart = isPinnedToBottom
        userMovedAwayFromBottomDuringDrag = false
        let interactiveKeyboardDismiss = lastEffectiveOcclusion.isKeyboardVisiblyOccluding
        scrollArbiter.beginUserTouchScroll(interactiveKeyboardDismiss: interactiveKeyboardDismiss)
        if interactiveKeyboardDismiss {
            bottomDockFocusBridge?.suppressFocusHaptic = true
            startInsetCatchUp(toBottom: targetBottomInset, duration: 0.25)
        }
        if isProgrammaticScroll {
            animatedScrollID &+= 1
            isProgrammaticScroll = false
        }
        actions.onScrollPhaseChanged("拖动")
        actions.onTouchScrollingChanged(true, true)
        actions.chat.setBrowsingHistory(true)
        actions.onScrollingChanged(true)
        if !isPinnedToBottom {
            actions.onDragStarted()
        }
        publishActiveTurnIfNeeded(for: scrollView)
    }

    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        // CX-08: Prevent manual flicks from overshooting past the actively pacing reveal boundary into blank tail space.
        guard revealFollowItem != nil else { return }
        let revealLimitY = bottomOffsetFollowingReveal()
        let fullBottomY = bottomOffsetY(for: scrollView)
        if revealLimitY < fullBottomY - 2, targetContentOffset.pointee.y > revealLimitY {
            targetContentOffset.pointee.y = revealLimitY
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        actions.onChromeDragEnded()
        if decelerate {
            actions.onScrollPhaseChanged("惯性")
        } else {
            handleUserScrollEnded(scrollView)
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        handleUserScrollEnded(scrollView)
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        animatedScrollID &+= 1
        isProgrammaticScroll = false
        lastScrollOffsetY = scrollView.contentOffset.y
        publishVisibleAndFooterMetrics()
    }

    private func handleUserScrollEnded(_ scrollView: UIScrollView) {
        isTrackingUserScroll = false
        isSettlingUserScrollEnd = true
        defer { isSettlingUserScrollEnd = false }

        actions.onScrollPhaseChanged("静止")
        actions.onTouchScrollingChanged(false, false)
        actions.chat.setBrowsingHistory(false)
        actions.onScrollingChanged(false)

        if needsDeferredDynamicRefresh || needsDeferredStreamingResize {
            let hadDynamicRefresh = needsDeferredDynamicRefresh
            let hadStreamingResize = needsDeferredStreamingResize
            needsDeferredDynamicRefresh = false
            needsDeferredStreamingResize = false
            if !isDismantled, collectionView != nil, collectionView.bounds.width > 0 {
                if hadDynamicRefresh {
                    preserveReadingAnchorDuring {
                        applyPendingDynamicCellReconfigurations()
                        collectionView.collectionViewLayout.invalidateLayout()
                        collectionView.layoutIfNeeded()
                    }
                } else if hadStreamingResize {
                    applyStreamingResizePreservingScroll()
                }
            }
        }

        let revealLimitY = bottomOffsetFollowingReveal()
        let fullBottomY = bottomOffsetY(for: scrollView)
        let distanceFromBottom = revealLimitY - scrollView.contentOffset.y
        let withinFollowThreshold = distanceFromBottom < 80
            || (wasPinnedAtDragStart && !userMovedAwayFromBottomDuringDrag && distanceFromBottom < 120)
        let shouldFollow = !(currentState?.historyInView ?? false) && selectingOwnerIDs.isEmpty && withinFollowThreshold
        let prevPinned = isPinnedToBottom
        scrollArbiter.endUserTouchScroll(shouldPinToBottom: shouldFollow)
        bottomDockFocusBridge?.suppressFocusHaptic = false
        if insetDisplayLink != nil && CACurrentMediaTime() > activeKeyboardDeadline {
            stopInsetDisplayLink()
            updateCollectionInsetsIfNeeded()
        }
        if prevPinned != isPinnedToBottom {
            actions.onFollowingChanged(isPinnedToBottom)
        }
        let overshotReveal = revealFollowItem != nil
            && revealLimitY < fullBottomY - 2
            && scrollView.contentOffset.y > revealLimitY + 1
        if (overshotReveal || (isPinnedToBottom && distanceFromBottom > 2))
            && insetDisplayLink == nil
            && CACurrentMediaTime() > activeKeyboardDeadline
        {
            scrollToBottom(animated: abs(distanceFromBottom) > 12)
        }
        actions.onScrollEnded()
        publishVisibleAndFooterMetricsNow()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard hasPerformedInitialScroll, !isDismantled else { return }

        var currentY = scrollView.contentOffset.y
        let prevY = lastScrollOffsetY
        let insets = scrollView.adjustedContentInset
        let touching = scrollView.isDragging || scrollView.isDecelerating
        let bottomY = touching ? bottomOffsetFollowingReveal() : bottomOffsetY(for: scrollView)

        // CX-08: Clamp inertial deceleration if it glides past the actively pacing reveal boundary.
        if !isProgrammaticScroll,
           !isInHostUpdate,
           scrollView.isDecelerating,
           !scrollView.isDragging,
           revealFollowItem != nil,
           bottomY < bottomOffsetY(for: scrollView) - 2,
           currentY > bottomY + 1
        {
            let wasProgrammatic = isProgrammaticScroll
            isProgrammaticScroll = true
            scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: bottomY), animated: false)
            isProgrammaticScroll = wasProgrammatic
            currentY = bottomY
        }

        lastScrollOffsetY = currentY

        if !isProgrammaticScroll && !isInHostUpdate {
            if currentY < prevY - 0.5 {
                scrollDirection = -1
            } else if currentY > prevY + 0.5 {
                scrollDirection = 1
            }
            let userMoving = scrollView.isTracking || touching
            let movedUp = currentY < prevY - 0.5 || (scrollView.isDragging && currentY < dragStartOffsetY - 0.5)
            if userMoving && movedUp && currentY < bottomY - 4 {
                userMovedAwayFromBottomDuringDrag = true
                if isPinnedToBottom {
                    scrollArbiter.userScrolledAwayFromBottom()
                    actions.onFollowingChanged(false)
                    actions.onDragStarted()
                }
            }
            if touching {
                let rawDeltaY = currentY - prevY
                if abs(rawDeltaY) > 0.01 {
                    let minY = -insets.top
                    let trueBottomY = bottomOffsetY(for: scrollView)
                    let clampedPrev = min(trueBottomY, max(minY, prevY))
                    let clampedCurr = min(trueBottomY, max(minY, currentY))
                    let clampedDeltaY = clampedCurr - clampedPrev
                    let trueDistanceFromBottom = max(0, trueBottomY - currentY)
                    let distanceFromTop = currentY - minY
                    let totalContentH = scrollView.contentSize.height + insets.top + insets.bottom
                    let isScrollable = totalContentH > scrollView.bounds.height + 60
                    actions.onScrollDelta(
                        rawDeltaY,
                        clampedDeltaY,
                        trueDistanceFromBottom,
                        distanceFromTop,
                        scrollView.isDragging,
                        isScrollable
                    )
                }
            }
        }

        let distanceFromTop = currentY + insets.top
        let movingUp = currentY < prevY
        if !isProgrammaticScroll,
           !isInHostUpdate,
           touching,
           !isPinnedToBottom,
           !isLoadingEarlierRequest,
           selectingOwnerIDs.isEmpty,
           (currentState?.canLoadEarlier ?? false),
           movingUp,
           distanceFromTop < 240,
           CACurrentMediaTime() - lastAutoPrependTime > 0.35 {
            lastAutoPrependTime = CACurrentMediaTime()
            requestLoadEarlier()
        }

        publishActiveTurnIfNeeded(for: scrollView)

        let now = CACurrentMediaTime()
        if now - lastScrollMetricsPublishTime >= 0.10 {
            lastScrollMetricsPublishTime = now
            publishVisibleAndFooterMetrics()
        }
    }

    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        if let assistant = cell as? ChatAssistantCell {
            assistant.setRevealVisible(true)
        } else if let toolTailCell = cell as? ChatLiveToolTailCell {
            let chatKey = currentState?.chatKey ?? actions.chat.key
            let tail = actions.team.toolTail(for: chatKey)
            let expected = lastMeasuredItemHeights[.liveToolTail] ?? -1
            toolTailCell.configure(tail: tail, style: currentStyle, expectedHeight: expected) { [weak self] h in
                self?.handleLiveToolTailHeightChanged(h)
            }
        }
    }

    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        if let assistant = cell as? ChatAssistantCell {
            assistant.setRevealVisible(false)
            for uuid in assistant.activeSelectionOwnerIDs() {
                handleSelectionChanged(uuid, false)
            }
            if let owner = assistant.latestFooterOwnerID, owner == lastReportedReplyOwner {
                clearReplyPerchClearance()
            }
        } else if let user = cell as? ChatUserCell {
            for uuid in user.activeSelectionOwnerIDs() {
                handleSelectionChanged(uuid, false)
            }
            if let heroID = actions.currentPreparedHeroID(),
               user.containsAttachment(heroID),
               actions.bridge.activeViewingPhotoID != heroID {
                if lastReportedHeroTarget?.id == heroID {
                    lastReportedHeroTarget = nil
                }
                if isInHostUpdate {
                    Task { @MainActor [weak self] in
                        guard let self, !self.isDismantled else { return }
                        self.actions.onClearPhotoHero(heroID)
                    }
                } else {
                    actions.onClearPhotoHero(heroID)
                }
            }
        } else if let toolTailCell = cell as? ChatLiveToolTailCell {
            toolTailCell.stopObserving()
        }
    }

    private func scheduleHostMetricsFlush() {
        guard !pendingHostMetricFlush, !isDismantled else { return }
        pendingHostMetricFlush = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.pendingHostMetricFlush = false
            guard !self.isDismantled, self.isViewLoaded, self.collectionView != nil else { return }
            self.publishVisibleAndFooterMetricsNow()
        }
    }

    private func publishVisibleAndFooterMetrics() {
        guard !isDismantled, collectionView != nil else { return }
        if isInHostUpdate {
            scheduleHostMetricsFlush()
            return
        }
        publishVisibleAndFooterMetricsNow()
    }

    private func publishVisibleAndFooterMetricsNow() {
        guard !isDismantled, collectionView != nil else { return }
        lastScrollMetricsPublishTime = CACurrentMediaTime()
        let visiblePaths = collectionView.indexPathsForVisibleItems.sorted { $0.section < $1.section }
        var ids: [String] = []
        ids.reserveCapacity(visiblePaths.count)
        var latestOwner: String?
        var latestRect: CGRect = .null
        let trackedHeroID = actions.currentPreparedHeroID()
        var matchedHeroTarget: ChatPhotoHeroTarget?

        for path in visiblePaths where path.section < items.count {
            let itemID = items[path.section]
            if let rowID = itemID.rowID {
                ids.append(rowID)
            }
            if let cell = collectionView.cellForItem(at: path) as? ChatAssistantCell,
               let owner = cell.latestFooterOwnerID {
                latestOwner = owner
                latestRect = cell.footerActionsRectInWindow()
            } else if let trackedHeroID,
                      matchedHeroTarget == nil,
                      let user = collectionView.cellForItem(at: path) as? ChatUserCell,
                      let target = user.photoHeroTarget(for: trackedHeroID) {
                matchedHeroTarget = target
            }
        }

        if let matchedHeroTarget, lastReportedHeroTarget != matchedHeroTarget {
            lastReportedHeroTarget = matchedHeroTarget
            actions.onPreparePhotoHero(matchedHeroTarget)
        } else if trackedHeroID == nil {
            lastReportedHeroTarget = nil
        }

        let distanceFromBottom = bottomOffsetY(for: collectionView) - collectionView.contentOffset.y
        let far = distanceFromBottom >= 80
        if lastReportedFarFromEnd != far {
            lastReportedFarFromEnd = far
            actions.onFarFromEndChanged(far)
        }

        let needsEndCorrection = abs(distanceFromBottom) > 2
        if lastReportedNeedsEndCorrection != needsEndCorrection {
            lastReportedNeedsEndCorrection = needsEndCorrection
            actions.onNeedsEndCorrectionChanged(needsEndCorrection)
        }

        if ids != lastReportedVisibleIDs {
            lastReportedVisibleIDs = ids
            actions.onVisibleIDsChanged(ids)
        }
        publishActiveTurnIfNeeded(for: collectionView)

        if !isUserTouchScrolling {
            if latestOwner != lastReportedReplyOwner || latestRect != lastReportedReplyRect {
                lastReportedReplyOwner = latestOwner
                lastReportedReplyRect = latestRect
                actions.petPerch.replyActionsOwner = latestOwner
                actions.petPerch.replyActions = latestRect
            }
        }
    }

    private func computeActiveTurnID(for scrollView: UIScrollView) -> String? {
        guard !turnUserIDBySection.isEmpty else { return nil }
        let topInset = scrollView.adjustedContentInset.top
        let currentY = scrollView.contentOffset.y
        let bottomY = bottomOffsetY(for: scrollView)
        if currentY >= bottomY - 8 {
            return lastUserRowID
        }
        if currentY <= -topInset + 8 {
            return firstUserRowID
        }
        let viewportH = max(1, scrollView.bounds.height - topInset - scrollView.adjustedContentInset.bottom)
        let anchorY = currentY + topInset + viewportH * 0.25

        var bestAtOrAboveSection: Int?
        var bestMinY: CGFloat = -.greatestFiniteMagnitude
        var firstBelowSection: Int?
        var firstBelowMinY: CGFloat = .greatestFiniteMagnitude

        for cell in collectionView.visibleCells {
            guard !cell.isHidden, cell.superview != nil, cell.frame.height > 0,
                  let path = collectionView.indexPath(for: cell),
                  path.section >= 0, path.section < turnUserIDBySection.count else {
                continue
            }
            let minY = cell.frame.minY
            if minY <= anchorY {
                if minY > bestMinY || (minY == bestMinY && path.section > (bestAtOrAboveSection ?? -1)) {
                    bestMinY = minY
                    bestAtOrAboveSection = path.section
                }
            } else {
                if minY < firstBelowMinY || (minY == firstBelowMinY && path.section < (firstBelowSection ?? Int.max)) {
                    firstBelowMinY = minY
                    firstBelowSection = path.section
                }
            }
        }

        if let section = bestAtOrAboveSection ?? firstBelowSection {
            return turnUserIDBySection[section]
        }
        return lastReportedActiveTurnID ?? firstUserRowID
    }

    private func publishActiveTurnIfNeeded(for scrollView: UIScrollView) {
        guard !isDismantled, collectionView != nil else { return }
        let nextTurnID = computeActiveTurnID(for: scrollView)
        guard nextTurnID != lastReportedActiveTurnID else { return }
        if isInHostUpdate {
            scheduleHostMetricsFlush()
            return
        }
        lastReportedActiveTurnID = nextTurnID
        actions.onActiveTurnChanged(nextTurnID)
    }

    private func clearReplyPerchClearance() {
        if let owner = lastReportedReplyOwner, actions.petPerch.replyActionsOwner == owner {
            actions.petPerch.replyActionsOwner = nil
            actions.petPerch.replyActions = .null
        }
        lastReportedReplyOwner = nil
        lastReportedReplyRect = .null
    }

    // MARK: - UICollectionViewDataSourcePrefetching & Tile Prewarm

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        guard !isDismantled, isViewLoaded, collectionView.bounds.width > 0, let style = currentStyle else { return }
        let width = max(240, collectionView.bounds.width)
        let scale = ChatRichTextView.resolveDisplayScale(for: traitCollection, window: view.window)
        let palette = ChatTextRenderPalette.make(style: style)

        var requestedSections: [Int] = []
        var seenRequested: Set<Int> = []
        for indexPath in indexPaths {
            let section = indexPath.section
            guard section >= 0, section < items.count else { continue }
            if seenRequested.insert(section).inserted {
                requestedSections.append(section)
            }
        }
        guard !requestedSections.isEmpty else { return }

        let visibleSections = collectionView.indexPathsForVisibleItems
            .map(\.section)
            .filter { $0 >= 0 && $0 < items.count }

        var targetSections = requestedSections
        var seenTarget = seenRequested
        let lookaheadCount = 16
        if scrollDirection < 0 {
            let seed = min(requestedSections.min() ?? Int.max, visibleSections.min() ?? Int.max)
            if seed < items.count {
                var section = seed - 1
                var added = 0
                while section >= 0 && added < lookaheadCount {
                    if case .line = items[section], seenTarget.insert(section).inserted {
                        targetSections.append(section)
                        added += 1
                    }
                    section -= 1
                }
            }
        } else {
            let seed = max(requestedSections.max() ?? -1, visibleSections.max() ?? -1)
            if seed >= 0 {
                var section = seed + 1
                var added = 0
                while section < items.count && added < lookaheadCount {
                    if case .line = items[section], seenTarget.insert(section).inserted {
                        targetSections.append(section)
                        added += 1
                    }
                    section += 1
                }
            }
        }

        if let minTarget = targetSections.min(), let maxTarget = targetSections.max() {
            let visMin = visibleSections.min() ?? minTarget
            let visMax = visibleSections.max() ?? maxTarget
            let keepMin = min(minTarget, visMin) - 8
            let keepMax = max(maxTarget, visMax) + 8
            for existingSection in Array(prefetchTasksBySection.keys) where existingSection < keepMin || existingSection > keepMax {
                prefetchTasksBySection.removeValue(forKey: existingSection)?.cancel()
                if let token = prefetchTokensBySection.removeValue(forKey: existingSection) {
                    ChatTextTileRenderer.shared.cancelPrefetch(token: token)
                }
                prefetchedSectionIDs.removeValue(forKey: existingSection)
            }
        }

        let cache = layoutCache
        for section in targetSections {
            guard section >= 0, section < items.count else { continue }
            let itemID = items[section]
            if prefetchedSectionIDs[section] == itemID {
                continue
            }
            guard let job = makeBackgroundJob(forSection: section, width: width, style: style) else { continue }
            let token = ChatPrefetchToken()
            prefetchedSectionIDs[section] = itemID
            prefetchTokensBySection[section] = token
            let task = Task.detached(priority: .userInitiated) {
                ChatPrefetchWorker.runSection(
                    job: job,
                    layoutCache: cache,
                    scale: scale,
                    palette: palette,
                    token: token
                )
            }
            prefetchTasksBySection[section] = task
        }
        prewarmTraceRows(in: targetSections)
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        for indexPath in indexPaths {
            let section = indexPath.section
            prefetchTasksBySection.removeValue(forKey: section)?.cancel()
            if let token = prefetchTokensBySection.removeValue(forKey: section) {
                ChatTextTileRenderer.shared.cancelPrefetch(token: token)
            }
            prefetchedSectionIDs.removeValue(forKey: section)
        }
    }

    private func prewarmInitialWindow() {
        guard !isDismantled, isViewLoaded, collectionView != nil, collectionView.bounds.width > 0, let style = currentStyle else {
            return
        }
        let width = max(240, collectionView.bounds.width)
        var prioritySections: [Int] = []
        var seenSections: Set<Int> = []

        for path in collectionView.indexPathsForVisibleItems.sorted(by: { $0.section < $1.section }) {
            let section = path.section
            guard section >= 0, section < items.count, case .line = items[section] else { continue }
            if seenSections.insert(section).inserted {
                prioritySections.append(section)
            }
        }

        for section in items.indices.reversed() {
            guard prioritySections.count < 15 else { break }
            guard case .line = items[section] else { continue }
            if seenSections.insert(section).inserted {
                prioritySections.append(section)
            }
        }

        var secondarySections: [Int] = []
        secondarySections.reserveCapacity(85)
        for section in items.indices.reversed() {
            guard secondarySections.count < 85 else { break }
            guard case .line = items[section] else { continue }
            if seenSections.insert(section).inserted {
                secondarySections.append(section)
            }
        }

        launchPrewarm(prioritySections: prioritySections, secondarySections: secondarySections, width: width, style: style)
    }

    private func prewarmPrependedRows(prependedRowCount: Int) {
        guard !isDismantled,
              isViewLoaded,
              collectionView != nil,
              collectionView.bounds.width > 0,
              let style = currentStyle,
              let rows = currentState?.rows,
              prependedRowCount > 0 else {
            return
        }
        let boundedCount = min(prependedRowCount, rows.count)
        let width = max(240, collectionView.bounds.width)
        var prioritySections: [Int] = []
        var secondarySections: [Int] = []
        prioritySections.reserveCapacity(15)
        secondarySections.reserveCapacity(85)

        for idx in (0..<boundedCount).reversed() {
            let row = rows[idx]
            guard let section = itemIndexByID[.line(row.line.id)] else { continue }
            if prioritySections.count < 15 {
                prioritySections.append(section)
            } else if secondarySections.count < 85 {
                secondarySections.append(section)
            } else {
                break
            }
        }

        launchPrewarm(prioritySections: prioritySections, secondarySections: secondarySections, width: width, style: style)
    }

    func prewarmAroundRow(id: String) {
        guard !isDismantled,
              isViewLoaded,
              collectionView != nil,
              collectionView.bounds.width > 0,
              let section = itemIndexByID[.line(id)] else {
            return
        }
        prewarmAroundSection(section)
    }

    private func prewarmAroundSection(_ centerSection: Int) {
        guard !isDismantled,
              isViewLoaded,
              collectionView != nil,
              collectionView.bounds.width > 0,
              let style = currentStyle,
              centerSection >= 0,
              centerSection < items.count else {
            return
        }
        let width = max(240, collectionView.bounds.width)
        let key = JumpPrewarmKey(
            section: centerSection,
            itemID: items[centerSection],
            itemCount: items.count,
            widthKey: Int(width.rounded()),
            styleKey: style.styleKey,
            chatKey: currentState?.chatKey ?? actions.chat.key
        )
        if key == lastJumpPrewarmKey {
            return
        }

        cancelJumpPrewarm()
        lastJumpPrewarmKey = key

        let lower = max(0, centerSection - 6)
        let upper = min(items.count - 1, centerSection + 10)
        var orderedSections: [Int] = []
        orderedSections.reserveCapacity(upper - lower + 1)
        orderedSections.append(centerSection)
        let maxOffset = max(centerSection - lower, upper - centerSection)
        if maxOffset > 0 {
            for offset in 1...maxOffset {
                let forward = centerSection + offset
                if forward <= upper {
                    orderedSections.append(forward)
                }
                let backward = centerSection - offset
                if backward >= lower {
                    orderedSections.append(backward)
                }
            }
        }

        prewarmTraceRows(in: orderedSections)

        var jobs: [ChatPrefetchWorker.Job] = []
        jobs.reserveCapacity(orderedSections.count)
        for section in orderedSections {
            if let job = makeBackgroundJob(forSection: section, width: width, style: style) {
                jobs.append(job)
            }
        }
        guard !jobs.isEmpty else { return }

        let generation = jumpPrewarmGeneration
        let gate = jumpPrewarmGate
        let token = ChatPrefetchToken()
        jumpPrewarmToken = token
        let cache = layoutCache
        let scale = ChatRichTextView.resolveDisplayScale(for: traitCollection, window: view.window)
        let palette = ChatTextRenderPalette.make(style: style)

        jumpPrewarmTask = Task.detached(priority: .userInitiated) {
            ChatPrefetchWorker.runPrewarm(
                priorityJobs: jobs,
                secondaryTileJobs: [],
                secondaryLayoutOnlyJobs: [],
                layoutCache: cache,
                scale: scale,
                palette: palette,
                token: token,
                gate: gate,
                generation: generation,
                priorityTileQueuePriority: .high
            )
        }
    }

    private func launchPrewarm(
        prioritySections: [Int],
        secondarySections: [Int],
        width: CGFloat,
        style: ChatListStyle
    ) {
        var priorityJobs: [ChatPrefetchWorker.Job] = []
        priorityJobs.reserveCapacity(prioritySections.count)
        for section in prioritySections {
            if let job = makeBackgroundJob(forSection: section, width: width, style: style) {
                priorityJobs.append(job)
            }
        }

        var secondaryTileJobs: [ChatPrefetchWorker.Job] = []
        var secondaryLayoutOnlyJobs: [ChatPrefetchWorker.Job] = []
        for section in secondarySections {
            guard let job = makeBackgroundJob(forSection: section, width: width, style: style) else { continue }
            if secondaryTileJobs.count < 25 {
                secondaryTileJobs.append(job)
            } else {
                secondaryLayoutOnlyJobs.append(job)
            }
        }

        cancelPrewarm()
        prewarmTraceRows(in: prioritySections + secondarySections)
        guard !priorityJobs.isEmpty || !secondaryTileJobs.isEmpty || !secondaryLayoutOnlyJobs.isEmpty else {
            return
        }
        let generation = prewarmGeneration
        let gate = prewarmGate
        let token = ChatPrefetchToken()
        prewarmToken = token
        let cache = layoutCache
        let scale = ChatRichTextView.resolveDisplayScale(for: traitCollection, window: view.window)
        let palette = ChatTextRenderPalette.make(style: style)

        prewarmTask = Task.detached(priority: .userInitiated) {
            ChatPrefetchWorker.runPrewarm(
                priorityJobs: priorityJobs,
                secondaryTileJobs: secondaryTileJobs,
                secondaryLayoutOnlyJobs: secondaryLayoutOnlyJobs,
                layoutCache: cache,
                scale: scale,
                palette: palette,
                token: token,
                gate: gate,
                generation: generation
            )
        }
    }

    private func prewarmTraceRows(in sections: [Int]) {
        guard !isDismantled, !Pref.traceOpen else { return }
        let desk = Words.t("书案/")
        let mountRevision = MountedFolders.revision
        var pending: [ChatLine] = []
        for section in sections {
            guard section >= 0, section < items.count,
                  case .line(let id) = items[section],
                  let row = rowByID[id],
                  row.line.kind == .steps,
                  !inFlightTracePrewarmIDs.contains(row.line.id),
                  Trace.needsOffMainKeepsakePrewarm(for: row.line) else {
                continue
            }
            inFlightTracePrewarmIDs.insert(row.line.id)
            pending.append(row.line)
        }
        guard !pending.isEmpty else { return }

        let lines = pending
        let taskID = UUID()
        let expectedChatKey = currentState?.chatKey ?? actions.chat.key
        let task = Task { [weak self] in
            let payloads = await Task.detached(priority: .utility) { () -> [(ChatLine, Trace.PrewarmedTraceSummary)] in
                var results: [(ChatLine, Trace.PrewarmedTraceSummary)] = []
                results.reserveCapacity(lines.count)
                for line in lines {
                    if Task.isCancelled { break }
                    results.append((line, Trace.prewarmKeepsakePayload(for: line, desk: desk, mountRevision: mountRevision)))
                }
                return results
            }.value
            guard let self else { return }
            self.tracePrewarmTasks.removeValue(forKey: taskID)
            guard !Task.isCancelled, !self.isDismantled else { return }
            for line in lines {
                self.inFlightTracePrewarmIDs.remove(line.id)
            }
            guard (self.currentState?.chatKey ?? self.actions.chat.key) == expectedChatKey else { return }
            var becameEligibleIDs: [ChatListItemID] = []
            for (line, payload) in payloads {
                if Trace.commitPrewarmedSummary(payload, for: line, desk: desk),
                   let currentRow = self.rowByID[line.id],
                   currentRow.line == line,
                   self.itemIndexByID[.line(line.id)] != nil {
                    becameEligibleIDs.append(.line(line.id))
                }
            }
            guard !becameEligibleIDs.isEmpty, self.collectionView != nil, self.dataSource != nil else { return }
            self.preserveReadingAnchorDuring {
                var snapshot = self.dataSource.snapshot()
                let existing = Set(snapshot.itemIdentifiers)
                let valid = becameEligibleIDs.filter { existing.contains($0) }
                guard !valid.isEmpty else { return }
                snapshot.reloadItems(valid)
                self.dataSource.apply(snapshot, animatingDifferences: false)
                self.collectionView.collectionViewLayout.invalidateLayout()
                self.collectionView.layoutIfNeeded()
            }
            self.publishVisibleAndFooterMetrics()
        }
        tracePrewarmTasks[taskID] = task
    }

    private func cancelPrewarm() {
        prewarmGeneration = prewarmGate.advance()
        prewarmTask?.cancel()
        prewarmTask = nil
        cancelJumpPrewarm()
        for task in tracePrewarmTasks.values {
            task.cancel()
        }
        tracePrewarmTasks.removeAll()
        inFlightTracePrewarmIDs.removeAll()
        if let token = prewarmToken {
            ChatTextTileRenderer.shared.cancelPrefetch(token: token)
            prewarmToken = nil
        }
    }

    private func cancelJumpPrewarm() {
        jumpPrewarmGeneration = jumpPrewarmGate.advance()
        jumpPrewarmTask?.cancel()
        jumpPrewarmTask = nil
        if let token = jumpPrewarmToken {
            ChatTextTileRenderer.shared.cancelPrefetch(token: token)
            jumpPrewarmToken = nil
        }
        lastJumpPrewarmKey = nil
    }

    private func cancelAllPrefetches() {
        for task in prefetchTasksBySection.values {
            task.cancel()
        }
        prefetchTasksBySection.removeAll()
        for token in prefetchTokensBySection.values {
            ChatTextTileRenderer.shared.cancelPrefetch(token: token)
        }
        prefetchTokensBySection.removeAll()
        prefetchedSectionIDs.removeAll()
    }

    private func makeBackgroundJob(
        forSection section: Int,
        width: CGFloat,
        style: ChatListStyle
    ) -> ChatPrefetchWorker.Job? {
        guard section >= 0, section < items.count,
              case .line(let id) = items[section],
              let row = rowByID[id] else {
            return nil
        }

        switch row.line.kind {
        case .user:
            return .user(UserMeasureInput(row: row, collectionWidth: width, style: style))

        case .bot:
            guard !row.isFreshWriting else { return nil }
            let input = AssistantMeasureInput(
                row: row,
                collectionWidth: width,
                style: style,
                expandedThinking: expandedThinkingIDs.contains(row.line.id),
                expandedPulse: expandedPulseIDs.contains(row.line.id),
                expandedLookback: expandedLookbackIDs.contains(row.line.id),
                unfoldedSlices: unfoldedCodeSlices[row.line.id] ?? [],
                overrides: layoutCache.overrideSnapshot(for: row.line.id)
            )
            return .assistant(input)

        case .steps, .note:
            return nil
        }
    }

    private func traceHeightKey(_ row: ChatListRowItem) -> String {
        "trace|\(row.line.id)|\(row.line.tools.count)|\(row.line.live ? 1 : 0)|\(row.opens ? 1 : 0)|\(row.faces ? 1 : 0)|\(row.lit ? 1 : 0)"
    }

    @objc private func handleImmersiveBackgroundTap(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, actions.canRestoreImmersiveChrome() else { return }
        let location = recognizer.location(in: collectionView)
        if let hitView = collectionView.hitTest(location, with: nil) {
            var cursor: UIView? = hitView
            while let current = cursor, current !== collectionView {
                if current is UIControl
                    || current is UITextView
                    || current is ChatPetAvatarView
                    || current is ChatMeAvatarView
                    || current is ChatTraceHostingCell {
                    return
                }
                if let richText = current as? ChatRichTextView {
                    if richText.hasActiveSelection {
                        return
                    }
                    if richText.hitTestLink(at: collectionView.convert(location, to: richText)) != nil {
                        return
                    }
                } else if let recognizers = current.gestureRecognizers,
                          recognizers.contains(where: { $0 is UITapGestureRecognizer && $0.isEnabled }) {
                    return
                }
                cursor = current.superview
            }
        }
        actions.onImmersiveBackgroundTap()
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === immersiveRestoreTapGesture else { return true }
        return actions.canRestoreImmersiveChrome()
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        gestureRecognizer === immersiveRestoreTapGesture
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        guard gestureRecognizer === immersiveRestoreTapGesture else { return false }
        guard let otherTap = otherGestureRecognizer as? UITapGestureRecognizer,
              otherTap.numberOfTapsRequired > 1,
              otherTap.view is ChatRichTextView else {
            return false
        }
        return true
    }
}

private final class ChatPrewarmGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0

    func advance() -> UInt64 {
        lock.lock()
        generation &+= 1
        let next = generation
        lock.unlock()
        return next
    }

    func isCurrent(_ expected: UInt64) -> Bool {
        lock.lock()
        let match = generation == expected
        lock.unlock()
        return match
    }
}

private enum ChatPrefetchWorker {
    enum Job: Sendable {
        case user(UserMeasureInput)
        case assistant(AssistantMeasureInput)
    }

    nonisolated static func runSection(
        job: Job,
        layoutCache: ChatLayoutCache,
        scale: CGFloat,
        palette: ChatTextRenderPalette,
        token: ChatPrefetchToken
    ) {
        guard !Task.isCancelled, !ChatTextTileRenderer.shared.isCancelled(token) else { return }
        let requests = buildRequests(job: job, layoutCache: layoutCache, scale: scale, palette: palette)
        guard !Task.isCancelled, !ChatTextTileRenderer.shared.isCancelled(token), !requests.isEmpty else { return }
        ChatTextTileRenderer.shared.prefetch(requests, token: token, queuePriority: .normal)
    }

    nonisolated static func runPrewarm(
        priorityJobs: [Job],
        secondaryTileJobs: [Job],
        secondaryLayoutOnlyJobs: [Job],
        layoutCache: ChatLayoutCache,
        scale: CGFloat,
        palette: ChatTextRenderPalette,
        token: ChatPrefetchToken,
        gate: ChatPrewarmGate,
        generation: UInt64,
        priorityTileQueuePriority: Operation.QueuePriority = .normal
    ) {
        processBatch(
            priorityJobs,
            generateTiles: true,
            tilePriority: priorityTileQueuePriority,
            layoutCache: layoutCache,
            scale: scale,
            palette: palette,
            token: token,
            gate: gate,
            generation: generation
        )
        processBatch(
            secondaryTileJobs,
            generateTiles: true,
            tilePriority: .low,
            layoutCache: layoutCache,
            scale: scale,
            palette: palette,
            token: token,
            gate: gate,
            generation: generation
        )
        processBatch(
            secondaryLayoutOnlyJobs,
            generateTiles: false,
            tilePriority: .low,
            layoutCache: layoutCache,
            scale: scale,
            palette: palette,
            token: token,
            gate: gate,
            generation: generation
        )
    }

    private nonisolated static func processBatch(
        _ jobs: [Job],
        generateTiles: Bool,
        tilePriority: Operation.QueuePriority,
        layoutCache: ChatLayoutCache,
        scale: CGFloat,
        palette: ChatTextRenderPalette,
        token: ChatPrefetchToken,
        gate: ChatPrewarmGate,
        generation: UInt64
    ) {
        guard !jobs.isEmpty else { return }
        var pendingRequests: [ChatTextRenderRequest] = []
        var rowCountInChunk = 0

        for job in jobs {
            if Task.isCancelled || ChatTextTileRenderer.shared.isCancelled(token) || !gate.isCurrent(generation) {
                return
            }
            if generateTiles {
                let rowRequests = buildRequests(job: job, layoutCache: layoutCache, scale: scale, palette: palette)
                if !rowRequests.isEmpty {
                    pendingRequests.append(contentsOf: rowRequests)
                }
                rowCountInChunk += 1
                if rowCountInChunk >= 6 && !pendingRequests.isEmpty {
                    guard gate.isCurrent(generation) else { return }
                    ChatTextTileRenderer.shared.prefetch(pendingRequests, token: token, queuePriority: tilePriority)
                    pendingRequests.removeAll(keepingCapacity: true)
                    rowCountInChunk = 0
                }
            } else {
                measureLayoutOnly(job: job, layoutCache: layoutCache)
            }
        }

        if generateTiles,
           !pendingRequests.isEmpty,
           !Task.isCancelled,
           !ChatTextTileRenderer.shared.isCancelled(token),
           gate.isCurrent(generation) {
            ChatTextTileRenderer.shared.prefetch(pendingRequests, token: token, queuePriority: tilePriority)
        }
    }

    private nonisolated static func measureLayoutOnly(job: Job, layoutCache: ChatLayoutCache) {
        switch job {
        case .user(let input):
            _ = layoutCache.measureUser(input: input)
        case .assistant(let input):
            _ = layoutCache.measureAssistant(input: input, allowMainThreadMathMeasure: false)
        }
    }

    private nonisolated static func buildRequests(
        job: Job,
        layoutCache: ChatLayoutCache,
        scale: CGFloat,
        palette: ChatTextRenderPalette
    ) -> [ChatTextRenderRequest] {
        switch job {
        case .user(let input):
            guard !input.text.isEmpty else { return [] }
            let entry = layoutCache.measureUser(input: input)
            guard entry.bubbleHeight > 0, entry.textWidth > 0, entry.textHeight > 0, !entry.rendered.isEmpty else {
                return []
            }
            let key = ChatTextTileRenderer.cacheKey(
                token: entry.rendered.renderToken,
                width: entry.textWidth,
                height: entry.textHeight,
                styleKey: input.style.styleKey,
                scale: scale
            )
            return [ChatTextRenderRequest(
                cacheKey: key,
                attributed: entry.rendered.attributed,
                decorations: entry.rendered.decorations,
                topInset: entry.rendered.topInset,
                bottomInset: entry.rendered.bottomInset,
                width: entry.textWidth,
                height: entry.textHeight,
                scale: scale,
                palette: palette
            )]

        case .assistant(let input):
            guard !input.isFresh else { return [] }
            let entry = layoutCache.measureAssistant(input: input, allowMainThreadMathMeasure: false)
            let contentWidth = entry.contentWidth
            let style = input.style
            let spaceL = style.metrics.spaceL
            let readingSize = style.readingSize
            let unfoldedSet = input.unfoldedSlices
            var requests: [ChatTextRenderRequest] = []

            for measured in entry.slices {
                switch measured.slice {
                case .richText(let rendered):
                    guard !rendered.isEmpty, contentWidth > 0, measured.height > 0 else { continue }
                    let key = ChatTextTileRenderer.cacheKey(
                        token: rendered.renderToken,
                        width: contentWidth,
                        height: measured.height,
                        styleKey: style.styleKey,
                        scale: scale
                    )
                    requests.append(ChatTextRenderRequest(
                        cacheKey: key,
                        attributed: rendered.attributed,
                        decorations: rendered.decorations,
                        topInset: rendered.topInset,
                        bottomInset: rendered.bottomInset,
                        width: contentWidth,
                        height: measured.height,
                        scale: scale,
                        palette: palette
                    ))

                case .code(let codeSlice, let sliceIndex):
                    guard !codeSlice.isLive else { continue }
                    let unfolded = unfoldedSet.contains(sliceIndex)
                    let resolved = codeSlice.resolved(unfolded: unfolded)
                    let activeAttr = resolved.attributed
                    let activeToken = resolved.token
                    let textSize = resolved.size
                    let codeW = max(contentWidth - spaceL * 2, textSize.width)
                    let codeH = max(16, textSize.height)
                    guard activeAttr.length > 0, codeW > 0, codeH > 0 else { continue }
                    let key = ChatTextTileRenderer.cacheKey(
                        token: activeToken,
                        width: codeW,
                        height: codeH,
                        styleKey: style.styleKey,
                        scale: scale
                    )
                    requests.append(ChatTextRenderRequest(
                        cacheKey: key,
                        attributed: activeAttr,
                        decorations: .empty,
                        topInset: 0,
                        bottomInset: 0,
                        width: codeW,
                        height: codeH,
                        scale: scale,
                        palette: palette
                    ))

                case .pictures(let words, let pics, _):
                    guard let words, !words.isEmpty else { continue }
                    let wordsH = max(18, measured.height - measured.pictureHeights.reduce(0, +) - CGFloat(pics.count) * readingSize * 0.6)
                    guard contentWidth > 0, wordsH > 0 else { continue }
                    let key = ChatTextTileRenderer.cacheKey(
                        token: words.renderToken,
                        width: contentWidth,
                        height: wordsH,
                        styleKey: style.styleKey,
                        scale: scale
                    )
                    requests.append(ChatTextRenderRequest(
                        cacheKey: key,
                        attributed: words.attributed,
                        decorations: words.decorations,
                        topInset: words.topInset,
                        bottomInset: words.bottomInset,
                        width: contentWidth,
                        height: wordsH,
                        scale: scale,
                        palette: palette
                    ))

                case .table, .math, .fileCards:
                    break
                }
            }
            return requests
        }
    }
}
