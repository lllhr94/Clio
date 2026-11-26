import AgentKit
import Combine
import Craft
import Observation
import SwiftUI
import UIKit

/// Unified scroll bridge allowing `ChatPage`, `ChatPage+Dock`, and `ChatPage+Finding`
/// to target either `ChatListUIKit` or the SwiftUI fallback `ScrollViewProxy`.
@MainActor
final class ChatScroller {
    private let swiftUIProxy: ScrollViewProxy?
    private weak var listProxy: ChatListControllerProxy?

    init(proxy: ScrollViewProxy) {
        self.swiftUIProxy = proxy
        self.listProxy = nil
    }

    init(listProxy: ChatListControllerProxy) {
        self.swiftUIProxy = nil
        self.listProxy = listProxy
    }

    func scrollTo(_ id: String, anchor: UnitPoint) {
        if let swiftUIProxy {
            swiftUIProxy.scrollTo(id, anchor: anchor)
        } else if let listProxy {
            let shouldAnimate: Bool
            if id == ChatPage.end {
                shouldAnimate = !listProxy.isNearBottom
            } else {
                shouldAnimate = anchor == .center
            }
            listProxy.scrollTo(id: id, anchor: anchor, animated: shouldAnimate)
        }
    }

    func prewarm(_ id: String) {
        listProxy?.prewarmAround(id: id)
    }
}

/// Top-level observable model for hosted `Trace` cells (top-level avoids Xcode 26.3 nested `@Observable` traps).
@MainActor @Observable
final class TraceRowModel {
    var row: ChatListRowItem
    var actions: ChatListActions

    init(row: ChatListRowItem, actions: ChatListActions) {
        self.row = row
        self.actions = actions
    }
}

private struct TraceGeometry: Equatable {
    let lineID: String
    let height: CGFloat
}

/// SwiftUI accessory view hosted inside `ChatTraceHostingCell` for expandable tool steps.
private struct ChatTraceHostView: View {
    let model: TraceRowModel
    let onHeightChanged: (String, CGFloat) -> Void

    private var row: ChatListRowItem { model.row }
    private var actions: ChatListActions { model.actions }

    var body: some View {
        let currentID = row.line.id
        VStack(alignment: .leading, spacing: Ink.Space.s) {
            if row.faces, row.opens, let timeGap = row.timeGap {
                Text(timeGap)
                    .font(Ink.footnote)
                    .foregroundStyle(Ink.inkFaint)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, Ink.Space.xs)
            }
            if row.opens, row.faces || row.isRoom {
                HStack(spacing: Ink.Space.s) {
                    PetStill(
                        size: row.faces ? ChatPage.face : ChatCellMetrics.compactSpeakerSize,
                        wash: row.speakerBot.map { Ink.wash(for: $0) },
                        avatar: true,
                        bot: row.speakerBot
                    )
                    Text(row.speakerTitle)
                        .font(.system(size: Ink.Size.small, weight: .semibold))
                        .foregroundStyle(Ink.inkSoft)
                }
                .accessibilityElement(children: .combine)
            }
            Trace(
                line: row.line,
                visit: { url in
                    actions.bridge.onOpenURL(url)
                },
                openFile: { url, mount in
                    actions.bridge.onOpenFile(url, mount)
                },
                unremember: { id, fact in
                    actions.team.unremember(id, fact: fact)
                }
            )
            .id(currentID)
        }
        .padding(.horizontal, Ink.Space.page)
        .padding(.bottom, Ink.Space.m)
        .background {
            if row.lit {
                RoundedRectangle(cornerRadius: Ink.Radius.small, style: .continuous)
                    .fill(Ink.accentWash)
                    .padding(.horizontal, Ink.Space.page - Ink.Space.s)
                    .padding(.bottom, Ink.Space.xs)
            }
        }
        .onGeometryChange(for: TraceGeometry.self) { proxy in
            TraceGeometry(lineID: currentID, height: proxy.size.height)
        } action: { geo in
            onHeightChanged(geo.lineID, geo.height)
        }
    }
}

/// Self-sizing `UICollectionViewCell` wrapping SwiftUI's interactive `Trace` drawer while keeping `@State` across live updates.
@MainActor
final class ChatTraceHostingCell: UICollectionViewCell {
    static let reuseID = "ChatTraceHostingCell"

    private var model: TraceRowModel?
    private var configuredLineID: String?
    private var onHeightChanged: ((ChatListRowItem, CGFloat) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        row: ChatListRowItem,
        actions: ChatListActions,
        onHeightChanged: @escaping (ChatListRowItem, CGFloat) -> Void
    ) {
        self.onHeightChanged = onHeightChanged
        configuredLineID = row.line.id
        if let model {
            if model.actions !== actions {
                model.actions = actions
            }
            model.row = row
            return
        }
        let nextModel = TraceRowModel(row: row, actions: actions)
        model = nextModel
        contentConfiguration = UIHostingConfiguration {
            ChatTraceHostView(model: nextModel) { [weak self, weak nextModel] reportedLineID, height in
                guard let self,
                      let nextModel,
                      self.configuredLineID == reportedLineID,
                      nextModel.row.line.id == reportedLineID else { return }
                self.onHeightChanged?(nextModel.row, height)
            }
        }
        .margins(.all, 0)
        .background(.clear)
    }

