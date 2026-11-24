import QuartzCore
import SwiftUI
import UIKit

@MainActor
final class SpikeChatViewController: UIViewController, UICollectionViewDelegate, UIScrollViewDelegate {
    var onDismiss: (() -> Void)?

    private var messages: [SpikeMessage] = []
    private var messageIndexByID: [UUID: Int] = [:]
    private let layoutCache = SpikeLayoutCache()
    private var currentStyle: SpikeStyle!

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<UUID, UUID>!

    private let hudView = SpikeHUDView()
    private let composerView = SpikeComposerView()

    private var hasPerformedInitialScroll = false
    private var isPinnedToBottom = true
    private var isLoadingEarlier = false
    private var isProgrammaticScroll = false
    private var prependedBatches = 0
    private var selectingMessageIDs: Set<UUID> = []
    private var lastScrollOffsetY: CGFloat = 0
    private var lastAutoPrependTime: CFTimeInterval = 0
    private var lastKnownContentWidth: CGFloat = 0
    private var lastKnownBottomInset: CGFloat = 0
    private var lastFinalizeDelta: CGFloat?

    // Display link handles both FPS telemetry and 60fps streaming chunk pacing.
    private var displayLink: CADisplayLink?
    private var fpsFrames = 0
    private var fpsWindowStart: CFTimeInterval = 0
    private var fpsLastTimestamp: CFTimeInterval = 0
    private var fpsWorstMs: Double = 0
    private var fpsHitchCount = 0

    private struct StreamState {
        let messageID: UUID
        let fullText: String
        let startTime: CFTimeInterval
        var shownCount: Int
        var lastCommitTime: CFTimeInterval
        var previousHeight: CGFloat
    }
    private var streamState: StreamState?

    private final class DisplayTicker: NSObject {
        weak var owner: SpikeChatViewController?
        init(_ owner: SpikeChatViewController) { self.owner = owner }
        @objc func tick(_ link: CADisplayLink) {
            let timestamp = link.timestamp
            let duration = link.targetTimestamp - link.timestamp
            MainActor.assumeIsolated {
                guard let owner else {
                    link.invalidate()
                    return
                }
                owner.handleDisplayTick(timestamp: timestamp, frameBudget: duration)
            }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        currentStyle = SpikeStyle.current(traits: traitCollection)
        view.backgroundColor = UIColor(Ink.paper)

        setupMessages(SpikeFixtureData.makeInitialMessages())
        setupCollectionView()
        setupChrome()
        applyInitialSnapshot()

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (controller: SpikeChatViewController, _) in
            controller.refreshTypographyAndTheme()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshTypographyAndTheme()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startDisplayLink()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopDisplayLink()
    }

    func refreshTypographyAndTheme() {
        let nextStyle = SpikeStyle.current(traits: traitCollection)
        view.backgroundColor = UIColor(Ink.paper)
        guard nextStyle != currentStyle else { return }
        currentStyle = nextStyle
        layoutCache.invalidateAll()
        guard collectionView != nil, collectionView.bounds.width > 0 else { return }
        preserveReadingAnchorDuring {
            reconfigureVisibleCells()
            collectionView.collectionViewLayout.invalidateLayout()
            collectionView.layoutIfNeeded()
        }
    }

    private func setupMessages(_ list: [SpikeMessage]) {
        messages = list
        rebuildIndexMap()
    }

    private func rebuildIndexMap() {
        messageIndexByID.removeAll(keepingCapacity: true)
        for (idx, msg) in messages.enumerated() {
            messageIndexByID[msg.id] = idx
        }
    }

    private func setupCollectionView() {
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.keyboardDismissMode = .interactive
        collectionView.contentInsetAdjustmentBehavior = .never
        collectionView.delegate = self
        collectionView.translatesAutoresizingMaskIntoConstraints = false

        collectionView.register(SpikeAssistantCell.self, forCellWithReuseIdentifier: SpikeAssistantCell.reuseID)
        collectionView.register(SpikeUserCell.self, forCellWithReuseIdentifier: SpikeUserCell.reuseID)

        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])

