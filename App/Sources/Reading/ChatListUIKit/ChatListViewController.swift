import AgentKit
import Observation
import QuartzCore
import SwiftUI
import UIKit

/// Production `UICollectionView` chat stream controller implementing:
/// - Deterministic pre-measured heights + hosted SwiftUI cells for `Trace` / empty / tool-tail
/// - Zero-flicker in-place streaming updates & live-to-settled selection transfer
/// - Upward pagination anchor lock (0.0 pt viewport shift)
/// - Clean `following` / `touchScrolling` / `PetPerch` clearance bridging
@MainActor
final class ChatListViewController: UIViewController, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching, UIScrollViewDelegate {
    private let actions: ChatListActions
    private let layoutCache = ChatLayoutCache()
    private var currentStyle: ChatListStyle!
    private var currentState: ChatListState?

    var makeEmptyView: (() -> AnyView)?

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<ChatListItemID, ChatListItemID>!

    private var items: [ChatListItemID] = []
    private var itemIndexByID: [ChatListItemID: Int] = [:]
    private var rowByID: [String: ChatListRowItem] = [:]

    private var expandedThinkingIDs: Set<String> = []
    private var expandedPulseIDs: Set<String> = []
    private var expandedLookbackIDs: Set<String> = []
    private var unfoldedCodeSlices: [String: Set<Int>] = [:]
    private var prefetchedKeysBySection: [Int: [String]] = [:]

    private var selectingOwnerIDs: Set<UUID> = []
    private var hasPerformedInitialScroll = false
    private(set) var isPinnedToBottom = true
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