    func updateLineInPlace(_ row: ChatListRowItem) {
        configuredLineID = row.line.id
        model?.row = row
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        configuredLineID = nil
        onHeightChanged = nil
    }
}

/// Top-level observable model driving the detail sheet presented when tapping a `ChatTraceSummaryCell`.
@MainActor @Observable
final class ChatTraceDetailSheetModel {
    var line: ChatLine

    init(line: ChatLine) {
        self.line = line
    }
}

struct ChatTraceDetailSheetView: View {
    let model: ChatTraceDetailSheetModel
    let actions: ChatListActions
    let onDismiss: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Trace(
                    line: model.line,
                    visit: { url in
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            actions.bridge.onOpenURL(url)
                        }
                    },
                    openFile: { url, mount in
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            actions.bridge.onOpenFile(url, mount)
                        }
                    },
                    unremember: { id, fact in
                        actions.team.unremember(id, fact: fact)
                    },
                    initiallyOpen: true
                )
                .padding(.horizontal, Ink.Space.page)
                .padding(.vertical, Ink.Space.l)
            }
            .background(Ink.paper.ignoresSafeArea())
            .navigationTitle(L.t("agent.steps"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(L.t("actions.done")) {
                        dismiss()
                    }
                }
            }
        }
        .onDisappear {
            onDismiss()
        }
    }
}

/// Caches mapped `ChatListRowItem`s so 15Hz live token updates never rebuild unchanged settled rows.
@MainActor
final class ChatRowsMemo {
    private struct CacheKey: Equatable {
        let chatKey: String
        let linesVersion: UInt64
        let visibleCount: Int
        let historyRows: [ChatLine]?
        let heads: Set<String>
        let lit: String?
        let freshWritingID: String?
        let editing: String?
        let faces: Bool
        let isRoom: Bool
        let historyInView: Bool
        let defaultBot: BotInfo
        let teamBots: [BotInfo]
        let showThinking: Bool
        let showStats: Bool
        let working: Bool
        let sendingBlocked: Bool
        let speakingText: String?
        let latestBot: String?
        let latestNote: String?
        let lastLineID: String?
    }

    private var lastKey: CacheKey?
    private var lastFreshShown: Int?
    private var lastItems: [ChatListRowItem] = []

    func buildRows(
        chat: ChatModel,
        displayedRows: [ChatLine],
        visibleRows: [ChatLine],
        heads: Set<String>,
        lit: String?,
        editing: String?,
        faces: Bool,
        isRoom: Bool,
        historyInView: Bool,
        defaultBot: BotInfo,
        teamBots: [BotInfo],
        showThinking: Bool,
        showStats: Bool,
        working: Bool,
        sendingBlocked: Bool,
        speakingText: String?,
        sourcesMemo: ChatPage.SourcesMemo,
        lineMeta: (ChatLine) -> ChatPage.SourcesMemo.LineMeta,
        endsTurn: (ChatLine) -> Bool,
        timeGap: (ChatLine) -> String?
    ) -> [ChatListRowItem] {
        sourcesMemo.sync(rows: displayedRows, defaultBotId: defaultBot.id)

        let freshWritingID = chat.freshWritingID
        let freshShown = freshWritingID != nil ? chat.stream.fresh?.shown : nil
        let latestBot: String?
        if !historyInView {
            latestBot = sourcesMemo.newestBotId
        } else {
            latestBot = displayedRows.last(where: { $0.kind == .bot })?.id
        }
        let latestNote = displayedRows.last(where: { $0.kind == .note })?.id
        let lastLineID = displayedRows.last?.id

        let key = CacheKey(
            chatKey: chat.key,
            linesVersion: chat.linesVersion,
            visibleCount: visibleRows.count,
            historyRows: historyInView ? visibleRows : nil,
            heads: heads,
            lit: lit,
            freshWritingID: freshWritingID,
            editing: editing,
            faces: faces,
            isRoom: isRoom,
            historyInView: historyInView,
            defaultBot: defaultBot,
            teamBots: teamBots,
            showThinking: showThinking,
            showStats: showStats,
            working: working,
            sendingBlocked: sendingBlocked,
            speakingText: speakingText,
            latestBot: latestBot,
            latestNote: latestNote,
            lastLineID: lastLineID
        )

        if let lastKey, lastKey == key {
            if lastFreshShown != freshShown {
                lastFreshShown = freshShown
                if let freshID = freshWritingID,
                   let idx = lastItems.lastIndex(where: { $0.line.id == freshID }) {
                    lastItems[idx].freshShown = freshShown
                }
            }
            return lastItems
        }

        let firstRowId = displayedRows.first?.id
        let defaultBotName = defaultBot.name
        let stepLimitNotice = "（这件事步骤太多，我先停在这里。要我接着做就说一声。）"

        var result: [ChatListRowItem] = []
        result.reserveCapacity(visibleRows.count)

        for line in visibleRows {
            let isFirst = line.id == firstRowId
            let opens = heads.contains(line.id)
            let isFreshWriting = freshWritingID == line.id
            let isBot = line.kind == .bot
            let meta: ChatPage.SourcesMemo.LineMeta? = (isBot && !isFreshWriting) ? lineMeta(line) : nil
            let lookback: (note: String?, rest: String) = (isBot && !isFreshWriting)
                ? ChatPage.lookback(meta?.trimmedText ?? line.text)
                : (nil, "")
            let speakerBot = line.speaker.flatMap { id in teamBots.first { $0.id == id } } ?? (isRoom ? nil : defaultBot)
            let hitStepLimit = isBot
                && !isFreshWriting
                && !historyInView
                && !working
                && !sendingBlocked
                && lastLineID == line.id
                && line.text.trimmingCharacters(in: .whitespacesAndNewlines) == stepLimitNotice

            result.append(ChatListRowItem(
                line: line,
                opens: opens,
                lit: lit == line.id,
                isFirst: isFirst,
                isFreshWriting: isFreshWriting,
                freshShown: isFreshWriting ? freshShown : nil,
                isLatestBot: line.id == latestBot,
                isLatestNote: line.id == latestNote && line.id == lastLineID,
                isLastLine: line.id == lastLineID,
                endsTurn: isBot ? endsTurn(line) : false,
                timeGap: (faces && opens) ? timeGap(line) : nil,
                isEditing: editing == line.id,
                faces: faces,
                isRoom: isRoom,
                historyInView: historyInView,
                speakerBot: speakerBot,
                defaultBotName: defaultBotName,
                lineMeta: meta,
                lookbackNote: lookback.note,
                lookbackRest: lookback.rest,
                showThinking: showThinking,
                showStats: showStats,
                hitStepLimit: hitStepLimit,
                working: working,
                speakingText: speakingText
            ))
        }

        lastKey = key
        lastFreshShown = freshShown
        lastItems = result
        return result
    }
}