        dataSource = UICollectionViewDiffableDataSource<UUID, UUID>(collectionView: collectionView) { [weak self] collectionView, indexPath, itemID in
            guard let self, let index = self.messageIndexByID[itemID] else {
                return UICollectionViewCell()
            }
            let message = self.messages[index]
            let entry = self.layoutCache.measure(
                message: message,
                collectionWidth: collectionView.bounds.width,
                style: self.currentStyle,
                showSpeaker: message.role == .assistant
            )

            switch message.role {
            case .assistant:
                guard let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: SpikeAssistantCell.reuseID,
                    for: indexPath
                ) as? SpikeAssistantCell else {
                    return UICollectionViewCell()
                }
                cell.configure(
                    message: message,
                    entry: entry,
                    style: self.currentStyle,
                    showSpeaker: true,
                    onQuote: { [weak self] excerpt, speaker in
                        self?.composerView.setQuote(excerpt, speaker: speaker)
                    },
                    onSelectionChanged: { [weak self] active in
                        self?.setSelectionActive(active, for: itemID)
                    },
                    onLinkTapped: { [weak self] url in
                        self?.showLinkNotice(url)
                    }
                )
                return cell

            case .user:
                guard let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: SpikeUserCell.reuseID,
                    for: indexPath
                ) as? SpikeUserCell else {
                    return UICollectionViewCell()
                }
                cell.configure(
                    message: message,
                    entry: entry,
                    style: self.currentStyle,
                    onQuote: { [weak self] excerpt, speaker in
                        self?.composerView.setQuote(excerpt, speaker: speaker)
                    },
                    onSelectionChanged: { [weak self] active in
                        self?.setSelectionActive(active, for: itemID)
                    }
                )
                return cell
            }
        }
    }

    private func makeLayout() -> UICollectionViewCompositionalLayout {
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, layoutEnvironment in
            let width = max(240, layoutEnvironment.container.effectiveContentSize.width)
            let height: CGFloat
            if let self,
               let sectionID = self.dataSource?.sectionIdentifier(for: sectionIndex),
               let index = self.messageIndexByID[sectionID] {
                let message = self.messages[index]
                let entry = self.layoutCache.measure(
                    message: message,
                    collectionWidth: width,
                    style: self.currentStyle,
                    showSpeaker: message.role == .assistant
                )
                height = entry.cellHeight
            } else {
                height = 60
            }

            let size = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1.0),
                heightDimension: .absolute(max(24, height))
            )
            let item = NSCollectionLayoutItem(layoutSize: size)
            let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [item])
            return NSCollectionLayoutSection(group: group)
        }
    }

    private func setupChrome() {
        hudView.translatesAutoresizingMaskIntoConstraints = false
        composerView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hudView)
        view.addSubview(composerView)

        view.keyboardLayoutGuide.followsUndockedKeyboard = true

        NSLayoutConstraint.activate([
            hudView.topAnchor.constraint(equalTo: view.topAnchor),
            hudView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hudView.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            composerView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composerView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composerView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])

        hudView.onDismiss = { [weak self] in
            self?.onDismiss?()
        }
        hudView.onLoadEarlier = { [weak self] in
            self?.loadEarlier20(source: "按钮触发")
        }
        hudView.onToggleStream = { [weak self] in
            self?.toggleStreamSimulation()
        }
        hudView.onScrollTop = { [weak self] in
            self?.scrollToTop()
        }
        hudView.onScrollBottom = { [weak self] in
            self?.scrollToBottom(animated: true)
        }
        hudView.onReset = { [weak self] in
            self?.resetPrototype()
        }
        hudView.updateMessageCount(messages.count)
        hudView.updateStreamState(isStreaming: false, finalizeDelta: nil)

        composerView.onSend = { [weak self] text, quote in
            self?.handleUserSend(text: text, quote: quote)
        }
    }

    private func applyInitialSnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<UUID, UUID>()
        let ids = messages.map(\.id)
        snapshot.appendSections(ids)
        for id in ids {
            snapshot.appendItems([id], toSection: id)
        }
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard collectionView.bounds.width > 0 else { return }

        let topInset = hudView.frame.maxY + Ink.Space.xs
        let bottomInset = max(0, view.bounds.height - composerView.frame.minY) + Ink.Space.xs
        let currentInset = collectionView.contentInset
        let insetsChanged = abs(currentInset.top - topInset) > 0.5 || abs(currentInset.bottom - bottomInset) > 0.5

        if insetsChanged {
            let prevBottom = currentInset.bottom
            isProgrammaticScroll = true
            collectionView.contentInset = UIEdgeInsets(top: topInset, left: 0, bottom: bottomInset, right: 0)
            collectionView.verticalScrollIndicatorInsets = collectionView.contentInset
            if hasPerformedInitialScroll {
                if isPinnedToBottom {
                    scrollToBottom(animated: false)
                } else if abs(bottomInset - prevBottom) > 0.5 {
                    lastKnownBottomInset = bottomInset
                }
            }
            lastScrollOffsetY = collectionView.contentOffset.y
            isProgrammaticScroll = false
            lastKnownBottomInset = bottomInset
        }

        if !hasPerformedInitialScroll {
            let width = collectionView.bounds.width
            for msg in messages {
                _ = layoutCache.measure(
                    message: msg,
                    collectionWidth: width,
                    style: currentStyle,
                    showSpeaker: msg.role == .assistant
                )
            }
            collectionView.layoutIfNeeded()
            scrollToBottom(animated: false)
            hasPerformedInitialScroll = true
            lastKnownContentWidth = width
            lastScrollOffsetY = collectionView.contentOffset.y
        } else if abs(collectionView.bounds.width - lastKnownContentWidth) > 0.5 {
            lastKnownContentWidth = collectionView.bounds.width
            layoutCache.invalidateAll()
            preserveReadingAnchorDuring {
                reconfigureVisibleCells()
                collectionView.collectionViewLayout.invalidateLayout()
                collectionView.layoutIfNeeded()
            }
        }
    }

    private func reconfigureVisibleCells() {
        let width = collectionView.bounds.width
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard let id = dataSource.sectionIdentifier(for: indexPath.section),
                  let idx = messageIndexByID[id] else { continue }
            let message = messages[idx]
            let entry = layoutCache.measure(
                message: message,
                collectionWidth: width,
                style: currentStyle,
                showSpeaker: message.role == .assistant
            )
            if let cell = collectionView.cellForItem(at: indexPath) as? SpikeAssistantCell {
                cell.updateInPlace(message: message, entry: entry, style: currentStyle)
            } else if let cell = collectionView.cellForItem(at: indexPath) as? SpikeUserCell {
                cell.configure(
                    message: message,
                    entry: entry,
                    style: currentStyle,
                    onQuote: { [weak self] excerpt, speaker in
                        self?.composerView.setQuote(excerpt, speaker: speaker)
                    },
                    onSelectionChanged: { [weak self] active in
                        self?.setSelectionActive(active, for: id)
                    }
                )
            }
        }
    }

    private func setSelectionActive(_ active: Bool, for messageID: UUID) {
        if active {
            selectingMessageIDs.insert(messageID)
        } else {
            selectingMessageIDs.remove(messageID)
        }
    }

    private func showLinkNotice(_ url: URL) {
        let alert = UIAlertController(title: "链接预览", message: url.absoluteString, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: L.t("actions.done"), style: .default))
        present(alert, animated: true)
    }

    // MARK: - Gate 2: Prepend-20 Y-Anchor Lock

    private func topVisibleAnchor() -> (id: UUID, visualY: CGFloat)? {
        let topEdge = collectionView.contentOffset.y + collectionView.contentInset.top
        let visiblePaths = collectionView.indexPathsForVisibleItems.sorted { $0.section < $1.section }
        let candidate = visiblePaths.first(where: { path in
            guard let attrs = collectionView.layoutAttributesForItem(at: path) else { return false }
            return attrs.frame.maxY > topEdge + 2
        }) ?? visiblePaths.first

        if let path = candidate,
           let id = dataSource.sectionIdentifier(for: path.section),
           let attrs = collectionView.layoutAttributesForItem(at: path) {
            return (id, attrs.frame.minY - collectionView.contentOffset.y)
        }

        if let first = messages.first {
            return (first.id, topEdge)
        }
        return nil
    }

    private func preserveReadingAnchorDuring(_ work: () -> Void) {
        let anchor = topVisibleAnchor()
        let wasPinned = isPinnedToBottom
        UIView.performWithoutAnimation {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            isProgrammaticScroll = true
            work()
            if wasPinned {
                scrollToBottom(animated: false)
            } else if let anchor,
                      let newIdx = messageIndexByID[anchor.id],
                      let afterAttrs = collectionView.layoutAttributesForItem(at: IndexPath(item: 0, section: newIdx)) {
                let targetY = afterAttrs.frame.minY - anchor.visualY
                collectionView.contentOffset = CGPoint(x: collectionView.contentOffset.x, y: targetY)
                collectionView.layoutIfNeeded()
            }
            isProgrammaticScroll = false
            CATransaction.commit()
        }
    }

    func loadEarlier20(source: String) {
        guard !isLoadingEarlier else { return }
        if source == "按钮触发" {
            clearVisibleSelections()
        } else if !selectingMessageIDs.isEmpty {
            return
        }

        guard let anchor = topVisibleAnchor() else { return }
        isLoadingEarlier = true
        isProgrammaticScroll = true

        let nextBatchIndex = prependedBatches + 1
        let batch = SpikeFixtureData.makeEarlierBatch(batchIndex: nextBatchIndex, count: 20)
        let width = max(240, collectionView.bounds.width)
        for msg in batch {
            _ = layoutCache.measure(
                message: msg,
                collectionWidth: width,
                style: currentStyle,
                showSpeaker: msg.role == .assistant
            )
        }

        var measuredDelta: CGFloat = 0

        UIView.performWithoutAnimation {
            CATransaction.begin()
            CATransaction.setDisableActions(true)

            prependedBatches = nextBatchIndex
            messages.insert(contentsOf: batch, at: 0)
            rebuildIndexMap()

            var snapshot = NSDiffableDataSourceSnapshot<UUID, UUID>()
            let ids = messages.map(\.id)
            snapshot.appendSections(ids)
            for id in ids {
                snapshot.appendItems([id], toSection: id)
            }
            dataSource.apply(snapshot, animatingDifferences: false)
            collectionView.layoutIfNeeded()

            if let newIdx = messageIndexByID[anchor.id],
               let afterAttrs = collectionView.layoutAttributesForItem(at: IndexPath(item: 0, section: newIdx)) {
                let targetY = afterAttrs.frame.minY - anchor.visualY
                collectionView.contentOffset = CGPoint(x: collectionView.contentOffset.x, y: targetY)
                collectionView.layoutIfNeeded()

                let verifiedY = collectionView.layoutAttributesForItem(at: IndexPath(item: 0, section: newIdx))?.frame.minY ?? afterAttrs.frame.minY
                let afterVisualY = verifiedY - collectionView.contentOffset.y
                measuredDelta = afterVisualY - anchor.visualY
            }

            CATransaction.commit()
        }

        lastScrollOffsetY = collectionView.contentOffset.y
        isProgrammaticScroll = false
        isLoadingEarlier = false

        hudView.updateMessageCount(messages.count)
        hudView.updateAnchorDelta(measuredDelta, source: source)
    }

    private func clearVisibleSelections() {
        for cell in collectionView.visibleCells {
            if let assistant = cell as? SpikeAssistantCell {
                assistant.clearSelection()
            } else if let user = cell as? SpikeUserCell {
                user.clearSelection()
            }
        }
        selectingMessageIDs.removeAll()
    }

    // MARK: - Gate 3: Streaming -> Finalize Zero-Flicker

    private func toggleStreamSimulation() {
        if streamState != nil {
            finalizeStream(immediate: true)
        } else {
            startStream(script: SpikeFixtureData.streamingScript)
        }
    }

    private func handleUserSend(text: String, quote: String?) {
        if streamState != nil {
            finalizeStream(immediate: true)
        }
        let userMsg = SpikeMessage(
            role: .user,
            speaker: "你",
            text: text,
            quote: quote,
            timestampText: "刚刚"
        )
        appendMessage(userMsg, scrollToEnd: true)
        let replyScript = SpikeFixtureData.makeReplyScript(for: text, quote: quote)
        startStream(script: replyScript)
    }

    private func startStream(script: String) {
        let message = SpikeMessage(
            role: .assistant,
            speaker: SpikeFixtureData.assistantName,
            text: "",
            timestampText: "实时"
        )
        var streamingMessage = message
        streamingMessage.isStreaming = true

        let width = max(240, collectionView.bounds.width)
        let initialEntry = layoutCache.measure(
            message: streamingMessage,
            collectionWidth: width,
            style: currentStyle,
            showSpeaker: true
        )

        appendMessage(streamingMessage, scrollToEnd: true)

        let now = CACurrentMediaTime()
        streamState = StreamState(
            messageID: streamingMessage.id,
            fullText: script,
            startTime: now,
            shownCount: 0,
            lastCommitTime: now - 0.02,
            previousHeight: initialEntry.cellHeight
        )
        hudView.updateStreamState(isStreaming: true, finalizeDelta: nil)
    }

    private func appendMessage(_ message: SpikeMessage, scrollToEnd: Bool) {
        let width = max(240, collectionView.bounds.width)
        _ = layoutCache.measure(
            message: message,
            collectionWidth: width,
            style: currentStyle,
            showSpeaker: message.role == .assistant
        )

        UIView.performWithoutAnimation {
            CATransaction.begin()
            CATransaction.setDisableActions(true)

            messages.append(message)
            rebuildIndexMap()

            var snapshot = dataSource.snapshot()
            snapshot.appendSections([message.id])
            snapshot.appendItems([message.id], toSection: message.id)
            dataSource.apply(snapshot, animatingDifferences: false)
            collectionView.layoutIfNeeded()

            if scrollToEnd {
                isPinnedToBottom = true
                scrollToBottom(animated: false)
            }
            CATransaction.commit()
        }
        hudView.updateMessageCount(messages.count)
    }

    private func stepStream(timestamp: CFTimeInterval) {
        guard var state = streamState else { return }
        guard timestamp - state.lastCommitTime >= (1.0 / 62.0) else { return }

        let totalChars = state.fullText.count
        if state.shownCount >= totalChars {
            finalizeStream(immediate: false)
            return
        }

        let elapsed = max(0, timestamp - state.startTime)
        let charsPerSecond = 320.0
        let targetCount = min(totalChars, max(state.shownCount + 1, Int(elapsed * charsPerSecond)))
        guard targetCount > state.shownCount else { return }

        state.shownCount = targetCount
        state.lastCommitTime = timestamp

        guard let index = messageIndexByID[state.messageID] else {
            streamState = nil
            return
        }

        let endIdx = state.fullText.index(state.fullText.startIndex, offsetBy: targetCount)
        let slice = String(state.fullText[..<endIdx])
        messages[index].text = slice
        let width = max(240, collectionView.bounds.width)
        let entry = layoutCache.measure(
            message: messages[index],
            collectionWidth: width,
            style: currentStyle,
            showSpeaker: true
        )

        let indexPath = IndexPath(item: 0, section: index)
        if let cell = collectionView.cellForItem(at: indexPath) as? SpikeAssistantCell {
            cell.updateInPlace(message: messages[index], entry: entry, style: currentStyle)
        }

        if abs(entry.cellHeight - state.previousHeight) > 0.25 {
            state.previousHeight = entry.cellHeight
            applyStreamingResizePreservingScroll()
        }

        streamState = state
    }

    private func finalizeStream(immediate: Bool) {
        guard let state = streamState,
              let index = messageIndexByID[state.messageID] else {
            streamState = nil
            hudView.updateStreamState(isStreaming: false, finalizeDelta: lastFinalizeDelta)
            return
        }
        streamState = nil

        let indexPath = IndexPath(item: 0, section: index)
        let beforeCellHeight = collectionView.layoutAttributesForItem(at: indexPath)?.frame.height ?? state.previousHeight

        if immediate {
            messages[index].text = state.fullText
        }
        messages[index].isStreaming = false

        let width = max(240, collectionView.bounds.width)
        let finalEntry = layoutCache.measure(
            message: messages[index],
            collectionWidth: width,
            style: currentStyle,
            showSpeaker: true
        )

        if let cell = collectionView.cellForItem(at: indexPath) as? SpikeAssistantCell {
            cell.updateInPlace(message: messages[index], entry: finalEntry, style: currentStyle)
        }

        let delta = finalEntry.cellHeight - beforeCellHeight
        if abs(delta) > 0.25 {
            applyStreamingResizePreservingScroll()
        }

        lastFinalizeDelta = delta
        hudView.updateStreamState(isStreaming: false, finalizeDelta: delta)
    }

    private func applyStreamingResizePreservingScroll() {
        let savedOffsetY = collectionView.contentOffset.y
        let pinned = isPinnedToBottom

        UIView.performWithoutAnimation {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            isProgrammaticScroll = true

            collectionView.collectionViewLayout.invalidateLayout()
            collectionView.layoutIfNeeded()

            if pinned {
                scrollToBottom(animated: false)
            } else {
                collectionView.contentOffset = CGPoint(x: collectionView.contentOffset.x, y: savedOffsetY)
            }

            isProgrammaticScroll = false
            CATransaction.commit()
        }
    }

    // MARK: - Navigation & Reset

    private func scrollToTop() {
        isPinnedToBottom = false
        isProgrammaticScroll = true
        let topY = -collectionView.contentInset.top
        collectionView.setContentOffset(CGPoint(x: 0, y: topY), animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            self.isProgrammaticScroll = false
            self.lastScrollOffsetY = self.collectionView.contentOffset.y
        }
    }

    private func scrollToBottom(animated: Bool) {
        let minY = -collectionView.contentInset.top
        let maxY = collectionView.contentSize.height - collectionView.bounds.height + collectionView.contentInset.bottom
        let targetY = max(minY, maxY)
        isPinnedToBottom = true
        if animated {
            isProgrammaticScroll = true
            collectionView.setContentOffset(CGPoint(x: 0, y: targetY), animated: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self else { return }
                self.isProgrammaticScroll = false
                self.lastScrollOffsetY = self.collectionView.contentOffset.y
            }
        } else {
            collectionView.contentOffset = CGPoint(x: 0, y: targetY)
            lastScrollOffsetY = targetY
        }
    }

    private func resetPrototype() {
        streamState = nil
        prependedBatches = 0
        selectingMessageIDs.removeAll()
        composerView.clearQuote()
        layoutCache.invalidateAll()
        setupMessages(SpikeFixtureData.makeInitialMessages())
        hudView.resetMetrics()
        hudView.updateStreamState(isStreaming: false, finalizeDelta: nil)
        hudView.updateMessageCount(messages.count)

        UIView.performWithoutAnimation {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            isProgrammaticScroll = true
            applyInitialSnapshot()
            collectionView.layoutIfNeeded()
            scrollToBottom(animated: false)
            isProgrammaticScroll = false
            CATransaction.commit()
        }
    }

    // MARK: - UIScrollViewDelegate & UICollectionViewDelegate

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard hasPerformedInitialScroll else { return }

        if !isProgrammaticScroll {
            let bottomY = max(-scrollView.contentInset.top, scrollView.contentSize.height - scrollView.bounds.height + scrollView.contentInset.bottom)
            isPinnedToBottom = (bottomY - scrollView.contentOffset.y) <= 36
        }

        let distanceFromTop = scrollView.contentOffset.y + scrollView.contentInset.top
        let movingUp = scrollView.contentOffset.y < lastScrollOffsetY
        lastScrollOffsetY = scrollView.contentOffset.y

        if !isProgrammaticScroll,
           !isLoadingEarlier,
           selectingMessageIDs.isEmpty,
           movingUp,
           distanceFromTop < 180,
           CACurrentMediaTime() - lastAutoPrependTime > 0.35 {
            lastAutoPrependTime = CACurrentMediaTime()
            loadEarlier20(source: "触顶自动加载")
        }
    }

    func collectionView(_ collectionView: UICollectionView, didEndDisplaying cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        if let id = dataSource.sectionIdentifier(for: indexPath.section) {
            selectingMessageIDs.remove(id)
        }
    }

    // MARK: - DisplayLink FPS + Streaming Driver

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: DisplayTicker(self), selector: #selector(DisplayTicker.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
        fpsFrames = 0
        fpsWindowStart = 0
        fpsLastTimestamp = 0
        fpsWorstMs = 0
        fpsHitchCount = 0
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }

    private func handleDisplayTick(timestamp: CFTimeInterval, frameBudget: CFTimeInterval) {
        if fpsWindowStart == 0 {
            fpsWindowStart = timestamp
            fpsLastTimestamp = timestamp
        } else {
            let dt = timestamp - fpsLastTimestamp
            fpsLastTimestamp = timestamp
            fpsFrames += 1
            let ms = dt * 1000
            if ms > fpsWorstMs { fpsWorstMs = ms }
            let expected = frameBudget > 0 ? frameBudget : (1.0 / 60.0)
            if dt > expected * 1.5 {
                fpsHitchCount += 1
            }

            let span = timestamp - fpsWindowStart
            if span >= 0.4 {
                let fps = Int((Double(fpsFrames) / span).rounded())
                let maxFPS = view.window?.windowScene?.screen.maximumFramesPerSecond ?? 60
                hudView.updateFPS(fps, maxFPS: maxFPS, worstMs: fpsWorstMs, hitches: fpsHitchCount)
                fpsFrames = 0
                fpsWorstMs = 0
                fpsHitchCount = 0
                fpsWindowStart = timestamp
            }
        }

        if streamState != nil {
            stepStream(timestamp: timestamp)
        }
    }
}