    private var pendingScrollRequest: (id: String, anchor: UnitPoint, animated: Bool)?
    private var pendingDynamicRefresh = false
    private var needsDeferredDynamicRefresh = false
    private var needsDeferredStreamingResize = false
    private var lastMeasuredItemHeights: [ChatListItemID: CGFloat] = [:]
    private var userDefaultsObserver: NSObjectProtocol?
    private var lastObservedUserAvatarSignature = ""
    private var keyboardObserverTokens: [NSObjectProtocol] = []
    private var isViewVisible = false
    private var pendingAvatarRefresh = false
    private var deferredState: ChatListState?
    private var pendingKeyboardSync = false
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
        deferredState = nil
        pendingKeyboardSync = false
        styleObservationGeneration &+= 1
        pendingHostMetricFlush = false
        pendingDynamicRefresh = false
        needsDeferredDynamicRefresh = false
        needsDeferredStreamingResize = false
        lastMeasuredItemHeights.removeAll()
        stopInsetDisplayLink()
        loadEarlierResetTask?.cancel()
        loadEarlierResetTask = nil
        if let observer = userDefaultsObserver {
            NotificationCenter.default.removeObserver(observer)
            userDefaultsObserver = nil
        }
        for token in keyboardObserverTokens {
            NotificationCenter.default.removeObserver(token)
        }
        keyboardObserverTokens.removeAll()
        cancelAllPrefetches()
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
        if let observer = userDefaultsObserver {
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

        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitPreferredContentSizeCategory.self]) { (controller: ChatListViewController, _) in
            controller.refreshTypographyAndTheme()
        }

        lastObservedUserAvatarSignature = currentUserAvatarSignature()
        userDefaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleUserDefaultsChanged()
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
        if pendingKeyboardSync {
            pendingKeyboardSync = false
            activeKeyboardDeadline = 0
            updateCollectionInsetsIfNeeded()
        }
        startStyleObservationIfVisible()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isViewVisible = false
        styleObservationGeneration &+= 1
        activeKeyboardDeadline = 0
        stopInsetDisplayLink()
        clearReplyPerchClearance()
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        updateCollectionInsetsIfNeeded()
    }

    private func setupCollectionView() {
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.showsVerticalScrollIndicator = false
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
        collectionView.register(ChatTraceHostingCell.self, forCellWithReuseIdentifier: ChatTraceHostingCell.reuseID)
        collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "ChatToolTailHostCell")
        collectionView.register(UICollectionViewCell.self, forCellWithReuseIdentifier: "ChatSpacerCell")

        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

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
                let key = traceHeightKey(row)
                let est = layoutCache.hostingHeight(for: key) ?? 50
                return .estimated(est)
            case .note:
                let h = layoutCache.measureNote(line: row.line, isLatestNote: row.isLatestNote, collectionWidth: width).cellHeight
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
            let est = layoutCache.hostingHeight(for: "toolTail") ?? 52
            return .estimated(est)

        case .liveFailure:
            let err = currentState?.failureCardError ?? ""
            let working = currentState?.working ?? false
            let h = layoutCache.measureFailure(error: err, working: working, collectionWidth: width)
            lastMeasuredItemHeights[itemID] = h
            return .absolute(h)

        case .queued(let id):
            if let item = currentState?.queuedItems.first(where: { $0.id == id }) {
                let h = layoutCache.measureQueued(item, collectionWidth: width).cellHeight
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
            let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "ChatToolTailHostCell", for: indexPath)
            cell.backgroundColor = .clear
            cell.contentView.backgroundColor = .clear
            let chatKey = currentState?.chatKey ?? actions.chat.key
            let team = actions.team
            cell.contentConfiguration = UIHostingConfiguration {
                ToolTailView(tail: team.toolTail(for: chatKey))
                    .padding(.horizontal, Ink.Space.page)
                    .padding(.bottom, Ink.Space.m)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [weak self] h in
                        self?.handleDynamicHostHeight(key: "toolTail", height: h)
                    }
            }
            .margins(.all, 0)
            .background(.clear)
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
            let entry = layoutCache.measureQueued(item, collectionWidth: width)
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
                transferredSelection: transfer
            )
            return cell

        case .steps:
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
            let entry = layoutCache.measureNote(line: row.line, isLatestNote: row.isLatestNote, collectionWidth: width)
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
            }
        )
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
        scheduleDynamicLayoutRefresh()
    }

    private func handleDynamicHostHeight(key: String, height: CGFloat) {
        guard layoutCache.setHostingHeight(height, for: key) else { return }
        scheduleDynamicLayoutRefresh()
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

        if isPinnedToBottom {
            isPinnedToBottom = false
            actions.onFollowingChanged(false)
        }

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
            prewarmTailWindow()
            publishVisibleAndFooterMetrics()
        }
    }

    private func resetForChatSwitch(_ next: ChatListState) {
        cancelAllPrefetches()
        expandedThinkingIDs.removeAll()
        expandedPulseIDs.removeAll()
        expandedLookbackIDs.removeAll()
        unfoldedCodeSlices.removeAll()
        pendingSelectionTransfers.removeAll()
        isLoadingEarlierRequest = false
        loadEarlierSawHostBusy = false
        loadEarlierResetTask?.cancel()
        loadEarlierResetTask = nil
        clearAllSelections()
        layoutCache.invalidateAll()
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
                prewarmTailWindow()
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
        }
        let width = max(240, collectionView.bounds.width)
        var layoutMayHaveChanged = false
        var checkedItemIDs: Set<ChatListItemID> = []

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
                    let entry = layoutCache.measureQueued(qItem, collectionWidth: width)
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
                let newHeight = updateVisibleRowCell(at: indexPath, newRow: newRow, width: width)
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
            return nil
        case .note:
            return layoutCache.measureNote(line: row.line, isLatestNote: row.isLatestNote, collectionWidth: width).cellHeight
        }
    }

    @discardableResult
    private func updateVisibleRowCell(at indexPath: IndexPath, newRow: ChatListRowItem, width: CGFloat) -> CGFloat? {
        switch newRow.line.kind {
        case .bot:
            let entry = measureAssistant(row: newRow, width: width)
            if let cell = collectionView.cellForItem(at: indexPath) as? ChatAssistantCell {
                cell.updateSettledInPlace(
                    row: newRow,
                    entry: entry,
                    style: currentStyle,
                    expandedThinking: expandedThinkingIDs.contains(newRow.line.id),
                    expandedPulse: expandedPulseIDs.contains(newRow.line.id),
                    expandedLookback: expandedLookbackIDs.contains(newRow.line.id),
                    unfoldedSlices: unfoldedCodeSlices[newRow.line.id] ?? []
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
            if let cell = collectionView.cellForItem(at: indexPath) as? ChatTraceHostingCell {
                cell.updateLineInPlace(newRow)
            }
            return nil
        case .note:
            let entry = layoutCache.measureNote(line: newRow.line, isLatestNote: newRow.isLatestNote, collectionWidth: width)
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

        // Transfer active text selection seamlessly if live stream just handed off to a committed bot reply.
        if prev.hasStreaming && !next.hasStreaming,
           let liveIdx = itemIndexByID[.liveProse(prev.streamGeneration)],
           let liveCell = collectionView.cellForItem(at: IndexPath(item: 0, section: liveIdx)) as? ChatAssistantCell,
           let snap = liveCell.currentProseSelectionSnapshot(),
           let targetBotID = next.fresh?.id ?? next.rows.last(where: { $0.line.kind == .bot })?.line.id {
            pendingSelectionTransfers[targetBotID] = snap
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
            for indexPath in collectionView.indexPathsForVisibleItems where indexPath.section < items.count {
                if case .line(let lineID) = items[indexPath.section],
                   let newRow = nextRowMap[lineID],
                   oldRowMap[lineID] != nil,
                   oldRowMap[lineID] != newRow {
                    updateVisibleRowCell(at: indexPath, newRow: newRow, width: width)
                }
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
            } else if let anchor,
                      let newIdx = itemIndexByID[anchor.id],
                      let afterAttrs = resolvedLayoutAttributes(at: IndexPath(item: 0, section: newIdx)) {
                let targetY = afterAttrs.frame.minY - anchor.visualY
                collectionView.contentOffset = CGPoint(x: collectionView.contentOffset.x, y: targetY)
                collectionView.layoutIfNeeded()
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
        guard isViewVisible else { return }
        let nextStyle = ChatListStyle.current(traits: traitCollection, reduceMotion: currentState?.reduceMotion ?? false)
        view.backgroundColor = UIColor(Ink.paper)
        guard nextStyle != currentStyle else { return }
        currentStyle = nextStyle
        cancelAllPrefetches()
        lastMeasuredItemHeights.removeAll()
        layoutCache.invalidateAll()
        ChatTextTileRenderer.shared.invalidateAll()
        guard collectionView != nil, collectionView.bounds.width > 0 else { return }
        preserveReadingAnchorDuring {
            reconfigureAllVisibleCells()
            collectionView.collectionViewLayout.invalidateLayout()
            collectionView.layoutIfNeeded()
        }
        publishVisibleAndFooterMetrics()
    }

    private func currentUserAvatarSignature() -> String {
        let face = UserDefaults.standard.string(forKey: "me.avatar") ?? ""
        let petChoice = PetLibrary.shared.choice
        let photoID: Int
        if face == "photo", let img = Avatars.image("me") {
            photoID = ObjectIdentifier(img).hashValue
        } else {
            photoID = 0
        }
        return "\(face)|\(petChoice)|\(photoID)"
    }

    private func handleUserDefaultsChanged() {
        guard isViewVisible else {
            pendingAvatarRefresh = true
            return
        }
        let nextSignature = currentUserAvatarSignature()
        guard nextSignature != lastObservedUserAvatarSignature else { return }
        lastObservedUserAvatarSignature = nextSignature
        refreshVisibleUserAvatars()
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
                    updateVisibleRowCell(at: indexPath, newRow: row, width: width)
                }
            case .liveFolding:
                (collectionView.cellForItem(at: indexPath) as? ChatLiveFoldingCell)?.refreshTypography()
            case .liveThinking:
                if let cell = collectionView.cellForItem(at: indexPath) as? ChatLiveThinkingCell {
                    cell.configure(text: currentState?.streamReasoning ?? "")
                }
            case .liveFailure:
                if let cell = collectionView.cellForItem(at: indexPath) as? ChatLiveFailureCell {
                    cell.configure(error: currentState?.failureCardError ?? "", working: currentState?.working ?? false) { [weak self] in
                        self?.actions.bridge.onRetry()
                    }
                }
            case .queued(let qid):
                if let qItem = currentState?.queuedItems.first(where: { $0.id == qid }),
                   let cell = collectionView.cellForItem(at: indexPath) as? ChatQueuedCell {
                    let entry = layoutCache.measureQueued(qItem, collectionWidth: width)
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
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard collectionView.bounds.width > 0 else { return }

        performHostUpdate {
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
                prewarmTailWindow()
                scheduleHostMetricsFlush()
            } else if abs(collectionView.bounds.width - lastKnownContentWidth) > 0.5 {
                lastKnownContentWidth = collectionView.bounds.width
                cancelAllPrefetches()
                lastMeasuredItemHeights.removeAll()
                layoutCache.invalidateHeightsOnly()
                preserveReadingAnchorDuring {
                    reconfigureAllVisibleCells()
                    collectionView.collectionViewLayout.invalidateLayout()
                    collectionView.layoutIfNeeded()
                }
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
        view.keyboardLayoutGuide.followsUndockedKeyboard = true
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
        guard let screen = view.window?.windowScene?.screen else { return 0 }
        let local = view.convert(screenRect, from: screen.coordinateSpace)
        return max(0, view.bounds.maxY - local.minY)
    }

    private func currentKeyboardLayoutOverlap() -> CGFloat {
        max(0, view.bounds.maxY - view.keyboardLayoutGuide.layoutFrame.minY)
    }

    private func handleKeyboardWillChangeFrame(beginScreen: CGRect?, endScreen: CGRect?, duration: TimeInterval) {
        guard !isDismantled, isViewLoaded, view.window != nil else { return }
        guard isViewVisible else {
            pendingKeyboardSync = true
            return
        }
        let beginOverlap = beginScreen.map { keyboardOverlap(forScreenRect: $0) } ?? currentKeyboardLayoutOverlap()
        let endOverlap = endScreen.map { keyboardOverlap(forScreenRect: $0) } ?? currentKeyboardLayoutOverlap()

        activeKeyboardStartOverlap = beginOverlap
        activeKeyboardEndOverlap = endOverlap
        activeKeyboardDuration = duration
        if duration > 0.01 {
            activeKeyboardDeadline = CACurrentMediaTime() + duration + 0.12
        } else {
            activeKeyboardDeadline = 0
        }

        if insetDisplayLink != nil && abs(insetCatchUpToBottom - insetCatchUpFromBottom) > 0.5 && duration > 0.01 {
            insetCatchUpDuration = max(0.08, duration)
        }
    }

    private func handleKeyboardDidChangeFrame(endScreen: CGRect?) {
        guard !isDismantled, isViewLoaded, view.window != nil else { return }
        guard isViewVisible else {
            pendingKeyboardSync = true
            activeKeyboardDeadline = 0
            stopInsetDisplayLink()
            return
        }
        if let endScreen {
            activeKeyboardEndOverlap = keyboardOverlap(forScreenRect: endScreen)
            activeKeyboardStartOverlap = activeKeyboardEndOverlap
        }
        activeKeyboardDeadline = 0
        if insetDisplayLink != nil {
            stopInsetDisplayLink()
            applyInsetsNow(top: targetTopInset, bottom: targetBottomInset)
        }
    }

    private func currentKeyboardAnimationProgress() -> CGFloat? {
        let kbDelta = activeKeyboardEndOverlap - activeKeyboardStartOverlap
        guard abs(kbDelta) > 1,
              keyboardSpacerView.layer.animationKeys()?.isEmpty == false,
              let presentation = keyboardSpacerView.layer.presentation(),
              view.bounds.height > 0 else {
            return nil
        }
        let currentOverlap = max(0, view.bounds.maxY - presentation.frame.minY)
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
        let windowTop = view.window?.safeAreaInsets.top ?? 0
        let resolvedTop = hostTopInset > 0
            ? hostTopInset
            : max(view.safeAreaInsets.top, windowTop + (currentState?.headerHeight ?? 0))
        let resolvedBottom = hostBottomInset > 0 ? hostBottomInset : view.safeAreaInsets.bottom
        let desiredTop = resolvedTop + Ink.Space.s
        let desiredBottom = resolvedBottom + Ink.Space.xs

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

    private func applyInsetsNow(top: CGFloat, bottom: CGFloat, publishMetrics: Bool = true) {
        guard collectionView != nil, collectionView.bounds.width > 0 else { return }
        let current = collectionView.contentInset
        guard abs(current.top - top) > 0.25 || abs(current.bottom - bottom) > 0.25 else { return }

        let shouldPinToBottom = canAutoPinToBottom
        let anchor: (id: ChatListItemID, visualY: CGFloat)? = (!shouldPinToBottom && hasPerformedInitialScroll && !isUserTouchScrolling)
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
            if shouldPinToBottom {
                scrollToBottom(animated: false, layoutIfNeeded: true, publishMetrics: false)
            } else if !isUserTouchScrolling,
                      let anchor,
                      let newIdx = itemIndexByID[anchor.id],
                      let afterAttrs = collectionView.layoutAttributesForItem(at: IndexPath(item: 0, section: newIdx)) {
                let minY = -nextInset.top
                let maxY = bottomOffsetY(for: collectionView)
                let desiredY = afterAttrs.frame.minY - anchor.visualY
                let clampedY = min(maxY, max(minY, desiredY))
                if abs(collectionView.contentOffset.y - clampedY) > 0.25 {
                    collectionView.contentOffset = CGPoint(x: collectionView.contentOffset.x, y: clampedY)
                }
            } else if !isUserTouchScrolling {
                let minY = -nextInset.top
                let maxY = bottomOffsetY(for: collectionView)
                let clampedY = min(maxY, max(minY, collectionView.contentOffset.y))
                if abs(collectionView.contentOffset.y - clampedY) > 0.25 {
                    collectionView.contentOffset = CGPoint(x: collectionView.contentOffset.x, y: clampedY)
                }
            }
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
        let topEdge = collectionView.contentOffset.y + collectionView.contentInset.top
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
            } else if !isUserTouchScrolling,
                      let anchor,
                      let newIdx = itemIndexByID[anchor.id],
                      let afterAttrs = resolvedLayoutAttributes(at: IndexPath(item: 0, section: newIdx)) {
                let targetY = afterAttrs.frame.minY - anchor.visualY
                collectionView.contentOffset = CGPoint(x: collectionView.contentOffset.x, y: targetY)
                collectionView.layoutIfNeeded()
            }
            isProgrammaticScroll = wasProgrammatic
            CATransaction.commit()
        }
    }

    private func applyStreamingResizePreservingScroll() {
        needsDeferredStreamingResize = false
        let savedOffsetY = collectionView.contentOffset.y
        let pinned = canAutoPinToBottom
        let wasProgrammatic = isProgrammaticScroll

        UIView.performWithoutAnimation {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            isProgrammaticScroll = true

            collectionView.collectionViewLayout.invalidateLayout()
            collectionView.layoutIfNeeded()

            if pinned {
                scrollToBottom(animated: false, layoutIfNeeded: false, publishMetrics: false)
            } else if !wasProgrammatic && !isUserTouchScrolling {
                let minY = -collectionView.contentInset.top
                let maxY = bottomOffsetY(for: collectionView)
                let clampedY = min(maxY, max(minY, savedOffsetY))
                if abs(collectionView.contentOffset.y - clampedY) > 0.25 {
                    collectionView.contentOffset = CGPoint(x: collectionView.contentOffset.x, y: clampedY)
                }
                lastScrollOffsetY = collectionView.contentOffset.y
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
        isPinnedToBottom = false
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
        let indexPath = IndexPath(item: 0, section: section)
        collectionView.layoutIfNeeded()
        guard let attrs = resolvedLayoutAttributes(at: indexPath) else { return }

        let minY = -collectionView.contentInset.top
        let maxY = bottomOffsetY(for: collectionView)
        let visibleH = max(40, collectionView.bounds.height - collectionView.contentInset.top - collectionView.contentInset.bottom)

        let rawTargetY: CGFloat
        switch anchor {
        case .top:
            rawTargetY = attrs.frame.minY - collectionView.contentInset.top
        case .center:
            rawTargetY = attrs.frame.midY - (collectionView.contentInset.top + visibleH * 0.5)
        case .bottom:
            rawTargetY = attrs.frame.maxY - (collectionView.bounds.height - collectionView.contentInset.bottom)
        default:
            rawTargetY = attrs.frame.minY - collectionView.contentInset.top
        }
        let targetY = min(maxY, max(minY, rawTargetY))

        if animated {
            if abs(collectionView.contentOffset.y - targetY) < 0.5 {
                isProgrammaticScroll = false
                lastScrollOffsetY = collectionView.contentOffset.y
                publishVisibleAndFooterMetrics()
                return
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
        } else {
            let wasProgrammatic = isProgrammaticScroll
            isProgrammaticScroll = true
            collectionView.contentOffset = CGPoint(x: 0, y: targetY)
            collectionView.layoutIfNeeded()
            lastScrollOffsetY = collectionView.contentOffset.y
            isProgrammaticScroll = wasProgrammatic
            publishVisibleAndFooterMetrics()
        }
    }

    private func bottomOffsetY(for scrollView: UIScrollView) -> CGFloat {
        let minY = -scrollView.contentInset.top
        let maxY = scrollView.contentSize.height - scrollView.bounds.height + scrollView.contentInset.bottom
        return max(minY, maxY)
    }

    private func scrollToBottom(animated: Bool, layoutIfNeeded: Bool = true, publishMetrics: Bool = true) {
        let targetY = bottomOffsetY(for: collectionView)
        isPinnedToBottom = true
        if animated {
            if abs(collectionView.contentOffset.y - targetY) < 0.5 {
                isProgrammaticScroll = false
                lastScrollOffsetY = collectionView.contentOffset.y
                if publishMetrics { publishVisibleAndFooterMetrics() }
                return
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
        } else {
            let wasProgrammatic = isProgrammaticScroll
            isProgrammaticScroll = true
            collectionView.contentOffset = CGPoint(x: 0, y: targetY)
            if layoutIfNeeded {
                collectionView.layoutIfNeeded()
            }
            lastScrollOffsetY = collectionView.contentOffset.y
            isProgrammaticScroll = wasProgrammatic
            if publishMetrics {
                publishVisibleAndFooterMetrics()
            }
        }
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

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
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
                        collectionView.collectionViewLayout.invalidateLayout()
                        collectionView.layoutIfNeeded()
                    }
                } else if hadStreamingResize {
                    applyStreamingResizePreservingScroll()
                }
            }
        }

        let distanceFromBottom = bottomOffsetY(for: scrollView) - scrollView.contentOffset.y
        let withinFollowThreshold = distanceFromBottom < 80
            || (wasPinnedAtDragStart && !userMovedAwayFromBottomDuringDrag && distanceFromBottom < 120)
        let shouldFollow = !(currentState?.historyInView ?? false) && selectingOwnerIDs.isEmpty && withinFollowThreshold
        if isPinnedToBottom != shouldFollow {
            isPinnedToBottom = shouldFollow
            actions.onFollowingChanged(shouldFollow)
        }
        if shouldFollow && distanceFromBottom > 2 && insetDisplayLink == nil && CACurrentMediaTime() > activeKeyboardDeadline {
            scrollToBottom(animated: distanceFromBottom > 12)
        }
        actions.onScrollEnded()
        publishVisibleAndFooterMetricsNow()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard hasPerformedInitialScroll, !isDismantled else { return }

        let currentY = scrollView.contentOffset.y
        let prevY = lastScrollOffsetY
        lastScrollOffsetY = currentY

        let bottomY = bottomOffsetY(for: scrollView)
        let touching = scrollView.isDragging || scrollView.isDecelerating
        if !isProgrammaticScroll && !isInHostUpdate {
            let userMoving = scrollView.isTracking || touching
            let movedUp = currentY < prevY - 0.5 || (scrollView.isDragging && currentY < dragStartOffsetY - 0.5)
            if userMoving && movedUp && currentY < bottomY - 4 {
                userMovedAwayFromBottomDuringDrag = true
                if isPinnedToBottom {
                    isPinnedToBottom = false
                    actions.onFollowingChanged(false)
                    actions.onDragStarted()
                }
            }
        }

        let distanceFromTop = currentY + scrollView.contentInset.top
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

    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        if let assistant = cell as? ChatAssistantCell {
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
        guard !isDismantled, collectionView.bounds.width > 0 else { return }
        let width = max(240, collectionView.bounds.width)
        let scale = ChatRichTextView.resolveDisplayScale(for: traitCollection, window: view.window)
        let palette = ChatTextRenderPalette.make(style: currentStyle)
        var requests: [ChatTextRenderRequest] = []
        for indexPath in indexPaths {
            let section = indexPath.section
            guard section >= 0, section < items.count else { continue }
            let itemRequests = buildRenderRequests(forSection: section, width: width, scale: scale, palette: palette)
            if !itemRequests.isEmpty {
                prefetchedKeysBySection[section] = itemRequests.map(\.cacheKey)
                requests.append(contentsOf: itemRequests)
            }
        }
        if !requests.isEmpty {
            ChatTextTileRenderer.shared.prefetch(requests)
        }
    }

    func collectionView(_ collectionView: UICollectionView, cancelPrefetchingForItemsAt indexPaths: [IndexPath]) {
        var keysToCancel: [String] = []
        for indexPath in indexPaths {
            if let keys = prefetchedKeysBySection.removeValue(forKey: indexPath.section) {
                keysToCancel.append(contentsOf: keys)
            }
        }
        if !keysToCancel.isEmpty {
            ChatTextTileRenderer.shared.cancelPrefetch(keys: keysToCancel)
        }
    }

    private func prewarmTailWindow(limit: Int = 8) {
        guard !isDismantled, isViewLoaded, collectionView != nil, collectionView.bounds.width > 0 else { return }
        let width = max(240, collectionView.bounds.width)
        let scale = ChatRichTextView.resolveDisplayScale(for: traitCollection, window: view.window)
        let palette = ChatTextRenderPalette.make(style: currentStyle)
        var requests: [ChatTextRenderRequest] = []
        var warmedRows = 0
        for section in items.indices.reversed() {
            guard warmedRows < limit else { break }
            guard case .line = items[section] else { continue }
            warmedRows += 1
            let itemRequests = buildRenderRequests(forSection: section, width: width, scale: scale, palette: palette)
            if !itemRequests.isEmpty {
                requests.append(contentsOf: itemRequests)
            }
        }
        if !requests.isEmpty {
            ChatTextTileRenderer.shared.prefetch(requests)
        }
    }

    private func cancelAllPrefetches() {
        guard !prefetchedKeysBySection.isEmpty else { return }
        var allKeys: [String] = []
        for keys in prefetchedKeysBySection.values {
            allKeys.append(contentsOf: keys)
        }
        prefetchedKeysBySection.removeAll()
        if !allKeys.isEmpty {
            ChatTextTileRenderer.shared.cancelPrefetch(keys: allKeys)
        }
    }

    private func buildRenderRequests(
        forSection section: Int,
        width: CGFloat,
        scale: CGFloat,
        palette: ChatTextRenderPalette
    ) -> [ChatTextRenderRequest] {
        guard section >= 0, section < items.count,
              case .line(let id) = items[section],
              let row = rowByID[id] else {
            return []
        }

        switch row.line.kind {
        case .user:
            guard !row.line.text.isEmpty else { return [] }
            let entry = layoutCache.measureUser(row: row, collectionWidth: width, style: currentStyle)
            guard entry.bubbleHeight > 0, entry.textWidth > 0, entry.textHeight > 0, !entry.rendered.isEmpty else {
                return []
            }
            let key = ChatTextTileRenderer.cacheKey(
                token: entry.rendered.renderToken,
                width: entry.textWidth,
                height: entry.textHeight,
                styleKey: currentStyle.styleKey,
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

        case .bot:
            guard !row.isFreshWriting else { return [] }
            let entry = measureAssistant(row: row, width: width)
            let contentWidth = entry.contentWidth
            let unfoldedSet = unfoldedCodeSlices[row.line.id] ?? []
            var requests: [ChatTextRenderRequest] = []

            for measured in entry.slices {
                switch measured.slice {
                case .richText(let rendered):
                    guard !rendered.isEmpty, contentWidth > 0, measured.height > 0 else { continue }
                    let key = ChatTextTileRenderer.cacheKey(
                        token: rendered.renderToken,
                        width: contentWidth,
                        height: measured.height,
                        styleKey: currentStyle.styleKey,
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
                    let codeW = max(contentWidth - Ink.Space.l * 2, textSize.width)
                    let codeH = max(16, textSize.height)
                    guard activeAttr.length > 0, codeW > 0, codeH > 0 else { continue }
                    let key = ChatTextTileRenderer.cacheKey(
                        token: activeToken,
                        width: codeW,
                        height: codeH,
                        styleKey: currentStyle.styleKey,
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
                    let wordsH = max(18, measured.height - measured.pictureHeights.reduce(0, +) - CGFloat(pics.count) * currentStyle.readingSize * 0.6)
                    guard contentWidth > 0, wordsH > 0 else { continue }
                    let key = ChatTextTileRenderer.cacheKey(
                        token: words.renderToken,
                        width: contentWidth,
                        height: wordsH,
                        styleKey: currentStyle.styleKey,
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

        case .steps, .note:
            return []
        }
    }

    private func traceHeightKey(_ row: ChatListRowItem) -> String {
        "trace|\(row.line.id)|\(row.line.tools.count)|\(row.line.live ? 1 : 0)|\(row.opens ? 1 : 0)|\(row.faces ? 1 : 0)|\(row.lit ? 1 : 0)"
    }
}