private struct SafeVerticalMetrics: Equatable {
    let minY: CGFloat
    let maxY: CGFloat
    let height: CGFloat
}

@MainActor @Observable
private final class ChatTeamSliceObserver {
    var phase: TeamModel.Phase
    var bots: [BotInfo]
    var waiting: Approval?
    var queuedItems: [TeamModel.Queued]
    var isCompressing: Bool
    var canAcceptInput: Bool
    var workDetail: TeamModel.WorkDetail

    @ObservationIgnored private weak var boundTeam: TeamModel?
    @ObservationIgnored private var boundKey = ""
    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []

    init(team: TeamModel, chatKey: String) {
        self.phase = team.phase
        self.bots = team.bots
        self.waiting = team.approvals.first { $0.chat == chatKey }
        self.queuedItems = team.queued[chatKey] ?? []
        self.isCompressing = team.compressing.contains(chatKey)
        self.canAcceptInput = team.canAcceptInput(for: chatKey)
        self.workDetail = team.workDetail(for: chatKey)
        bind(team: team, chatKey: chatKey)
    }

    func bind(team: TeamModel, chatKey: String) {
        guard boundTeam !== team || boundKey != chatKey else { return }
        boundTeam = team
        boundKey = chatKey
        cancellables.removeAll()

        let detail = team.workDetail(for: chatKey)
        if workDetail !== detail { workDetail = detail }
        let nextPhase = team.phase
        if phase != nextPhase { phase = nextPhase }
        let nextBots = team.bots
        if bots != nextBots { bots = nextBots }
        let nextWaiting = team.approvals.first { $0.chat == chatKey }
        if waiting != nextWaiting { waiting = nextWaiting }
        let nextQueued = team.queued[chatKey] ?? []
        if queuedItems != nextQueued { queuedItems = nextQueued }
        let nextCompressing = team.compressing.contains(chatKey)
        if isCompressing != nextCompressing { isCompressing = nextCompressing }
        let nextAccept = team.canAcceptInput(for: chatKey)
        if canAcceptInput != nextAccept { canAcceptInput = nextAccept }

        team.$phase
            .sink { [weak self] next in
                guard let self, self.phase != next else { return }
                self.phase = next
            }
            .store(in: &cancellables)

        team.$bots
            .sink { [weak self] next in
                guard let self, self.bots != next else { return }
                self.bots = next
            }
            .store(in: &cancellables)

        team.$approvals
            .sink { [weak self] all in
                guard let self else { return }
                let match = all.first { $0.chat == chatKey }
                if self.waiting != match { self.waiting = match }
            }
            .store(in: &cancellables)

        team.$queued
            .sink { [weak self] all in
                guard let self else { return }
                let next = all[chatKey] ?? []
                if self.queuedItems != next { self.queuedItems = next }
            }
            .store(in: &cancellables)

        team.$compressing
            .sink { [weak self] all in
                guard let self else { return }
                let next = all.contains(chatKey)
                if self.isCompressing != next { self.isCompressing = next }
            }
            .store(in: &cancellables)

        Publishers.CombineLatest3(team.$openingLeaves, team.$unresolvedLeafOpenChats, team.$queueDispatchSuspended)
            .sink { [weak self] opening, unresolved, suspended in
                guard let self else { return }
                let canDispatch = QueuedMessageStore.canDispatchQueue(isFrozen: Disk.frozen, isRestoring: suspended)
                let next = canDispatch && !opening.contains(chatKey) && !unresolved.contains(chatKey)
                if self.canAcceptInput != next { self.canAcceptInput = next }
            }
            .store(in: &cancellables)
    }
}

