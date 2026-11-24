import AgentKit
import QuartzCore
import SwiftUI
import UIKit

/// Production `UICollectionView` chat stream controller implementing:
/// - Deterministic pre-measured heights + hosted SwiftUI cells for `Trace` / empty / tool-tail
/// - Zero-flicker in-place streaming updates & live-to-settled selection transfer
/// - Upward pagination anchor lock (0.0 pt viewport shift)
/// - Clean `following` / `touchScrolling` / `PetPerch` clearance bridging
@MainActor
final class ChatListViewController: UIViewController, UICollectionViewDelegate, UIScrollViewDelegate {
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

    private var selectingOwnerIDs: Set<UUID> = []
    private var hasPerformedInitialScroll = false
    private var isPinnedToBottom = true
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
    private var lastReportedReplyOwner: String?
    private var lastReportedReplyRect: CGRect = .null

    private var pendingScrollRequest: (id: String, anchor: UnitPoint, animated: Bool)?
    private var pendingDynamicRefresh = false
    private var userDefaultsObserver: NSObjectProtocol?

    func performHostUpdate(_ work: () -> Void) {
        let wasInHost = isInHostUpdate
        isInHostUpdate = true
        work()
        isInHostUpdate = wasInHost
    }

    func prepareForDismantle() -> String? {
        isDismantled = true
        pendingHostMetricFlush = false
        pendingDynamicRefresh = false
        loadEarlierResetTask?.cancel()
        loadEarlierResetTask = nil
        if let observer = userDefaultsObserver {
            NotificationCenter.default.removeObserver(observer)
            userDefaultsObserver = nil
        }
        let owner = lastReportedReplyOwner
        lastReportedReplyOwner = nil
        lastReportedReplyRect = .null
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
        loadEarlierResetTask?.cancel()
        if let observer = userDefaultsObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        currentStyle = ChatListStyle.current(traits: traitCollection, reduceMotion: currentState?.reduceMotion ?? false)
        view.backgroundColor = UIColor(Ink.paper)

        setupCollectionView()

        registerForTraitChanges([UITraitUserInterfaceStyle.self, UITraitPreferredContentSizeCategory.self]) { (controller: ChatListViewController, _) in
            controller.refreshTypographyAndTheme()
        }

        userDefaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshVisibleUserAvatars()
            }
        }

        if let initialState = currentState {
            applyInitialState(initialState)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshTypographyAndTheme()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
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
            return .absolute(36 + ChatCellMetrics.rowSpacing)

        case .line(let id):
            guard let row = rowByID[id] else { return .absolute(44) }
            switch row.line.kind {
            case .user:
                return .absolute(layoutCache.measureUser(row: row, collectionWidth: width, style: currentStyle).cellHeight)
            case .bot:
                return .absolute(measureAssistant(row: row, width: width).cellHeight)
            case .steps:
                let key = traceHeightKey(row)
                let est = layoutCache.hostingHeight(for: key) ?? 64
                return .estimated(est)
            case .note:
                return .absolute(layoutCache.measureNote(line: row.line, isLatestNote: row.isLatestNote, collectionWidth: width).cellHeight)
            }

        case .liveFolding:
            return .absolute(24 + ChatCellMetrics.rowSpacing)

        case .livePulse:
            let text = currentState?.streamPulse ?? ""
            let tail = text.split(separator: "\n", omittingEmptySubsequences: true).suffix(4).joined(separator: "\n")
            let h = layoutCache.measureLiveText(tail, collectionWidth: width, style: currentStyle, cardInsetH: Ink.Space.m, cardInsetV: Ink.Space.s).cellHeight
            return .absolute(h)

        case .liveThinking:
            return .absolute(ChatLiveThinkingCell.fixedHeight())

        case .liveProse(let gen):
            let text = currentState?.streamText ?? ""
            let h = layoutCache.measureLiveStreamingProse(text: text, generation: gen, collectionWidth: width, style: currentStyle).cellHeight
            return .absolute(h)

        case .liveToolTail:
            let est = layoutCache.hostingHeight(for: "toolTail") ?? 52
            return .estimated(est)

        case .liveFailure:
            let err = currentState?.failureCardError ?? ""
            let working = currentState?.working ?? false
            return .absolute(layoutCache.measureFailure(error: err, working: working, collectionWidth: width))

        case .queued(let id):
            if let item = currentState?.queuedItems.first(where: { $0.id == id }) {
                return .absolute(layoutCache.measureQueued(item, collectionWidth: width).cellHeight)
            }
            return .absolute(56)

        case .bottomSpacer:
            return .absolute(ChatCellMetrics.bottomSpacerHeight)
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
        guard !pendingDynamicRefresh else { return }
        pendingDynamicRefresh = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingDynamicRefresh = false
            guard !self.isDismantled, self.collectionView != nil, self.collectionView.bounds.width > 0 else { return }
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
        premeasureItems(nextItems)

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
            publishVisibleAndFooterMetrics()
        }
    }

    private func resetForChatSwitch(_ next: ChatListState) {
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
        animatedScrollID &+= 1
        isPinnedToBottom = true
        hasPerformedInitialScroll = false
        lastReportedReplyOwner = nil
        lastReportedReplyRect = .null
        scheduleHostMetricsFlush()

        items = buildItemIDs(for: next)
        rebuildIndexMaps(rows: next.rows)
        premeasureItems(items)

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
        let width = max(240, collectionView.bounds.width)
        var layoutMayHaveChanged = false

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
                if prev.streamText != next.streamText,
                   let cell = collectionView.cellForItem(at: indexPath) as? ChatAssistantCell {
                    let entry = layoutCache.measureLiveStreamingProse(text: next.streamText, generation: gen, collectionWidth: width, style: currentStyle)
                    cell.updateLiveStreamingInPlace(entry: entry, style: currentStyle)
                    layoutMayHaveChanged = true
                }

            case .livePulse:
                if prev.streamPulse != next.streamPulse,
                   let cell = collectionView.cellForItem(at: indexPath) as? ChatLivePulseCell {
                    let tail = next.streamPulse.split(separator: "\n", omittingEmptySubsequences: true).suffix(4).joined(separator: "\n")
                    let entry = layoutCache.measureLiveText(tail, collectionWidth: width, style: currentStyle, cardInsetH: Ink.Space.m, cardInsetV: Ink.Space.s)
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
                    layoutMayHaveChanged = true
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
                    layoutMayHaveChanged = true
                }

            case .line(let lineID):
                guard let newRow = nextRowMap[lineID], oldRowMap[lineID] != newRow else { continue }
                updateVisibleRowCell(at: indexPath, newRow: newRow, width: width)
                layoutMayHaveChanged = true

            default:
                break
            }
        }

        // Also check offscreen height changes for fresh handoff / row text edits.
        if prev.streamText != next.streamText || prev.streamPulse != next.streamPulse || prev.rows != next.rows {
            layoutMayHaveChanged = true
        }

        if layoutMayHaveChanged && collectionView.bounds.width > 0 {
            applyStreamingResizePreservingScroll()
        }
        if prev.headerHeight != next.headerHeight {
            updateCollectionInsetsIfNeeded()
        }
        publishVisibleAndFooterMetrics()
    }

    private func updateVisibleRowCell(at indexPath: IndexPath, newRow: ChatListRowItem, width: CGFloat) {
        switch newRow.line.kind {
        case .bot:
            if let cell = collectionView.cellForItem(at: indexPath) as? ChatAssistantCell {
                let entry = measureAssistant(row: newRow, width: width)
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
        case .user:
            if let cell = collectionView.cellForItem(at: indexPath) as? ChatUserCell {
                let entry = layoutCache.measureUser(row: newRow, collectionWidth: width, style: currentStyle)
                cell.configure(row: newRow, entry: entry, style: currentStyle, hostViewController: self, actions: actions)
            }
        case .steps:
            if let cell = collectionView.cellForItem(at: indexPath) as? ChatTraceHostingCell {
                cell.updateLineInPlace(newRow)
            }
        case .note:
            if let cell = collectionView.cellForItem(at: indexPath) as? ChatNoteCell {
                let entry = layoutCache.measureNote(line: newRow.line, isLatestNote: newRow.isLatestNote, collectionWidth: width)
                cell.configure(row: newRow, entry: entry, actions: actions)
            }
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

        let shouldPinToBottom = isPinnedToBottom && !next.historyInView && selectingOwnerIDs.isEmpty
        let switchedHistoryView = prev.historyInView != next.historyInView
        let anchor: (id: ChatListItemID, visualY: CGFloat)? = (!shouldPinToBottom && !switchedHistoryView && pendingScrollRequest == nil)
            ? topVisibleAnchor()
            : nil

        items = nextItems
        rebuildIndexMaps(rows: next.rows)
        premeasureItems(nextItems)

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
                scrollToBottom(animated: false)
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
    }

    private func premeasureItems(_ list: [ChatListItemID]) {
        guard collectionView != nil else { return }
        let width = max(240, collectionView.bounds.width > 0 ? collectionView.bounds.width : view.bounds.width)
        guard width > 0 else { return }
        for itemID in list {
            if case .line(let id) = itemID, let row = rowByID[id] {
                switch row.line.kind {
                case .user:
                    _ = layoutCache.measureUser(row: row, collectionWidth: width, style: currentStyle)
                case .bot:
                    _ = measureAssistant(row: row, width: width)
                case .note:
                    _ = layoutCache.measureNote(line: row.line, isLatestNote: row.isLatestNote, collectionWidth: width)
                case .steps:
                    break
                }
            }
        }
    }

    // MARK: - Typography, Theme, Layout & Insets

    func refreshTypographyAndTheme() {
        let nextStyle = ChatListStyle.current(traits: traitCollection, reduceMotion: currentState?.reduceMotion ?? false)
        view.backgroundColor = UIColor(Ink.paper)
        guard nextStyle != currentStyle else { return }
        currentStyle = nextStyle
        layoutCache.invalidateAll()
        guard collectionView != nil, collectionView.bounds.width > 0 else { return }
        preserveReadingAnchorDuring {
            reconfigureAllVisibleCells()
            collectionView.collectionViewLayout.invalidateLayout()
            collectionView.layoutIfNeeded()
        }
        publishVisibleAndFooterMetrics()
    }

    private func refreshVisibleUserAvatars() {
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
                premeasureItems(items)
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
                scheduleHostMetricsFlush()
            } else if abs(collectionView.bounds.width - lastKnownContentWidth) > 0.5 {
                lastKnownContentWidth = collectionView.bounds.width
                layoutCache.invalidateAll()
                preserveReadingAnchorDuring {
                    reconfigureAllVisibleCells()
                    collectionView.collectionViewLayout.invalidateLayout()
                    collectionView.layoutIfNeeded()
                }
                scheduleHostMetricsFlush()
            }
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
        guard collectionView != nil, collectionView.bounds.width > 0 else { return }
        let windowTop = view.window?.safeAreaInsets.top ?? 0
        let resolvedTop = hostTopInset > 0
            ? hostTopInset
            : max(view.safeAreaInsets.top, windowTop + (currentState?.headerHeight ?? 0))
        let resolvedBottom = hostBottomInset > 0 ? hostBottomInset : view.safeAreaInsets.bottom
        let topInset = resolvedTop + Ink.Space.s
        let bottomInset = resolvedBottom + Ink.Space.xs
        let current = collectionView.contentInset
        guard abs(current.top - topInset) > 0.5 || abs(current.bottom - bottomInset) > 0.5 else { return }

        let wasProgrammatic = isProgrammaticScroll
        isProgrammaticScroll = true
        collectionView.contentInset = UIEdgeInsets(top: topInset, left: 0, bottom: bottomInset, right: 0)
        collectionView.verticalScrollIndicatorInsets = collectionView.contentInset
        if hasPerformedInitialScroll && isPinnedToBottom && !(currentState?.historyInView ?? false) && selectingOwnerIDs.isEmpty {
            scrollToBottom(animated: false)
        }
        lastScrollOffsetY = collectionView.contentOffset.y
        isProgrammaticScroll = wasProgrammatic
        if hasPerformedInitialScroll {
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
        let wasPinned = isPinnedToBottom && !(currentState?.historyInView ?? false) && selectingOwnerIDs.isEmpty
        UIView.performWithoutAnimation {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let wasProgrammatic = isProgrammaticScroll
            isProgrammaticScroll = true
            work()
            if wasPinned {
                scrollToBottom(animated: false)
            } else if let anchor,
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
        let savedOffsetY = collectionView.contentOffset.y
        let pinned = isPinnedToBottom && !(currentState?.historyInView ?? false) && selectingOwnerIDs.isEmpty
        let wasProgrammatic = isProgrammaticScroll

        UIView.performWithoutAnimation {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            isProgrammaticScroll = true

            collectionView.collectionViewLayout.invalidateLayout()
            collectionView.layoutIfNeeded()

            if pinned {
                scrollToBottom(animated: false)
            } else if !wasProgrammatic {
                collectionView.contentOffset = CGPoint(x: collectionView.contentOffset.x, y: savedOffsetY)
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
        if following && isViewLoaded && collectionView.bounds.width > 0 && !(currentState?.historyInView ?? false) && !isProgrammaticScroll {
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

    private func scrollToBottom(animated: Bool) {
        let targetY = bottomOffsetY(for: collectionView)
        isPinnedToBottom = true
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
        if isProgrammaticScroll {
            animatedScrollID &+= 1
            isProgrammaticScroll = false
        }
        actions.onScrollPhaseChanged("拖动")
        actions.onTouchScrollingChanged(true, true)
        actions.chat.setBrowsingHistory(true)
        actions.onScrollingChanged(true)
        actions.onDragStarted()
        if isPinnedToBottom {
            isPinnedToBottom = false
            actions.onFollowingChanged(false)
        }
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
        actions.onScrollPhaseChanged("静止")
        actions.onTouchScrollingChanged(false, false)
        actions.chat.setBrowsingHistory(false)
        actions.onScrollingChanged(false)

        let distanceFromBottom = bottomOffsetY(for: scrollView) - scrollView.contentOffset.y
        let shouldFollow = !(currentState?.historyInView ?? false) && selectingOwnerIDs.isEmpty && distanceFromBottom < 80
        if isPinnedToBottom != shouldFollow {
            isPinnedToBottom = shouldFollow
            actions.onFollowingChanged(shouldFollow)
        }
        if shouldFollow && distanceFromBottom > 2 {
            scrollToBottom(animated: false)
        }
        actions.onScrollEnded()
        publishVisibleAndFooterMetrics()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard hasPerformedInitialScroll, !isDismantled else { return }

        let currentY = scrollView.contentOffset.y
        let prevY = lastScrollOffsetY
        lastScrollOffsetY = currentY

        let bottomY = bottomOffsetY(for: scrollView)
        let isUserTouchScrolling = scrollView.isDragging || scrollView.isDecelerating
        if !isProgrammaticScroll && !isInHostUpdate {
            let userMoving = scrollView.isTracking || isUserTouchScrolling
            let movedUp = currentY < prevY - 0.5 || (scrollView.isDragging && currentY < dragStartOffsetY - 0.5)
            if userMoving && movedUp && currentY < bottomY - 2 && isPinnedToBottom {
                isPinnedToBottom = false
                actions.onFollowingChanged(false)
            }
        }

        let distanceFromTop = currentY + scrollView.contentInset.top
        let movingUp = currentY < prevY
        if !isProgrammaticScroll,
           !isInHostUpdate,
           isUserTouchScrolling,
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

        publishVisibleAndFooterMetrics()
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
        let visiblePaths = collectionView.indexPathsForVisibleItems.sorted { $0.section < $1.section }
        var ids: [String] = []
        ids.reserveCapacity(visiblePaths.count)
        var latestOwner: String?
        var latestRect: CGRect = .null

        for path in visiblePaths where path.section < items.count {
            let itemID = items[path.section]
            if let rowID = itemID.rowID {
                ids.append(rowID)
            }
            if let cell = collectionView.cellForItem(at: path) as? ChatAssistantCell,
               let owner = cell.latestFooterOwnerID {
                latestOwner = owner
                latestRect = cell.footerActionsRectInWindow()
            }
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

        if latestOwner != lastReportedReplyOwner || latestRect != lastReportedReplyRect {
            lastReportedReplyOwner = latestOwner
            lastReportedReplyRect = latestRect
            actions.petPerch.replyActionsOwner = latestOwner
            actions.petPerch.replyActions = latestRect
        }
    }

    private func clearReplyPerchClearance() {
        if let owner = lastReportedReplyOwner, actions.petPerch.replyActionsOwner == owner {
            actions.petPerch.replyActionsOwner = nil
            actions.petPerch.replyActions = .null
        }
        lastReportedReplyOwner = nil
        lastReportedReplyRect = .null
    }

    private func traceHeightKey(_ row: ChatListRowItem) -> String {
        "trace|\(row.line.id)|\(row.line.tools.count)|\(row.line.live ? 1 : 0)|\(row.opens ? 1 : 0)|\(row.faces ? 1 : 0)|\(row.lit ? 1 : 0)"
    }
}