/// SwiftUI host embedding `ChatListViewController` edge-to-edge under `header` and `bottomStack`
/// while preserving safe-area alignment for `minimap` and automatic keyboard/dock inset tracking.
struct ChatUIKitContainer<Minimap: View>: View {
    let chat: ChatModel
    let team: TeamModel
    let bot: BotInfo
    let isRoom: Bool
    let displayedRows: [ChatLine]
    let visibleRows: [ChatLine]
    let heads: Set<String>
    let historyPage: [ChatLine]?
    let shownCount: Int
    let isLoadingEarlier: Bool
    let lit: String?
    let editing: String?
    let speakingText: String?
    let headerHeight: CGFloat
    let headerBottomY: CGFloat?
    let dockTopY: CGFloat?
    let starters: [(String, String, String)]
    let reach: String
    let petPerch: PetPerch
    let chrome: ChatChrome
    let chromeCoordinator: ChatChromeCoordinator
    let viewport: ChatViewport
    let followState: ChatFollowState
    let dictationSlot: ChatDictationSlot
    let idleMood: ChatIdleMood
    let bridge: ChatRowBridge
    let sourcesMemo: ChatPage.SourcesMemo
    let listProxy: ChatListControllerProxy
    let typing: FocusState<Bool>.Binding
    @Binding var touchScrolling: Bool
    @Binding var quote: String?
    let onLoadEarlier: () -> Void
    let onSelectionChanged: (UUID, Bool) -> Void
    let onSpeak: (String) -> Void
    let onSaveNote: (String, String) -> Void
    let onPickStarter: (String) -> Void
    let onStir: () -> Void
    let onDragStarted: () -> Void
    let onScrollEnded: () -> Void
    let lineMeta: (ChatLine) -> ChatPage.SourcesMemo.LineMeta
    let endsTurn: (ChatLine) -> Bool
    let timeGap: (ChatLine) -> String?
    @ViewBuilder let minimap: () -> Minimap

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.photoZoomNamespace) private var photoZoomNamespace

    @AppStorage("chat.faces") private var faces = false
    @AppStorage("look.thinking") private var showThinking = true
    @AppStorage("look.stats") private var showStats = true

    @State private var fullVertical = SafeVerticalMetrics(minY: 0, maxY: 0, height: 0)
    @State private var safeVertical = SafeVerticalMetrics(minY: 0, maxY: 0, height: 0)
    @State private var rowsMemo = ChatRowsMemo()
    @State private var photoHero: ChatPhotoHeroTarget?
    @State private var teamSlice: ChatTeamSliceObserver

    init(
        chat: ChatModel,
        team: TeamModel,
        bot: BotInfo,
        isRoom: Bool,
        displayedRows: [ChatLine],
        visibleRows: [ChatLine],
        heads: Set<String>,
        historyPage: [ChatLine]?,
        shownCount: Int,
        isLoadingEarlier: Bool,
        lit: String?,
        editing: String?,
        speakingText: String?,
        headerHeight: CGFloat,
        headerBottomY: CGFloat?,
        dockTopY: CGFloat?,
        starters: [(String, String, String)],
        reach: String,
        petPerch: PetPerch,
        chrome: ChatChrome,
        chromeCoordinator: ChatChromeCoordinator,
        viewport: ChatViewport,
        followState: ChatFollowState,
        dictationSlot: ChatDictationSlot,
        idleMood: ChatIdleMood,
        bridge: ChatRowBridge,
        sourcesMemo: ChatPage.SourcesMemo,
        listProxy: ChatListControllerProxy,
        typing: FocusState<Bool>.Binding,
        touchScrolling: Binding<Bool>,
        quote: Binding<String?>,
        onLoadEarlier: @escaping () -> Void,
        onSelectionChanged: @escaping (UUID, Bool) -> Void,
        onSpeak: @escaping (String) -> Void,
        onSaveNote: @escaping (String, String) -> Void,
        onPickStarter: @escaping (String) -> Void,
        onStir: @escaping () -> Void,
        onDragStarted: @escaping () -> Void,
        onScrollEnded: @escaping () -> Void,
        lineMeta: @escaping (ChatLine) -> ChatPage.SourcesMemo.LineMeta,
        endsTurn: @escaping (ChatLine) -> Bool,
        timeGap: @escaping (ChatLine) -> String?,
        @ViewBuilder minimap: @escaping () -> Minimap
    ) {
        self.chat = chat
        self.team = team
        self.bot = bot
        self.isRoom = isRoom
        self.displayedRows = displayedRows
        self.visibleRows = visibleRows
        self.heads = heads
        self.historyPage = historyPage
        self.shownCount = shownCount
        self.isLoadingEarlier = isLoadingEarlier
        self.lit = lit
        self.editing = editing
        self.speakingText = speakingText
        self.headerHeight = headerHeight
        self.headerBottomY = headerBottomY
        self.dockTopY = dockTopY
        self.starters = starters
        self.reach = reach
        self.petPerch = petPerch
        self.chrome = chrome
        self.chromeCoordinator = chromeCoordinator
        self.viewport = viewport
        self.followState = followState
        self.dictationSlot = dictationSlot
        self.idleMood = idleMood
        self.bridge = bridge
        self.sourcesMemo = sourcesMemo
        self.listProxy = listProxy
        self.typing = typing
        self._touchScrolling = touchScrolling
        self._quote = quote
        self.onLoadEarlier = onLoadEarlier
        self.onSelectionChanged = onSelectionChanged
        self.onSpeak = onSpeak
        self.onSaveNote = onSaveNote
        self.onPickStarter = onPickStarter
        self.onStir = onStir
        self.onDragStarted = onDragStarted
        self.onScrollEnded = onScrollEnded
        self.lineMeta = lineMeta
        self.endsTurn = endsTurn
        self.timeGap = timeGap
        self.minimap = minimap
        self._teamSlice = State(initialValue: ChatTeamSliceObserver(team: team, chatKey: chat.key))
    }

    private var safeTopInset: CGFloat {
        guard fullVertical.height > 0, safeVertical.height > 0 else { return 0 }
        let headerEdge = headerBottomY ?? safeVertical.minY
        return max(0, max(safeVertical.minY, headerEdge) - fullVertical.minY)
    }

    private var safeBottomInset: CGFloat {
        guard fullVertical.height > 0, safeVertical.height > 0 else { return 0 }
        let dockEdge = dockTopY ?? safeVertical.maxY
        return max(0, fullVertical.maxY - min(safeVertical.maxY, dockEdge))
    }

    private var styleSignal: String {
        let darkFlag = colorScheme == .dark ? 1 : 0
        let motionFlag = reduceMotion ? 1 : 0
        return "\(darkFlag)|\(motionFlag)|\(dynamicTypeSize)"
    }

    private var doing: String? {
        teamSlice.workDetail.words
    }

    private var working: Bool {
        doing != nil || chat.hasStreaming
    }

    private var sendingBlocked: Bool {
        teamSlice.phase != .demo && !teamSlice.canAcceptInput
    }

    private var waiting: Approval? {
        teamSlice.waiting
    }

    var body: some View {
        let state = makeListState()
        ZStack {
            photoHeroProxy

            ChatFollowHostSyncView(followState: followState, listProxy: listProxy, petPerch: petPerch)

            ChatListUIKitRepresentable(
                state: state,
                styleSignal: styleSignal,
                safeTopInset: safeTopInset,
                safeBottomInset: safeBottomInset,
                touchScrolling: $touchScrolling,
                quote: $quote,
                photoHero: $photoHero,
                chrome: chrome,
                chromeCoordinator: chromeCoordinator,
                viewport: viewport,
                followState: followState,
                petPerch: petPerch,
                chat: chat,
                team: team,
                bridge: bridge,
                dictationSlot: dictationSlot,
                idleMood: idleMood,
                listProxy: listProxy,
                typing: typing,
                onLoadEarlier: onLoadEarlier,
                onSelectionChanged: onSelectionChanged,
                onSpeak: onSpeak,
                onSaveNote: onSaveNote,
                onPickStarter: onPickStarter,
                onStir: onStir,
                onDragStarted: onDragStarted,
                onScrollEnded: onScrollEnded,
                makeEmptyView: { makeEmptyStatusAnyView() }
            )
            .ignoresSafeArea()
            .onGeometryChange(for: SafeVerticalMetrics.self) { proxy in
                let rect = proxy.frame(in: .global)
                return SafeVerticalMetrics(
                    minY: rect.minY.rounded(),
                    maxY: rect.maxY.rounded(),
                    height: rect.height.rounded()
                )
            } action: { metrics in
                fullVertical = metrics
            }

            Color.clear
                .allowsHitTesting(false)
                .onGeometryChange(for: SafeVerticalMetrics.self) { proxy in
                    let rect = proxy.frame(in: .global)
                    return SafeVerticalMetrics(
                        minY: rect.minY.rounded(),
                        maxY: rect.maxY.rounded(),
                        height: rect.height.rounded()
                    )
                } action: { metrics in
                    safeVertical = metrics
                }
                .overlay(alignment: .trailing) { minimap() }

        }
        .onAppear {
            teamSlice.bind(team: team, chatKey: chat.key)
        }
        .onChange(of: chat.key) { _, newKey in
            teamSlice.bind(team: team, chatKey: newKey)
        }
    }

    @ViewBuilder
    private var photoHeroProxy: some View {
        if let photoZoomNamespace, !reduceMotion, fullVertical.height > 0 {
            ChatPhotoHeroPreviewView(hero: photoHero, namespace: photoZoomNamespace)
        }
    }

    private func makeEmptyStatusAnyView() -> AnyView {
        AnyView(
            ChatEmptyStatusView(chat: chat) {
                ChatEmptyContentView(
                    chat: chat,
                    team: team,
                    bot: bot,
                    dictationSlot: dictationSlot,
                    idleMood: idleMood,
                    starters: starters,
                    reach: reach,
                    typing: typing,
                    onPickStarter: onPickStarter
                )
            }
        )
    }

    private func makeListState() -> ChatListState {
        let rows = rowsMemo.buildRows(
            chat: chat,
            displayedRows: displayedRows,
            visibleRows: visibleRows,
            heads: heads,
            lit: lit,
            editing: editing,
            faces: faces,
            isRoom: isRoom,
            historyInView: historyPage != nil,
            defaultBot: bot,
            teamBots: teamSlice.bots,
            showThinking: showThinking,
            showStats: showStats,
            working: working,
            sendingBlocked: sendingBlocked,
            speakingText: speakingText,
            sourcesMemo: sourcesMemo,
            lineMeta: lineMeta,
            endsTurn: endsTurn,
            timeGap: timeGap
        )

        let showToolTail: Bool = {
            guard let activeDoing = doing,
                  activeDoing.contains("："),
                  let kind = Trace.canonicalKind(of: activeDoing) else {
                return false
            }
            let icon = Trace.icon(for: kind)
            return icon == "terminal" || icon == "mountain.2"
        }()

        let failureCardError: String? = {
            guard let error = chat.error else { return nil }
            if let last = chat.lines.last,
               last.kind == .note,
               let firstLine = error.split(separator: "\n").first,
               last.text.contains(firstLine) {
                return nil
            }
            return error
        }()

        let emptyPetState = ChatPage.companionPetState(
            waiting: waiting,
            hasStreaming: chat.hasStreaming,
            doing: doing,
            working: working,
            typing: typing.wrappedValue,
            listening: dictationSlot.instance?.listening == true,
            cheering: idleMood.cheering,
            dozing: idleMood.dozing
        )

        let pulseSpeaker = chat.stream.pulseSpeaker.flatMap { id in
            teamSlice.bots.first { $0.id == id }
        }

        let canLoadEarlier = historyPage == nil && (displayedRows.count > shownCount || chat.hasEarlier)

        return ChatListState(
            chatKey: chat.key,
            loaded: chat.loaded,
            canLoadEarlier: canLoadEarlier,
            isLoadingEarlier: isLoadingEarlier,
            historyInView: historyPage != nil,
            isRoom: isRoom,
            defaultBot: bot,
            teamBots: teamSlice.bots,
            working: working,
            sendingBlocked: sendingBlocked,
            faces: faces,
            rows: rows,
            isCompressing: teamSlice.isCompressing,
            streamPulse: chat.stream.pulse,
            streamPulseSpeaker: pulseSpeaker,
            streamReasoning: chat.stream.reasoning,
            streamText: chat.stream.text,
            streamGeneration: chat.stream.generation,
            hasStreaming: chat.hasStreaming,
            fresh: chat.stream.fresh,
            showToolTail: showToolTail,
            failureCardError: failureCardError,
            queuedItems: teamSlice.queuedItems,
            emptyPetState: emptyPetState,
            starters: starters,
            reach: reach,
            headerHeight: headerHeight,
            reduceMotion: reduceMotion
        )
    }
}

private struct ChatFollowHostSyncView: View {
    let followState: ChatFollowState
    let listProxy: ChatListControllerProxy
    let petPerch: PetPerch

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onChange(of: followState.following, initial: true) { _, next in
                petPerch.avoidsReplies = next
                if let controller = listProxy.controller, controller.isPinnedToBottom != next {
                    controller.setFollowingFromHost(next)
                }
            }
    }
}

/// UIKit representable wrapping `ChatListViewController` with loop-free bidirectional state binding.
private struct ChatListUIKitRepresentable: UIViewControllerRepresentable {
    let state: ChatListState
    let styleSignal: String
    let safeTopInset: CGFloat
    let safeBottomInset: CGFloat
    @Binding var touchScrolling: Bool
    @Binding var quote: String?
    @Binding var photoHero: ChatPhotoHeroTarget?
    let chrome: ChatChrome
    let chromeCoordinator: ChatChromeCoordinator
    let viewport: ChatViewport
    let followState: ChatFollowState
    let petPerch: PetPerch
    let chat: ChatModel
    let team: TeamModel
    let bridge: ChatRowBridge
    let dictationSlot: ChatDictationSlot
    let idleMood: ChatIdleMood
    let listProxy: ChatListControllerProxy
    let typing: FocusState<Bool>.Binding
    let onLoadEarlier: () -> Void
    let onSelectionChanged: (UUID, Bool) -> Void
    let onSpeak: (String) -> Void
    let onSaveNote: (String, String) -> Void
    let onPickStarter: (String) -> Void
    let onStir: () -> Void
    let onDragStarted: () -> Void
    let onScrollEnded: () -> Void
    let makeEmptyView: () -> AnyView

    func makeCoordinator() -> Coordinator {
        Coordinator(lastStyleSignal: styleSignal)
    }

    func makeUIViewController(context: Context) -> ChatListViewController {
        let actions = ChatListActions(
            chat: chat,
            team: team,
            bridge: bridge,
            dictationSlot: dictationSlot,
            idleMood: idleMood,
            petPerch: petPerch
        )
        wireActions(actions, coordinator: context.coordinator)

        let controller = ChatListViewController(actions: actions)
        controller.makeEmptyView = makeEmptyView
        listProxy.controller = controller
        context.coordinator.actions = actions
        controller.performHostUpdate {
            controller.setHostSafeInsets(top: safeTopInset, bottom: safeBottomInset)
            controller.setFollowingFromHost(followState.following)
            controller.applyState(state)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: ChatListViewController, context: Context) {
        let coordinator = context.coordinator
        guard !coordinator.isDismantled else { return }
        if let actions = coordinator.actions {
            wireActions(actions, coordinator: coordinator)
        }
        uiViewController.makeEmptyView = makeEmptyView
        listProxy.controller = uiViewController

        uiViewController.performHostUpdate {
            if coordinator.lastStyleSignal != styleSignal {
                coordinator.lastStyleSignal = styleSignal
                uiViewController.refreshTypographyAndTheme()
            }

            uiViewController.setHostSafeInsets(top: safeTopInset, bottom: safeBottomInset)

            uiViewController.applyState(state)
        }
    }

    static func dismantleUIViewController(_ uiViewController: ChatListViewController, coordinator: Coordinator) {
        coordinator.isDismantled = true
        let staleIDs = Array(coordinator.ownedSelectionIDs)
        coordinator.ownedSelectionIDs.removeAll()
        let staleReplyOwner = uiViewController.prepareForDismantle()
        let clearSelection = coordinator.onClearSelection
        let perch = coordinator.petPerch
        let proxy = coordinator.listProxy
        if proxy?.controller === uiViewController {
            proxy?.controller = nil
        }

        Task { @MainActor in
            for uuid in staleIDs {
                clearSelection?(uuid, false)
            }
            if let staleReplyOwner, perch?.replyActionsOwner == staleReplyOwner {
                perch?.replyActionsOwner = nil
                perch?.replyActions = .null
            }
        }
    }

    private func wireActions(_ actions: ChatListActions, coordinator: Coordinator) {
        coordinator.onClearSelection = onSelectionChanged
        coordinator.petPerch = petPerch
        coordinator.listProxy = listProxy

        actions.onLoadEarlier = { [weak coordinator] in
            guard let coordinator, !coordinator.isDismantled else { return }
            onLoadEarlier()
        }

        actions.onQuoteExcerpt = { [weak coordinator, typing] excerpt in
            guard let coordinator, !coordinator.isDismantled else { return }
            Haptics.tick(0.5)
            withAnimation(Ink.Motion.settle) {
                quote = excerpt
            }
            typing.wrappedValue = true
        }

        actions.onSpeakExcerpt = { [weak coordinator] excerpt in
            guard let coordinator, !coordinator.isDismantled else { return }
            Haptics.light()
            onSpeak(excerpt)
        }

        actions.onSaveNoteExcerpt = { [weak coordinator] lineID, excerpt in
            guard let coordinator, !coordinator.isDismantled else { return }
            onSaveNote(lineID, excerpt)
        }

        actions.onSelectionChanged = { [weak coordinator] uuid, active in
            guard let coordinator else { return }
            if active {
                coordinator.ownedSelectionIDs.insert(uuid)
            } else {
                coordinator.ownedSelectionIDs.remove(uuid)
            }
            guard !coordinator.isDismantled else { return }
            onSelectionChanged(uuid, active)
        }

        actions.onFollowingChanged = { [weak coordinator] next in
            guard let coordinator, !coordinator.isDismantled else { return }
            if followState.following != next {
                followState.following = next
            }
        }

        actions.onTouchScrollingChanged = { [weak coordinator] isTouching, isTouchScroll in
            guard let coordinator, !coordinator.isDismantled else { return }
            if viewport.isTouching != isTouching {
                viewport.isTouching = isTouching
            }
            if touchScrolling != isTouchScroll {
                touchScrolling = isTouchScroll
            }
        }

        actions.onScrollingChanged = { [weak coordinator] moving in
            guard let coordinator, !coordinator.isDismantled else { return }
            if moving != chrome.scrolling {
                chrome.scrolling = moving
                onStir()
                Hitches.shared.doing(moving ? Words.t("滚动絮语") : nil, as: "scroll")
            }
        }

        actions.onFarFromEndChanged = { [weak coordinator] far in
            guard let coordinator, !coordinator.isDismantled else { return }
            if chrome.farFromEnd != far {
                withAnimation(Ink.Motion.settle) {
                    chrome.farFromEnd = far
                }
            }
        }

        actions.onNeedsEndCorrectionChanged = { [weak coordinator] needs in
            guard let coordinator, !coordinator.isDismantled else { return }
            if viewport.needsEndCorrection != needs {
                viewport.needsEndCorrection = needs
            }
        }

        actions.onVisibleIDsChanged = { [weak coordinator] ids in
            guard let coordinator, !coordinator.isDismantled else { return }
            if viewport.ids != ids {
                viewport.ids = ids
            }
        }

        actions.onActiveTurnChanged = { [weak coordinator] turnID in
            guard let coordinator, !coordinator.isDismantled else { return }
            if chrome.activeTurnID != turnID {
                chrome.activeTurnID = turnID
            }
        }

        actions.onScrollPhaseChanged = { [weak coordinator] label in
            guard let coordinator, !coordinator.isDismantled else { return }
            if viewport.scrollPhaseLabel != label {
                viewport.scrollPhaseLabel = label
            }
        }

        actions.onScrollDelta = { [weak coordinator] deltaY, distanceFromBottom, isScrollable in
            guard let coordinator, !coordinator.isDismantled else { return }
            chromeCoordinator.handleUserScroll(
                deltaY: deltaY,
                distanceFromBottom: distanceFromBottom,
                isScrollable: isScrollable
            )
        }

        actions.onKeyboardVisibilityChanged = { [weak coordinator] isOpen in
            guard let coordinator, !coordinator.isDismantled else { return }
            chromeCoordinator.syncLocks(keyboardOpen: isOpen)
        }

        actions.onProgrammaticScroll = { [weak coordinator] in
            guard let coordinator, !coordinator.isDismantled else { return }
            chromeCoordinator.markProgrammaticScroll()
        }

        actions.onDragStarted = { [weak coordinator] in
            guard let coordinator, !coordinator.isDismantled else { return }
            onDragStarted()
        }

        actions.onScrollEnded = { [weak coordinator] in
            guard let coordinator, !coordinator.isDismantled else { return }
            onScrollEnded()
        }

        actions.onPickStarter = { [weak coordinator] text in
            guard let coordinator, !coordinator.isDismantled else { return }
            onPickStarter(text)
        }

        actions.onPreparePhotoHero = { [weak coordinator] target in
            guard let coordinator, !coordinator.isDismantled else { return }
            if photoHero != target {
                photoHero = target
            }
            bridge.matchedHeroID = target.id
        }

        actions.onClearPhotoHero = { [weak coordinator] id in
            guard let coordinator, !coordinator.isDismantled else { return }
            if bridge.matchedHeroID == id {
                bridge.matchedHeroID = nil
            }
            if photoHero?.id == id {
                photoHero = nil
            }
        }

        actions.currentPreparedHeroID = { [weak coordinator] in
            guard let coordinator, !coordinator.isDismantled else { return nil }
            return photoHero?.id
        }

        bridge.onDismissPhotoHero = { [weak coordinator] dismissedID in
            guard let coordinator, !coordinator.isDismantled else { return }
            if bridge.matchedHeroID == dismissedID {
                bridge.matchedHeroID = nil
            }
            if photoHero?.id == dismissedID {
                photoHero = nil
            }
        }
    }

    @MainActor
    final class Coordinator {
        var lastStyleSignal: String
        var actions: ChatListActions?
        var ownedSelectionIDs: Set<UUID> = []
        var isDismantled = false
        var onClearSelection: ((UUID, Bool) -> Void)?
        weak var petPerch: PetPerch?
        weak var listProxy: ChatListControllerProxy?

        init(lastStyleSignal: String) {
            self.lastStyleSignal = lastStyleSignal
        }
    }
}

/// Isolated hero fallback view so `ChatUIKitContainer.body` does not read `Ink.paperRaised`, `Ink.Radius.small`, or `ChatCellMetrics.photoSize`,
/// and horizontal container drags do not trigger geometry updates when `hero == nil`.
private struct ChatPhotoHeroPreviewView: View {
    let hero: ChatPhotoHeroTarget?
    let namespace: Namespace.ID

    var body: some View {
        if let hero {
            GeometryReader { proxy in
                let frame = proxy.frame(in: .global)
                let rect = CGRect(
                    x: hero.globalRect.minX - frame.minX,
                    y: hero.globalRect.minY - frame.minY,
                    width: max(1, hero.globalRect.width),
                    height: max(1, hero.globalRect.height)
                )
                heroLayer(hero: hero, rect: rect)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        } else {
            let idleRect = CGRect(x: 0, y: 0, width: ChatCellMetrics.photoSize, height: ChatCellMetrics.photoSize)
            heroLayer(hero: nil, rect: idleRect)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func heroLayer(hero: ChatPhotoHeroTarget?, rect: CGRect) -> some View {
        let heroID = hero?.id ?? "__clio-photo-hero-idle__"
        return Group {
            if let image = hero?.image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Ink.paperRaised.opacity(0.7)
            }
        }
        .frame(width: rect.width, height: rect.height)
        .clipShape(.rect(cornerRadius: Ink.Radius.small, style: .continuous))
        .modifier(PhotoZoomSourceModifier(id: heroID, namespace: namespace, enabled: true))
        .position(x: rect.midX, y: rect.midY)
    }
}
